import CoreGraphics
import Foundation

/// 自动检查: the scheduler (docs/auto-check.md §3–§4; AGENTS.md「自动检查」).
///
/// The app feeds it every committed board (and whether a new pen stroke was written); it finds
/// finished blocks (`WritingTracker`), queues them and sends them to the AI one request at a time,
/// in a multi-turn conversation per open page. Pages that no longer hold the block being checked
/// are transcribed and fixed first. Manual 检查 / 重新检查, 忽视, switching on (a full check of
/// what is not checked yet) and off are handled here too. What it keeps in the document is
/// `state` (reported through `onStateChange`); what the canvas shows is `marks`, and what the
/// toolbar and its 自动检查 menu show is `activity`, `checkingUnits`, `queuedUnits`, `fullCheck` and
/// `writingUnit` (all reported through `onDisplayChange`).
///
/// Blocks are identified by their strokes; a queued block is found again, by shared strokes, when
/// its turn comes, so it is sent as it is then.
@MainActor
public final class AutoChecker {
    // MARK: Output

    /// What one check unit shows on the canvas (docs/auto-check.md §2, §8).
    public struct Mark: Equatable {
        public enum Kind: Equatable {
            /// Red (error) or yellow (warning) box with 详情, 忽视 and 重新检查.
            case issue(CheckSeverity)
            /// Edited since it got a red / yellow box: grey dashed box with 重新检查.
            case modifiedBox
            /// Edited since it was checked without a box: only 重新检查.
            case recheck
            /// Not checked, not queued and not being written: a small 检查 button.
            case check
        }

        public var kind: Kind
        /// The unit's strokes (what a button acts on).
        public var ids: Set<UUID>
        public var bounds: CGRect
        /// The check it refers to (issue, modifiedBox, recheck).
        public var tag: String?
    }

    public enum Stage: Equatable {
        /// Checking one block (`tag`) in the page conversation.
        case block(String)
        /// Judging several blocks shown on a page image.
        case page([String])
        /// Transcribing the current page before moving on to the next one.
        case transcribingPage
        /// Re-judging later blocks from their transcriptions (text only).
        case laterBlocks([String])
        /// Opening a conversation.
        case starting
    }

    public enum Activity: Equatable {
        case idle
        /// A request is running; `queued` more jobs wait.
        case working(Stage, queued: Int)
        /// The last request failed; the job waits for `retry()` (or a manual check).
        case failed(String)
    }

    /// The document's part: results, fixed pages, the switch. Not undoable (see AutoCheckState).
    public private(set) var state: AutoCheckState
    public private(set) var board = Board()
    public private(set) var blocks: [InkBlock] = []
    public private(set) var units: [CheckUnit] = []
    public private(set) var marks: [Mark] = []
    public private(set) var activity: Activity = .idle

    /// The state changed (save it and mark the document edited).
    public var onStateChange: ((AutoCheckState) -> Void)?
    /// `marks`, `activity` or what the menu lists changed.
    public var onDisplayChange: (() -> Void)?

    /// How open pages are packed (the app passes `AISettings.pageOptions`, like 全局转换).
    public var pageOptions: PageAssembler.Options {
        didSet { refreshMarks() }
    }

    public let service: AutoCheckService

    // MARK: Internal state

    private struct Job: Equatable {
        enum Kind: Equatable {
            case unit(Set<UUID>)
            case fullCheck
        }

        var kind: Kind
        /// Sent automatically (a finished block): never for a block on a fixed page.
        var automatic: Bool
        /// After it is sent, writing on in the same block re-checks it automatically ("接着写").
        var continuable: Bool
    }

    /// The conversation of the current (first open) page.
    private struct PageConversation {
        let conversation: ModelConversation
        /// Tags the conversation has seen, in the order they were first sent.
        var sent: [String] = []
        /// Turns sent so far; the first one carries the context.
        var turns = 0
    }

    private var tracker = WritingTracker()
    private var queue: [Job] = []
    private var task: Task<Void, Never>?
    private var run = 0
    /// After a failure: nothing is sent until `retry()` or a manual check.
    private var paused = false
    private var failedMessage: String?
    private var conversation: PageConversation?
    /// AI settings changed while a request was running: the conversation is replaced afterwards.
    private var conversationStale = false
    /// The block sent last that may grow on ("接着写", docs/auto-check.md §3).
    private var continuationTag: String?
    /// Units being judged by the running request.
    private var busyIDs: Set<UUID> = []
    /// The block the running job is for (it waits while its page is transcribed first).
    private var jobIDs: Set<UUID> = []
    private var fullCheckRunning = false
    /// Tags given to units that have no check yet (sent on a page image, or awaiting an answer),
    /// so a unit keeps its tag until it has a result.
    private var provisionalTags: [String: Set<UUID>] = [:]

    public init(service: AutoCheckService, state: AutoCheckState = AutoCheckState(),
                pageOptions: PageAssembler.Options = PageAssembler.Options()) {
        self.service = service
        self.state = state
        self.pageOptions = pageOptions
    }

    // MARK: - Input

