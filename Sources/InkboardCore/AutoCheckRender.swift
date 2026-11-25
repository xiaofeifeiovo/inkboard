import CoreGraphics
import CoreText
import Foundation

/// The images 自动检查 sends (docs/auto-check.md §4, AGENTS.md「自动检查」):
///   • a block image: one check unit with a margin, only its strokes and the pictures under it;
///   • a tagged page image: one page with only that page's blocks, every unit boxed in red and
///     labelled with its tag ("B3"), like the images of 识别分块类型 (`BlockLabeling`).
/// Both are black ink on white, like every image sent to a model.
public enum AutoCheckRender {
    /// White margin around a block, in canvas units.
    public static let blockPadding: CGFloat = 16
    /// A block image's longest side, in pixels (an oversized block is rendered smaller).
    public static let blockMaxPixels: CGFloat = 1600

    /// A unit on a page image: its tag and where to draw the box.
    public struct Tagged: Equatable {
        public var tag: String
        public var bounds: CGRect

        public init(tag: String, bounds: CGRect) {
            self.tag = tag
            self.bounds = bounds
        }
    }

    /// The unit's strokes (and the pictures under them, for ink on a picture), cropped to the
    /// unit's bounds plus `padding`. Nil when the unit has no area.
    public static func blockImage(_ unit: CheckUnit, board: Board, padding: CGFloat = blockPadding,
                                  maxPixels: CGFloat = blockMaxPixels) -> InkImage? {
        let ids = unit.ids.union(unit.imageIDs)
        let bounds = unit.bounds.isNull ? board.bounds(of: unit.ids) : unit.bounds
        guard !bounds.isNull else { return nil }
        return InkImage.render(board.subset(ids), rect: bounds.insetBy(dx: -padding, dy: -padding), maxPixels: maxPixels)
    }

    /// The page `rect` with only `ids` drawn (the page's blocks), and each of `tagged` boxed in red
    /// with its tag at the box's top-left corner. The area is widened a little where a tag would
    /// stick out, so every tag is readable. Tags are drawn at a fixed size in pixels (18 px), so
    /// they stay readable however much the page is scaled down.
    public static func pageImage(_ board: Board, rect: CGRect, ids: Set<UUID>, tagged: [Tagged],
                                 maxPixels: CGFloat) -> InkImage? {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        // First guess of the scale, to size the tags; then grow the area to hold them.
        var scale = min(2, maxPixels / max(rect.width, rect.height))
        var area = rect
        for _ in 0..<2 {
            area = rect
            for unit in tagged {
                let box = unit.bounds.insetBy(dx: -3 / scale, dy: -3 / scale)
                let tag = tagSize(unit.tag, fontSize: tagPixels / scale)
                area = area.union(CGRect(x: box.minX, y: box.minY - tag.height, width: tag.width, height: tag.height))
                area = area.union(box)
            }
            area = area.integral
            scale = min(2, maxPixels / max(area.width, area.height))
        }
        let red = CGColor(srgbRed: 0.9, green: 0.12, blue: 0.1, alpha: 1)
        guard let image = InkRenderer.renderImage(board.subset(ids), rect: area, scale: scale, overlay: { ctx in
            for unit in tagged {
                let box = unit.bounds.insetBy(dx: -3 / scale, dy: -3 / scale)
                ctx.setStrokeColor(red)
                ctx.setLineWidth(2 / scale)
                ctx.stroke(box)
                let size = tagPixels / scale
                let tag = tagSize(unit.tag, fontSize: size)
                // Above the box's top-left corner; inside it when that would leave the image.
                var origin = CGPoint(x: box.minX, y: box.minY - tag.height)
                if origin.y < area.minY { origin.y = box.minY }
                if origin.x + tag.width > area.maxX { origin.x = area.maxX - tag.width }
                drawTag(unit.tag, at: origin, fontSize: size, color: red, in: ctx)
            }
        }), let png = InkRenderer.pngData(image) else { return nil }
        return InkImage(rect: area, pngData: png, pixelSize: CGSize(width: image.width, height: image.height))
    }

    /// Tag height in pixels of the sent image (before the model scales it).
    static let tagPixels: CGFloat = 18

    // MARK: Tags (as in BlockLabeling)

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
