import CoreGraphics
import Foundation
import ImageIO
import InkboardCore
import UniformTypeIdentifiers

// Lightweight assertions for InkboardCore (no XCTest with Command Line Tools).
// Usage: swift run InkboardCheck [output.png]

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)  (line \(line))")
    }
}

/// Simulates a pen stroke through the smoother, like the canvas does.
func penStroke(_ samples: [(CGFloat, CGFloat, CGFloat)], width: CGFloat = 3) -> Stroke {
    var smoother = StrokeSmoother()
    for (x, y, p) in samples { smoother.add(InkPoint(x: x, y: y, pressure: p)) }
    return Stroke(points: smoother.finish(), width: width)
}

func line(from a: CGPoint, to b: CGPoint, samples: Int, pressure: (CGFloat) -> CGFloat = { _ in 0.6 }) -> [(CGFloat, CGFloat, CGFloat)] {
    (0...samples).map { i in
        let t = CGFloat(i) / CGFloat(samples)
        return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, pressure(t))
    }
}

print("Smoother")
do {
    let s = penStroke(line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), samples: 10))
    check(s.points.count >= 95, "resamples a 100-unit line to ~1 unit spacing (\(s.points.count) points)")
    check(s.points.allSatisfy { abs($0.y) < 0.01 }, "straight input stays straight")
    check(abs(s.points.last!.x - 100) < 0.01, "ends exactly on the last sample")

    var smoother = StrokeSmoother()
    smoother.add(InkPoint(x: 0, y: 0, pressure: 0.5))
    smoother.add(InkPoint(x: 10, y: 0, pressure: 0.5))
    check(smoother.output.count == 1 && smoother.tail.count == 1, "latest segment stays provisional until the next sample")
    smoother.add(InkPoint(x: 20, y: 5, pressure: 0.5))
    check(smoother.output.count > 5 && smoother.tail.count == 1, "previous segment is finalised once the next sample arrives")

    let dot = penStroke([(5, 5, 0.6)])
    check(dot.points.count == 1 && dot.bounds.width > 0, "a single tap makes a dot")
}

print("Pressure")
do {
    let light = StrokeGeometry.radius(pressure: 0.1, width: 4)
    let firm = StrokeGeometry.radius(pressure: 1, width: 4)
    check(firm > 2.5 * light, "firm pressure is much wider than light pressure (\(light) → \(firm))")
}

print("Eraser")
do {
    let s = penStroke(line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), samples: 20))
    let cut = InkOps.erase([s], from: CGPoint(x: 50, y: -20), to: CGPoint(x: 50, y: 20), radius: 5)
    check(cut?.strokes.count == 2, "erasing the middle splits the stroke in two")
    let miss = InkOps.erase([s], from: CGPoint(x: 50, y: 30), to: CGPoint(x: 60, y: 30), radius: 5)
    check(miss == nil, "erasing empty space changes nothing")
    let all = InkOps.erase([s], from: CGPoint(x: -10, y: 0), to: CGPoint(x: 110, y: 0), radius: 5)
    check(all?.strokes.isEmpty == true, "sweeping along the whole stroke removes it")
}

print("Lasso")
do {
    let inside = penStroke(line(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 30), samples: 5))
    let outside = penStroke(line(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 220, y: 210), samples: 5))
    let crossing = penStroke(line(from: CGPoint(x: 80, y: 50), to: CGPoint(x: 180, y: 50), samples: 5))  // ~20% inside
    let lasso = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
    let selected = InkOps.strokes(inLasso: lasso, from: [inside, outside, crossing])
    check(selected == [inside.id], "selects strokes mostly inside the lasso only")
    check(InkOps.hitTest(CGPoint(x: 30, y: 25), in: [inside, outside], tolerance: 3) == inside.id, "tap hit-tests a stroke")
}

print("Insert space")
do {
    let above = penStroke(line(from: CGPoint(x: 0, y: 10), to: CGPoint(x: 50, y: 10), samples: 5))
    let below = penStroke(line(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 50, y: 110), samples: 5))
    let ids = InkOps.itemsBelow(60, in: Board(strokes: [above, below]))
    check(ids == [below.id], "only strokes below the line move")
    let minDelta = InkOps.minimumSpaceDelta(lineY: 60, moving: ids, in: Board(strokes: [above, below]))
    check(minDelta < -30 && minDelta > -45, "removing space stops when ink reaches the line (\(minDelta))")
    let moved = InkOps.translate([above, below], ids: ids, dx: 0, dy: 40)
    check(abs(moved[1].bounds.minY - below.bounds.minY - 40) < 0.001 && moved[0].bounds == above.bounds,
          "translation moves points and bounds of the selected strokes only")
}

print("Persistence")
do {
    let s = penStroke(line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 30, y: 40), samples: 6))
    let data = try BoardStore.encode(Board(strokes: [s]))
    let back = try BoardStore.decode(data).strokes
    check(back.count == 1 && back[0].id == s.id && back[0].points.count == s.points.count, "JSON round-trip keeps strokes")
} catch {
    check(false, "JSON round-trip threw \(error)")
}

func hline(_ x0: CGFloat, _ x1: CGFloat, y: CGFloat) -> Stroke {
    penStroke(line(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), samples: 10))
}

print("Page images")
do {
    let tall = penStroke(line(from: CGPoint(x: 50, y: 0), to: CGPoint(x: 60, y: 5000), samples: 50))
    let image = InkImage.render([tall], rect: CGRect(x: 0, y: 0, width: 300, height: 2500), maxPixels: 1000)
    check(image.map { max($0.pixelSize.width, $0.pixelSize.height) <= 1000 } == true, "page images respect the pixel limit")
    check(InkImage.render([tall], rect: CGRect(x: 500, y: 0, width: 100, height: 100)) == nil, "a box without ink renders nothing")
}