    /// New document content (opening, 复原, browsing versions): forgets everything in flight.
    public func load(board: Board, state: AutoCheckState) {
        cancelAll()
        self.state = state
        provisionalTags = [:]
        continuationTag = nil
        tracker.reset()
        setBoard(board)
        displayChanged()
    }

    /// After every committed change of the board (and undo / redo). `addedStroke`: the change
    /// was a new pen stroke (only writing finishes blocks; erasing, moving or undoing doesn't).
    /// A change of only the segmentation hints (`Board.groups` from AI 识别分块, or `labels`), with
    /// the same strokes, is handled as `layoutDidChange(_:)`.
    public func boardDidChange(_ board: Board, addedStroke: UUID? = nil) {
        if addedStroke == nil, board.groups != self.board.groups || board.labels != self.board.labels,
           board.strokes.count == self.board.strokes.count,
           Set(board.strokes.map(\.id)) == Set(self.board.strokes.map(\.id)) {
            layoutDidChange(board)
            return
        }
        setBoard(board)
        if state.enabled, let stroke = addedStroke {
            // Usually one finished block; after a split, every part left behind.
            tracker.didWriteUnits(stroke, units: units).forEach(blockFinished)
        }
        displayChanged()
    }

    /// The segmentation changed while the ink did not: new AI groups (AI 识别分块, its undo / redo)
    /// or another 分块方式 (`InkLayout.defaultOptions`). `board`: the new board (nil: the same board,
    /// segmented again).
    ///
    /// A block that was checked as it was and is now merged with others or split only because of
    /// the new grouping is re-checked automatically (on open pages, through the queue: every part
    /// of a split, the merged block once). Blocks the user had edited since their check keep
    /// waiting for 重新检查. A regrouped block that is being written is re-checked when writing
    /// moves on, like "接着写".
    public func layoutDidChange(_ board: Board? = nil) {
        // Checks whose block was intact before the change.
        let intact = Set(units.compactMap { tagIfChecked($0) })
        setBoard(board ?? self.board)
        if state.enabled {
            let writing = tracker.currentUnit(in: units)
            for unit in units {
                if case .checked = status(of: unit) { continue }
                let touched = state.checks.filter { !$0.ids.isDisjoint(with: unit.ids) }
                guard !touched.isEmpty, touched.allSatisfy({ intact.contains($0.tag) }),
                      fixedPageIndex(of: unit) == nil else { continue }
                let checkedInk = touched.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
                if let writing, writing.ids == unit.ids, !unit.ids.isSubset(of: checkedInk) {
                    // Joined to the block being written: checked once that block is finished.
                    continuationTag = touched.max { $0.ids.intersection(unit.ids).count < $1.ids.intersection(unit.ids).count }?.tag
                    continue
                }
                enqueue(Job(kind: .unit(unit.ids), automatic: true, continuable: false))
            }
        }
        displayChanged()
    }

    /// The 自动检查 switch. On: checks what isn't checked yet (docs/auto-check.md §4.3), then
    /// every finished block. Off: stops everything; results are kept (and hidden).
    public func setEnabled(_ on: Bool) {
        guard on != state.enabled else { return }
        cancelAll()
        tracker.reset()
        state.enabled = on
        stateChanged()
        if on { enqueue(Job(kind: .fullCheck, automatic: true, continuable: false)) }
        displayChanged()
    }

    /// 检查 / 重新检查 on a unit (`Mark.ids`). Resumes after a failure.
    public func check(_ ids: Set<UUID>) {
        guard state.enabled, !ids.isEmpty else { return }
        let writing = tracker.currentUnit(in: units)
        let continuable = writing.map { !$0.ids.isDisjoint(with: ids) } ?? false
        resume()
        enqueue(Job(kind: .unit(ids), automatic: false, continuable: continuable))
        displayChanged()
    }

    /// The block written last (检查最新的块, ⇧⌘K): false when there is nothing to check.
    @discardableResult
    public func checkLatest() -> Bool {
        guard state.enabled, let unit = latestUnit else { return false }
        if case .checked = status(of: unit), !isPending(unit) { return false }
        check(unit.ids)
        return true
    }

    /// The unit being written, or else the one holding the newest stroke.
    public var latestUnit: CheckUnit? {
        if let unit = tracker.currentUnit(in: units) { return unit }
        guard let last = board.strokes.last?.id else { return nil }
        return units.first { $0.ids.contains(last) }
    }

    /// 忽视: hides the box until the block is checked again.
    public func dismiss(tag: String) {
        guard var check = state.check(tagged: tag), !check.dismissed else { return }
        check.dismissed = true
        state.setCheck(check)
        stateChanged()
        displayChanged()
    }

    /// Sends the job that failed again.
    public func retry() {
        guard state.enabled else { return }
        resume()
        pump()
        displayChanged()
    }

    /// The AI settings for 自动检查 changed: the conversation is not continued.
    public func settingsDidChange() {
        if task == nil { closeConversation() } else { conversationStale = true }
    }

    /// Stops everything (the window closes).
    public func shutdown() {
        cancelAll()
    }

