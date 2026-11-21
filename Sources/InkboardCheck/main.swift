import CoreGraphics
import Foundation
import InkboardCore

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
    let ids = InkOps.strokesBelow(60, in: [above, below])
    check(ids == [below.id], "only strokes below the line move")
    let minDelta = InkOps.minimumSpaceDelta(lineY: 60, moving: ids, in: [above, below])
    check(minDelta < -30 && minDelta > -45, "removing space stops when ink reaches the line (\(minDelta))")
    let moved = InkOps.translate([above, below], ids: ids, dx: 0, dy: 40)
    check(abs(moved[1].bounds.minY - below.bounds.minY - 40) < 0.001 && moved[0].bounds == above.bounds,
          "translation moves points and bounds of the selected strokes only")
}

print("Persistence")
do {
    let s = penStroke(line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 30, y: 40), samples: 6))
    let data = try BoardStore.encode([s])
    let back = try BoardStore.decode(data)
    check(back.count == 1 && back[0].id == s.id && back[0].points.count == s.points.count, "JSON round-trip keeps strokes")
} catch {
    check(false, "JSON round-trip threw \(error)")
}

func hline(_ x0: CGFloat, _ x1: CGFloat, y: CGFloat) -> Stroke {
    penStroke(line(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), samples: 10))
}

print("Page slicing")
do {
    let rows = (0..<40).map { hline(0, 600, y: 100 + CGFloat($0) * 60) }
    let options = PageSlicer.Options()
    let pages = PageSlicer.pages(for: rows, options: options)
    let maxHeight = max(rows.unionBounds.width + 2 * options.padding, options.minWidth) * options.aspect
    check(pages.count >= 2, "a long board becomes several pages (\(pages.count))")
    check(pages.allSatisfy { $0.height <= maxHeight + 1 }, "pages stay within the A4-like height")
    check(zip(pages, pages.dropFirst()).allSatisfy { $0.maxY <= $1.minY }, "pages run top to bottom without overlap")
    check(rows.allSatisfy { row in pages.filter { $0.contains(row.bounds) }.count == 1 },
          "every line of writing lies whole on exactly one page")

    let tall = penStroke(line(from: CGPoint(x: 50, y: 0), to: CGPoint(x: 60, y: 5000), samples: 50))
    let tallPages = PageSlicer.pages(for: [tall], options: options)
    check(tallPages.count >= 3 && tallPages.allSatisfy { $0.height <= options.maxSide + 1 },
          "a single band taller than a page is cut into slices (\(tallPages.count))")
    check(zip(tallPages, tallPages.dropFirst()).allSatisfy { abs($0.maxY - $1.minY) <= 1 },
          "slices of one band are contiguous")

    let gapped = PageSlicer.pages(for: [hline(0, 400, y: 100), hline(0, 400, y: 6000)], options: options)
    check(gapped.count == 2 && gapped.allSatisfy { $0.height < 200 }, "blank stretches are skipped, not sent as pages")

    let wide = PageSlicer.pages(for: [hline(0, 5000, y: 100)], options: options)
    check(wide.count == 3 && Set(wide.map(\.minY)).count == 1 && zip(wide, wide.dropFirst()).allSatisfy { $0.minX < $1.minX },
          "a board wider than the page limit is tiled left to right (\(wide.count))")

    let image = InkImage.render([tall], rect: tallPages[0], maxPixels: 1000)
    check(image.map { max($0.pixelSize.width, $0.pixelSize.height) <= 1000 } == true, "page images respect the pixel limit")
    check(InkImage.render([tall], rect: CGRect(x: 500, y: 0, width: 100, height: 100)) == nil, "a box without ink renders nothing")
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

    if let image = InkRenderer.renderImage(strokes, rect: CGRect(x: 0, y: 0, width: 400, height: 290), scale: 2),
       let png = InkRenderer.pngData(image) {
        try png.write(to: URL(fileURLWithPath: outputPath))
        print("\nSample render written to \(outputPath)")
    } else {
        check(false, "sample render")
    }
} catch {
    check(false, "writing sample render: \(error)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