print("Pictures: import")
do {
    let twoTone = twoToneImage(width: 200, height: 100)
    let retinaPNG = retinaTwoTonePNG()
    let kept = ImageImport.prepare(retinaPNG)
    check(kept?.data == retinaPNG, "PNG is stored byte for byte")
    check(kept?.size == CGSize(width: 100, height: 50), "a 144-DPI (Retina) picture comes in at half its pixel size (\(String(describing: kept?.size)))")

    let tiff = ImageImport.prepare(encode([(twoTone, [:])], as: .tiff))
    check(tiff.map { imageType($0.data) } == UTType.png.identifier, "TIFF is re-encoded as PNG")
    check(tiff?.size == CGSize(width: 200, height: 100), "without DPI, one pixel is one canvas unit")

    let small = twoToneImage(width: 100, height: 50)
    let multi = ImageImport.prepare(encode([(small, [kCGImagePropertyDPIWidth: 72]),
                                            (twoTone, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])], as: .tiff))
    let multiImage = multi.flatMap { BoardImage(data: $0.data, frame: .zero) }
    check(multiImage?.pixelSize == CGSize(width: 200, height: 100) && multi?.size == CGSize(width: 100, height: 50),
          "a 1x + 2x clipboard TIFF keeps the sharper picture at its on-screen size")

    let shrunk = ImageImport.prepare(retinaPNG, maxPixels: 50)
    let shrunkImage = shrunk.flatMap { BoardImage(data: $0.data, frame: .zero) }
    check(shrunkImage?.pixelSize == CGSize(width: 50, height: 25) && shrunk?.size == CGSize(width: 100, height: 50),
          "an oversized picture is downscaled but keeps its natural size")

    // EXIF orientation 6: the stored picture is shown rotated 90° clockwise (stored top → right side).
    let rotated = ImageImport.prepare(encode([(twoTone, [kCGImagePropertyOrientation: 6])], as: .jpeg))
    let upright = rotated.flatMap { BoardImage(data: $0.data, frame: .zero) }
    check(rotated?.size == CGSize(width: 100, height: 200) && upright?.pixelSize == CGSize(width: 100, height: 200),
          "a rotated photo is stored upright")
    if let upright {
        let px = Pixels(upright.image)
        check(px.isRed(75, 100) && px.isBlue(25, 100), "…turned the right way")
    }
    check(rotated.map { imageType($0.data) } == UTType.jpeg.identifier, "photos stay JPEG")

    check(ImageImport.prepare(Data("not an image".utf8)) == nil && BoardImage(data: Data([1, 2, 3]), frame: .zero) == nil,
          "data that isn't an image is refused")
}

print("Pictures on the board")
do {
    let retinaPNG = retinaTwoTonePNG()
    let picture = BoardImage(data: retinaPNG, frame: CGRect(x: 100, y: 100, width: 100, height: 50))!
    let ink = hline(120, 180, y: 110)
    let board = Board(strokes: [ink], images: [picture])
    check(board.bounds == picture.frame.union(ink.bounds) && board.ids == [ink.id, picture.id], "a board covers ink and pictures")
    check(InkOps.hitTest(CGPoint(x: 150, y: 140), in: board, tolerance: 2) == picture.id, "tapping a picture away from ink selects the picture")
    check(InkOps.hitTest(CGPoint(x: 150, y: 110), in: board, tolerance: 2) == ink.id, "ink on top of a picture is hit first")

    let around = [CGPoint(x: 90, y: 90), CGPoint(x: 210, y: 90), CGPoint(x: 210, y: 160), CGPoint(x: 90, y: 160)]
    check(InkOps.selection(inLasso: around, in: board) == [ink.id, picture.id], "the lasso selects pictures and ink together")
    let edge = [CGPoint(x: 90, y: 90), CGPoint(x: 130, y: 90), CGPoint(x: 130, y: 160), CGPoint(x: 90, y: 160)]
    check(!InkOps.selection(inLasso: edge, in: board).contains(picture.id), "a picture mostly outside the lasso isn't selected")

    let moved = InkOps.translate(board, ids: [picture.id], dx: 10, dy: 20)
    check(moved.images[0].frame.origin == CGPoint(x: 110, y: 120) && moved.strokes[0].bounds == ink.bounds,
          "moving translates the picked picture only")
    check(InkOps.itemsBelow(120, in: board) == [picture.id], "insert space pushes pictures whose centre is below the line")
    check(abs(InkOps.minimumSpaceDelta(lineY: 90, moving: [picture.id], in: board) + 10) < 0.001,
          "removing space stops when a picture reaches the line")
    check(board.removing([picture.id]).images.isEmpty && board.subset([picture.id]).strokes.isEmpty, "delete / subset by id")

    let frame = CGRect(x: 100, y: 100, width: 100, height: 50)
    let grown = InkOps.resize(frame, dragging: .bottomRight, to: CGPoint(x: 400, y: 120), minSide: 10)
    check(grown == CGRect(x: 100, y: 100, width: 300, height: 150), "resizing keeps the aspect ratio and the opposite corner (\(grown))")
    let shrunk = InkOps.resize(frame, dragging: .topLeft, to: CGPoint(x: 150, y: 140), minSide: 10)
    check(shrunk == CGRect(x: 150, y: 125, width: 50, height: 25), "dragging the top-left corner anchors the bottom-right (\(shrunk))")
    let tiny = InkOps.resize(frame, dragging: .topRight, to: CGPoint(x: 0, y: 500), minSide: 10)
    check(tiny == CGRect(x: 100, y: 140, width: 20, height: 10), "the frame stops at the minimum size instead of flipping (\(tiny))")

    let stored = BoardImage(data: retinaPNG, frame: CGRect(x: 10.123, y: 20, width: 100, height: 50))!
    let back = try BoardStore.decode(BoardStore.encode(Board(strokes: [ink], images: [stored])))
    check(back.strokes.count == 1 && back.images.count == 1 && back.images[0].id == stored.id && back.images[0].data == retinaPNG
          && back.images[0].frame == CGRect(x: 10.12, y: 20, width: 100, height: 50), "pictures are saved in the file")
    let version1 = #"{"version":1,"strokes":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","width":3,"points":[0,0,0.5,10,10,0.5]}]}"#
    let old = try BoardStore.decode(Data(version1.utf8))
    check(old.strokes.count == 1 && old.images.isEmpty, "version 1 files (ink only) still open")

    let bitmap = InkRenderer.renderImage(Board(strokes: [hline(5, 35, y: 30)], images: [BoardImage(data: retinaPNG, frame: CGRect(x: 0, y: 0, width: 40, height: 40))!]),
                                         rect: CGRect(x: 0, y: 0, width: 40, height: 40), scale: 1)
    if let bitmap {
        let px = Pixels(bitmap)
        check(px.isRed(20, 8) && px.isBlue(20, 36), "PNG export draws pictures upright")
        check(px.isDark(20, 30), "ink is drawn over pictures")
    } else {
        check(false, "render a board with a picture")
    }
} catch {
    check(false, "pictures threw \(error)")
}

