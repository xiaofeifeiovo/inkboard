import CoreGraphics
import Foundation
import ImageIO
import InkboardCore

// 自动检查: scheduler checks (AutoChecker with a scripted AutoCheckService) and tagged rendering.
// Called from main.swift. Nothing here depends on the wording of AutoCheckPrompts: requests are
// recognised by comparing parts with the prompt functions' own output.

/// A scripted AI: records every request, answers with canned JSON / Markdown.
final class FakeCheckService: AutoCheckService {
    enum Request {
        /// A turn of conversation number `conversation` (1-based).
        case turn(Int, [PromptPart])
        case independent([PromptPart])

        var parts: [PromptPart] {
            switch self {
            case .turn(_, let parts), .independent(let parts): return parts
            }
        }
    }

    static let documentPrompt = "DOCUMENT PROMPT"

    var log: [Request] = []
    var conversationsOpened = 0
    /// Issues reported for a tag (every other tag: no issue).
    var issues: [String: [CheckIssue]] = [:]
    /// Requests wait for `release()` while true.
    var hold = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The next request fails with this message.
    var failNext: String?
    /// Page transcriptions handed out so far.
    var transcriptions = 0

    func prepare() {}

    func openCheckConversation() async throws -> ModelConversation {
        conversationsOpened += 1
        return FakeConversation(service: self, number: conversationsOpened)
    }

    func sendCheckRequest(_ parts: [PromptPart]) async throws -> String {
        log.append(.independent(parts))
        try await gate()
        if case .text(let first) = parts.first, first == Self.documentPrompt {
            transcriptions += 1
            return "<!-- B1 -->\nPAGE-MARKDOWN-\(transcriptions)\n"
        }
        if case .text(let first) = parts.first, first == AutoCheckPrompts.pageRequestIntro {
            transcriptions += 1
            return verdicts() + "\n\(AutoCheckReply.pageMarker)\n<!-- B1 -->\nPAGE-MARKDOWN-\(transcriptions)\n"
        }
        return verdicts()
    }

    func documentPrompt() throws -> String { Self.documentPrompt }