    /// Waits until nothing is queued or running (or the queue is paused by a failure).
    public func waitUntilIdle() async {
        while task != nil || (state.enabled && !paused && !queue.isEmpty) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - Queries (for the canvas)

    /// The result shown for a mark.
    public func result(tagged tag: String) -> BlockCheck? {
        state.check(tagged: tag)
    }

    /// Where the block with this tag is now (for 相关：B5 highlights).
    public func bounds(ofTag tag: String) -> CGRect? {
        guard let check = state.check(tagged: tag) else { return nil }
        let best = units.max { $0.ids.intersection(check.ids).count < $1.ids.intersection(check.ids).count }
        guard let best, !best.ids.isDisjoint(with: check.ids) else { return nil }
        return best.bounds
    }

    public func status(of unit: CheckUnit) -> AutoCheckTracker.Status {
        AutoCheckTracker.status(of: unit, in: state.checks)
    }

    /// Jobs waiting (not counting the running one).
    public var queuedCount: Int { queue.count }

    /// The unit sharing most strokes with `ids` (a menu item's block, found again after edits).
    public func unit(sharing ids: Set<UUID>) -> CheckUnit? {
        resolve(ids)
    }

    // MARK: - Queries (for the 自动检查 menu)

    /// A full check (switching on) that is queued or running.
    public struct FullCheckStatus: Equatable {
        public var running: Bool
        /// Units on open pages it has yet to judge (those being judged now included), in reading order.
        public var units: [CheckUnit]
    }

    /// The running request's stage; nil when nothing runs.
    public var stage: Stage? {
        if case .working(let stage, _) = activity { return stage }
        return nil
    }

    /// Units judged by the running request (a block, a page's blocks, later blocks re-judged), in
    /// reading order. Empty while a page is only transcribed.
    public var checkingUnits: [CheckUnit] {
        guard task != nil, !busyIDs.isEmpty else { return [] }
        return units.filter { !$0.ids.isDisjoint(with: busyIDs) }
    }

    /// Units waiting for their turn, in queue order (all parts of a block that split while it
    /// waited), first the running job's block while its page is transcribed; units being checked
    /// are not repeated. A queued full check is `fullCheck`.
    public var queuedUnits: [CheckUnit] {
        let checking = checkingUnits.map(\.ids)
        var result: [CheckUnit] = []
        var running: [Set<UUID>] = task != nil && !jobIDs.isEmpty ? [jobIDs] : []
        if case .laterBlocks? = stage { running = [] }   // its own verdict is in already
        let waiting = queue.compactMap { job -> Set<UUID>? in
            if case .unit(let ids) = job.kind { return ids }
            return nil
        }
        for ids in running + waiting {
            for unit in units where !unit.ids.isDisjoint(with: ids) {
                if checking.contains(unit.ids) || result.contains(where: { $0.ids == unit.ids }) { continue }
                result.append(unit)
            }
        }
        return result
    }

    /// The full check started by switching on, while it waits or runs.
    public var fullCheck: FullCheckStatus? {
        let queued = queue.contains { $0.kind == .fullCheck }
        guard state.enabled, fullCheckRunning || queued else { return nil }
        return FullCheckStatus(running: fullCheckRunning, units: fullCheckUnits())
    }

    /// The block being written (as of the last pen stroke); nil while 自动检查 is off.
    public var writingUnit: CheckUnit? {
        state.enabled ? tracker.currentUnit(in: units) : nil
    }

    /// The error of the request that failed; the queue waits for `retry()`.
    public var failureMessage: String? {
        if case .failed(let message) = activity { return message }
        return nil
    }

    // MARK: - Board

    private func setBoard(_ board: Board) {
        self.board = board
        blocks = InkLayout.analyze(board).blocks
        units = AutoCheckTracker.units(in: blocks)
    }

    /// Open pages of whole blocks: unlike 全局转换, a paragraph taller than a page is not split
    /// between lines (it gets a page of its own), so a check unit is never judged or fixed in part.
    private func openPages() -> [InkPage] {
        let whole = blocks.map { block -> InkBlock in
            var block = block
            block.lines = []
            return block
        }
        return AutoCheckPages.openPages(blocks: whole, fixed: state.pages, options: pageOptions)
    }

    private func fixedPageIndex(of unit: CheckUnit) -> Int? {
        guard blocks.indices.contains(unit.blockIndex) else { return nil }
        return AutoCheckPages.fixedPageIndex(of: blocks[unit.blockIndex], fixed: state.pages)
    }

    /// The unit sharing most strokes with `ids`.
    private func resolve(_ ids: Set<UUID>) -> CheckUnit? {
        var best: CheckUnit?
        var bestCount = 0
        for unit in units {
            let count = unit.ids.intersection(ids).count
            if count > bestCount { best = unit; bestCount = count }
        }
        return best
    }

    /// Units on a page, in reading order.
    private func units(on page: InkPage) -> [CheckUnit] {
        let ids = page.ids
        return units.filter { !$0.ids.isDisjoint(with: ids) }
    }

    // MARK: - Finished blocks

    private func blockFinished(_ unit: CheckUnit) {
        // Content of fixed pages is only sent when the user asks.
        guard fixedPageIndex(of: unit) == nil else { return }
        switch status(of: unit) {
        case .unchecked:
            enqueue(Job(kind: .unit(unit.ids), automatic: true, continuable: true))
        case .checked:
            break
        case .modified:
            // Writing on in the block checked last re-checks it; other edits wait for 重新检查.
            if continues(unit) { enqueue(Job(kind: .unit(unit.ids), automatic: true, continuable: true)) }
        }
    }

    /// "接着写": the unit only grew (`AutoCheckTracker.grownFrom`: every check it touches lies wholly
    /// inside it, nothing checked was erased or split off) and one of those checks is the block sent
    /// last (`continuationTag`). Blocks checked on the way may have merged into it (a formula line
    /// first seen as a block of its own, then joined to the lines above).
    private func continues(_ unit: CheckUnit) -> Bool {
        guard let tag = continuationTag, let grown = AutoCheckTracker.grownFrom(unit, in: state.checks) else { return false }
        return grown.contains { $0.tag == tag }
    }

    private func enqueue(_ job: Job) {
        if case .unit(let ids) = job.kind,
           let i = queue.firstIndex(where: { if case .unit(let other) = $0.kind { return !other.isDisjoint(with: ids) }; return false }) {
            queue[i].kind = .unit(ids)
            queue[i].automatic = queue[i].automatic && job.automatic
            queue[i].continuable = queue[i].continuable || job.continuable
        } else if job.kind == .fullCheck, queue.contains(where: { $0.kind == .fullCheck }) {
            return
        } else {
            queue.append(job)
        }
        pump()
    }

    private func resume() {
        paused = false
        failedMessage = nil
    }

    // MARK: - Running jobs

    private func pump() {
        guard state.enabled, task == nil, !paused, !queue.isEmpty else {
            updateActivity()
            return
        }
        let job = queue.removeFirst()
        run += 1
        let run = self.run
        switch job.kind {
        case .fullCheck: fullCheckRunning = true
        case .unit(let ids): busyIDs = ids; jobIDs = ids
        }
        task = Task { @MainActor [weak self] in
            var failure: Error?
            do {
                try await self?.perform(job, run: run)
            } catch {
                failure = error
            }
            self?.finished(job, run: run, error: failure)
        }
        updateActivity()
    }

    private func finished(_ job: Job, run: Int, error: Error?) {
        guard run == self.run else { return }   // cancelled: a newer run owns the state
        task = nil
        busyIDs = []
        jobIDs = []
        fullCheckRunning = false
        if conversationStale { closeConversation() }
        if let error, !(error is CancellationError) {
            closeConversation()
            queue.insert(job, at: 0)
            paused = true
            failedMessage = error.localizedDescription
        }
        pump()
        refreshMarks()
        displayChanged()
    }

    private func cancelAll() {
        run += 1
        task?.cancel()
        task = nil
        queue = []
        busyIDs = []
        jobIDs = []
        fullCheckRunning = false
        resume()
        closeConversation()
        activity = .idle
    }

    private func closeConversation() {
        conversation?.conversation.close()
        conversation = nil
        conversationStale = false
    }

    /// Throws when the run was cancelled (switched off, new content) while awaiting.
    private func ensureCurrent(_ run: Int) throws {
        if run != self.run || Task.isCancelled { throw CancellationError() }
    }

    private func perform(_ job: Job, run: Int) async throws {
        try ensureCurrent(run)   // switched off (or new content) before the task got to run
        switch job.kind {
        case .fullCheck:
            try await fullCheck(run: run)
        case .unit(let ids):
            try await checkUnit(ids, job: job, run: run)
        }
    }

    private func setStage(_ stage: Stage, busy: Set<UUID>) {
        busyIDs = busy
        activity = .working(stage, queued: queue.count)
        refreshMarks()
        displayChanged()
    }

    private func updateActivity() {
        if let failedMessage, paused {
            activity = .failed(failedMessage)
        } else if task == nil {
            activity = .idle
        } else if case .working(let stage, _) = activity {
            activity = .working(stage, queued: queue.count)
        } else {
            activity = .working(.starting, queued: queue.count)
        }
    }

    // MARK: Checking one block

    private func checkUnit(_ ids: Set<UUID>, job: Job, run: Int) async throws {
        // Split while it waited: every part is checked (the others go first in the queue).
        let parts = units.filter { !$0.ids.isDisjoint(with: ids) }
        if parts.count > 1, let main = resolve(ids) {
            // Not twice: after a failure this job is retried while those parts are still queued.
            let queued = queue.compactMap { job -> Set<UUID>? in
                if case .unit(let ids) = job.kind { return ids }
                return nil
            }
            let others = parts.filter { part in part.ids != main.ids && !queued.contains { !$0.isDisjoint(with: part.ids) } }
                .map { Job(kind: .unit($0.ids), automatic: job.automatic, continuable: false) }
            queue.insert(contentsOf: others, at: 0)
        }
        while true {
            guard let unit = resolve(ids) else { return }   // erased meanwhile
            if job.automatic, case .checked = status(of: unit) { return }   // checked meanwhile (switching on)
            if let index = fixedPageIndex(of: unit) {
                if job.automatic { return }
                try await recheckFixedPage(index, target: unit, run: run)
                return
            }
            let pages = openPages()
            guard let k = pages.firstIndex(where: { !$0.ids.isDisjoint(with: unit.ids) }) else { return }
            var page = pages[0]
            if k > 0 {
                if let writing = tracker.currentUnit(in: units), !pages[0].ids.isDisjoint(with: writing.ids) {
                    // The current page is still being written on: it stays open, and the block
                    // joins its conversation.
                    page = pages[k]
                } else {
                    // The block starts a new page: the current one is transcribed and fixed first.
                    try await fixPage(pages[0], run: run)
                    continue
                }
            }
            if conversation == nil || conversation?.conversation.isUsable == false || conversationStale
                || conversationLostContext() {
                closeConversation()
                setStage(.starting, busy: unit.ids)
                let opened = try await service.openCheckConversation()
                guard run == self.run else { opened.close(); throw CancellationError() }
                conversation = PageConversation(conversation: opened)
                continue   // the board may have changed while opening
            }
            try await sendBlock(unit, page: page, continuable: job.continuable, run: run)
            return
        }
    }

    /// A block the conversation has seen was erased: the AI would still take it as context.
    /// (A tag merged into another block has no check any more; that is not a loss.)
    private func conversationLostContext() -> Bool {
        guard let conv = conversation else { return false }
        let present = Set(board.strokes.map(\.id))
        return conv.sent.contains { tag in
            guard let check = state.check(tagged: tag) else { return false }
            return check.ids.isDisjoint(with: present)
        }
    }

    /// One turn of the page conversation about `unit` (docs/auto-check.md §4).
    private func sendBlock(_ unit: CheckUnit, page: InkPage, continuable: Bool, run: Int) async throws {
        guard var conv = conversation else { return }
        let tag = tag(for: unit)
        guard let image = AutoCheckRender.blockImage(unit, board: board) else { return }
        let hadCheck = state.check(tagged: tag) != nil
        var parts: [PromptPart] = []
        var later: [String] = []

        if conv.turns == 0 {
            // Context: the fixed pages' Markdown and this page's checked blocks with their verdicts.
            parts.append(.text(AutoCheckPrompts.conversationIntro))
            parts += previousPagesParts(state.pages)
            var included: [String] = []
            var checkedParts: [PromptPart] = []
            for other in units(on: page) where other.ids != unit.ids {
                guard case .checked(let otherTag) = status(of: other), let check = state.check(tagged: otherTag),
                      let otherImage = AutoCheckRender.blockImage(other, board: board) else { continue }
                checkedParts += [.text(AutoCheckPrompts.blockLabel(otherTag)), .png(otherImage.pngData),
                                 .text(AutoCheckPrompts.previousVerdict(Self.verdictJSON(check)))]
                included.append(otherTag)
            }
            if !checkedParts.isEmpty {
                parts.append(.text(AutoCheckPrompts.checkedBlocksHeading))
                parts += checkedParts
            }
            conv.sent = included
            if hadCheck {
                // Blocks after it in reading order may depend on it.
                let pageUnits = units(on: page)
                let position = pageUnits.firstIndex { $0.ids == unit.ids } ?? 0
                let after = Set(pageUnits.suffix(from: min(position + 1, pageUnits.count)).compactMap { tagIfChecked($0) })
                later = included.filter(after.contains)
            }
        } else if conv.sent.contains(tag) {
            // Checked blocks after it on the page (reading order) that this conversation has seen.
            // Blocks merged into it are no longer units of their own.
            let pageUnits = units(on: page)
            let position = pageUnits.firstIndex { $0.ids == unit.ids } ?? pageUnits.count
            let seen = Set(conv.sent)
            later = pageUnits.suffix(from: min(position + 1, pageUnits.count))
                .compactMap { tagIfChecked($0) }
                .filter { $0 != tag && seen.contains($0) }
        }
        if hadCheck && (!later.isEmpty || conv.sent.contains(tag)) {
            parts.append(.text(AutoCheckPrompts.recheckBlock(tag, later: later)))
        } else {
            parts.append(.text(AutoCheckPrompts.checkBlock(tag)))
        }
        parts.append(.png(image.pngData))
        conversation = conv

        if continuable { continuationTag = tag }
        let laterIDs = later.compactMap { state.check(tagged: $0)?.ids }.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        setStage(.block(tag), busy: unit.ids.union(laterIDs))
        let reply = try await conv.conversation.send(parts)
        try ensureCurrent(run)

        let results = try AutoCheckReply.parseChecks(reply, expected: Set([tag] + later))
        guard let own = results.first(where: { $0.tag == tag }) else { throw AutoCheckError.unreadableReply(reply) }
        setVerdict(own, ids: unit.ids)
        for result in results where result.tag != tag { updateVerdict(result, keepReading: false) }
        if !conv.sent.contains(tag) { conv.sent.append(tag) }
        conv.turns += 1
        if conversation?.conversation === conv.conversation { conversation = conv }
        stateChanged()
    }

    // MARK: Pages

    /// Transcribes the current page and fixes it (docs/auto-check.md §4.2); its conversation ends.
    /// Blocks on it that were never checked are judged in the same request (a page request).
    private func fixPage(_ page: InkPage, run: Int) async throws {
        let pageUnits = units(on: page)
        let unchecked = pageUnits.filter { if case .unchecked = status(of: $0) { return true }; return false }
        if !unchecked.isEmpty {
            // Blocks never checked (e.g. its last one, never finished): judged with the transcription.
            try await pageRequest(ids: page.ids, rect: page.rect, pageUnits: pageUnits, judge: unchecked, modified: [],
                                  replacing: nil, run: run)
            closeConversation()
            return
        }
        let tagged = pageUnits.map { AutoCheckRender.Tagged(tag: tag(for: $0), bounds: $0.bounds) }
        stateChanged()   // tags handed out
        guard let image = AutoCheckRender.pageImage(board, rect: page.rect, ids: page.ids, tagged: tagged,
                                                     maxPixels: pageOptions.maxSide) else { return }
        let prompt = try service.documentPrompt()
        setStage(.transcribingPage, busy: [])
        let reply = try await service.sendCheckRequest([.text(prompt), .text(AutoCheckPrompts.transcriptionRequirements),
                                                        .png(image.pngData)])
        try ensureCurrent(run)
        state.pages.append(FixedPage(ids: page.ids, rect: page.rect, tags: tagged.map(\.tag),
                                     markdown: AutoCheckReply.parseTranscription(reply)))
        closeConversation()
        stateChanged()
    }

    /// Checks the units in `judge` on a page image and transcribes the page in one request
    /// (docs/auto-check.md §4.3–4.4). `replacing`: the fixed page it replaces; nil appends a new one.
    private func pageRequest(ids: Set<UUID>, rect: CGRect, pageUnits: [CheckUnit], judge: [CheckUnit],
                             modified: [String], replacing index: Int?, run: Int) async throws {
        let tags = pageUnits.map { tag(for: $0) }
        stateChanged()
        let judgeTags = judge.map { tag(for: $0) }
        let tagged = zip(pageUnits, tags).map { AutoCheckRender.Tagged(tag: $1, bounds: $0.bounds) }
        guard let image = AutoCheckRender.pageImage(board, rect: rect, ids: ids, tagged: tagged,
                                                     maxPixels: pageOptions.maxSide) else { return }
        var parts: [PromptPart] = [.text(AutoCheckPrompts.pageRequestIntro)]
        parts += previousPagesParts(Array(state.pages.prefix(index ?? state.pages.count)))
        parts += [.text(AutoCheckPrompts.checkAndTranscribePage(judgeTags, modified: modified)), .png(image.pngData)]
        setStage(.page(judgeTags), busy: judge.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) })
        let reply = try await service.sendCheckRequest(parts)
        try ensureCurrent(run)

