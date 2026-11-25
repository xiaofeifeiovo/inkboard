import CoreGraphics
import Foundation

// MARK: - 自动错误检查 (auto check): shared model
//
// Design: docs/auto-check.md. While the user writes, every finished block is sent to the AI, which
// judges it in the context of what came before; problems are boxed on the canvas (red = error,
// yellow = warning). This file holds the pure parts: results and what is stored in the document,
// check units and their identity (by stroke ids, like `Board.labels`), "a block is finished"
// detection, fixed pages, and reading the AI's answers. The scheduler is `AutoChecker`, prompts are
// in `AutoCheckPrompts`, the tagged images in `AutoCheckRender`.

// MARK: - Results

public enum CheckSeverity: String, CaseIterable, Comparable, Codable {
    /// Inaccurate but not serious (a missing subscript).
    case warning
    /// Serious: affects what follows (a wrong formula, a wrong definition).
    case error

    public static func < (a: CheckSeverity, b: CheckSeverity) -> Bool { a == .warning && b == .error }
}

public struct CheckIssue: Equatable, Codable {
    public var severity: CheckSeverity
    /// One sentence.
    public var summary: String
    /// Which line, what is wrong, why, and what it should be.
    public var detail: String
    /// Tags of related blocks ("B5"), e.g. one this block contradicts.
    public var related: [String]

    public init(severity: CheckSeverity, summary: String, detail: String = "", related: [String] = []) {
        self.severity = severity
        self.summary = summary
        self.detail = detail
        self.related = related
    }
}

/// The AI's verdict on one block.
public struct BlockCheck: Equatable {
    /// "B12": given when the block is first sent, never renumbered (it names the block in a conversation).
    public var tag: String
    /// The block's strokes when it was checked. A block whose strokes differ has been modified since.
    public var ids: Set<UUID>
    /// What the AI read (formulas in LaTeX), shown in 详情 so the user can tell a misread.
    public var reading: String
    /// Empty: no problem.
    public var issues: [CheckIssue]
    /// 忽视: the box is hidden until the block is checked again.
    public var dismissed: Bool

    public init(tag: String, ids: Set<UUID>, reading: String = "", issues: [CheckIssue] = [], dismissed: Bool = false) {
        self.tag = tag
        self.ids = ids
        self.reading = reading
        self.issues = issues
        self.dismissed = dismissed
    }

    /// The most serious issue; nil when there is none.
    public var severity: CheckSeverity? { issues.map(\.severity).max() }
}

/// A page whose transcription is done. It no longer moves: open pages are assembled after it, and
/// its Markdown is the context of later pages (and reused by 全局转换 while it is unchanged).
public struct FixedPage: Equatable {
    /// Strokes and pictures on the page when it was fixed.
    public var ids: Set<UUID>
    /// The page's area when it was fixed (canvas coordinates).
    public var rect: CGRect
    /// Tags of the blocks on the page, in reading order.
    public var tags: [String]
    /// Markdown with "<!-- B12 -->" before each block (see `AutoCheckReply.blockComment`).
    public var markdown: String

    public init(ids: Set<UUID>, rect: CGRect, tags: [String], markdown: String) {
        self.ids = ids
        self.rect = rect
        self.tags = tags
        self.markdown = markdown
    }
}

/// Everything 自动检查 keeps in the document. Not part of `Board`: results arrive asynchronously
/// and must stay out of undo (⌘Z must undo the last stroke, not the last result).
public struct AutoCheckState: Equatable {
    /// The 自动检查 switch, remembered per document. Off by default.
    public var enabled: Bool
    /// One per tag.
    public var checks: [BlockCheck]
    /// In page order.
    public var pages: [FixedPage]
    /// Number of the next tag to hand out (B1, B2…). Tags are never reused.
    public var nextTag: Int

    public init(enabled: Bool = false, checks: [BlockCheck] = [], pages: [FixedPage] = [], nextTag: Int = 1) {
        self.enabled = enabled
        self.checks = checks
        self.pages = pages
        self.nextTag = nextTag
    }