    func gate() async throws {
        if let message = failNext {
            failNext = nil
            throw NSError(domain: "FakeCheckService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if hold { await withCheckedContinuation { waiting.append($0) } }
    }

    func release() {
        hold = false
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }

    /// Simulates a valid reply that skips one of the requested blocks.
    var omittedTag: String?

    /// A verdict for every non-omitted tag up to B40; the checker only reads the ones it asked for.
    func verdicts() -> String {
        let blocks = (1...40).compactMap { n -> [String: Any]? in
            let tag = "B\(n)"
            guard tag != omittedTag else { return nil }
            return ["id": tag, "reading": "reading of \(tag)",
                    "issues": (issues[tag] ?? []).map { ["severity": $0.severity.rawValue, "summary": $0.summary,
                                                         "detail": $0.detail, "related": $0.related] }]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["blocks": blocks])
        return String(data: data, encoding: .utf8)!
    }

    var turns: [[PromptPart]] { log.compactMap { if case .turn(_, let parts) = $0 { return parts }; return nil } }
    var independents: [[PromptPart]] { log.compactMap { if case .independent(let parts) = $0 { return parts }; return nil } }
}

final class FakeConversation: ModelConversation {
    weak var service: FakeCheckService?
    let number: Int
    private(set) var isUsable = true

    init(service: FakeCheckService, number: Int) {
        self.service = service
        self.number = number
    }

    func send(_ parts: [PromptPart]) async throws -> String {
        guard let service else { throw CancellationError() }
        service.log.append(.turn(number, parts))
        do {
            try await service.gate()
        } catch {
            isUsable = false
            throw error
        }
        return service.verdicts()
    }

    func close() { isUsable = false }
}

private func texts(_ parts: [PromptPart]) -> [String] {
    parts.compactMap { if case .text(let text) = $0 { return text }; return nil }
}

private func pngCount(_ parts: [PromptPart]) -> Int {
    parts.filter { if case .png = $0 { return true }; return false }.count
}

/// Waits (up to 2 s) until `count` requests have reached the fake service.
private func waitForRequests(_ service: FakeCheckService, _ count: Int) async {
    for _ in 0..<2000 where service.log.count < count {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Feeds a checker stroke by stroke, like the canvas does after each pen stroke.
@MainActor
private final class Writer {
    var board = Board()
    let checker: AutoChecker

    init(_ checker: AutoChecker) {
        self.checker = checker
    }

    func write(_ strokes: [Stroke]) {
        for stroke in strokes {
            board.strokes.append(stroke)
            checker.boardDidChange(board, addedStroke: stroke.id)
        }
    }

    /// Changes that are not writing (erasing, moving, undo).
    func edit(_ change: (inout Board) -> Void) {
        change(&board)
        checker.boardDidChange(board)
    }

    func mark(containing stroke: Stroke) -> AutoChecker.Mark? {
        checker.marks.first { $0.ids.contains(stroke.id) }
    }

    /// The block holding `stroke` is the one being written.
    func isWriting(_ stroke: Stroke) -> Bool {
        checker.writingUnit?.ids.contains(stroke.id) == true
    }

    func isChecking(_ stroke: Stroke) -> Bool {
        checker.checkingUnits.contains { $0.ids.contains(stroke.id) }
    }

    func isQueued(_ stroke: Stroke) -> Bool {
        checker.queuedUnits.contains { $0.ids.contains(stroke.id) }
    }
}

/// One-line blocks 80 apart: separate blocks, two per page with `smallPages`.
private func blockLine(_ index: Int) -> [Stroke] {
    textLine(x: 20, baseline: 40 + CGFloat(index) * 80, words: [3, 2])
}

private var smallPages: PageAssembler.Options {
    var options = PageAssembler.Options()
    options.minWidth = 100
    return options
}

@MainActor
func runAutoCheckerChecks() async {
    let error = [CheckIssue(severity: .error, summary: "wrong", detail: "line 1", related: ["B1"])]
    let warning = [CheckIssue(severity: .warning, summary: "subscript")]

    // Pages: two blocks per page (checked here so the other tests can rely on it).
    do {
        let board = Board(strokes: (0..<4).flatMap(blockLine))
        let blocks = InkLayout.analyze(board).blocks
        let pages = PageAssembler.pages(for: blocks, options: smallPages)
        check(blocks.count == 4 && pages.map(\.blocks.count) == [2, 2], "test layout: 4 one-line blocks, 2 per page (\(describe(blocks)), pages \(pages.map(\.blocks.count)))")
    }

    // Trigger: a block is sent when writing starts in another one; the first turn has the intro.
    do {
        let service = FakeCheckService()
        service.issues["B1"] = error
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        var saved: [AutoCheckState] = []
        checker.onStateChange = { saved.append($0) }
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        check(service.log.isEmpty && checker.state.enabled, "switching on with an empty board sends nothing")

        let a = blockLine(0), b = blockLine(1)
        writer.write(a)
        await checker.waitUntilIdle()
        check(service.log.isEmpty, "nothing is sent while the first block is being written")
        check(writer.mark(containing: a[0]) == nil && writer.isWriting(a[0]),
              "the block being written has no mark; the checker reports it as being written")

        writer.write([b[0]])
        check(writer.mark(containing: a[0]) == nil && writer.isChecking(a[0]) && !writer.isWriting(a[0]),
              "the finished block is being checked at once, with no mark on the canvas")
        check(checker.stage != nil && checker.queuedUnits.isEmpty && checker.fullCheck == nil && checker.failureMessage == nil,
              "…the running request has a stage, nothing else waits")
        await checker.waitUntilIdle()
        check(service.conversationsOpened == 1 && service.turns.count == 1, "starting another block sends the first one (\(service.log.count) requests)")
        let first = service.turns.first ?? []
        check(texts(first).first == AutoCheckPrompts.conversationIntro, "the first turn starts with the conversation intro")
        check(texts(first).contains(AutoCheckPrompts.checkBlock("B1")) && pngCount(first) == 1, "…asks to check B1 with one block image")
        check(!texts(first).contains(AutoCheckPrompts.previousPagesHeading), "…and has no previous pages yet")
        check(checker.state.check(tagged: "B1")?.ids == Set(a.map(\.id)), "the result is stored with the block's strokes")
        check(writer.mark(containing: a[0])?.kind == .issue(.error), "an error gets a red box")
        check(writer.mark(containing: b[0]) == nil && writer.isWriting(b[0]), "the new block being written has no mark")
        check(checker.stage == nil && checker.checkingUnits.isEmpty, "…and nothing is being checked once the answer is in")
        check(saved.last?.checks.count == 1, "results reach the document through onStateChange")
        check(checker.unit(sharing: [a[0].id])?.ids == Set(a.map(\.id)), "a menu item's block is found again from one of its strokes")

        // Dismiss.
        checker.dismiss(tag: "B1")
        check(writer.mark(containing: a[0]) == nil && checker.state.check(tagged: "B1")?.dismissed == true, "忽视 hides the box and is stored")

        // A non-writing edit (erasing a stroke elsewhere) doesn't finish a block.
        writer.write(Array(b.dropFirst()))
        writer.edit { $0.strokes.removeAll { $0.id == b.last!.id } }
        await checker.waitUntilIdle()
        check(service.turns.count == 1, "erasing doesn't count as writing")

        // Switching off hides everything but keeps the results.
        checker.setEnabled(false)
        check(checker.marks.isEmpty && checker.state.checks.count == 1 && !checker.state.enabled, "switching off hides the marks and keeps the results")
    }

    // One request at a time, in order; the conversation is reused; failures pause with retry.
    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let a = blockLine(0), b = blockLine(1), c = blockLine(2)
        service.hold = true
        writer.write(a + [b[0]])
        await waitForRequests(service, 1)
        writer.write(Array(b.dropFirst()) + [c[0]])
        for _ in 0..<5 { await Task.yield() }
        check(service.log.count == 1 && checker.queuedCount == 1, "while a request runs, the next finished block waits (\(service.log.count) sent, \(checker.queuedCount) queued)")
        check(writer.mark(containing: a[0]) == nil && writer.mark(containing: b[0]) == nil, "…neither has a mark on the canvas")
        check(checker.checkingUnits.count == 1 && writer.isChecking(a[0]) && checker.queuedUnits.count == 1 && writer.isQueued(b[0])
              && writer.isWriting(c[0]), "…the checker lists A as being checked, B as queued and C as being written")
        if case .working(.block("B1"), queued: 1) = checker.activity {
            check(true, "the activity names the block and the queue")
        } else {
            check(false, "the activity names the block and the queue (\(checker.activity))")
        }
        service.release()
        await checker.waitUntilIdle()
        check(service.turns.count == 2 && service.conversationsOpened == 1, "the second block goes in the same conversation")
        let second = service.turns.last ?? []
        check(texts(second) == [AutoCheckPrompts.checkBlock("B2")] && pngCount(second) == 1, "a later turn is only the request and the block image")
        check(checker.state.checks.map(\.tag) == ["B1", "B2"], "tags are handed out in writing order")

        // A failure: the job waits, the banner offers 重试.
        service.failNext = "network down"
        writer.write(Array(c.dropFirst()) + [blockLine(3)[0]])   // C finished; D starts on page 2
        await checker.waitUntilIdle()
        if case .failed(let message) = checker.activity {
            check(message.contains("network down"), "a failed request shows its error")
        } else {
            check(false, "a failed request shows its error (\(checker.activity))")
        }
        checker.retry()
        await checker.waitUntilIdle()
        check(checker.activity == .idle && checker.state.checks.count == 3, "重试 sends it again")
    }

    // Page change: the full page is transcribed and fixed, then a new conversation starts with
    // its Markdown as context. Rebuilding a lost conversation re-sends this page's checked blocks.
    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let lines = (0..<6).map(blockLine)
        writer.write(lines[0] + lines[1] + lines[2] + [lines[3][0]])
        await checker.waitUntilIdle()
        check(service.independents.count == 1 && texts(service.independents[0]).first == FakeCheckService.documentPrompt
              && texts(service.independents[0]).contains(AutoCheckPrompts.transcriptionRequirements),
              "a block on the next page first transcribes the current page with the 全局转换 prompt")
        check(checker.state.pages.count == 1 && checker.state.pages[0].tags == ["B1", "B2"]
              && checker.state.pages[0].ids == Set((lines[0] + lines[1]).map(\.id)), "…which becomes a fixed page")
        check(service.conversationsOpened == 2, "…and a new conversation starts")
        let newPage = service.turns.last ?? []
        check(texts(newPage).contains(AutoCheckPrompts.previousPagesHeading) && texts(newPage).contains { $0.contains("PAGE-MARKDOWN-1") },
              "the new conversation's first turn has the previous page's Markdown")
        check(texts(newPage).contains(AutoCheckPrompts.checkBlock("B3")) && pngCount(newPage) == 1, "…and checks B3")

        // Conversation lost (settings changed): rebuilt with the page's checked blocks.
        checker.settingsDidChange()
        writer.write(Array(lines[3].dropFirst()) + [lines[4][0]])
        await checker.waitUntilIdle()
        check(service.conversationsOpened == 3, "a lost conversation is opened again")
        let rebuilt = service.turns.last ?? []
        check(texts(rebuilt).contains(AutoCheckPrompts.checkedBlocksHeading) && texts(rebuilt).contains(AutoCheckPrompts.blockLabel("B3"))
              && texts(rebuilt).contains { $0 == AutoCheckPrompts.previousVerdict(#"{"id":"B3","issues":[],"reading":"reading of B3"}"#) },
              "…with this page's checked blocks and their verdicts")
        check(pngCount(rebuilt) == 2 && texts(rebuilt).contains(AutoCheckPrompts.checkBlock("B4")), "…then the new block (2 images)")
        check(texts(rebuilt).contains { $0.contains("PAGE-MARKDOWN-1") }, "…and the fixed page's Markdown")
    }

    // Continuation vs. modification.
    do {
        let service = FakeCheckService()
        service.issues["B1"] = warning
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let a = blockLine(0), b = blockLine(1), c = blockLine(2)
        // A, then a word far to its right (its own block for now): A is sent (B1).
        let far = glyph(200, 40)
        writer.write(a + [far])
        await checker.waitUntilIdle()
        check(writer.mark(containing: a[0])?.kind == .issue(.warning), "a warning gets a yellow box")

        // Filling the gap from the right joins the two: A only grew, and it was sent last.
        let fill = stride(from: 187, through: 109, by: -13).map { glyph(CGFloat($0), 40) }
        writer.write(fill)
        check(checker.units.count == 1, "setup: the words joined into one block")
        check(writer.mark(containing: a[0]) == nil && writer.isWriting(a[0]),
              "writing on in the block checked last shows no mark (no grey box, no 检查)")
        writer.write([b[0]])
        await checker.waitUntilIdle()
        let recheck = service.turns.last ?? []
        check(service.turns.count == 2 && texts(recheck).contains(AutoCheckPrompts.recheckBlock("B1", later: [])),
              "…and it is re-checked automatically when writing moves on")
        check(checker.state.check(tagged: "B1")?.ids == Set((a + [far] + fill).map(\.id)), "…with its new strokes")

        // B is finished (B2), C started; then A (not the block sent last) is edited: not sent.
        writer.write(Array(b.dropFirst()) + [c[0]])
        await checker.waitUntilIdle()
        writer.write([glyph(213, 40)])   // finishes C's first stroke (B3)
        check(writer.mark(containing: a[0]) == nil && writer.isWriting(a[0]), "going back to write in an older block: no grey box while writing")
        writer.write([c[1]])             // finishes the edited A
        await checker.waitUntilIdle()
        check(service.turns.count == 4 && texts(service.turns.last ?? []).contains(AutoCheckPrompts.checkBlock("B3")),
              "editing an older block sends nothing (only the block it interrupted)")
        check(writer.mark(containing: a[0])?.kind == .modifiedBox, "…its yellow box turns into a grey dashed box with 重新检查")

        // 重新检查 on the open page: a recheck turn naming the later blocks.
        checker.check(Set(a.map(\.id)))
        await checker.waitUntilIdle()
        let manual = service.turns.last ?? []
        check(texts(manual).contains(AutoCheckPrompts.recheckBlock("B1", later: ["B2", "B3"])) && pngCount(manual) == 1,
              "重新检查 on the current page re-sends the block and names the later ones")
        check(service.conversationsOpened == 1, "…in the same conversation")
        check(writer.mark(containing: a[0])?.kind == .issue(.warning), "…and the box comes back with the new verdict")

        // ⇧⌘K: the block being written (C, grown since B3 was sent).
        check(writer.mark(containing: c[0]) == nil, "a queued block is sent as it is when its turn comes (C with 2 strokes)")
        writer.write([c[2]])
        check(writer.mark(containing: c[0]) == nil && writer.isWriting(c[0]) && !writer.isQueued(c[0]),
              "the block being written has no mark, and is reported as being written")
        check(checker.checkLatest(), "检查最新的块 sends the block being written")
        await checker.waitUntilIdle()
        check(texts(service.turns.last ?? []).contains(AutoCheckPrompts.recheckBlock("B3", later: [])), "…as a re-check of B3")
        check(!checker.checkLatest(), "…and does nothing once it is checked")
    }

    // A block on a fixed page: page request, then a text-only re-check of later blocks.
    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let lines = (0..<4).map(blockLine)
        writer.write(lines[0] + lines[1] + lines[2] + [lines[3][0]])   // page 1 fixed, B3 checked
        await checker.waitUntilIdle()
        check(checker.state.pages.count == 1 && checker.state.checks.count == 3, "setup: one fixed page, three checks")

        let extra = glyph(105, 40)
        writer.write([extra])   // edit B1 on the fixed page
        writer.write([lines[3][1]])
        await checker.waitUntilIdle()
        let before = service.log.count
        check(writer.mark(containing: lines[0][0])?.kind == .recheck, "an edited block on a fixed page waits for 重新检查")

        checker.check(Set(lines[0].map(\.id)))
        await checker.waitUntilIdle()
        let requests = Array(service.log.suffix(from: before))
        let page = requests.first?.parts ?? []
        check(requests.count == 2 && texts(page).first == AutoCheckPrompts.pageRequestIntro
              && texts(page).contains(AutoCheckPrompts.checkAndTranscribePage(["B1", "B2"], modified: ["B1"])) && pngCount(page) == 1,
              "重新检查 on a fixed page re-sends the page image (\(requests.count) requests)")
        let later = requests.last?.parts ?? []
        check(texts(later).first == AutoCheckPrompts.recheckLaterIntro && pngCount(later) == 0
              && texts(later).contains(AutoCheckPrompts.recheckLater(["B3", "B4"], changed: ["B1"]))
              && texts(later).contains(AutoCheckPrompts.readingsHeading),
              "…then re-judges the later blocks from text only")
        check(checker.state.pages[0].ids.contains(extra.id) && checker.state.pages[0].markdown.contains("PAGE-MARKDOWN-2"),
              "the fixed page gets the new content and transcription")
        check(checker.state.check(tagged: "B1")?.ids.contains(extra.id) == true, "the edited block is checked with its new strokes")

        // The conversation is out of date: the next block opens a new one.
        let opened = service.conversationsOpened
        writer.write(Array(lines[3].dropFirst(2)) + [blockLine(4)[0]])
        await checker.waitUntilIdle()
        check(service.conversationsOpened == opened + 1, "after a fixed page is re-checked, the next block starts a new conversation")
    }

    // Switching on with content: page requests for all open pages but the last, which is the
    // first turn of the conversation.
    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let board = Board(strokes: (0..<5).flatMap(blockLine))   // pages of 2, 2, 1 blocks
        checker.load(board: board, state: AutoCheckState())
        checker.setEnabled(true)
        check(checker.marks.isEmpty && checker.fullCheck?.running == true && checker.fullCheck?.units.count == 5,
              "switching on: no marks, the full check runs over all 5 blocks")
        await checker.waitUntilIdle()
        let pageRequests = service.independents.filter { texts($0).first == AutoCheckPrompts.pageRequestIntro }
        check(pageRequests.count == 2, "two page requests for the first two pages (\(service.log.count) requests)")
        check(texts(pageRequests.last ?? []).contains { $0.contains("PAGE-MARKDOWN-1") }, "…the second with the first page's Markdown")
        let last = service.turns.first ?? []
        check(service.turns.count == 1 && texts(last).first == AutoCheckPrompts.conversationIntro
              && texts(last).contains(AutoCheckPrompts.checkPage(["B5"])) && pngCount(last) == 1,
              "the last page is the first turn of a conversation (checkPage with the page image)")
        check(checker.state.pages.count == 2 && checker.state.checks.count == 5, "every block is checked, two pages fixed")
        check(checker.marks.isEmpty, "no problems, no marks")

        // Switching off and on again: nothing left to check.
        checker.setEnabled(false)
        let count = service.log.count
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        check(service.log.count == count, "switching on again sends nothing when everything is checked")
    }

    // Switching off cancels the running request and empties the queue.
    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        service.hold = true
        writer.write(blockLine(0) + [blockLine(1)[0]])
        await waitForRequests(service, 1)
        writer.write(Array(blockLine(1).dropFirst()) + [blockLine(2)[0]])
        check(service.log.count == 1 && checker.queuedCount == 1, "setup: one request running, one queued")
        checker.setEnabled(false)
        service.release()
        await checker.waitUntilIdle()
        for _ in 0..<5 { await Task.yield() }
        check(checker.state.checks.isEmpty && checker.queuedCount == 0 && checker.activity == .idle && service.log.count == 1,
              "switching off drops the running request's answer and the queue")
    }

    // What the canvas shows while blocks are re-checked, and what the menu gets to list.
    do {
        let service = FakeCheckService()
        service.issues["B1"] = error
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let a = blockLine(0), b = blockLine(1)
        writer.write(a + b)
        await checker.waitUntilIdle()
        check(writer.mark(containing: a[0])?.kind == .issue(.error) && writer.isWriting(b[0]), "setup: A has a red box, B is being written")

        service.hold = true
        var sent = service.log.count
        checker.check(Set(a.map(\.id)))
        await waitForRequests(service, sent + 1)
        check(writer.mark(containing: a[0])?.kind == .issue(.error) && writer.isChecking(a[0]),
              "a flagged block keeps its red box (and its buttons) while it is re-checked")
        check(checker.checkLatest() && writer.isQueued(b[0]) && writer.mark(containing: b[0]) == nil,
              "检查最新的块 queues the block being written; it still has no mark")
        service.release()
        await checker.waitUntilIdle()
        check(checker.checkingUnits.isEmpty && checker.queuedUnits.isEmpty && checker.stage == nil, "…both are done")

        writer.edit { $0.strokes.removeAll { $0.id == a.last!.id } }
        check(writer.mark(containing: a[0])?.kind == .modifiedBox, "erasing in a flagged block gives it a grey dashed box")
        service.hold = true
        sent = service.log.count
        checker.check(Set(a.dropLast().map(\.id)))
        await waitForRequests(service, sent + 1)
        check(writer.mark(containing: a[0]) == nil && writer.isChecking(a[0]), "…which goes away while it is re-checked")
        service.release()
        await checker.waitUntilIdle()
        check(writer.mark(containing: a[0])?.kind == .issue(.error), "…and the verdict brings the box back")
        checker.shutdown()
    }

    // The block starting the next page waits while the current page is transcribed.
    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let lines = (0..<4).map(blockLine)
        writer.write(lines[0] + lines[1] + [lines[2][0]])
        await checker.waitUntilIdle()
        service.hold = true
        let sent = service.log.count
        writer.write(Array(lines[2].dropFirst()) + [lines[3][0]])
        await waitForRequests(service, sent + 1)
        check(checker.stage == .transcribingPage && checker.checkingUnits.isEmpty && writer.isQueued(lines[2][0])
              && writer.mark(containing: lines[2][0]) == nil && writer.isWriting(lines[3][0]),
              "while the current page is transcribed, the block that starts the next one is listed as waiting, with no mark (\(String(describing: checker.stage)))")
        service.release()
        await checker.waitUntilIdle()
        check(checker.queuedUnits.isEmpty && checker.state.pages.count == 1, "…and is checked after the page is fixed")
        checker.shutdown()
    }

