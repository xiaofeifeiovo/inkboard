import CoreGraphics
import Foundation

/// A region of the board rendered black on white, ready to send to a vision model.
public struct InkImage {
    /// Canvas area covered by the image.
    public let rect: CGRect
    public let pngData: Data
    public let pixelSize: CGSize

    /// Renders `rect` (ink is clipped to it). The scale is at most `maxScale` pixels per canvas
    /// unit and keeps the longer side within `maxPixels`. Returns nil when no ink touches `rect`.
    public static func render(_ strokes: [Stroke], rect: CGRect, maxPixels: CGFloat = 2000, maxScale: CGFloat = 2) -> InkImage? {
        render(Board(strokes: strokes), rect: rect, maxPixels: maxPixels, maxScale: maxScale)
    }

    /// Like the strokes version, with pictures under the ink. Nil when nothing touches `rect`.
    public static func render(_ board: Board, rect: CGRect, maxPixels: CGFloat = 2000, maxScale: CGFloat = 2) -> InkImage? {
        let area = rect.integral
        guard area.width > 0, area.height > 0,
              board.strokes.contains(where: { $0.bounds.intersects(area) })
                || board.images.contains(where: { $0.frame.intersects(area) }) else { return nil }
        let scale = min(maxScale, maxPixels / max(area.width, area.height))
        guard let image = InkRenderer.renderImage(board, rect: area, scale: scale),
              let png = InkRenderer.pngData(image) else { return nil }
        return InkImage(rect: area, pngData: png, pixelSize: CGSize(width: image.width, height: image.height))
    }
}
