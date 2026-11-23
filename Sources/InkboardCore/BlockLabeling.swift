import CoreGraphics
import CoreText
import Foundation

/// Asks a vision model what each segmentation unit is, so blocks get the right type where geometry
/// can only guess: every line of writing (text or formula?) and every drawing (drawing, diagram —
/// or really a formula or text?).
///
/// "Set-of-mark" prompting: the board is sent as page images (the same pages as 全局转换) on which
/// each unit is boxed and tagged — L1, L2… for lines, G1, G2… for drawings, in reading order — and
/// the model answers with a JSON object from tag to type. Boundaries stay exactly as `InkLayout`
/// found them; the model only names types. The answers go into `Board.labels`, keyed by each
/// unit's strokes, and `InkLayout` regroups blocks with them (consecutive formula lines become a
/// formula block, and so on).
public enum BlockLabeling {
    public struct Unit: Equatable {
        /// "L3" (a line) or "G1" (a drawing).
        public let tag: String
        /// The unit's strokes: the key in `Board.labels`.
        public let ids: Set<UUID>
        public let bounds: CGRect
        public var isLine: Bool { tag.hasPrefix("L") }
    }

    public struct Request {
        public let units: [Unit]
        public let pages: [InkImage]

        /// The prompt, then each page.
        public var parts: [PromptPart] {
            var parts: [PromptPart] = [.text(BlockLabeling.prompt)]
            for (i, page) in pages.enumerated() {
                parts.append(.text("第 \(i + 1)/\(pages.count) 页："))
                parts.append(.png(page.pngData))
            }
            return parts
        }
    }

    public enum LabelingError: LocalizedError {
        case unreadableReply(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableReply(let reply):
                return "模型的回答不是预期的 JSON 格式：\n\n" + String(reply.prefix(300))
            }
        }
    }

    /// Fixed (not a setting): the answer format is part of the contract with `parse`.
    public static let prompt = """
        这些图片是同一份手写笔记，按阅读顺序分成了几页。图中用红色方框和编号标出了一些区域：
        - L 开头的编号（如 L3）是一行书写。判断它是 text（文字，可以夹带行内公式）还是 formula（单独的数学公式或推导）。
        - G 开头的编号（如 G2）是一块图形。判断它是 drawing（手绘图、草图）、diagram（示意图、流程图、坐标图、表格等由线条和标注组成的图）、formula（其实是公式，比如大的矩阵）还是 text（其实是文字）。
        只输出一个 JSON 对象，键是编号，值是类型，每个编号都要给出，例如：{"L1": "text", "L2": "formula", "G1": "diagram"}
        不要输出其他内容，不要用代码块包起来，不要调用任何工具。
        """

    /// Lines of text / formula blocks and blocks without lines (drawings, diagrams, or drawings
    /// already labelled as writing), in reading order, including those on pictures.
    public static func units(in blocks: [InkBlock]) -> [Unit] {
        var units: [Unit] = []
        var lines = 0, graphics = 0
        func visit(_ block: InkBlock) {
            if !block.lines.isEmpty {
                for line in block.lines {
                    lines += 1
                    units.append(Unit(tag: "L\(lines)", ids: Set(line.strokeIDs), bounds: line.bounds))
                }
            } else if block.kind != .image && block.kind != .figure {
                graphics += 1
                units.append(Unit(tag: "G\(graphics)", ids: Set(block.strokeIDs), bounds: block.bounds))
            }
            block.children.forEach(visit)
        }
        blocks.forEach(visit)
        return units
    }

    /// Segments the board and renders its pages with every unit marked.
    public static func request(for board: Board, options: PageAssembler.Options) -> Request {
        var options = options
        options.padding = max(options.padding, 40)   // room for the tags left of the lines
        let blocks = InkLayout.analyze(board).blocks
        let units = units(in: blocks)
        let pages = PageAssembler.pages(for: blocks, options: options).compactMap { page -> InkImage? in
            let ids = page.ids
            let marked = units.filter { $0.ids.isSubset(of: ids) }
            return render(board.subset(ids), rect: page.rect, units: marked, maxPixels: options.maxSide)
        }
        return Request(units: units, pages: pages)
    }

    /// Reads the model's JSON answer. Tags it doesn't know and types that don't fit the unit
    /// (a line can only be text or formula) are skipped.
    public static func parse(_ reply: String, units: [Unit]) throws -> [Set<UUID>: InkBlock.Kind] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any] else {
            throw LabelingError.unreadableReply(reply)
        }
        let byTag = Dictionary(units.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
        var labels: [Set<UUID>: InkBlock.Kind] = [:]
        for (key, value) in object {
            let tag = key.trimmingCharacters(in: .whitespaces).uppercased()
            guard let unit = byTag[tag], let name = value as? String,
                  let kind = InkBlock.Kind(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) else { continue }
            let allowed: [InkBlock.Kind] = unit.isLine ? [.text, .formula] : [.drawing, .diagram, .formula, .text]
            if allowed.contains(kind) { labels[unit.ids] = kind }
        }
        return labels
    }

    // MARK: Rendering

    private static func render(_ board: Board, rect: CGRect, units: [Unit], maxPixels: CGFloat) -> InkImage? {
        let area = rect.integral
        guard area.width > 0, area.height > 0 else { return nil }
        let scale = min(2, maxPixels / max(area.width, area.height))
        let red = CGColor(srgbRed: 0.9, green: 0.12, blue: 0.1, alpha: 1)
        guard let image = InkRenderer.renderImage(board, rect: area, scale: scale, overlay: { ctx in
            for unit in units {
                let box = unit.bounds.insetBy(dx: -2 / scale, dy: -2 / scale)
                ctx.setStrokeColor(red)
                ctx.setLineWidth(1.5 / scale)
                ctx.stroke(box)
                // Lines: tag in the margin to the left; drawings: inside the top-left corner.
                let size = 18 / scale
                let tag = tagSize(unit.tag, fontSize: size)
                var origin = unit.isLine
                    ? CGPoint(x: box.minX - tag.width - 2 / scale, y: box.midY - tag.height / 2)
                    : CGPoint(x: box.minX, y: box.minY)
                if origin.x < area.minX { origin.x = box.minX }
                drawTag(unit.tag, at: origin, fontSize: size, color: red, in: ctx)
            }
        }), let png = InkRenderer.pngData(image) else { return nil }
        return InkImage(rect: area, pngData: png, pixelSize: CGSize(width: image.width, height: image.height))
    }

    private static func line(_ text: String, fontSize: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func tagSize(_ text: String, fontSize: CGFloat) -> CGSize {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line(text, fontSize: fontSize), &ascent, &descent, nil))
        let pad = fontSize * 0.25
        return CGSize(width: width + 2 * pad, height: ascent + descent + 2 * pad)
    }

    /// A filled label with white text, top-left at `origin`, in a y-down context.
    private static func drawTag(_ text: String, at origin: CGPoint, fontSize: CGFloat, color: CGColor, in ctx: CGContext) {
        let ctLine = line(text, fontSize: fontSize)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        let pad = fontSize * 0.25
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: origin.x, y: origin.y, width: width + 2 * pad, height: ascent + descent + 2 * pad))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: origin.x + pad, y: origin.y + pad + ascent)
        ctx.scaleBy(x: 1, y: -1)   // text is drawn y-up
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }
}
