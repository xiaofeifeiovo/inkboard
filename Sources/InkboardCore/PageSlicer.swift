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
        let area = rect.integral
        guard area.width > 0, area.height > 0,
              strokes.contains(where: { $0.bounds.intersects(area) }) else { return nil }
        let scale = min(maxScale, maxPixels / max(area.width, area.height))
        guard let image = InkRenderer.renderImage(strokes, rect: area, scale: scale),
              let png = InkRenderer.pngData(image) else { return nil }
        return InkImage(rect: area, pngData: png, pixelSize: CGSize(width: image.width, height: image.height))
    }
}

/// Cuts the whole board into page-sized images for the "全局转换" (board → Markdown) request.
///
/// Strokes are grouped into horizontal bands (rows of ink whose vertical extents overlap), and
/// bands are packed top to bottom into pages, so a cut falls between lines of writing rather
/// than through them. Only a single band taller than a page is cut through. All pages share the
/// board's horizontal extent, which keeps indentation comparable from page to page; a board
/// wider than `maxSide` is additionally split into side-by-side tiles (left to right).
public enum PageSlicer {
    public struct Options {
        /// Page height / width.
        public var aspect: CGFloat = 1.414
        /// Narrow boards still get pages at least this tall (`minWidth * aspect`).
        public var minWidth: CGFloat = 800
        /// Longest page side in canvas units (keeps handwriting legible after downscaling).
        public var maxSide: CGFloat = 2000
        /// White margin around the ink.
        public var padding: CGFloat = 24

        public init() {}
    }

    /// Page rectangles in reading order.
    public static func pages(for strokes: [Stroke], options: Options = Options()) -> [CGRect] {
        guard !strokes.isEmpty else { return [] }
        let pad = options.padding
        let content = strokes.unionBounds
        let left = content.minX - pad
        let width = content.width + 2 * pad

        let columns = max(1, Int((width / options.maxSide).rounded(.up)))
        let tileWidth = width / CGFloat(columns)
        let maxHeight = min(max(tileWidth, options.minWidth) * options.aspect, options.maxSide)

        var rows: [ClosedRange<CGFloat>] = []
        for band in bands(of: strokes) {
            rows.append(contentsOf: split(band, maxHeight: maxHeight - 2 * pad))
        }

        // Pack rows into pages; a page ends halfway into the gap before the next row.
        var pages: [ClosedRange<CGFloat>] = []
        var start = 0
        for i in rows.indices {
            let isLast = i == rows.count - 1
            let fitsNext = !isLast && rows[i + 1].upperBound - rows[start].lowerBound + 2 * pad <= maxHeight
            if fitsNext { continue }
            let top = start == 0 ? rows[start].lowerBound - pad
                                 : max(rows[start].lowerBound - pad, (rows[start - 1].upperBound + rows[start].lowerBound) / 2)
            let bottom = isLast ? rows[i].upperBound + pad
                                : min(rows[i].upperBound + pad, (rows[i].upperBound + rows[i + 1].lowerBound) / 2)
            pages.append(top...bottom)
            start = i + 1
        }

        return pages.flatMap { page in
            (0..<columns).map { column in
                CGRect(x: left + CGFloat(column) * tileWidth, y: page.lowerBound,
                       width: tileWidth, height: page.upperBound - page.lowerBound).integral
            }
        }
    }

    /// Vertical extents of the ink, merged where strokes overlap vertically, top to bottom.
    static func bands(of strokes: [Stroke]) -> [ClosedRange<CGFloat>] {
        let spans = strokes.map { $0.bounds.minY...$0.bounds.maxY }.sorted { $0.lowerBound < $1.lowerBound }
        var bands: [ClosedRange<CGFloat>] = []
        for span in spans {
            if let last = bands.last, span.lowerBound <= last.upperBound {
                bands[bands.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                bands.append(span)
            }
        }
        return bands
    }

    /// Cuts a band taller than `maxHeight` into equal slices.
    private static func split(_ band: ClosedRange<CGFloat>, maxHeight: CGFloat) -> [ClosedRange<CGFloat>] {
        let height = band.upperBound - band.lowerBound
        guard height > maxHeight, maxHeight > 0 else { return [band] }
        let count = Int((height / maxHeight).rounded(.up))
        let step = height / CGFloat(count)
        return (0..<count).map { i in
            let top = band.lowerBound + CGFloat(i) * step
            return top...(i == count - 1 ? band.upperBound : top + step)
        }
    }
}