    /// Nothing worth saving.
    public var isEmpty: Bool { !enabled && checks.isEmpty && pages.isEmpty }

    /// Hands out the next tag ("B7").
    public mutating func allocateTag() -> String {
        defer { nextTag += 1 }
        return "B\(nextTag)"
    }

    public func check(tagged tag: String) -> BlockCheck? {
        checks.first { $0.tag == tag }
    }

    /// Adds `check`, or replaces the one with the same tag.
    public mutating func setCheck(_ check: BlockCheck) {
        if let i = checks.firstIndex(where: { $0.tag == check.tag }) { checks[i] = check } else { checks.append(check) }
    }
}

// MARK: - The AI side

/// A multi-turn conversation with a model: each `send` adds a user turn and returns the reply,
/// which joins the history. ACP keeps the history in the agent's session; the OpenAI-compatible
/// backend keeps the message list itself and sends all of it every time.
public protocol ModelConversation: AnyObject {
    /// Never called concurrently. Cancelling the calling task cancels the turn.
    func send(_ parts: [PromptPart]) async throws -> String
    /// False once the conversation can't go on (the agent exited or was replaced, it was closed,
    /// or a turn failed): open a new one.
    var isUsable: Bool { get }
    func close()
}

/// What `AutoChecker` needs from the AI. `AITranscriber` implements it with the model chosen for
/// 自动检查 in 设置; the self-check uses a scripted fake.
public protocol AutoCheckService: AnyObject {
    /// Starts the backend ahead of a request (may do nothing).
    func prepare()
    /// Opens a conversation with the 自动检查 model and thinking level.
    func openCheckConversation() async throws -> ModelConversation
    /// One independent request with the 自动检查 model (a page request, a transcription, a text-only re-check).
    func sendCheckRequest(_ parts: [PromptPart]) async throws -> String
    /// The 全局转换 prompt (from 设置): page transcriptions are built on it.
    func documentPrompt() throws -> String
}

// MARK: - Check units

/// What gets checked and boxed: a top-level block other than a bare picture, or the ink on a
/// picture (each child of a figure block; the picture itself is context, not checked).
public struct CheckUnit: Equatable {
    /// Its strokes: the unit's identity (compared with `BlockCheck.ids`).
    public var ids: Set<UUID>
    /// The same strokes in writing order.
    public var strokeIDs: [UUID]
    public var bounds: CGRect
    public var kind: InkBlock.Kind
    /// Pictures under the ink (figure children): drawn with the unit when it is rendered.
    public var imageIDs: [UUID]
    /// Index of the top-level block it comes from, in `InkLayout.analyze(_:).blocks`.
    public var blockIndex: Int

    public init(ids: Set<UUID>, strokeIDs: [UUID], bounds: CGRect, kind: InkBlock.Kind, imageIDs: [UUID] = [], blockIndex: Int) {
        self.ids = ids
        self.strokeIDs = strokeIDs
        self.bounds = bounds
        self.kind = kind
        self.imageIDs = imageIDs
        self.blockIndex = blockIndex
    }
}

public enum AutoCheckTracker {
    /// Units in reading order (see `CheckUnit`). Blocks without strokes give no unit.
    public static func units(in blocks: [InkBlock]) -> [CheckUnit] {
        var result: [CheckUnit] = []
        func visit(_ block: InkBlock, images: [UUID], index: Int) {
            if block.kind == .figure {
                let background = images + block.imageIDs.filter { !images.contains($0) }
                for child in block.children { visit(child, images: background, index: index) }
            } else if block.kind != .image, !block.strokeIDs.isEmpty {
                result.append(CheckUnit(ids: Set(block.strokeIDs), strokeIDs: block.strokeIDs, bounds: block.bounds,
                                        kind: block.kind, imageIDs: images, blockIndex: index))
            }
        }
        for (index, block) in blocks.enumerated() { visit(block, images: [], index: index) }
        return result
    }

