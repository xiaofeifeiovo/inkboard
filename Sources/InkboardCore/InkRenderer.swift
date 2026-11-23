import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Drawing in canvas coordinates (y down) — shared by the canvas, PNG export, AI images and PDF export.
public enum InkRenderer {
    public static let inkColor = CGColor(gray: 0, alpha: 1)

    /// Fills the strokes intersecting `clip` (or all of them) with a single non-zero fill.
    public static func fill(_ strokes: [Stroke], in ctx: CGContext, color: CGColor = inkColor, clip: CGRect? = nil) {
        var any = false
        for stroke in strokes where clip.map({ stroke.bounds.intersects($0) }) ?? true {
            ctx.addPath(stroke.path)
            any = true
        }
        guard any else { return }
        ctx.setFillColor(color)
        ctx.fillPath(using: .winding)
    }

    /// Draws a picture into `rect` of a y-down context (CGContext.draw alone would draw it upside down).
    public static func draw(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Pictures first, then all ink on top.
    public static func draw(_ board: Board, in ctx: CGContext, clip: CGRect? = nil) {
        for image in board.images where clip.map({ image.frame.intersects($0) }) ?? true {
            draw(image.image, in: image.frame, ctx: ctx)
        }
        fill(board.strokes, in: ctx, clip: clip)
    }

    public static func renderImage(_ strokes: [Stroke], rect: CGRect? = nil, padding: CGFloat = 24, scale: CGFloat = 2) -> CGImage? {
        renderImage(Board(strokes: strokes), rect: rect, padding: padding, scale: scale)
    }

    /// Renders the board onto a white bitmap. `rect` is in canvas coordinates (defaults to the
    /// content bounds plus `padding`); `scale` is pixels per canvas unit. `overlay` draws on top,
    /// also in canvas coordinates.
    public static func renderImage(_ board: Board, rect: CGRect? = nil, padding: CGFloat = 24, scale: CGFloat = 2,
                                   overlay: ((CGContext) -> Void)? = nil) -> CGImage? {
        let area = (rect ?? board.bounds.insetBy(dx: -padding, dy: -padding)).integral
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }

        let width = Int(area.width * scale), height = Int(area.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Canvas coordinates are y-down; bitmap contexts are y-up.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.setShouldAntialias(true)
        draw(board, in: ctx, clip: area)
        overlay?(ctx)
        return ctx.makeImage()
    }

    public static func pngData(_ image: CGImage) -> Data? {
        ImageImport.encode(image, as: .png)
    }
}