        let answer = try AutoCheckReply.parsePageCheck(reply, expected: Set(judgeTags))
        // A page is fixed only when every block asked about was answered.
        guard Set(judgeTags).isSubset(of: answer.checks.map(\.tag)) else { throw AutoCheckError.unreadableReply(reply) }
        for result in answer.checks {
            if let unit = zip(judge, judgeTags).first(where: { $0.1 == result.tag })?.0 { setVerdict(result, ids: unit.ids) }
        }
        var markdown = answer.markdown
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // No transcription after the JSON: ask for it on its own.
            stateChanged()
            setStage(.transcribingPage, busy: [])
            let prompt = try service.documentPrompt()
            let text = try await service.sendCheckRequest([.text(prompt), .text(AutoCheckPrompts.transcriptionRequirements),
                                                           .png(image.pngData)])
            try ensureCurrent(run)
            markdown = AutoCheckReply.parseTranscription(text)
        }
        let page = FixedPage(ids: ids, rect: rect, tags: tags, markdown: markdown)
        if let index, state.pages.indices.contains(index) { state.pages[index] = page } else { state.pages.append(page) }
        stateChanged()
    }

    /// 检查 / 重新检查 of a block on a fixed page: the page again (§7.4), then the blocks after it
    /// from their transcriptions (§7.5). The page conversation's context is out of date afterwards.
    private func recheckFixedPage(_ index: Int, target: CheckUnit, run: Int) async throws {
        let fixed = state.pages
        let onPage = blocks.filter { AutoCheckPages.fixedPageIndex(of: $0, fixed: fixed) == index }
        let ids = onPage.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
        let pageUnits = units.filter { !$0.ids.isDisjoint(with: ids) }
        let pad = pageOptions.padding
        let content = onPage.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !content.isNull else { return }
        let rect = content.insetBy(dx: -pad, dy: -pad).integral

        // From the first changed unit on: blocks before it keep their context and verdict.
        let first = pageUnits.firstIndex { unit in
            if unit.ids == target.ids { return true }
            if case .checked = status(of: unit) { return false }
            return true
        } ?? 0
        let judge = Array(pageUnits.suffix(from: first))
        var changed: [String] = []
        for unit in judge {
            if unit.ids == target.ids { changed.append(tag(for: unit)); continue }
            if case .modified(let tag) = status(of: unit) { changed.append(tag) }
        }
        let modified = changed
        try await pageRequest(ids: ids, rect: rect, pageUnits: pageUnits, judge: judge, modified: modified,
                              replacing: index, run: run)

        // Later blocks: on the fixed pages after this one, and on the open pages.
        var later: [String] = []
        var readings: [String] = []
        for unit in units {
            guard case .checked(let tag) = status(of: unit) else { continue }
            if let page = fixedPageIndex(of: unit) {
                if page > index { later.append(tag) }
            } else {
                later.append(tag)
                readings.append("\(tag)：\(state.check(tagged: tag)?.reading ?? "")")
            }
        }
        if !later.isEmpty {
            var parts: [PromptPart] = [.text(AutoCheckPrompts.recheckLaterIntro)]
            parts += previousPagesParts(state.pages)
            if !readings.isEmpty {
                parts += [.text(AutoCheckPrompts.readingsHeading), .text(readings.joined(separator: "\n"))]
            }
            parts.append(.text(AutoCheckPrompts.recheckLater(later, changed: modified)))
            let laterIDs = later.compactMap { state.check(tagged: $0)?.ids }.reduce(into: Set<UUID>()) { $0.formUnion($1) }
            setStage(.laterBlocks(later), busy: laterIDs)
            let reply = try await service.sendCheckRequest(parts)
            try ensureCurrent(run)
            for result in try AutoCheckReply.parseChecks(reply, expected: Set(later)) {
                updateVerdict(result, keepReading: true)
            }
            stateChanged()
        }
        closeConversation()
    }

    /// Switching on (docs/auto-check.md §4.3): every open page but the last is checked and fixed
    /// with page requests; the last one is the first turn of the page conversation.
    private func fullCheck(run: Int) async throws {
        closeConversation()
        while true {
            let pages = openPages()
            guard let first = pages.first else { return }
            let pageUnits = units(on: first)
            let judge = pageUnits.filter { if case .checked = status(of: $0) { return false }; return true }
            if pages.count > 1 {
                if judge.isEmpty {
                    try await fixPage(first, run: run)
                } else {
                    let modified = judge.compactMap { unit -> String? in
                        if case .modified(let tag) = status(of: unit) { return tag }
                        return nil
                    }
                    try await pageRequest(ids: first.ids, rect: first.rect, pageUnits: pageUnits, judge: judge,
                                          modified: modified, replacing: nil, run: run)
                }
                closeConversation()
                continue
            }
            guard !judge.isEmpty else { return }
            if conversation == nil {
                setStage(.starting, busy: [])
                let opened = try await service.openCheckConversation()
                guard run == self.run else { opened.close(); throw CancellationError() }
                conversation = PageConversation(conversation: opened)
                continue   // the board may have changed while opening
            }
            try await checkLastPage(first, pageUnits: pageUnits, judge: judge, run: run)
            return
        }
    }

    private func checkLastPage(_ page: InkPage, pageUnits: [CheckUnit], judge: [CheckUnit], run: Int) async throws {
        guard var conv = conversation else { return }
        let tags = pageUnits.map { tag(for: $0) }
        let judgeTags = judge.map { tag(for: $0) }
        stateChanged()
        let tagged = zip(pageUnits, tags).map { AutoCheckRender.Tagged(tag: $1, bounds: $0.bounds) }
        guard let image = AutoCheckRender.pageImage(board, rect: page.rect, ids: page.ids, tagged: tagged,
                                                     maxPixels: pageOptions.maxSide) else { return }
        var parts: [PromptPart] = [.text(AutoCheckPrompts.conversationIntro)]
        parts += previousPagesParts(state.pages)
        parts += [.text(AutoCheckPrompts.checkPage(judgeTags)), .png(image.pngData)]
        setStage(.page(judgeTags), busy: judge.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) })
        let reply = try await conv.conversation.send(parts)
        try ensureCurrent(run)

        let results = try AutoCheckReply.parseChecks(reply, expected: Set(judgeTags))
        guard Set(judgeTags).isSubset(of: results.map(\.tag)) else { throw AutoCheckError.unreadableReply(reply) }
        for result in results {
            if let unit = zip(judge, judgeTags).first(where: { $0.1 == result.tag })?.0 { setVerdict(result, ids: unit.ids) }
        }
        conv.sent = tags
        conv.turns += 1
        conversation = conv
        // Writing on at the end of the page continues its last block.
        continuationTag = tags.last
        stateChanged()
    }

    private func previousPagesParts(_ pages: [FixedPage]) -> [PromptPart] {
        let markdown = pages.map(\.markdown).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !markdown.isEmpty else { return [] }
        return [.text(AutoCheckPrompts.previousPagesHeading), .text(markdown.joined(separator: "\n\n"))]
    }

    // MARK: Tags and results

    /// The unit's tag: its check's, a tag it was given before, or a new one.
    private func tag(for unit: CheckUnit) -> String {
        switch status(of: unit) {
        case .checked(let tag):
            return tag
        case .modified(let tag):
            // After a split only one part keeps the tag: the one holding most of its strokes.
            if let check = state.check(tagged: tag), primaryUnit(of: check)?.ids == unit.ids { return tag }
            return provisionalTag(for: unit)
        case .unchecked:
            return provisionalTag(for: unit)
        }
    }

    /// The unit holding most of a check's strokes (ties: the first in reading order).
    private func primaryUnit(of check: BlockCheck) -> CheckUnit? {
        var best: CheckUnit?
        var bestCount = 0
        for unit in units {
            let count = unit.ids.intersection(check.ids).count
            if count > bestCount { best = unit; bestCount = count }
        }
        return best
    }

    /// A tag given earlier to (most of) this unit while it has no check, or a new one.
    private func provisionalTag(for unit: CheckUnit) -> String {
        var best: String?
        var bestCount = 0
        for (tag, ids) in provisionalTags {
            let count = ids.intersection(unit.ids).count
            if count > bestCount || (count == bestCount && count > 0 && (AutoCheckTracker.tagNumber(tag) ?? 0) < (best.flatMap(AutoCheckTracker.tagNumber) ?? Int.max)) {
                best = tag; bestCount = count
            }
        }
        if let best {
            provisionalTags[best] = unit.ids
            return best
        }
        let tag = state.allocateTag()
        provisionalTags[tag] = unit.ids
        return tag
    }

    private func tagIfChecked(_ unit: CheckUnit) -> String? {
        if case .checked(let tag) = status(of: unit) { return tag }
        return nil
    }

    /// The verdict on a block sent with its strokes `ids`: replaces its check, and the checks merged
    /// into it (every surviving stroke of theirs is in `ids`). A check that only lent it a stroke
    /// keeps its verdict and shows as modified.
    private func setVerdict(_ result: AutoCheckReply.BlockResult, ids: Set<UUID>) {
        let present = Set(board.strokes.map(\.id))
        state.checks.removeAll { other in
            guard other.tag != result.tag else { return false }
            let surviving = other.ids.intersection(present)
            return !surviving.isEmpty && surviving.isSubset(of: ids)
        }
        state.setCheck(BlockCheck(tag: result.tag, ids: ids, reading: result.reading, issues: result.issues))
        provisionalTags[result.tag] = nil
    }

    /// A new verdict on a block that was not re-sent: its strokes stay as they were checked.
    private func updateVerdict(_ result: AutoCheckReply.BlockResult, keepReading: Bool) {
        guard var check = state.check(tagged: result.tag) else { return }
        if check.issues != result.issues { check.dismissed = false }
        check.issues = result.issues
        if !keepReading, !result.reading.isEmpty { check.reading = result.reading }
        state.setCheck(check)
    }

    /// A check in the answer format, for `previousVerdict`.
    static func verdictJSON(_ check: BlockCheck) -> String {
        let object: [String: Any] = [
            "id": check.tag,
            "reading": check.reading,
            "issues": check.issues.map { issue -> [String: Any] in
                ["severity": issue.severity.rawValue, "summary": issue.summary, "detail": issue.detail, "related": issue.related]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - Display

    private func isPending(_ unit: CheckUnit) -> Bool {
        !unit.ids.isDisjoint(with: busyIDs) || !unit.ids.isDisjoint(with: jobIDs) || queue.contains { job in
            if case .unit(let ids) = job.kind { return !ids.isDisjoint(with: unit.ids) }
            return false
        }
    }

    /// Units on open pages that are not checked as they are: what a full check will judge.
    private func fullCheckUnits() -> [CheckUnit] {
        openPages().flatMap { page in
            units(on: page).filter { if case .checked = status(of: $0) { return false }; return true }
        }
    }

    /// Only results and what needs the user stay on the canvas: blocks queued, being checked or
    /// being written get no mark of their own (the 自动检查 menu lists them), except that a red /
    /// yellow box stays while its block is re-checked.
    private func refreshMarks() {
        guard state.enabled else {
            marks = []
            return
        }
        // Switching on: everything the full check will judge.
        var waiting: Set<UUID> = []
        if fullCheckRunning || queue.contains(where: { $0.kind == .fullCheck }) {
            for unit in fullCheckUnits() { waiting.formUnion(unit.ids) }
        }
        let writing = tracker.currentUnit(in: units)
        var result: [Mark] = []
        for unit in units {
            let busy = isPending(unit) || !unit.ids.isDisjoint(with: waiting)
            let status = status(of: unit)
            if let writing, writing.ids == unit.ids {
                // Being written: a new block, or one written into without erasing anything checked
                // ("接着写", re-checked automatically when writing moves on if it continues the
                // block sent last; otherwise it then shows 重新检查).
                if case .unchecked = status { continue }
                if case .modified = status, AutoCheckTracker.grownFrom(unit, in: state.checks) != nil { continue }
            }
            switch status {
            case .unchecked:
                if !busy { result.append(Mark(kind: .check, ids: unit.ids, bounds: unit.bounds, tag: nil)) }
            case .checked(let tag):
                if let check = state.check(tagged: tag), let severity = check.severity, !check.dismissed {
                    result.append(Mark(kind: .issue(severity), ids: unit.ids, bounds: unit.bounds, tag: tag))
                }
            case .modified(let tag):
                let check = state.check(tagged: tag)
                if busy {
                    continue
                } else if let check, check.severity != nil, !check.dismissed {
                    result.append(Mark(kind: .modifiedBox, ids: unit.ids, bounds: unit.bounds, tag: tag))
                } else {
                    result.append(Mark(kind: .recheck, ids: unit.ids, bounds: unit.bounds, tag: tag))
                }
            }
        }
        marks = result
    }

    private func stateChanged() {
        onStateChange?(state)
    }

    private func displayChanged() {
        updateActivity()
        refreshMarks()
        onDisplayChange?()
    }
}
