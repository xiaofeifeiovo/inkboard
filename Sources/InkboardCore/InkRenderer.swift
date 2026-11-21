import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    /// Renders strokes onto a white bitmap. `rect` is in canvas coordinates (defaults to the ink
    /// bounds plus `padding`); `scale` is pixels per canvas unit.
    public static func renderImage(_ strokes: [Stroke], rect: CGRect? = nil, padding: CGFloat = 24, scale: CGFloat = 2) -> CGImage? {
        let area = (rect ?? strokes.unionBounds.insetBy(dx: -padding, dy: -padding)).integral
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
        fill(strokes, in: ctx, clip: area)
        return ctx.makeImage()
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