print("PDF export")
do {
    // 15 paragraphs of 4 lines, a blank line apart.
    let board = Board(strokes: (0..<15).flatMap { paragraph(x: 20, top: 20 + CGFloat($0) * 5 * 34, lines: 4) })
    let options = PDFExport.Options()
    let printable = CGSize(width: options.pageSize.width - 2 * options.margin, height: options.pageSize.height - 2 * options.margin)
    let pages = PDFExport.layout(board, options: options)
    check(pages.count >= 2, "a long board becomes several pages (\(pages.count))")
    check(pages.allSatisfy { $0.rect.width * $0.scale <= printable.width + 0.5 && $0.rect.height * $0.scale <= printable.height + 0.5 },
          "every page fits the printable area")
    check(Set(pages.map { ($0.scale * 1000).rounded() }).count == 1 && Set(pages.map(\.rect.minX)).count == 1,
          "pages share one scale and left edge")
    let blocks = InkLayout.analyze(board).blocks
    check(blocks.allSatisfy { block in pages.filter { $0.ids.isSuperset(of: block.ids) }.count == 1 },
          "every paragraph is whole on exactly one page")

    let document = PDFExport.data(board, options: options).flatMap(pdfDocument)
    check(document?.numberOfPages == pages.count, "the PDF has one page per layout page")
    check(document?.page(at: 1)?.getBoxRect(.mediaBox).size == options.pageSize, "pages are A4")
    check(PDFExport.data(Board()) == nil, "an empty board exports nothing")

    // A drawing taller than a page gets a page of its own, shrunk to fit.
    let zigzag = penStroke((0...10).map { (i: Int) -> (CGFloat, CGFloat, CGFloat) in
        (CGFloat(i % 2) * 200, 200 + CGFloat(i) * 300, 0.6)
    })
    let tall = PDFExport.layout(Board(strokes: paragraph(x: 20, top: 20, lines: 3) + [zigzag]), options: options)
    check(tall.count == 2 && tall[1].rect.height * tall[1].scale <= printable.height + 0.5 && tall[1].scale < tall[0].scale,
          "an oversized drawing is shrunk onto its own page")

    let picture = BoardImage(data: retinaTwoTonePNG(), frame: CGRect(x: 0, y: 0, width: 400, height: 200))!
    let pictured = PDFExport.data(Board(strokes: [hline(20, 380, y: 150)], images: [picture])).flatMap(pdfDocument)
    if let page = pictured?.page(at: 1) {
        let px = Pixels(rasterize(page))
        let column = px.width / 2
        let red = (0..<px.height).filter { px.isRed(column, $0) }, blue = (0..<px.height).filter { px.isBlue(column, $0) }
        check(pictured?.numberOfPages == 1 && !red.isEmpty && !blue.isEmpty && red.max()! < blue.min()!,
              "pictures are upright in the PDF")
        check((0..<px.height).contains { px.isDark(column, $0) }, "ink is drawn over the picture in the PDF")
        check(abs(CGFloat(red.min() ?? 0) - options.margin) < 10, "content starts at the top margin (\(red.min() ?? -1))")
    } else {
        check(false, "PDF with a picture")
    }
}