    public enum Status: Equatable {
        /// No check shares a stroke with it.
        case unchecked
        /// Exactly the strokes of the check with this tag.
        case checked(tag: String)
        /// Shares strokes with one or more checks but differs (strokes added, erased, split or
        /// merged). `tag` is the check it overlaps most (ties: the lower tag number).
        case modified(tag: String)
    }

    public static func status(of unit: CheckUnit, in checks: [BlockCheck]) -> Status {
        var best: BlockCheck?
        var bestScore = (0, 0, Int.min)
        for check in checks {
            let overlap = unit.ids.intersection(check.ids).count
            guard overlap > 0 else { continue }
            let score = (unit.ids == check.ids ? 1 : 0, overlap, -(tagNumber(check.tag) ?? Int.max))
            if score > bestScore { best = check; bestScore = score }
        }
        guard let best else { return .unchecked }
        return best.ids == unit.ids ? .checked(tag: best.tag) : .modified(tag: best.tag)
    }

    /// The unit only grew from `check`: every stroke of `check` is still in it, it has new strokes,
    /// and it shares no stroke with any other check in `checks`. ("接着写", docs/auto-check.md §3.)
    public static func isContinuation(_ unit: CheckUnit, of check: BlockCheck, in checks: [BlockCheck]) -> Bool {
        !check.ids.isEmpty && check.ids.isStrictSubset(of: unit.ids)
            && checks.allSatisfy { $0.tag == check.tag || $0.ids.isDisjoint(with: unit.ids) }
    }

    /// Prior checks wholly contained in a growing or merged unit, in numeric tag order.
    /// A partial overlap, an unchanged single check, or no overlap gives nil.
    public static func grownFrom(_ unit: CheckUnit, in checks: [BlockCheck]) -> [BlockCheck]? {
        let overlaps = checks.filter { !$0.ids.isDisjoint(with: unit.ids) }
        guard let first = overlaps.first,
              overlaps.allSatisfy({ $0.ids.isSubset(of: unit.ids) }),
              overlaps.count > 1 || first.ids != unit.ids else { return nil }
        return overlaps.sorted { (tagNumber($0.tag) ?? Int.max) < (tagNumber($1.tag) ?? Int.max) }
    }

    /// "B12" → 12; nil when it isn't a tag.
    public static func tagNumber(_ tag: String) -> Int? {
        let t = tag.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.hasPrefix("B"), t.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(t.dropFirst()), n > 0 else { return nil }
        return n
    }
}

/// Tells when a block is finished: only when the user starts writing in another block (no pause
/// timer — the user may be thinking). docs/auto-check.md §3.
public struct WritingTracker: Equatable {
    /// The stroke written last; nil before any writing.
    public private(set) var lastStroke: UUID?
    /// Strokes of the block being written (as of the last stroke).
    public private(set) var writingIDs: Set<UUID>

    public init() {
        lastStroke = nil
        writingIDs = []
    }

    /// Call after a stroke is committed. Surviving parts of the previous writing block
    /// outside the new stroke's unit have finished, in the supplied units' reading order.
    public mutating func didWriteUnits(_ stroke: UUID, units: [CheckUnit]) -> [CheckUnit] {
        let previous = writingIDs
        let current = units.first { $0.ids.contains(stroke) }
        lastStroke = stroke
        writingIDs = current?.ids ?? []
        guard current != nil, !previous.isEmpty else { return [] }
        return units.filter { !$0.ids.contains(stroke) && !$0.ids.isDisjoint(with: previous) }
    }

    /// Returns only the first finished unit. Use didWriteUnits to handle every part of a split.
    public mutating func didWrite(_ stroke: UUID, units: [CheckUnit]) -> CheckUnit? {
        didWriteUnits(stroke, units: units).first
    }

    /// The unit being written: the one holding the last stroke (nil if it was erased).
    public func currentUnit(in units: [CheckUnit]) -> CheckUnit? {
        lastStroke.flatMap { last in units.first { $0.ids.contains(last) } }
    }

    /// Forgets the writing (new document content loaded, 自动检查 switched off).
    public mutating func reset() {
        self = WritingTracker()
    }
}

