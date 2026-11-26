import CoreGraphics
import Foundation
import InkboardCore

func runAutoCheckCoreChecks() async {
    checkWritingAndPages()
    do {
        try checkReplyFormats()
        try checkStoredResults()
        try replayHandwriting()
        try await checkHTTPHistory()
        try await checkAgentHistory()
    } catch {
        check(false, "Unexpected auto-check exception: \(error)")
    }
}

private func checkWritingAndPages() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), image = UUID()
    let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
    func block(_ ids: [UUID]) -> InkBlock { InkBlock(kind: .text, bounds: rect, strokeIDs: ids) }
    func unit(_ ids: [UUID]) -> CheckUnit {
        CheckUnit(ids: Set(ids), strokeIDs: ids, bounds: rect, kind: .text, blockIndex: 0)
    }
    let picture = InkBlock(kind: .image, bounds: rect, strokeIDs: [], imageIDs: [image])
    let figure = InkBlock(kind: .figure, bounds: rect, strokeIDs: [a,b], imageIDs: [image], children: [block([a]), block([b])])
    let units = AutoCheckTracker.units(in: [picture, figure, block([]), block([c])])
    check(units.map(\.strokeIDs) == [[a],[b],[c]] && units.map(\.imageIDs) == [[image],[image],[]]
          && units.map(\.blockIndex) == [1,1,3], "figure children inherit the image and reading position")
    let first = BlockCheck(tag: "B10", ids: [a]), second = BlockCheck(tag: "B2", ids: [b])
    let checks = [first, second]
    check(AutoCheckTracker.status(of: unit([a]), in: checks) == .checked(tag: "B10")
          && AutoCheckTracker.status(of: unit([c]), in: checks) == .unchecked
          && AutoCheckTracker.status(of: unit([a,b]), in: checks) == .modified(tag: "B2"), "exact, unchecked and merged identities")
    check(AutoCheckTracker.isContinuation(unit([a,c]), of: first, in: checks)
          && !AutoCheckTracker.isContinuation(unit([a,b]), of: first, in: checks)
          && !AutoCheckTracker.isContinuation(unit([a]), of: first, in: checks), "only unambiguous growth continues a check")

    var tracker = WritingTracker()
    check(tracker.didWrite(a, units: [unit([a])]) == nil
          && tracker.didWrite(b, units: [unit([a,b])]) == nil, "same block stays active")
    var split = tracker
    check(split.didWriteUnits(c, units: [unit([b,c]), unit([a])]) == [unit([a])]
          && split.writingIDs == [b,c], "split finishes the part away from the new stroke")
    let reunited = unit([a,b,c,d])
    check(split.didWriteUnits(d, units: [reunited]).isEmpty && split.writingIDs == reunited.ids
          && AutoCheckTracker.grownFrom(reunited, in: [first]) == [first], "re-merge absorbs the finished part")
    split = tracker
    check(split.didWriteUnits(c, units: [unit([b]),unit([c]),unit([a])]) == [unit([b]),unit([a])],
          "all split-off parts finish in reading order")
    check(tracker.didWrite(c, units: [unit([a,b,c])]) == nil && tracker.writingIDs == [a,b,c], "merged block becomes the current identity")
    split = tracker
    check(split.didWrite(d, units: [unit([c]),unit([a,b]),unit([d])]) == unit([c]), "single-result wrapper returns first finished unit")
    let beforeErase = BlockCheck(tag: "B3", ids: [b,c])
    check(AutoCheckTracker.grownFrom(unit([a,b,d]), in: [first, beforeErase]) == nil, "losing one checked stroke disqualifies an otherwise growing merge")
    check(AutoCheckTracker.grownFrom(unit([a,b]), in: checks) == [second, first], "merge without a new stroke returns both checks by numeric tag")
    check(AutoCheckTracker.grownFrom(unit([a]), in: checks) == nil && AutoCheckTracker.grownFrom(unit([c]), in: checks) == nil,
          "unchanged and disjoint units have no growth")
    split = tracker
    check(split.currentUnit(in: [unit([a,b])]) == nil && split.didWrite(d, units: [unit([a,b]),unit([d])]) == unit([a,b]),
          "after undo of last stroke, earlier surviving strokes can finish")
    check(tracker.didWrite(d, units: [unit([d])]) == nil, "a fully erased block cannot finish")

    let page = FixedPage(ids: [a,image], rect: rect, tags: ["B10"], markdown: "p")
    let neighbor = FixedPage(ids: [b,c], rect: rect.offsetBy(dx: 0, dy: 48), tags: [], markdown: "q")
    let fixed = [page, neighbor]
    var inside = block([d])
    inside.bounds = rect.offsetBy(dx: 0, dy: 32)
    var below = inside
    below.bounds = rect.offsetBy(dx: 0, dy: 100)
    check(AutoCheckPages.fixedPageIndex(of: block([a,b,c]), fixed: fixed) == 1
          && AutoCheckPages.fixedPageIndex(of: inside, fixed: fixed) == 1
          && AutoCheckPages.fixedPageIndex(of: below, fixed: fixed) == nil, "shared IDs precede geometry; new ink follows greatest coverage")
    let blocks = [picture,block([a]),below]
    check(!AutoCheckPages.isModified(page, at: 0, blocks: blocks, fixed: fixed)
          && AutoCheckPages.isModified(page, at: 0, blocks: Array(blocks.dropFirst()), fixed: fixed)
          && AutoCheckPages.isModified(page, at: 0, blocks: blocks + [block([d])], fixed: fixed), "page comparison includes pictures, additions and deletions")
    let options = PageAssembler.Options()
    check(AutoCheckPages.openPages(blocks: blocks, fixed: fixed, options: options).map(\.ids) == [[d]]
          && AutoCheckPages.openPages(blocks: blocks, fixed: [], options: options) == PageAssembler.pages(for: blocks), "only unassigned blocks pack into open pages")
}

