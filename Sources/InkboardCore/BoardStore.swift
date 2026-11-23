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
        return try JSONEncoder().encode(File(strokes: strokes, images: images, labels: labels.isEmpty ? nil : labels))
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
        return Board(strokes: strokes, images: images, labels: labels)
    }
}