// MARK: - Fixed and open pages

public enum AutoCheckPages {
    /// The fixed page (index in `fixed`) a top-level block belongs to: the page it shares content
    /// with (most shared ids), or — new content — the page whose rect holds most of it. Nil: the
    /// block is on an open page. New content must overlap at least half its area. Ties use the earlier page.
    public static func fixedPageIndex(of block: InkBlock, fixed: [FixedPage]) -> Int? {
        var best: Int?
        var bestCount = 0
        let ids = block.ids
        for index in fixed.indices {
            let count = fixed[index].ids.intersection(ids).count
            if count > bestCount { bestCount = count; best = index }
        }
        if let best { return best }
        var bestArea: CGFloat = 0
        let area = block.bounds.width * block.bounds.height
        for index in fixed.indices {
            let overlap = fixed[index].rect.intersection(block.bounds)
            guard !overlap.isEmpty else { continue }
            let shared = overlap.width * overlap.height
            if shared >= area / 2, shared > bestArea { bestArea = shared; best = index }
        }
        return best
    }

    /// Blocks on no fixed page, packed into pages with `PageAssembler` (in reading order). The
    /// first one is the current page.
    public static func openPages(blocks: [InkBlock], fixed: [FixedPage], options: PageAssembler.Options) -> [InkPage] {
        PageAssembler.pages(for: blocks.filter { fixedPageIndex(of: $0, fixed: fixed) == nil }, options: options)
    }

    /// The page's content differs from when it was fixed: some of its ids are gone, or the blocks
    /// that belong to it now hold other ids (strokes added, moved in or out).
    public static func isModified(_ page: FixedPage, at index: Int, blocks: [InkBlock], fixed: [FixedPage]) -> Bool {
        let currentIDs = blocks.reduce(into: Set<UUID>()) { ids, block in
            if fixedPageIndex(of: block, fixed: fixed) == index { ids.formUnion(block.ids) }
        }
        return page.ids != currentIDs
    }
}

// MARK: - Reading the AI's answers

public enum AutoCheckReply {
    /// The verdict on one block, as answered.
    public struct BlockResult: Equatable {
        public var tag: String
        public var reading: String
        public var issues: [CheckIssue]

        public init(tag: String, reading: String, issues: [CheckIssue]) {
            self.tag = tag
            self.reading = reading
            self.issues = issues
        }
    }

    /// The line between the JSON and the Markdown in a page request's answer.
    public static let pageMarker = "<!-- PAGE -->"

    /// "<!-- B12 -->": put before each block in a page transcription.
    public static func blockComment(_ tag: String) -> String { "<!-- \(tag) -->" }