private func checkReplyFormats() throws {
    let reply = #"""
    wrapped {aside}
    ```json
    {"blocks":[{"id":" b12 ","reading":"\frac{\beta}{\nabla} \theta \right \alpha \\frac \u0041 {\"x\"} \/",
      "issues":[{"severity":"Warning","summary":"a\n换行","related":[" b4 ","B+6","B0",4]},
                {"severity":"bad","summary":"x"}]},
      {"id":"B12","reading":"duplicate"},{"id":"B100"}]}
    ```
    trailing {math}
    """#
    let markdown = "<!-- B12 -->\n$x^{2}$"
    let input = reply + "\n<!-- PAGE -->\n```markdown\n" + markdown + "\n```"
    let page = try AutoCheckReply.parsePageCheck(input, expected: ["B12"])
    let result = page.checks.first
    check(page.checks.count == 1 && result?.tag == "B12" &&
          result?.reading == #"\frac{\beta}{\nabla} \theta \right \alpha \frac A {"x"} /"#, "JSON boundaries, duplicate tags, escaped and raw LaTeX")
    check(result?.issues == [CheckIssue(severity: .warning, summary: "a\n换行", related: ["B4"])], "severity and related tags normalized; legitimate newline preserved")
    check(page.markdown == markdown + "\n" && AutoCheckReply.parseTranscription(markdown) == page.markdown, "page markdown retains block comments")
    let missing = try AutoCheckReply.parsePageCheck(reply, expected: ["B12"])
    check(missing.markdown.isEmpty, "missing marker gives empty markdown")
    let inline = try AutoCheckReply.parsePageCheck(#"{"blocks":[{"id":"B12","issues":[]}]} <!-- PAGE -->"# + "\n" + markdown, expected: ["B12"])
    check(inline.checks.count == 1 && inline.markdown == markdown + "\n", "page marker right after the JSON is found too")
    let withComments = "a\n\n<!-- B1 -->\nb\n\n\n<!-- other -->\nc<!-- B12 -->d\n"
    check(AutoCheckReply.stripBlockComments(withComments) == "a\n\nb\n\n\n<!-- other -->\ncd\n", "only block markers and marker lines are stripped")
    check(AutoCheckReply.stripBlockComments("<!-- B1 -->\n\nx\n\n<!-- B2 -->\n\ny") == "x\n\ny",
          "standalone marker paragraphs leave no extra separator")
    do {
        _ = try AutoCheckReply.parseChecks("no verdict {oops}", expected: [])
        check(false, "unreadable response rejected")
    } catch AutoCheckError.unreadableReply { check(true, "unreadable response rejected") }
}

private func checkStoredResults() throws {
    let board = Board(strokes: [glyph(0,0), glyph(12,0)])
    let ids = Set(board.strokes.map(\.id))
    let deleted = UUID()
    let saved = AutoCheckState(enabled: true, checks: [
        BlockCheck(tag: "B9", ids: ids.union([deleted]), reading: "x",
                   issues: [CheckIssue(severity: .error, summary: "s", detail: "d", related: ["B1"])], dismissed: true)],
        pages: [FixedPage(ids: ids, rect: CGRect(x: 0, y: 0, width: 20, height: 20), tags: ["B9"], markdown: "m")], nextTag: 10)
    var stale = saved
    stale.checks.append(BlockCheck(tag: "B2", ids: [deleted]))
    stale.pages.append(FixedPage(ids: [deleted], rect: .zero, tags: [], markdown: "gone"))
    let data = try BoardStore.encode(board, autoCheck: stale)
    let restored = try BoardStore.decode(data)
    check(BoardStore.decodeAutoCheck(data, board: restored) == saved, "persist and prune checks, preserve historical shared sets")
    check(BoardStore.decodeAutoCheck(data, board: Board()).checks.isEmpty && BoardStore.decodeAutoCheck(data, board: Board()).pages.isEmpty,
          "prune on read for changed content")
    let object = try JSONSerialization.jsonObject(with: data) as! JSONObject
    let checkRecord = ((object["autoCheck"] as? JSONObject)?["checks"] as? [JSONObject])?.first
    let strokes = checkRecord?["strokes"] as? [String]
    check(strokes == ids.union([deleted]).map(\.uuidString).sorted(), "stored stroke ids sorted")
    let empty = try BoardStore.encode(board, autoCheck: AutoCheckState())
    let plain = try BoardStore.encode(board)
    let old = try JSONSerialization.jsonObject(with: plain) as! NSDictionary
    check(old.isEqual(try JSONSerialization.jsonObject(with: empty)) && old["autoCheck"] == nil
          && BoardStore.decodeAutoCheck(plain, board: board).isEmpty, "empty state preserves legacy document format")
    var malformed = object
    malformed["autoCheck"] = ["nextTag": "invalid"]
    let bad = try JSONSerialization.data(withJSONObject: malformed)
    check(try BoardStore.decode(bad).strokes.count == 2 && BoardStore.decodeAutoCheck(bad, board: board).isEmpty,
          "a malformed check record leaves the board readable")
}

private func replayHandwriting() throws {
    let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("test/未命名.inkboard")
    guard FileManager.default.fileExists(atPath: sample.path) else { return }
    let source = try BoardStore.decode(Data(contentsOf: sample))
    var tracker = WritingTracker()
    var board = Board(images: source.images, labels: source.labels)
    var state = AutoCheckState()
    var lastSent: String?
    let numbers = Dictionary(uniqueKeysWithValues: source.strokes.enumerated().map { ($0.element.id, $0.offset + 1) })
    var events: [String] = []
    var missingCurrent: [Int] = []
    for (index, stroke) in source.strokes.enumerated() {
        board.strokes.append(stroke)
        let blocks = InkLayout.analyze(board).blocks
        let units = AutoCheckTracker.units(in: blocks)
        let pages = AutoCheckPages.openPages(blocks: blocks, fixed: [], options: .init())
        for done in tracker.didWriteUnits(stroke.id, units: units) {
            let action: String
            if let parents = AutoCheckTracker.grownFrom(done, in: state.checks),
               parents.contains(where: { $0.tag == lastSent }) {
                let tags = parents.map(\.tag)
                state.checks.removeAll { tags.contains($0.tag) }
                let tag = parents[0].tag
                state.setCheck(BlockCheck(tag: tag, ids: done.ids))
                lastSent = tag
                action = "recheck " + tags.joined(separator: "+")
            } else {
                switch AutoCheckTracker.status(of: done, in: state.checks) {
                case .unchecked:
                    let tag = state.allocateTag()
                    state.setCheck(BlockCheck(tag: tag, ids: done.ids))
                    lastSent = tag
                    action = "new " + tag
                case .checked(let tag): action = "checked " + tag
                case .modified(let tag): action = "manual " + tag
                }
            }
            let ids = done.ids.compactMap { numbers[$0] }.sorted()
            guard let start = ids.first, let end = ids.last else {
                check(false, "finished sample unit has no known strokes")
                continue
            }
            check(ids == Array(start...end) && ids.count == done.ids.count && !done.ids.contains(stroke.id)
                  && pages.contains { done.ids.isSubset(of: $0.ids) }, "finished sample range belongs to one page at stroke \(index + 1)")
            events.append("\(index + 1): \(done.kind.rawValue)[\(start)–\(end)] \(action)")
        }
        if tracker.currentUnit(in: units)?.ids.contains(stroke.id) != true { missingCurrent.append(index + 1) }
    }
    check(missingCurrent.isEmpty, "sample strokes missing from the current unit: \(missingCurrent)")
    print("  Replay (\(source.strokes.count) strokes): " + events.joined(separator: ", "))
    check(events == [
        "11: formula[1–10] new B1", "38: formula[1–37] recheck B1",
        "61: formula[1–60] recheck B1",
        "101: text[61–100] new B2", "120: formula[101–119] new B3"
    ], "real note extends the derivation in B1 and finishes each following line when writing moves on")
}

private func checkHTTPHistory() async throws {
    let backend = OpenAICompatibleBackend(configuration: .init(baseURL: URL(string: "https://example.test/v1")!, apiKey: ""), session: StubHTTP.session)
    let profile = TranscriptionProfile(model: "check", thoughtLevel: "high", prompt: "")
    let document = TranscriptionProfile(model: "document", thoughtLevel: "", prompt: "doc")
    let service = AITranscriber(settings: { .init(backend: .openAI(backend.configuration), formula: document, document: document, check: profile) },
                                makeBackend: { _ in backend })
    StubHTTP.respond(200, #"{"choices":[{"message":{"content":"answer"}}]}"#)
    let conversation = try await service.openCheckConversation()
    _ = try await conversation.send([.text("one"), .png(Data([1]))])
    _ = try await conversation.send([.text("two")])
    func body() throws -> JSONObject { try JSONSerialization.jsonObject(with: StubHTTP.lastBody ?? Data()) as! JSONObject }
    let request = try body()
    let messages = request["messages"] as? [JSONObject] ?? []
    check(messages.map { $0["role"] as? String } == ["user","assistant","user"]
          && messages[1]["content"] as? String == "answer" && (messages[0]["content"] as? [JSONObject])?.count == 2
          && request["model"] as? String == "check" && request["reasoning_effort"] as? String == "high", "HTTP conversation replays images, replies and check settings")
    _ = try await service.sendCheckRequest([.text("independent")])
    let independent = try body()
    check((independent["messages"] as? [JSONObject])?.count == 1 && independent["model"] as? String == "check",
          "one-off check starts with fresh history")
    StubHTTP.respond(429, "{}")
    do { _ = try await conversation.send([.text("fail")]); check(false, "HTTP failure throws") }
    catch { check(!conversation.isUsable, "HTTP failure invalidates conversation") }
}

private func checkAgentHistory() async throws {
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    guard FileManager.default.isExecutableFile(atPath: python.path) else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let agent = ACPAgent(configuration: .init(executable: python, arguments: ["-I", "-u", "-c", mockAgentSource],
                                              environment: ProcessInfo.processInfo.environment, workingDirectory: folder))
    defer { agent.shutdown() }
    let a = try await agent.openConversation(model: "beta", thoughtLevel: "high")
    let b = try await agent.openConversation(model: "alpha", thoughtLevel: "high")
    let first = try await a.send([.text("one"),.png(Data([1]))])
    let other = try await b.send([.text("separate")])
    let second = try await a.send([.text("two")])
    check(TranscriptCleanup.latex(first) == "model=beta level=low images=1 permission=no"
          && TranscriptCleanup.latex(second) == "model=beta level=low images=0 permission=no turn=2"
          && TranscriptCleanup.latex(other) == "model=alpha level=high images=0 permission=no", "ACP sessions preserve independent history and collect only this turn")
    let slow = Task { try await a.send([.text("SLOW")]) }
    try await Task.sleep(nanoseconds: 80_000_000)
    slow.cancel()
    do { _ = try await slow.value; check(false, "cancelled ACP turn throws") }
    catch { check(error is CancellationError && !a.isUsable && b.isUsable, "cancellation invalidates only its session") }
    let idle = try await agent.openConversation(model: "", thoughtLevel: "")
    do { _ = try await b.send([.text("CRASH")]); check(false, "ACP crash throws") }
    catch { check(!idle.isUsable && !b.isUsable, "process exit invalidates idle and active conversations") }
    let replacement = try await agent.openConversation(model: "", thoughtLevel: "")
    replacement.close()
    check(!replacement.isUsable && !idle.isUsable, "closed and replaced sessions stay unusable")
}