    // A full check that failed waits in the queue with the blocks it covers.
    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        checker.load(board: Board(strokes: (0..<3).flatMap(blockLine)), state: AutoCheckState())
        service.failNext = "offline"
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        check(checker.failureMessage == "offline" && checker.fullCheck?.running == false && checker.fullCheck?.units.count == 3
              && checker.stage == nil && checker.marks.isEmpty,
              "a failed full check waits with its 3 blocks, which have no marks (\(String(describing: checker.fullCheck)))")
        checker.retry()
        await checker.waitUntilIdle()
        check(checker.fullCheck == nil && checker.failureMessage == nil && checker.state.checks.count == 3, "…and 重试 runs it")
    }

    await runSchedulerRegressionChecks()
    await runLayoutChangeChecks()

    // Tagged page image: red boxes and tags, only the page's own blocks.
    do {
        let a = blockLine(0), b = blockLine(1), other = blockLine(2)
        let board = Board(strokes: a + b + other)
        let units = AutoCheckTracker.units(in: InkLayout.analyze(board).blocks)
        let ids = Set((a + b).map(\.id))
        let rect = board.bounds(of: ids).insetBy(dx: -24, dy: -24)
        let tagged = units.prefix(2).enumerated().map { AutoCheckRender.Tagged(tag: "B\($0.offset + 1)", bounds: $0.element.bounds) }
        if let image = AutoCheckRender.pageImage(board, rect: rect, ids: ids, tagged: tagged, maxPixels: 2000),
           let source = CGImageSourceCreateWithData(image.pngData as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let pixels = Pixels(cg)
            var red = 0, dark = 0
            for y in 0..<cg.height {
                for x in 0..<cg.width {
                    if pixels.isRed(x, y) { red += 1 }
                    if pixels.isDark(x, y) { dark += 1 }
                }
            }
            check(red > 200 && dark > 100, "the page image has red boxes and tags over the ink (\(red) red px)")
            check(image.rect.contains(rect), "…and covers the page")
        } else {
            check(false, "the tagged page image renders")
        }
        if let unit = units.first, let block = AutoCheckRender.blockImage(unit, board: board) {
            check(block.rect.contains(unit.bounds) && block.rect.height < 80, "a block image is the unit plus a margin")
        } else {
            check(false, "the block image renders")
        }
    }

    // A queued check whose block split meanwhile fails, then is retried: each part is sent once.
    do {
        let a = blockLine(0), b = blockLine(1), c = blockLine(2)
        let board = Board(strokes: a + b + c)
        let service = FakeCheckService()
        let checker = AutoChecker(service: service)
        // A and B start as one block (B moved up under A), then B moves back while the check waits.
        checker.load(board: InkOps.translate(board, ids: Set(b.map(\.id)), dx: 0, dy: -46), state: AutoCheckState(enabled: true))
        service.hold = true
        checker.check(Set(c.map(\.id)))
        await waitForRequests(service, 1)
        checker.check(Set((a + b).map(\.id)))
        checker.boardDidChange(board)
        service.failNext = "split request failed"
        service.release()
        await checker.waitUntilIdle()
        checker.retry()
        await checker.waitUntilIdle()
        // C, A (failed), A, B.
        check(service.turns.count == 4, "retrying a check whose block split sends each part once (\(service.turns.count) turns)")
        checker.shutdown()
    }

    // Real handwriting, written in its stroke order: when are blocks sent?
    if let data = try? Data(contentsOf: realNote), let note = try? BoardStore.decode(data) {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        var slowest: TimeInterval = 0
        var textLineSentAt: Int?
        for (n, stroke) in note.strokes.enumerated() {
            let start = Date()
            writer.write([stroke])
            slowest = max(slowest, Date().timeIntervalSince(start))
            await checker.waitUntilIdle()
            // Stroke 61 starts the line of Chinese text; stroke 101 starts the formula line below it
            // (more than 1.5h lower), which finishes the text line.
            // Sent: checked (or edited since), and not being written into.
            if textLineSentAt == nil, n >= 60, let unit = checker.units.first(where: { $0.ids.contains(note.strokes[60].id) }) {
                let sent: Bool
                switch checker.status(of: unit) {
                case .unchecked: sent = false
                case .checked: sent = true
                case .modified: sent = !(checker.writingUnit?.ids == unit.ids && AutoCheckTracker.grownFrom(unit, in: checker.state.checks) != nil)
                }
                if sent { textLineSentAt = n + 1 }
            }
        }
        check(textLineSentAt == 101, "the text line is checked as soon as the formula line below it starts (stroke \(textLineSentAt.map(String.init) ?? "never"))")
        let finalUnits = AutoCheckTracker.units(in: InkLayout.analyze(note).blocks)
        let statuses = finalUnits.map { checker.status(of: $0) }
        let checked = statuses.filter { if case .checked = $0 { return true }; return false }.count
        print("    replay: \(note.strokes.count) strokes, \(service.log.count) requests, \(checker.state.checks.count) checks, " +
              "final units \(finalUnits.count) (\(checked) checked as they are), slowest update \(Int(slowest * 1000)) ms")
        check(service.log.count >= finalUnits.count - 1 && service.log.count <= 3 * finalUnits.count,
              "replaying the real note sends each finished block about once (\(service.log.count) requests for \(finalUnits.count) blocks)")
        check(checked >= finalUnits.count - 1, "every block but the last one ends up checked as written")
        check(slowest < 0.25, "segmentation per stroke stays fast (\(Int(slowest * 1000)) ms)")
        check(checker.state.checks.count == 3, "formula lines first sent as blocks of their own are merged into one check when they join")
    } else {
        print("  - skipped: \(realNote.path) not found")
    }

    // A full page of writing: the per-stroke update (segmentation + marks) on the main thread.
    do {
        let checker = AutoChecker(service: FakeCheckService())
        let writer = Writer(checker)
        writer.board = Board(strokes: (0..<12).flatMap { paragraph(x: 20, top: 20 + CGFloat($0) * 140, lines: 3) })
        checker.setEnabled(true)
        let start = Date()
        writer.write([glyph(20, 1800)])
        let elapsed = Date().timeIntervalSince(start)
        print("    one stroke on a board of \(writer.board.strokes.count) strokes: \(Int(elapsed * 1000)) ms")
        check(elapsed < 0.5, "the per-stroke update stays usable on a full board (\(Int(elapsed * 1000)) ms)")
        checker.setEnabled(false)
    }
}

