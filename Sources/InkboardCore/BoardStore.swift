import CoreGraphics
import Foundation

/// JSON persistence. Points are stored flat as [x, y, pressure, x, y, pressure, ...]
/// rounded to 1/100 unit, which keeps files small and diff-friendly.
///
/// Version 2 added `images`: each picture's frame `[x, y, width, height]` and its PNG / JPEG
/// bytes (base64), and `labels`: the type of a line or drawing (`{"strokes": [ids], "kind"}`, see
/// `Board.labels`). Version 1 files (ink only) still open.
public enum BoardStore {
    public static let version = 2

    struct File: Codable {
        var version = BoardStore.version
        var strokes: [Record]
        var images: [ImageRecord]?
        var labels: [LabelRecord]?
        var groups: [LabelRecord]?
    }

    struct Record: Codable {
        var id: UUID
        var width: Double
        var points: [Double]
    }

    struct ImageRecord: Codable {
        var id: UUID
        var frame: [Double]
        var data: Data
    }

    struct LabelRecord: Codable {
        var strokes: [UUID]
        var kind: String
    }

    private static func r(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }

    public static func encode(_ board: Board) throws -> Data {
        try JSONEncoder().encode(file(for: board))
    }

    private static func file(for board: Board) -> File {
        let strokes = board.strokes.map { stroke in
            Record(id: stroke.id,
                   width: Double(stroke.width),
                   points: stroke.points.flatMap { [r($0.x), r($0.y), r($0.pressure)] })
        }
        let images = board.images.map { image in
            ImageRecord(id: image.id,
                        frame: [r(image.frame.minX), r(image.frame.minY), r(image.frame.width), r(image.frame.height)],
                        data: image.data)
        }
        // Labels whose strokes are gone can never match again; sorted so saving is deterministic.
        let present = Set(board.strokes.map(\.id))
        let labels = board.labels.filter { $0.key.isSubset(of: present) }
            .map { LabelRecord(strokes: $0.key.sorted { $0.uuidString < $1.uuidString }, kind: $0.value.rawValue) }
            .sorted { ($0.strokes.first?.uuidString ?? "") < ($1.strokes.first?.uuidString ?? "") }
        let groups = board.groups.compactMap { $0.restricted(to: present) }
            .map { LabelRecord(strokes: sortedIDs($0.ids), kind: $0.kind.rawValue) }
        return File(strokes: strokes, images: images, labels: labels.isEmpty ? nil : labels,
                    groups: groups.isEmpty ? nil : groups)
    }

    public static func decode(_ data: Data) throws -> Board {
        let file = try JSONDecoder().decode(File.self, from: data)
        let strokes = file.strokes.compactMap { record -> Stroke? in
            let flat = record.points
            guard flat.count >= 3 else { return nil }
            let points = stride(from: 0, to: flat.count - 2, by: 3).map {
                InkPoint(x: flat[$0], y: flat[$0 + 1], pressure: flat[$0 + 2])
            }
            return Stroke(id: record.id, points: points, width: record.width)
        }
        let images = (file.images ?? []).compactMap { record -> BoardImage? in
            let f = record.frame
            guard f.count == 4, f[2] > 0, f[3] > 0 else { return nil }
            return BoardImage(id: record.id, data: record.data, frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]))
        }
        let present = Set(strokes.map(\.id))
        var labels: [Set<UUID>: InkBlock.Kind] = [:]
        for record in file.labels ?? [] {
            let key = Set(record.strokes)
            if !key.isEmpty, key.isSubset(of: present), let kind = InkBlock.Kind(rawValue: record.kind) { labels[key] = kind }
        }
        let groups = (file.groups ?? []).compactMap { record -> BlockGroup? in
            guard let kind = InkBlock.Kind(rawValue: record.kind), kind != .image, kind != .figure else { return nil }
            return BlockGroup(ids: Set(record.strokes), kind: kind).restricted(to: present)
        }
        return Board(strokes: strokes, images: images, labels: labels, groups: groups)
    }
}

// MARK: - 自动检查 results (optional "autoCheck" object in the same file)

extension BoardStore {
    /// The board plus the 自动检查 state (omitted from the file when `autoCheck.isEmpty`).
    public static func encode(_ board: Board, autoCheck: AutoCheckState) throws -> Data {
        let state = pruned(autoCheck, board: board)
        guard !state.isEmpty else { return try encode(board) }
        let stored = StoredState(enabled: state.enabled, nextTag: state.nextTag, checks: state.checks.map {
            StoredCheck(tag: $0.tag, strokes: sortedIDs($0.ids), reading: $0.reading, dismissed: $0.dismissed, issues: $0.issues)
        }, pages: state.pages.map {
            StoredPage(ids: sortedIDs($0.ids), rect: [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height],
                       tags: $0.tags, markdown: $0.markdown)
        })
        return try JSONEncoder().encode(CheckedFile(board: file(for: board), extra: Envelope(autoCheck: stored)))
    }

    /// The 自动检查 state stored in a file (empty when there is none). Checks and pages that share
    /// no id with `board` are dropped.
    public static func decodeAutoCheck(_ data: Data, board: Board) -> AutoCheckState {
        guard let stored = try? JSONDecoder().decode(Envelope.self, from: data).autoCheck else { return AutoCheckState() }
        let checks = stored.checks.map { BlockCheck(tag: $0.tag, ids: Set($0.strokes), reading: $0.reading,
                                                   issues: $0.issues, dismissed: $0.dismissed) }
        let pages = stored.pages.compactMap { page -> FixedPage? in
            let r = page.rect
            guard r.count == 4, r[2] > 0, r[3] > 0 else { return nil }
            return FixedPage(ids: Set(page.ids), rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
                             tags: page.tags, markdown: page.markdown)
        }
        guard stored.nextTag > 0, stored.nextTag < Int.max else { return AutoCheckState() }
        return pruned(AutoCheckState(enabled: stored.enabled, checks: checks, pages: pages, nextTag: stored.nextTag), board: board)
    }

    private static func sortedIDs(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.uuidString < $1.uuidString }
    }

    private static func pruned(_ state: AutoCheckState, board: Board) -> AutoCheckState {
        var kept = state
        let strokes = Set(board.strokes.map(\.id))
        let all = strokes.union(board.images.map(\.id))
        kept.checks.removeAll { $0.ids.isDisjoint(with: strokes) }
        kept.pages.removeAll { $0.ids.isDisjoint(with: all) }
        return kept
    }

    private struct CheckedFile: Encodable {
        var board: File
        var extra: Envelope

        func encode(to encoder: Encoder) throws {
            try board.encode(to: encoder)
            try extra.encode(to: encoder)
        }
    }

    private struct Envelope: Codable { var autoCheck: StoredState }
    private struct StoredState: Codable {
        var enabled: Bool
        var nextTag: Int
        var checks: [StoredCheck]
        var pages: [StoredPage]
    }
    private struct StoredCheck: Codable {
        var tag: String
        var strokes: [UUID]
        var reading: String
        var dismissed: Bool
        var issues: [CheckIssue]
    }
    private struct StoredPage: Codable {
        var ids: [UUID]
        var rect: [CGFloat]
        var tags: [String]
        var markdown: String
    }
}
