import CoreGraphics
import Foundation

/// Writes a board as a PDF: ink stays vector, pictures are embedded, pages are A4 portrait.
///
/// Pages are made like 全局转换's: the board is split into blocks (`InkLayout`) and the blocks are
/// packed into pages (`PageAssembler`), so a paragraph, formula or drawing is never cut in two
/// (only a paragraph taller than a page is split, between lines). Every page uses the same scale
/// and left edge: the board's width (but at least `minWidth` canvas units, so a narrow board isn't
/// blown up) fills the printable width. A block too tall for that is shrunk to fit its own page.
/// Each page shows only its own blocks, at the top.
public enum PDFExport {
    public struct Options {
        /// A4 in points.
        public var pageSize = CGSize(width: 595.28, height: 841.89)
        public var margin: CGFloat = 36
        /// Canvas units across the printable width at the most (≈ 0.73 at the default sizes).
        public var minWidth: CGFloat = 720
        /// Space kept around the content inside the margins, in canvas units.
        public var padding: CGFloat = 8
        /// Document title in the PDF's metadata.
        public var title: String?

        public init() {}
    }

    public struct Page {
        /// Canvas area shown on the page.
        public var rect: CGRect
        /// Points per canvas unit.
        public var scale: CGFloat
        /// Strokes and pictures drawn on it.
        public var ids: Set<UUID>
    }

    public static func layout(_ board: Board, options: Options = Options()) -> [Page] {
        let printable = CGSize(width: options.pageSize.width - 2 * options.margin,
                               height: options.pageSize.height - 2 * options.margin)
        var packing = PageAssembler.Options()
        packing.aspect = printable.height / printable.width
        packing.minWidth = options.minWidth
        packing.maxSide = .greatestFiniteMagnitude   // one column: wide boards are scaled down, not tiled
        packing.padding = options.padding
        return PageAssembler.pages(for: InkLayout.analyze(board).blocks, options: packing).map { page in
            let scale = min(printable.width / max(page.rect.width, options.minWidth), printable.height / page.rect.height)
            return Page(rect: page.rect, scale: scale, ids: page.ids)
        }
    }

    /// Nil for an empty board.
    public static func data(_ board: Board, options: Options = Options()) -> Data? {
        let pages = layout(board, options: options)
        guard !pages.isEmpty else { return nil }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: options.pageSize)
        var info: [CFString: Any] = [kCGPDFContextCreator: "Inkboard"]
        if let title = options.title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return nil }

        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // PDF space is y-up from the bottom-left corner; canvas coordinates are y-down.
            ctx.translateBy(x: options.margin, y: options.pageSize.height - options.margin)
            ctx.scaleBy(x: page.scale, y: -page.scale)
            ctx.translateBy(x: -page.rect.minX, y: -page.rect.minY)
            ctx.clip(to: page.rect)
            InkRenderer.draw(board.subset(page.ids), in: ctx, clip: page.rect)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
