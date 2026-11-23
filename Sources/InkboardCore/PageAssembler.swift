import CoreGraphics
import Foundation

/// One page made of whole blocks, ready to render and send to a model.
public struct InkPage: Equatable {
    /// Canvas area of the page.
    public var rect: CGRect
    /// Blocks on this page, in reading order. A text block too tall for one page is split between
    /// lines; each part is a block holding some of the lines.
    public var blocks: [InkBlock]

    /// Strokes and pictures to draw. Other content inside `rect` belongs to other pages and is left out.
    public var ids: Set<UUID> { blocks.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) } }
}

/// Packs blocks (from `InkLayout`) into pages, in reading order.
///
/// Blocks are never cut: a page ends before the first block that would make it too large. A text
/// block taller than a page is split between its lines; any other oversized block (a big drawing
/// or picture) gets a page of its own and is rendered smaller. When the content is narrow enough,
/// every page spans the same horizontal range, so indentation compares from page to page.
public enum PageAssembler {
    public struct Options {
        /// Page height / width.
        public var aspect: CGFloat = 1.414
        /// Narrow content still gets pages at least `minWidth * aspect` tall.
        public var minWidth: CGFloat = 800
        /// Longest page side in canvas units.
        public var maxSide: CGFloat = 2000
        /// White margin around the content.
        public var padding: CGFloat = 24

        public init() {}
    }

    public static func pages(for blocks: [InkBlock], options: Options = Options()) -> [InkPage] {
        guard !blocks.isEmpty else { return [] }
        let pad = options.padding
        let content = blocks.reduce(CGRect.null) { $0.union($1.bounds) }
        let shared: ClosedRange<CGFloat>? = content.width + 2 * pad <= options.maxSide
            ? (content.minX - pad)...(content.maxX + pad) : nil

        func fits(_ r: CGRect) -> Bool {
            let width = shared.map { $0.upperBound - $0.lowerBound } ?? r.width + 2 * pad
            let maxHeight = min(max(width, options.minWidth) * options.aspect, options.maxSide)
            return width <= options.maxSide + 0.5 && r.height + 2 * pad <= maxHeight + 0.5
        }

        var units: [InkBlock] = []
        for block in blocks {
            if fits(block.bounds) || block.lines.count < 2 {
                units.append(block)
            } else {
                units += splitByLines(block, fits: fits)
            }
        }

        var pages: [InkPage] = []
        var current: [InkBlock] = []
        var area = CGRect.null
        func finishPage() {
            guard !current.isEmpty else { return }
            var rect = area.insetBy(dx: -pad, dy: -pad)
            if let shared { rect = CGRect(x: shared.lowerBound, y: rect.minY, width: shared.upperBound - shared.lowerBound, height: rect.height) }
            pages.append(InkPage(rect: rect.integral, blocks: current))
            current = []
            area = .null
        }
        for unit in units {
            if !current.isEmpty, !fits(area.union(unit.bounds)) { finishPage() }
            current.append(unit)
            area = area.union(unit.bounds)
        }
        finishPage()
        return pages
    }

    /// Consecutive lines that fit on a page. Strokes outside every line (a box drawn around the
    /// text) go with every part.
    private static func splitByLines(_ block: InkBlock, fits: (CGRect) -> Bool) -> [InkBlock] {
        let inLines = Set(block.lines.flatMap(\.strokeIDs))
        let extra = block.strokeIDs.filter { !inLines.contains($0) }
        var parts: [[InkLine]] = []
        var area = CGRect.null
        for line in block.lines {
            if !(parts.last?.isEmpty ?? true), !fits(area.union(line.bounds)) {
                parts.append([])
                area = .null
            }
            if parts.isEmpty { parts.append([]) }
            parts[parts.count - 1].append(line)
            area = area.union(line.bounds)
        }
        return parts.map { lines in
            let ids = Set(lines.flatMap(\.strokeIDs))
            return InkBlock(kind: block.kind,
                            bounds: lines.reduce(CGRect.null) { $0.union($1.bounds) },
                            strokeIDs: block.strokeIDs.filter { ids.contains($0) } + extra,
                            lines: lines)
        }
    }
}