@MainActor
private func runSchedulerRegressionChecks() async {
    let a = blockLine(0), b = blockLine(1), c = blockLine(2)
    let board = Board(strokes: a + b + c)
    let aIDs = Set(a.map(\.id)), bIDs = Set(b.map(\.id)), cIDs = Set(c.map(\.id))

    do {
        let checker = AutoChecker(service: FakeCheckService(), pageOptions: smallPages)
        let strokes = paragraph(x: 20, top: 40, lines: 14, words: [3, 2])
        let ids = Set(strokes.map(\.id))
        checker.load(board: Board(strokes: strokes + blockLine(9)), state: AutoCheckState())
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        check(checker.state.pages.count == 1 && checker.state.pages.first?.ids == ids
              && checker.state.check(tagged: "B1")?.ids == ids,
              "a full check fixes the entire tall paragraph including its last line")
    }

    do {
        let checker = AutoChecker(service: FakeCheckService())
        let original = BlockCheck(tag: "B1", ids: aIDs.union(bIDs))
        checker.load(board: Board(strokes: a + b), state: AutoCheckState(checks: [original], nextTag: 2))
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        check(checker.state.check(tagged: "B1")?.ids == aIDs && checker.state.check(tagged: "B2")?.ids == bIDs,
              "two split descendants get separate verdicts and the first equal-sized part keeps B1")
    }

    do {
        let checker = AutoChecker(service: FakeCheckService(), pageOptions: smallPages)
        let writer = Writer(checker)
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        // Start at the bottom, then return to the top. B's first stroke puts C on page two.
        writer.write(c + a + [b[0]])
        await checker.waitUntilIdle()
        check(checker.state.pages.isEmpty && checker.state.checks.contains { $0.ids == aIDs }
              && checker.state.checks.contains { $0.ids == cIDs } && writer.mark(containing: b[0]) == nil && writer.isWriting(b[0]),
              "checking the lower block leaves the page still being written on open")
    }

    do {
        let checker = AutoChecker(service: FakeCheckService(), pageOptions: smallPages)
        checker.load(board: board, state: AutoCheckState(enabled: true))
        checker.check(cIDs)
        await checker.waitUntilIdle()
        check(checker.state.pages.first?.ids == aIDs.union(bIDs)
              && Set(checker.state.checks.map(\.ids)) == [aIDs, bIDs, cIDs],
              "rollover judges every previously unchecked block before fixing its page")
    }

    do {
        let checker = AutoChecker(service: FakeCheckService())
        let donor = BlockCheck(tag: "B2", ids: bIDs.union([a[0].id]), reading: "donor")
        let receiver = BlockCheck(tag: "B1", ids: aIDs.subtracting([a[0].id]))
        checker.load(board: board, state: AutoCheckState(enabled: true, checks: [receiver, donor], nextTag: 3))
        checker.check(aIDs)
        await checker.waitUntilIdle()
        check(checker.state.check(tagged: "B1")?.ids == aIDs && checker.state.check(tagged: "B2") == donor,
              "checking a block that gained one stroke preserves the donor block's previous verdict")
    }

    // Exercise both the independent fixed-page request and the last page's conversation turn.
    for hasFollowingPage in [true, false] {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        service.omittedTag = "B2"
        checker.load(board: hasFollowingPage ? board : Board(strokes: a + b), state: AutoCheckState())
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let paused: Bool
        if case .failed = checker.activity { paused = true } else { paused = false }
        check(paused && checker.state.pages.isEmpty && checker.state.checks.isEmpty,
              "an incomplete \(hasFollowingPage ? "fixed-page" : "last-page") answer pauses without accepting a partial result")
        service.omittedTag = nil
        checker.retry()
        await checker.waitUntilIdle()
        check(checker.activity == .idle && checker.state.check(tagged: "B2")?.ids == bIDs,
              "retry with a complete page answer stores the missing verdict")
    }

    do {
        let checker = AutoChecker(service: FakeCheckService(), pageOptions: smallPages)
        let oldRect = board.bounds(of: aIDs).insetBy(dx: -24, dy: -24)
        let fixed = FixedPage(ids: aIDs, rect: oldRect, tags: ["B1"], markdown: "A")
        let moved = InkOps.translate(board, ids: aIDs, dx: 0, dy: 320)
        checker.load(board: moved, state: AutoCheckState(enabled: true, checks: [BlockCheck(tag: "B1", ids: aIDs)],
                                                        pages: [fixed], nextTag: 2))
        checker.check(aIDs)
        await checker.waitUntilIdle()
        let open = AutoCheckPages.openPages(blocks: checker.blocks, fixed: checker.state.pages, options: smallPages)
        check(checker.state.pages.first?.rect.contains(moved.bounds(of: aIDs)) == true
              && open.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) } == bIDs.union(cIDs),
              "rechecking a moved fixed page leaves intervening blocks on open pages")
    }

    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service)
        checker.load(board: board, state: AutoCheckState(enabled: true))
        checker.check(aIDs)
        await checker.waitUntilIdle()
        checker.boardDidChange(Board(strokes: b + c))
        checker.check(bIDs)
        await checker.waitUntilIdle()
        check(service.conversationsOpened == 2 && service.turns.count == 2
              && pngCount(service.turns.last ?? []) == 1 && checker.state.check(tagged: "B2")?.ids == bIDs,
              "erasing a checked premise starts a fresh conversation with only the next block")
    }

    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service)
        let checks = [aIDs, bIDs, cIDs].enumerated().map { BlockCheck(tag: "B\($0.offset + 1)", ids: $0.element) }
        checker.load(board: board, state: AutoCheckState(enabled: true, checks: checks, nextTag: 4))
        checker.check(aIDs)
        await checker.waitUntilIdle()
        let warning = [CheckIssue(severity: .warning, summary: "changed premise")]
        service.issues = ["B2": warning, "B3": warning]
        checker.check(aIDs)
        await checker.waitUntilIdle()
        check(service.conversationsOpened == 1 && checker.state.check(tagged: "B2")?.issues == warning
              && checker.state.check(tagged: "B3")?.issues == warning,
              "rechecking the first block twice in a rebuilt conversation updates both later verdicts")
    }

    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service)
        let joined = InkOps.translate(board, ids: bIDs, dx: 0, dy: -46)
        checker.load(board: joined, state: AutoCheckState(enabled: true))
        check(checker.units.contains { $0.ids == aIDs.union(bIDs) }, "setup: the queued paragraph starts as one unit")
        service.hold = true
        checker.check(cIDs)
        await waitForRequests(service, 1)
        checker.check(aIDs.union(bIDs))
        checker.boardDidChange(board)
        service.release()
        await checker.waitUntilIdle()
        check(Set(checker.state.checks.map(\.ids)) == [aIDs, bIDs, cIDs],
              "a queued paragraph that splits leaves a verdict on each surviving part")
    }

    do {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        checker.load(board: board, state: AutoCheckState())
        checker.setEnabled(true)
        checker.setEnabled(false)
        // The disabled checker already reports idle. Give its previously scheduled main-actor
        // task a turn before inspecting calls to the service.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        check(service.log.isEmpty && service.conversationsOpened == 0 && checker.state.nextTag == 1,
              "a full check cancelled before its first turn sends nothing and consumes no tags")
    }
}

