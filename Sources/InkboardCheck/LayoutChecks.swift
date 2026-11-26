import CoreGraphics
import Foundation
import InkboardCore

func runLayoutChecks() async {
    let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("test/test.inkboard")
    if FileManager.default.fileExists(atPath: sample.path) {
        do {
            let board = try BoardStore.decode(Data(contentsOf: sample))
            let blocks = InkLayout.analyze(board, options: .init()).blocks
            let indices = Dictionary(uniqueKeysWithValues: board.strokes.enumerated().map { ($1.id, $0 + 1) })
            let ranges = blocks.map { $0.strokeIDs.compactMap { indices[$0] } }
            check(blocks.map(\.kind) == [.text, .formula, .formula] && blocks.map(\.lines.count) == [1, 1, 1]
                  && ranges == [Array(1...21), Array(22...35), Array(36...52)],
                  "Integral sample preserves the three handwritten lines (\(describe(blocks)))")
        } catch { check(false, "Integral sample failed to load: \(error)") }
    } else { print("  - skipped: \(sample.path) not found") }

    // Statistics notes: one statement per row, rows well apart, text and formulas mixed in a row.
    let notes = sample.deletingLastPathComponent().appendingPathComponent("多元统计分析.inkboard")
    if FileManager.default.fileExists(atPath: notes.path) {
        do {
            let board = try BoardStore.decode(Data(contentsOf: notes))
            let blocks = InkLayout.analyze(board, options: .init()).blocks
            let indices = Dictionary(uniqueKeysWithValues: board.strokes.enumerated().map { ($1.id, $0 + 1) })
            let ranges = blocks.map { $0.strokeIDs.compactMap { indices[$0] } }
            let rows: [[Int]] = [Array(1...46), Array(47...79), Array(80...130), Array(131...190), Array(191...242) + [289],
                                 Array(243...288), Array(290...365) + Array(432...434), Array(366...379), Array(380...431),
                                 Array(435...477)]
            check(blocks.map(\.kind) == [.text, .text, .formula, .formula, .formula, .text, .text, .text, .formula, .formula]
                  && blocks.allSatisfy { $0.lines.count == 1 } && ranges == rows,
                  "Statistics notes: one block per written row (\(describe(blocks)))")
            // Row 3: hooked bar, superscript of t² left of the "="; row 5: hooked bar;
            // row 10: numerator overhanging the bar's end.
            check([2, 4, 8, 9].allSatisfy { blocks.indices.contains($0) && blocks[$0].lines.first?.hasFraction == true },
                  "…every fraction keeps its denominator")
        } catch { check(false, "Statistics notes failed to load: \(error)") }
    } else { print("  - skipped: \(notes.path) not found") }

    let options = InkLayout.Options(textHeight: 16)
    func blocks(_ ink: [Stroke]) -> [InkBlock] { InkLayout.analyze(Board(strokes: ink), options: options).blocks }
    let word = textLine(x: 20, baseline: 46, words: [3])
    let equation = blocks(word + equalsSign(x: 95, axis: 39))
    check(equation.map(\.kind) == [.formula] && equation[0].lines.count == 1, "Distant equals sign joins its formula")
    let integral = penStroke([(18, 66, 0.6), (22, 67, 0.6), (25, 51, 0.6),
                              (29, 25, 0.6), (33, 12, 0.6), (38, 13, 0.6)])
    let tall = blocks([integral] + textLine(x: 45, baseline: 46, words: [3]))
    check(tall.map(\.kind) == [.formula] && tall[0].lines.first?.strokeIDs.count == 4, "Tall open integral marks a formula")
    let columns = blocks(paragraph(x: 10, top: 10, lines: 3, words: [3]) + paragraph(x: 84, top: 10, lines: 3, words: [3]))
    check(columns.map(\.lines.count) == [3, 3], "Aligned column gutter keeps both columns separate")
    let other = textLine(x: 98, baseline: 46, words: [3])
    let divider = rectangle(CGRect(x: 73, y: 10, width: 8, height: 60))
    let divided = blocks(word + [divider] + other)
    check(divided.count == 3 && divided.allSatisfy { !$0.ids.contains(word[0].id) || !$0.ids.contains(other[0].id) },
          "A drawing in the gap prevents joining the flanking words")
    let boxed = blocks(word + [rectangle(CGRect(x: 10, y: 12, width: 60, height: 50))])
    check(boxed.map(\.kind) == [.text] && boxed[0].strokeIDs.count == 4 && boxed[0].lines.count == 1, "Closed frame keeps its word")
    let separated = blocks(word + textLine(x: 20, baseline: 89, words: [3]))
    check(separated.map(\.lines.count) == [1, 1], "A gap larger than 1.5 text heights separates paragraphs")
    let hooked = penStroke(line(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 110, y: 60.5), samples: 6) + [(107, 63, 0.6)])
    let fraction = blocks(textLine(x: 66, baseline: 55, words: [3]) + [hooked] + textLine(x: 66, baseline: 79, words: [3]))
    check(fraction.map(\.kind) == [.formula] && fraction[0].lines.count == 1 && fraction[0].lines[0].hasFraction,
          "A fraction bar hooked at its end is still a bar (\(describe(fraction)))")
    let row = blocks(word + textLine(x: 120, baseline: 46, words: [3]))
    check(row.count == 1 && row[0].lines.count == 1, "Writing four text heights further right stays on its row")
    let outdented = blocks(textLine(x: 60, baseline: 40, words: [3, 2]) + textLine(x: 20, baseline: 76, words: [4, 3]))
    let aligned = blocks(textLine(x: 20, baseline: 40, words: [3, 2]) + textLine(x: 20, baseline: 76, words: [4, 3]))
    check(outdented.map(\.lines.count) == [1, 1] && aligned.map(\.lines.count) == [2],
          "A moderate gap separates rows starting at different margins, not rows sharing one")

    let second = textLine(x: 20, baseline: 136, words: [3])
    var board = Board(strokes: word + second)
    let assisted = InkLayout.Options(textHeight: 16, useGroups: true)
    let groups = [BlockGroup(ids: Set([word[0].id, word[1].id, second[0].id]), kind: .formula),
                  BlockGroup(ids: [word[2].id], kind: .text)]
    board.groups = groups
    let unclaimed = glyph(61, 46)
    board.strokes.append(unclaimed)
    let grouped = InkLayout.analyze(board, options: assisted).blocks
    let merged = grouped.first { $0.kind == .formula }
    let rest = grouped.first { $0.kind == .text }
    check(grouped.count == 2 && merged?.lines.map(\.strokeIDs.count) == [3, 3] && merged?.ids.contains(unclaimed.id) == true
          && rest?.strokeIDs == [word[2].id], "Groups split a line, join rows, and claim new ink by majority")
    check(InkLayout.analyze(board, options: options).blocks.map(\.kind) == [.text, .text], "Local geometry ignores stored groups")
    var pictured = board
    pictured.images = [BoardImage(data: retinaTwoTonePNG(), frame: CGRect(x: 0, y: 0, width: 100, height: 70))!]
    let pictureBlocks = InkLayout.analyze(pictured, options: assisted).blocks
    let figure = pictureBlocks.first { $0.kind == .figure }
    check(pictureBlocks.count == 2 && figure?.children.count == 2 && figure?.ids.contains(second[0].id) == false,
          "A group crossing a picture boundary splits into figure children and external writing")
    board.strokes.removeAll { $0.id == word[1].id || $0.id == word[2].id }
    let erased = InkLayout.analyze(board, options: assisted).blocks
    check(erased.count == 1 && erased[0].ids == board.ids && erased[0].kind == .formula, "Groups ignore erased strokes")
    do {
        let data = try BoardStore.encode(board)
        let decoded = try BoardStore.decode(data)
        check(decoded.groups == [BlockGroup(ids: [word[0].id, second[0].id], kind: .formula)], "Groups survive storage with stale IDs pruned")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stored = (object?["groups"] as? [[String: Any]])?.first?["strokes"] as? [String]
        check(stored == decoded.groups.first?.ids.map(\.uuidString).sorted() && object?["version"] as? Int == 2, "Group IDs are sorted in version 2")
        board.groups = []
        let legacy = try JSONSerialization.jsonObject(with: BoardStore.encode(board)) as? [String: Any]
        check(legacy?["groups"] == nil, "Boards without groups omit the groups field")
        let units = BlockLabeling.units(in: separated + [InkBlock(kind: .drawing, bounds: .zero, strokeIDs: [UUID()])])
        let reply = """
            here: ```json
            {"blocks":[{"units":["L1"],"kind":"image"},{"units":[" l1 ","unknown"],"kind":" FORMULA "},
                       {"units":["L1","g1"],"kind":"diagram"}]}
            ```
            """
        let parsed = try BlockSegmentation.parse(reply, units: units)
        check(parsed == [BlockGroup(ids: units[0].ids, kind: .formula), BlockGroup(ids: units[2].ids, kind: .diagram)],
              "Parsing tolerates wrappers and skips invalid, duplicate and unmentioned units")
        check((try? BlockSegmentation.parse("absent", units: units)) == nil, "Unreadable segmentation throws")
    } catch { check(false, "Segmentation persistence or parsing failed: \(error)") }
}