print("Layout: blocks")
do {
    // Two paragraphs separated by a blank line (line pitch 34, glyphs ~16 tall).
    let two = Board(strokes: paragraph(x: 20, top: 20, lines: 3) + paragraph(x: 20, top: 20 + 4 * 34, lines: 2))
    let result = InkLayout.analyze(two)
    check(result.textHeight > 13 && result.textHeight < 20, "text height is estimated from the writing (\(result.textHeight))")
    check(result.blocks.map(\.kind) == [.text, .text] && result.blocks.map(\.lines.count) == [3, 2],
          "a blank line separates paragraphs; lines are found (\(describe(result.blocks)))")

    // Paragraph, a formula with a fraction on its own, paragraph.
    let formulaTop: CGFloat = 20 + 3 * 34 + 40
    var strokes = paragraph(x: 20, top: 20, lines: 3)
    strokes += fractionFormula(x: 60, axis: formulaTop + 20)
    strokes += paragraph(x: 20, top: formulaTop + 40 + 40, lines: 2)
    let withFormula = InkLayout.analyze(Board(strokes: strokes)).blocks
    check(withFormula.map(\.kind) == [.text, .formula, .text] && withFormula[1].lines.count == 1,
          "a standalone fraction is a one-line formula block (\(describe(withFormula)))")

    // The same fraction inside a paragraph (no blank lines): it stays in the text block.
    var inline = paragraph(x: 20, top: 20, lines: 2)
    inline += fractionFormula(x: 60, axis: 20 + 2 * 34 + 26)
    inline += paragraph(x: 20, top: 20 + 2 * 34 + 52, lines: 1)
    let inlineBlocks = InkLayout.analyze(Board(strokes: inline)).blocks
    check(inlineBlocks.map(\.kind) == [.text, .formula, .text] && inlineBlocks.map(\.lines.count) == [2, 1, 1],
          "a formula line between lines of text splits the paragraph (\(describe(inlineBlocks)))")

    // "=" is found; stacked strokes of a character (三) are not mistaken for it.
    let equation = Board(strokes: [glyph(20, 40)] + equalsSign(x: 36, axis: 33) + [glyph(56, 40)])
    let equationLines = InkLayout.analyze(equation).blocks.flatMap(\.lines)
    check(equationLines.count == 1 && equationLines[0].hasEquals && equationLines[0].kind == .formula, "a line with \"=\" is a formula")

    // A raised superscript and a subscript hanging below the baseline join their line.
    var scripts = textLine(x: 20, baseline: 40, words: [3])
    scripts.append(glyph(62, 24, width: 6, height: 8))                      // superscript, mostly above
    scripts += textLine(x: 20, baseline: 120, words: [2])
    scripts.append(glyph(48, 133, width: 6, height: 9))                     // subscript, mostly below
    let scriptLines = InkLayout.analyze(Board(strokes: scripts)).blocks.flatMap(\.lines)
    check(scriptLines.count == 2 && scriptLines.map(\.strokeIDs.count) == [4, 3],
          "super- and subscripts join their line (\(scriptLines.map(\.strokeIDs.count)))")

    // Stacked strokes (like 三) written one after another: one line per row of characters.
    let han = Board(strokes: (0..<3).flatMap { row in hanLine(x: 20, top: 20 + CGFloat(row) * 34, characters: 8) })
    let hanBlocks = InkLayout.analyze(han).blocks
    check(hanBlocks.count == 1 && hanBlocks[0].lines.count == 3, "stacked strokes of a character stay on their line (\(describe(hanBlocks)))")
    check(InkLayout.analyze(han).blocks.allSatisfy { $0.kind == .text }, "characters made of stacked strokes are not \"=\"")

    // A diagram (circle → rectangle with an arrow, a label inside the circle), its caption, and
    // a paragraph to the right of it.
    var diagram = circle(cx: 100, cy: 100, r: 60) + [rectangle(CGRect(x: 230, y: 65, width: 100, height: 70))]
    diagram.append(penStroke(line(from: CGPoint(x: 162, y: 100), to: CGPoint(x: 228, y: 100), samples: 8)))
    diagram += textLine(x: 80, baseline: 108, words: [3])                     // label inside the circle
    diagram += textLine(x: 40, baseline: 210, words: [4, 3, 5])               // caption below
    diagram += paragraph(x: 420, top: 40, lines: 4)                           // text beside it
    let diagramBlocks = InkLayout.analyze(Board(strokes: diagram)).blocks
    check(diagramBlocks.map(\.kind) == [.diagram, .text, .text] && diagramBlocks.map(\.lines.count) == [0, 1, 4],
          "diagram, its caption, then the text beside it (\(describe(diagramBlocks)))")
    let rowsFirst = InkLayout.readingOrder([CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 300, y: 0, width: 100, height: 200),
                                            CGRect(x: 0, y: 100, width: 100, height: 50), CGRect(x: 0, y: 250, width: 400, height: 50)])
    check(rowsFirst == [0, 2, 1, 3], "reading order is top to bottom, side by side left to right (\(rowsFirst))")
    check(diagramBlocks.first?.strokeIDs.count == 6, "the diagram includes its label (\(diagramBlocks.first?.strokeIDs.count ?? 0) strokes)")
    check(diagramBlocks.count == 3 && diagramBlocks[1].bounds.minY > diagramBlocks[0].bounds.maxY
          && diagramBlocks[2].bounds.minX > diagramBlocks[0].bounds.maxX, "reading order: left column top to bottom, then right")

    let freehand = InkLayout.analyze(Board(strokes: circle(cx: 100, cy: 100, r: 60) + circle(cx: 180, cy: 110, r: 50))).blocks
    check(freehand.map(\.kind) == [.drawing], "curves without labels are a drawing (\(describe(freehand)))")

    // A box drawn around two lines of text is boxed text, not a diagram.
    let boxed = paragraph(x: 40, top: 40, lines: 2) + [rectangle(CGRect(x: 28, y: 30, width: 260, height: 90))]
    let boxedBlocks = InkLayout.analyze(Board(strokes: boxed)).blocks
    check(boxedBlocks.map(\.kind) == [.text] && boxedBlocks[0].lines.count == 2 && boxedBlocks[0].strokeIDs.count == boxed.count,
          "a box around writing keeps it a text block (\(describe(boxedBlocks)))")

    // Pictures: plain, annotated (circle + word on it; a line below only grazes it), and two
    // pictures joined by an arrow.
    let png = retinaTwoTonePNG()
    let plain = BoardImage(data: png, frame: CGRect(x: 20, y: 20, width: 200, height: 150))!
    let annotated = BoardImage(data: png, frame: CGRect(x: 20, y: 260, width: 200, height: 150))!
    let left = BoardImage(data: png, frame: CGRect(x: 20, y: 560, width: 150, height: 100))!
    let right = BoardImage(data: png, frame: CGRect(x: 230, y: 560, width: 150, height: 100))!
    var ink = circle(cx: 80, cy: 320, r: 30)
    ink += textLine(x: 140, baseline: 360, words: [3])
    ink += textLine(x: 20, baseline: 425, words: [4, 3, 4, 5])                 // top edge dips into the picture
    ink.append(penStroke(line(from: CGPoint(x: 120, y: 610), to: CGPoint(x: 290, y: 612), samples: 10)))
    let pictured = InkLayout.analyze(Board(strokes: ink, images: [plain, annotated, left, right])).blocks
    check(pictured.map(\.kind) == [.image, .figure, .text, .figure], "pictures become image / figure blocks (\(describe(pictured)))")
    if pictured.count == 4 {
        check(pictured[1].children.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.drawing, .text],
              "ink on a picture is segmented into child blocks (\(describe(pictured[1].children)))")
        check(pictured[2].strokeIDs.count == 16, "a line mostly off the picture stays outside it")
        check(pictured[3].imageIDs == [left.id, right.id] && pictured[3].strokeIDs.count == 1, "ink joining two pictures makes one figure")
    }

    // Size doesn't matter: the same page at twice the size gives the same blocks.
    let page = Board(strokes: strokes + diagram.map { $0.translated(dx: 0, dy: 400) }, images: [])
    let doubled = Board(strokes: page.strokes.map { s in
        Stroke(points: s.points.map { InkPoint(x: $0.x * 2, y: $0.y * 2, pressure: $0.pressure) }, width: s.width * 2)
    })
    let normal = InkLayout.analyze(page).blocks, big = InkLayout.analyze(doubled).blocks
    check(normal.map(\.kind) == [.text, .formula, .text, .diagram, .text, .text] && normal.map(\.lines.count) == [3, 1, 2, 0, 1, 4],
          "a diagram's caption follows it even below other content (\(describe(normal)))")
    check(normal.map(\.kind) == big.map(\.kind) && normal.map(\.strokeIDs.count) == big.map(\.strokeIDs.count)
          && normal.map(\.lines.count) == big.map(\.lines.count), "segmentation doesn't depend on handwriting size (\(describe(normal)))")

    check(InkLayout.analyze(Board()).blocks.isEmpty, "an empty board has no blocks")

    let manyLines = Board(strokes: (0..<120).flatMap { textLine(x: 20, baseline: 30 + CGFloat($0) * 34, words: [5, 4, 6, 3, 5, 4, 6, 5]) })
    let started = Date()
    let many = InkLayout.analyze(manyLines).blocks
    let seconds = Date().timeIntervalSince(started)
    check(many.count == 1 && many[0].lines.count == 120 && seconds < 2,
          "\(manyLines.strokes.count) strokes analysed in \(String(format: "%.3f", seconds)) s")
}