    /// Reads `{"blocks": [{"id", "reading", "issues": [{"severity", "summary", "detail", "related"}]}]}`.
    /// Lenient like `BlockLabeling.parse`: code fences and text around the JSON, tag case ("b12"),
    /// LaTeX backslashes left unescaped inside JSON strings ("\frac" must not become a form feed).
    /// Tags not in `expected` and unknown severities are skipped; a tag answered twice keeps the
    /// first. Throws `AutoCheckError.unreadableReply` when no JSON object can be read.
    public static func parseChecks(_ reply: String, expected: Set<String>) throws -> [BlockResult] {
        let allowed = Set(expected.compactMap(normalizedTag))
        var seen = Set<String>()
        guard let blocks = replyBlocks(reply) else { throw AutoCheckError.unreadableReply(reply) }
        return blocks.compactMap { block in
            guard let id = block["id"] as? String, let tag = normalizedTag(id),
                  allowed.contains(tag), seen.insert(tag).inserted else { return nil }
            let issues = (block["issues"] as? [Any] ?? []).compactMap { value -> CheckIssue? in
                guard let issue = value as? JSONObject, let raw = issue["severity"] as? String,
                      let severity = CheckSeverity(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                      let summary = issue["summary"] as? String else { return nil }
                let related = (issue["related"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(normalizedTag) }
                return CheckIssue(severity: severity, summary: summary, detail: issue["detail"] as? String ?? "", related: related)
            }
            return BlockResult(tag: tag, reading: block["reading"] as? String ?? "", issues: issues)
        }
    }

    private static func normalizedTag(_ value: String) -> String? {
        AutoCheckTracker.tagNumber(value.trimmingCharacters(in: .whitespacesAndNewlines)).map { "B\($0)" }
    }

    // Read one balanced object at a time. Repair ambiguous escapes only inside string literals.
    private static func replyBlocks(_ reply: String) -> [JSONObject]? {
        let chars = Array(reply)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else { index += 1; continue }
            var json = ""
            var depth = 0
            var quoted = false
            repeat {
                let char = chars[index]
                index += 1
                json.append(char)
                if quoted, char == "\\", index < chars.count {
                    let escape = chars[index]
                    let tail = chars[(index + 1)...]
                    if !isJSONEscape(escape, followedBy: tail) { json.append("\\") }
                    json.append(escape)
                    index += 1
                } else if char == "\"" {
                    quoted.toggle()
                } else if !quoted {
                    if char == "{" { depth += 1 }
                    if char == "}" { depth -= 1 }
                }
            } while depth > 0 && index < chars.count
            if let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? JSONObject,
               let blocks = object["blocks"] as? [Any] { return blocks.compactMap { $0 as? JSONObject } }
        }
        return nil
    }

    private static func isJSONEscape(_ escape: Character, followedBy tail: ArraySlice<Character>) -> Bool {
        switch escape {
        case "\\", "\"", "/":
            return true
        case "u":
            return tail.count >= 4 && tail.prefix(4).allSatisfy { $0.isASCII && $0.isHexDigit }
        case "b", "f", "n", "r", "t":
            // A letter after \f in \frac, for example, indicates a raw LaTeX command.
            return !(tail.first.map { $0.isASCII && $0.isLetter } ?? false)
        default:
            return false
        }
    }

    /// A page request's answer: the JSON (as `parseChecks`), the `pageMarker` line, then the page's
    /// Markdown (cleaned like `TranscriptCleanup.markdown`). Throws when the JSON can't be read;
    /// a missing marker leaves the Markdown empty.
    public static func parsePageCheck(_ reply: String, expected: Set<String>) throws -> (checks: [BlockResult], markdown: String) {
        // Usually on a line of its own, but models sometimes put it right after the JSON's last brace.
        guard let marker = reply.range(of: pageMarker) else {
            return (try parseChecks(reply, expected: expected), "")
        }
        let checks = try parseChecks(String(reply[..<marker.lowerBound]), expected: expected)
        return (checks, parseTranscription(String(reply[marker.upperBound...])))
    }

    /// A page transcription (Markdown with block comments), cleaned like `TranscriptCleanup.markdown`.
    public static func parseTranscription(_ reply: String) -> String {
        TranscriptCleanup.markdown(reply)
    }

    /// The Markdown without "<!-- Bn -->" comments (and the blank lines they leave), for 全局转换.
    public static func stripBlockComments(_ markdown: String) -> String {
        let pattern = #"<!--[ \t]*B[0-9]+[ \t]*-->"#
        let markerLine = #"(?m)^[ \t]*"# + pattern + #"[ \t]*(?:\r?\n|$)"#
        // When Markdown treats the marker as its own paragraph, remove its extra separator too.
        let paragraph = #"(?m)(?:\A|(?<=\n\n)|(?<=\r\n\r\n))[ \t]*"# + pattern + #"[ \t]*\r?\n[ \t]*\r?\n"#
        return markdown.replacingOccurrences(of: paragraph, with: "", options: .regularExpression)
            .replacingOccurrences(of: markerLine, with: "", options: .regularExpression)
            .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

public enum AutoCheckError: LocalizedError {
    case unreadableReply(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableReply(let reply):
            return "模型的回答不是预期的 JSON 格式：\n\n" + String(reply.prefix(300))
        }
    }
}