/// 分块方式「AI 辅助」: the grouping changes without the ink changing (AI 识别分块, its undo / redo,
/// switching 分块方式). Blocks checked as they were are re-checked when they merge or split; blocks
/// the user edited keep waiting for 重新检查.
@MainActor
private func runLayoutChangeChecks() async {
    let saved = InkLayout.defaultOptions
    defer { InkLayout.defaultOptions = saved }
    InkLayout.defaultOptions.useGroups = true

    /// A checker with every block of `board` checked (switching on runs a full check).
    func checked(_ board: Board) async -> (AutoChecker, FakeCheckService, Writer) {
        let service = FakeCheckService()
        let checker = AutoChecker(service: service)
        checker.load(board: board, state: AutoCheckState())
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        let writer = Writer(checker)
        writer.board = board
        return (checker, service, writer)
    }
    func isChecked(_ checker: AutoChecker, _ ids: Set<UUID>) -> Bool {
        guard let unit = checker.units.first(where: { $0.ids == ids }) else { return false }
        if case .checked = checker.status(of: unit) { return true }
        return false
    }

    // Pure merge: two checked blocks grouped into one are checked again as one block.
    do {
        let a = blockLine(0), b = blockLine(1)
        let aIDs = Set(a.map(\.id)), bIDs = Set(b.map(\.id))
        let (checker, service, writer) = await checked(Board(strokes: a + b))
        check(checker.state.checks.count == 2 && isChecked(checker, aIDs) && isChecked(checker, bIDs),
              "layout change: two blocks checked before the AI groups them")
        let before = service.log.count
        writer.edit { $0.groups = [BlockGroup(ids: aIDs.union(bIDs), kind: .text)] }
        check(checker.units.count == 1, "…the group makes them one unit (\(checker.units.count) units)")
        check(writer.isChecking(a[0]) || writer.isQueued(a[0]), "…which is queued for a check at once")
        await checker.waitUntilIdle()
        check(service.log.count == before + 1, "…one request for the merged block (\(service.log.count - before))")
        check(checker.state.checks.count == 1 && isChecked(checker, aIDs.union(bIDs)),
              "…which ends up as one check covering both (\(checker.state.checks.map(\.tag)))")
        check(checker.marks.isEmpty, "…with no 重新检查 left on the canvas")

        // Undo: the old grouping comes back, both parts are checked again.
        let merged = service.log.count
        writer.edit { $0.groups = [] }
        await checker.waitUntilIdle()
        check(service.log.count == merged + 2 && isChecked(checker, aIDs) && isChecked(checker, bIDs),
              "undoing the grouping re-checks both blocks (\(service.log.count - merged) requests)")
        checker.shutdown()
    }

    // Split: a checked paragraph split by the AI into two groups — both parts are re-checked.
    do {
        let p = paragraph(x: 20, top: 40, lines: 2, words: [3, 2])
        let line1 = Set(p.prefix(5).map(\.id)), line2 = Set(p.suffix(5).map(\.id))
        let (checker, service, writer) = await checked(Board(strokes: p))
        check(checker.units.count == 1 && isChecked(checker, line1.union(line2)), "layout change: a two-line paragraph checked as one block")
        let before = service.log.count
        writer.edit { $0.groups = [BlockGroup(ids: line1, kind: .text), BlockGroup(ids: line2, kind: .formula)] }
        await checker.waitUntilIdle()
        check(checker.units.count == 2 && isChecked(checker, line1) && isChecked(checker, line2),
              "…split by the groups, both parts are checked again (\(describe(checker.blocks)))")
        check(service.log.count == before + 2 && Set(checker.state.checks.map(\.tag)).count == 2,
              "…one request each, the first part keeps the tag (\(checker.state.checks.map(\.tag)))")
        checker.shutdown()
    }

    // A block the user edited is not re-checked; the others still are.
    do {
        let a = blockLine(0), b = blockLine(1), c = blockLine(2)
        let aIDs = Set(a.map(\.id)), bIDs = Set(b.map(\.id)), cIDs = Set(c.map(\.id))
        let (checker, service, writer) = await checked(Board(strokes: a + b + c))
        writer.edit { $0.strokes.removeAll { $0.id == a.last!.id } }   // erased: A is modified
        await checker.waitUntilIdle()
        let before = service.log.count
        let aLeft = aIDs.subtracting([a.last!.id])
        writer.edit { $0.groups = [BlockGroup(ids: aLeft.union(bIDs), kind: .text), BlockGroup(ids: cIDs, kind: .formula)] }
        await checker.waitUntilIdle()
        check(service.log.count == before, "a merge with a block the user edited waits for 重新检查 (\(service.log.count - before) requests)")
        let merged = checker.units.first { $0.ids == aLeft.union(bIDs) }
        check(merged != nil && checker.marks.contains { $0.ids == aLeft.union(bIDs) && $0.kind == .recheck },
              "…and shows 重新检查")
        check(isChecked(checker, cIDs), "a group that only changes the kind keeps the check")
        checker.shutdown()
    }

    // Switching 分块方式: the same board segmented again (groups now ignored) re-checks what split.
    do {
        let a = blockLine(0), b = blockLine(1)
        let aIDs = Set(a.map(\.id)), bIDs = Set(b.map(\.id))
        let board = Board(strokes: a + b, groups: [BlockGroup(ids: aIDs.union(bIDs), kind: .text)])
        let (checker, service, _) = await checked(board)
        check(isChecked(checker, aIDs.union(bIDs)), "分块方式: the AI group is checked as one block")
        let before = service.log.count
        InkLayout.defaultOptions.useGroups = false
        checker.layoutDidChange()
        await checker.waitUntilIdle()
        check(service.log.count == before + 2 && isChecked(checker, aIDs) && isChecked(checker, bIDs),
              "…switching to 本地计算 re-checks both geometric blocks (\(service.log.count - before) requests)")
        InkLayout.defaultOptions.useGroups = true
        checker.setEnabled(false)
        checker.layoutDidChange()
        check(checker.queuedCount == 0 && checker.marks.isEmpty, "…nothing is queued while 自动检查 is off")
        checker.shutdown()
    }

    // Ink not on an open page (fixed) is left alone.
    do {
        let a = blockLine(0), b = blockLine(1), c = blockLine(2), d = blockLine(3)
        let aIDs = Set(a.map(\.id)), bIDs = Set(b.map(\.id))
        let service = FakeCheckService()
        let checker = AutoChecker(service: service, pageOptions: smallPages)
        checker.load(board: Board(strokes: a + b + c + d), state: AutoCheckState())
        checker.setEnabled(true)
        await checker.waitUntilIdle()
        check(checker.state.pages.count == 1, "fixed page for the layout test")
        let writer = Writer(checker)
        writer.board = Board(strokes: a + b + c + d)
        let before = service.log.count
        writer.edit { $0.groups = [BlockGroup(ids: aIDs.union(bIDs), kind: .text)] }
        await checker.waitUntilIdle()
        check(service.log.count == before, "a regrouped block on a fixed page is not re-checked automatically (\(service.log.count - before))")
        checker.shutdown()
    }
}