print("Layout: pages")
do {
    // 15 paragraphs of 4 lines, a blank line apart.
    let strokes = (0..<15).flatMap { paragraph(x: 20, top: 20 + CGFloat($0) * 5 * 34, lines: 4) }
    let blocks = InkLayout.analyze(Board(strokes: strokes)).blocks
    let options = PageAssembler.Options()
    let pages = PageAssembler.pages(for: blocks, options: options)
    let maxHeight = max(pages.first?.rect.width ?? 0, options.minWidth) * options.aspect
    check(blocks.count == 15 && pages.count >= 2, "\(blocks.count) paragraphs make \(pages.count) pages")
    check(pages.flatMap(\.blocks) == blocks, "pages hold whole blocks, in reading order")
    check(pages.allSatisfy { page in page.blocks.allSatisfy { page.rect.contains($0.bounds) } && page.rect.height <= maxHeight + 2 },
          "each page contains its blocks and fits the page size")
    check(Set(pages.map(\.rect.minX)).count == 1 && Set(pages.map(\.rect.width)).count == 1,
          "pages share the board's horizontal extent")

    // One very long paragraph is split between its lines.
    let long = InkLayout.analyze(Board(strokes: paragraph(x: 20, top: 20, lines: 50))).blocks
    let longPages = PageAssembler.pages(for: long, options: options)
    let lines = longPages.flatMap { $0.blocks.flatMap(\.lines) }
    check(long.count == 1 && longPages.count >= 2 && lines == long[0].lines && longPages.allSatisfy { $0.rect.height <= maxHeight + 2 },
          "a paragraph taller than a page is split between lines (\(longPages.count) pages)")
    check(Set(longPages.flatMap { $0.blocks.flatMap(\.strokeIDs) }).count == long[0].strokeIDs.count, "…with every stroke on exactly one page")

    // A huge drawing gets a page of its own between the text.
    let mixed = paragraph(x: 20, top: 20, lines: 3) + circle(cx: 300, cy: 1300, r: 1100) + paragraph(x: 20, top: 2500, lines: 3)
    let mixedPages = PageAssembler.pages(for: InkLayout.analyze(Board(strokes: mixed)).blocks, options: options)
    check(mixedPages.map { $0.blocks.map(\.kind) } == [[.text], [.drawing], [.text]], "an oversized drawing is kept whole on its own page")
    check(PageAssembler.pages(for: [], options: options).isEmpty, "no blocks, no pages")
}

print("Layout: real handwriting (test/未命名.inkboard)")
let realNote = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("test/未命名.inkboard")
if let data = try? Data(contentsOf: realNote), let board = try? BoardStore.decode(data) {
    let blocks = InkLayout.analyze(board).blocks
    check(blocks.map(\.kind) == [.formula, .diagram, .text, .formula] && blocks.map(\.lines.count) == [3, 0, 1, 1],
          "three formulas, the plot, the text line, the last formula (\(describe(blocks)))")
    check(blocks.first?.lines.allSatisfy(\.hasEquals) == true, "the \"=\" of every formula line is found")
    check(blocks.flatMap(\.lines).allSatisfy { $0.bounds.height < 3 * InkLayout.estimateTextHeight(board.strokes) },
          "superscript ᵀ and subscript j are part of their lines, not lines of their own")
} else {
    print("  - skipped: \(realNote.path) not found")
}

print("Layout: labels")
do {
    var board = Board(strokes: paragraph(x: 20, top: 20, lines: 3))
    let lines = InkLayout.analyze(board).blocks[0].lines
    board.labels[Set(lines[1].strokeIDs)] = .formula
    let relabelled = InkLayout.analyze(board).blocks
    check(relabelled.map(\.kind) == [.text, .formula, .text] && relabelled.map(\.lines.count) == [1, 1, 1],
          "a line labelled formula splits the paragraph (\(describe(relabelled)))")

    let shapes = Board(strokes: circle(cx: 100, cy: 100, r: 60) + circle(cx: 180, cy: 110, r: 50))
    var labelledShapes = shapes
    labelledShapes.labels[Set(InkLayout.analyze(shapes).blocks[0].strokeIDs)] = .diagram
    check(InkLayout.analyze(labelledShapes).blocks.map(\.kind) == [.diagram], "a drawing's label replaces the guess")

    var stale = board
    stale.labels[[UUID()]] = .formula
    let back = try BoardStore.decode(BoardStore.encode(stale))
    check(back.labels == board.labels, "labels are saved with the board; labels of deleted ink are dropped")
    let middle = Set(lines[1].strokeIDs)
    check(board.removing(middle).labels.isEmpty && board.subset(middle).labels.count == 1, "deleting ink drops its labels")
} catch {
    check(false, "labels threw \(error)")
}

print("AI labelling")
do {
    let board = Board(strokes: paragraph(x: 20, top: 20, lines: 2) + circle(cx: 120, cy: 250, r: 50))
    let request = BlockLabeling.request(for: board, options: PageAssembler.Options())
    check(request.units.map(\.tag) == ["L1", "L2", "G1"], "lines and drawings are tagged in reading order (\(request.units.map(\.tag)))")
    check(request.pages.count == 1 && request.parts.count == 3, "one page: prompt, page caption, image")
    if let png = request.pages.first?.pngData, let source = CGImageSourceCreateWithData(png as CFData, nil),
       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        let px = Pixels(image)
        let marked = stride(from: 0, to: px.height, by: 2).contains { y in stride(from: 0, to: px.width, by: 2).contains { px.isRed($0, y) } }
        check(marked, "units are boxed and tagged in red on the page")
    }

    let reply = "好的：\n```json\n{\"L1\": \"text\", \"l2\": \"Formula\", \"G1\": \"diagram\", \"G9\": \"text\", \"L3\": 3}\n```"
    let labels = try BlockLabeling.parse(reply, units: request.units)
    check(labels.count == 3 && labels[request.units[1].ids] == .formula && labels[request.units[2].ids] == .diagram,
          "the JSON answer is read despite fences, case and unknown tags")
    check(try BlockLabeling.parse(#"{"L1": "diagram"}"#, units: request.units).isEmpty, "a type that doesn't fit the unit is ignored")
    do {
        _ = try BlockLabeling.parse("我看不清。", units: request.units)
        check(false, "an answer without JSON is an error")
    } catch {
        check(error is BlockLabeling.LabelingError, "an answer without JSON is an error")
    }

    // End to end through AITranscriber with the OpenAI-compatible backend (HTTP stubbed).
    StubHTTP.respond(200, #"{"choices":[{"message":{"content":"{\"L1\":\"text\",\"L2\":\"formula\",\"G1\":\"drawing\"}"},"finish_reason":"stop"}]}"#)
    let api = OpenAIConfiguration(baseURL: URL(string: "https://example.test/v1")!, apiKey: "sk-test")
    let transcriber = AITranscriber(
        settings: { AITranscriberSettings(backend: .openAI(api),
                                          formula: TranscriptionProfile(model: "m", thoughtLevel: "", prompt: "p"),
                                          document: TranscriptionProfile(model: "vision-1", thoughtLevel: "", prompt: "p")) },
        makeBackend: { configuration in
            guard case .openAI(let config) = configuration else { fatalError() }
            return OpenAICompatibleBackend(configuration: config, session: StubHTTP.session)
        })
    let answered = try await transcriber.labelBlocks(request)
    check(answered[request.units[1].ids] == .formula && answered[request.units[2].ids] == .drawing && answered.count == 3,
          "labelling through the API backend returns the labels")
    let sent = StubHTTP.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let content = ((sent?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
    check(sent?["model"] as? String == "vision-1" && content.count == 3
          && content[0]["text"] as? String == BlockLabeling.prompt
          && ((content[2]["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true,
          "the request carries the prompt and the marked page image")
} catch {
    check(false, "AI labelling threw \(error)")
}

print("OpenAI-compatible API")
do {
    check(OpenAIConfiguration.normalizedBaseURL(" https://api.openai.com/v1/ ")?.absoluteString == "https://api.openai.com/v1"
          && OpenAIConfiguration.normalizedBaseURL("http://localhost:11434/v1/chat/completions")?.absoluteString == "http://localhost:11434/v1",
          "base URLs are cleaned up (spaces, trailing slash, pasted endpoint)")
    check(OpenAIConfiguration.normalizedBaseURL("ftp://x/v1") == nil && OpenAIConfiguration.normalizedBaseURL("") == nil,
          "only http(s) base URLs are accepted")

    let backend = OpenAICompatibleBackend(
        configuration: OpenAIConfiguration(baseURL: URL(string: "https://example.test/v1")!, apiKey: "sk-test"),
        session: StubHTTP.session)
    StubHTTP.respond(200, #"{"choices":[{"message":{"content":"hello"},"finish_reason":"stop"}]}"#)
    let reply = try await backend.send([.text("hi"), .png(Data([1, 2, 3]))], model: "m1", thoughtLevel: "low")
    let body = StubHTTP.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(reply == "hello" && StubHTTP.lastRequest?.url?.absoluteString == "https://example.test/v1/chat/completions"
          && StubHTTP.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test",
          "posts to /chat/completions with the API key")
    check(body?["reasoning_effort"] as? String == "low", "the thinking level is sent as reasoning_effort")

    StubHTTP.respond(200, #"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#)
    let parts = try await backend.send([.text("hi")], model: "m1", thoughtLevel: "")
    let plain = StubHTTP.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(parts == "ab" && plain?["reasoning_effort"] == nil, "content given as parts is joined; no thinking level, no reasoning_effort")

    StubHTTP.respond(401, #"{"error":{"message":"bad key"}}"#)
    do {
        _ = try await backend.send([.text("hi")], model: "m1", thoughtLevel: "")
        check(false, "an HTTP error is reported")
    } catch {
        check(error.localizedDescription.contains("API Key") && error.localizedDescription.contains("bad key"),
              "an HTTP error is reported with the server's message")
    }
    do {
        _ = try await backend.send([.text("hi")], model: "", thoughtLevel: "")
        check(false, "a missing model is reported")
    } catch {
        check(error.localizedDescription.contains("模型"), "a missing model is reported before any request")
    }

    StubHTTP.respond(200, #"{"data":[{"id":"b-model"},{"id":"a-model"}]}"#)
    let catalog = try await backend.modelCatalog()
    check(catalog.models.map(\.value) == ["a-model", "b-model"] && StubHTTP.lastRequest?.url?.path == "/v1/models",
          "models are listed from /models")
} catch {
    check(false, "OpenAI-compatible API threw \(error)")
}

print("Transcript cleanup")
do {
    check(TranscriptCleanup.latex("```latex\n\\frac{a}{b}\n```") == "\\frac{a}{b}", "code fence removed from LaTeX")
    check(TranscriptCleanup.latex(" $$x^2$$ ") == "x^2" && TranscriptCleanup.latex("\\[ x \\]") == "x", "math delimiters removed")
    check(TranscriptCleanup.latex("$a$ + $b$") == "$a$ + $b$", "separate inline formulas are left alone")
    check(TranscriptCleanup.markdown("```markdown\n# T\n\ntext\n```") == "# T\n\ntext\n", "fence around the whole Markdown removed")
    let withCode = "# T\n```py\nx\n```"
    check(TranscriptCleanup.markdown(withCode) == withCode + "\n", "code blocks inside Markdown are kept")
}

print("Agent command line")
do {
    check(ACPAgentConfiguration.splitArguments(#"acp --model "a b" 'c' --x """#) == ["acp", "--model", "a b", "c", "--x", ""],
          "arguments split on spaces, quotes group words")
    check(ACPAgentConfiguration.splitArguments("  ").isEmpty, "blank arguments give none")
    let found = ACPAgentConfiguration.locate("agy", searchPath: ["/a", "/b"], isExecutable: { $0 == "/b/agy" })
    check(found?.path == "/b/agy", "a bare command is looked up in the search path")
    let tilde = ACPAgentConfiguration.locate("~/x/agy", home: "/h", isExecutable: { $0 == "/h/x/agy" })
    check(tilde?.path == "/h/x/agy", "~ in a path expands to the home folder")
    check(ACPAgentConfiguration.locate("nope", searchPath: ["/a"], isExecutable: { _ in false }) == nil, "missing command gives nil")
}

print("ACP client (mock agent)")
let python = "/usr/bin/python3"
if FileManager.default.isExecutableFile(atPath: python) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InkboardCheck-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let script = folder.appendingPathComponent("mock_agent.py")
    try? mockAgentSource.write(to: script, atomically: true, encoding: .utf8)
    let agent = ACPAgent(configuration: ACPAgentConfiguration(
        executable: URL(fileURLWithPath: python), arguments: ["-I", script.path],
        environment: ProcessInfo.processInfo.environment, workingDirectory: folder))
    let png = InkImage.render([hline(0, 100, y: 10)], rect: CGRect(x: 0, y: 0, width: 120, height: 30))!.pngData

    do {
        let catalog = try await agent.modelCatalog()
        check(catalog.models.map(\.value) == ["alpha", "beta"] && catalog.defaultModel == "alpha",
              "reads the models, including grouped options")
        check(catalog.thoughtLevels["alpha"]?.map(\.value) == ["low", "high"] && catalog.thoughtLevels["beta"]?.map(\.value) == ["low"],
              "reads each model's thinking levels")

        let reply = try await agent.prompt([ACPContent.text("hi"), ACPContent.image(png: png)], model: "beta", thoughtLevel: "high")
        check(TranscriptCleanup.latex(reply) == "model=beta level=low images=1 permission=no",
              "sets the model, skips a level the model lacks, sends the image, declines permissions (\(reply.debugDescription))")
    } catch {
        check(false, "mock agent conversation threw \(error)")
    }

    do {
        _ = try await agent.prompt([ACPContent.text("hi")], model: "gamma", thoughtLevel: "")
        check(false, "an unknown model is rejected")
    } catch ACPError.unknownOption(_, let value, let available) {
        check(value == "gamma" && available == ["alpha", "beta"], "an unknown model is rejected, listing the choices")
    } catch {
        check(false, "unknown model threw \(error)")
    }

    let started = Date()
    let slow = Task { try await agent.prompt([ACPContent.text("SLOW")], model: "", thoughtLevel: "") }
    try? await Task.sleep(nanoseconds: 300_000_000)
    slow.cancel()
    do {
        _ = try await slow.value
        check(false, "cancelling stops the prompt")
    } catch {
        check(error is CancellationError && Date().timeIntervalSince(started) < 3, "cancelling sends session/cancel and stops the prompt")
    }

    do {
        _ = try await agent.prompt([ACPContent.text("CRASH")], model: "", thoughtLevel: "")
        check(false, "a crashing agent fails the request")
    } catch {
        check(error.localizedDescription.contains("mock agent crashed"), "a crashing agent fails the request with its stderr")
    }
    do {
        let again = try await agent.prompt([ACPContent.text("hi")], model: "", thoughtLevel: "")
        check(again.contains("model=alpha"), "the agent is restarted on the next request")
    } catch {
        check(false, "restart after crash threw \(error)")
    }
    agent.shutdown()
    try? FileManager.default.removeItem(at: folder)
} else {
    print("  - skipped: \(python) not found")
}

print("分块：数学版式、AI 分组、真实样本 test/test.inkboard")
await runLayoutChecks()

print("自动检查：核心逻辑")
await runAutoCheckCoreChecks()

print("自动检查：调度")
await runAutoCheckerChecks()

// Sample render for eyeballing stroke quality.
let outputPath = CommandLine.arguments.dropFirst().first ?? "inkboard-sample.png"
do {
    var strokes: [Stroke] = []
    // Pressure ramp: light → firm → light.
    strokes.append(penStroke(line(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 380, y: 30), samples: 40) { t in sin(t * .pi) }, width: 6))
    // A sparse, fast loop (big gaps between samples) to show the spline smoothing.
    var loop: [(CGFloat, CGFloat, CGFloat)] = []
    for i in 0...14 {
        let a = CGFloat(i) / 14 * 2 * .pi * 1.2
        loop.append((110 + 70 * cos(a) + CGFloat(i) * 6, 140 + 55 * sin(a), 0.4 + 0.5 * CGFloat(i) / 14))
    }
    strokes.append(penStroke(loop, width: 4))
    // Sharp zig-zag: joints must stay round with no holes.
    let zig: [(CGFloat, CGFloat, CGFloat)] = [(240, 200, 0.7), (270, 90, 0.7), (300, 200, 0.7), (330, 90, 0.7), (360, 200, 0.7)]
    strokes.append(penStroke(zig, width: 8))
    // Handwriting-ish wave with varying pressure.
    strokes.append(penStroke((0...120).map { i in
        let x = 20 + CGFloat(i) * 3
        return (x, 250 + 14 * sin(CGFloat(i) / 5), 0.2 + 0.8 * abs(sin(CGFloat(i) / 9)))
    }, width: 3))
    // Erase a gap through the wave.
    if let cut = InkOps.erase(strokes, from: CGPoint(x: 200, y: 225), to: CGPoint(x: 200, y: 275), radius: 6) {
        strokes = cut.strokes
    }

    // A pasted picture under part of the ink.
    let images = ImageImport.encode(gradientImage(width: 300, height: 220), as: .png)
        .flatMap { BoardImage(data: $0, frame: CGRect(x: 230, y: 60, width: 150, height: 110)) }.map { [$0] } ?? []
    let board = Board(strokes: strokes, images: images)

    if let image = InkRenderer.renderImage(board, rect: CGRect(x: 0, y: 0, width: 400, height: 290), scale: 2),
       let png = InkRenderer.pngData(image) {
        try png.write(to: URL(fileURLWithPath: outputPath))
        print("\nSample render written to \(outputPath)")
    } else {
        check(false, "sample render")
    }
    let pdfPath = (outputPath as NSString).deletingPathExtension + ".pdf"
    if let pdf = PDFExport.data(board) {
        try pdf.write(to: URL(fileURLWithPath: pdfPath))
        print("Sample PDF written to \(pdfPath)")
    } else {
        check(false, "sample PDF")
    }
} catch {
    check(false, "writing sample render: \(error)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)

// MARK: - Picture helpers (functions and types only: globals here are initialised in statement order)

/// Opaque test picture: top half red, bottom half blue.
func twoToneImage(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))                 // y-up: lower half
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    return ctx.makeImage()!
}

/// The two-tone picture (200 × 100 pixels) as a 144-DPI PNG, like a Retina screenshot.
func retinaTwoTonePNG() -> Data {
    encode([(twoToneImage(width: 200, height: 100), [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])], as: .png)
}

func gradientImage(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let colors = [CGColor(srgbRed: 1, green: 0.93, blue: 0.6, alpha: 1), CGColor(srgbRed: 0.6, green: 0.8, blue: 1, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    return ctx.makeImage()!
}

/// Encodes one or more images (each with its properties) into one file of `type`.
func encode(_ images: [(CGImage, [CFString: Any])], as type: UTType) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
    for (image, properties) in images { CGImageDestinationAddImage(dest, image, properties as CFDictionary) }
    CGImageDestinationFinalize(dest)
    return data as Data
}

func imageType(_ data: Data) -> String? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
}

func pdfDocument(_ data: Data) -> CGPDFDocument? {
    CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
}

/// One pixel per point on white.
func rasterize(_ page: CGPDFPage) -> CGImage {
    let box = page.getBoxRect(.mediaBox)
    let ctx = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(box)
    ctx.drawPDFPage(page)
    return ctx.makeImage()!
}

/// RGBA pixels of an image, rows from the top.
struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func isRed(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.r > 180 && c.g < 80 && c.b < 80 }
    func isBlue(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.b > 180 && c.r < 80 && c.g < 80 }
    func isDark(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.r < 90 && c.g < 90 && c.b < 90 }
}

// MARK: - Synthetic handwriting (h ≈ 16: glyphs 14 tall plus the pen)

/// An "n"-like arch, `width` wide, standing on `baseline`.
func glyph(_ x: CGFloat, _ baseline: CGFloat, width: CGFloat = 10, height: CGFloat = 14) -> Stroke {
    penStroke([(x, baseline, 0.6), (x + width * 0.2, baseline - height, 0.6),
               (x + width * 0.8, baseline - height * 0.9, 0.6), (x + width, baseline, 0.6)])
}

/// Words of `n` glyphs (3 apart), 13 apart from each other, written left to right.
func textLine(x: CGFloat, baseline: CGFloat, words: [Int]) -> [Stroke] {
    var strokes: [Stroke] = []
    var cx = x
    for letters in words {
        for _ in 0..<letters {
            strokes.append(glyph(cx, baseline))
            cx += 13
        }
        cx += 10
    }
    return strokes
}

/// Lines 34 apart; `top` is the top of the first line.
func paragraph(x: CGFloat, top: CGFloat, lines: Int, words: [Int] = [4, 3, 5, 2, 4]) -> [Stroke] {
    (0..<lines).flatMap { textLine(x: x, baseline: top + 14 + CGFloat($0) * 34, words: words) }
}

/// "a = ⅔"-like: a glyph and "=" on the axis, then a fraction (3 glyphs over a bar over 3 glyphs).
func fractionFormula(x: CGFloat, axis: CGFloat) -> [Stroke] {
    var strokes = [glyph(x, axis + 7)]
    strokes.append(penStroke(line(from: CGPoint(x: x + 18, y: axis - 3), to: CGPoint(x: x + 30, y: axis - 3), samples: 4)))
    strokes.append(penStroke(line(from: CGPoint(x: x + 18, y: axis + 3), to: CGPoint(x: x + 30, y: axis + 3), samples: 4)))
    let fx = x + 40
    strokes += textLine(x: fx + 6, baseline: axis - 5, words: [3])
    strokes.append(penStroke(line(from: CGPoint(x: fx, y: axis), to: CGPoint(x: fx + 50, y: axis + 0.5), samples: 6)))
    strokes += textLine(x: fx + 6, baseline: axis + 19, words: [3])
    return strokes
}

/// Characters made of three short stacked strokes (like 三), each written top to bottom.
func hanLine(x: CGFloat, top: CGFloat, characters: Int) -> [Stroke] {
    (0..<characters).flatMap { c in
        (0..<3).map { k in
            let cx = x + CGFloat(c) * 17, y = top + 2 + CGFloat(k) * 6
            return penStroke(line(from: CGPoint(x: cx, y: y), to: CGPoint(x: cx + 11, y: y + 0.5), samples: 4))
        }
    }
}

func circle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> [Stroke] {
    [penStroke((0...32).map { i in
        let a = CGFloat(i) / 32 * 2 * .pi
        return (cx + r * cos(a), cy + r * sin(a), 0.6)
    })]
}

/// One stroke around the rectangle, starting at the top-left corner.
func rectangle(_ r: CGRect) -> Stroke {
    let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
    var samples: [(CGFloat, CGFloat, CGFloat)] = []
    for (a, b) in zip(corners, corners.dropFirst()) {
        samples += line(from: a, to: b, samples: 6).dropLast()
    }
    samples.append((r.minX, r.minY, 0.6))
    return penStroke(samples)
}

func describe(_ blocks: [InkBlock]) -> String {
    blocks.map { "\($0.kind.rawValue)[\($0.lines.count)L \($0.strokeIDs.count)s]" }.joined(separator: " ")
}

/// "=": two short bars 6 apart, centred on `axis`.
func equalsSign(x: CGFloat, axis: CGFloat) -> [Stroke] {
    [penStroke(line(from: CGPoint(x: x, y: axis - 3), to: CGPoint(x: x + 12, y: axis - 3), samples: 4)),
     penStroke(line(from: CGPoint(x: x, y: axis + 3), to: CGPoint(x: x + 12, y: axis + 3), samples: 4))]
}

/// Answers every request with a canned response (the OpenAI-compatible backend under test).
final class StubHTTP: URLProtocol {
    static var status = 200
    static var response = Data()
    static var lastRequest: URLRequest?
    static var lastBody: Data?
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: configuration)
    }()

    static func respond(_ status: Int, _ json: String) {
        self.status = status
        response = Data(json.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubHTTP.lastRequest = request
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {   // URLSession moves the body into a stream
            var data = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        StubHTTP.lastBody = body
        let response = HTTPURLResponse(url: request.url!, statusCode: StubHTTP.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StubHTTP.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
