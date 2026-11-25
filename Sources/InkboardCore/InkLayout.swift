import CoreGraphics
import Foundation

// MARK: - Result

/// A part of the board that belongs together: a paragraph, a formula, a drawing, a picture…
public struct InkBlock: Equatable {
    public enum Kind: String, CaseIterable {
        /// A paragraph of writing (inline formulas included).
        case text
        /// A formula on its own (a run of formula lines, see `InkLine.kind`).
        case formula
        /// A freehand drawing.
        case drawing
        /// A diagram: straight lines, boxes, arrows, labels.
        case diagram
        /// A pasted picture without ink on it.
        case image
        /// A pasted picture with ink on it; the ink is in `children`.
        case figure
    }

    public var kind: Kind
    public var bounds: CGRect
    /// Every stroke of the block (children's included), in writing order.
    public var strokeIDs: [UUID]
    /// Pictures of an image or figure block, back to front.
    public var imageIDs: [UUID]
    /// Text and formula blocks: their lines, top to bottom.
    public var lines: [InkLine]
    /// Figure blocks: the ink on the picture, segmented like the rest of the board, in reading order.
    public var children: [InkBlock]

    public init(kind: Kind, bounds: CGRect, strokeIDs: [UUID], imageIDs: [UUID] = [],
                lines: [InkLine] = [], children: [InkBlock] = []) {
        self.kind = kind
        self.bounds = bounds
        self.strokeIDs = strokeIDs
        self.imageIDs = imageIDs
        self.lines = lines
        self.children = children
    }

    /// Strokes and pictures of the block.
    public var ids: Set<UUID> { Set(strokeIDs).union(imageIDs) }
}

public struct InkLine: Equatable {
    public var bounds: CGRect
    /// In writing order.
    public var strokeIDs: [UUID]
    /// `.text` or `.formula`: the label from `Board.labels` when there is one, otherwise a guess
    /// (a line with a fraction or an "=" is a formula).
    public var kind: InkBlock.Kind
    /// Contains a fraction (a bar with ink right above and below it).
    public var hasFraction: Bool
    /// Contains an "=" (two short parallel bars, nothing else between them).
    public var hasEquals: Bool

    public init(bounds: CGRect, strokeIDs: [UUID], kind: InkBlock.Kind = .text, hasFraction: Bool = false, hasEquals: Bool = false) {
        self.bounds = bounds
        self.strokeIDs = strokeIDs
        self.kind = kind
        self.hasFraction = hasFraction
        self.hasEquals = hasEquals
    }
}

// MARK: - Segmentation

/// Splits a board into blocks (paragraphs, formulas, drawings, diagrams, pictures) in reading order.
///
/// Works on the vector ink, not on pixels, and every distance is a multiple of the text height `h`
/// (the typical height of a written word, estimated from the ink), so handwriting size and zoom
/// don't matter. Steps:
///
///  1. Each stroke is text, a rule (a straight horizontal line) or a graphic (much larger than writing).
///  2. A rule with ink right above and right below it, neither reaching past its ends, is a fraction
///     bar: bar, numerator and denominator are glued together. With ink only above, it's an underline.
///     A rule on its own that is long or touches a drawing belongs to drawings. Two short parallel
///     bars written one after the other, with no other ink around them, are an "=".
///  3. Text strokes become glyphs (written one after the other and close together; dots join their
///     neighbour), and glyphs become lines (overlapping vertically, with word-sized gaps at most).
///     A small fragment right next to a line (a superscript, a low subscript) joins it.
///     Each line is text or a formula: its label in `Board.labels`, else a guess (fraction or "=").
///  4. Graphic strokes close to each other form drawings. A drawing takes the lines lying inside it
///     and short labels touching it. A drawing that is only a box or circle around writing is boxed text.
///  5. A pasted picture takes the lines lying mostly on it and the drawings reaching onto it
///     (pictures sharing ink, or overlapping, become one figure). Inside, the same rules apply.
///  6. The remaining lines become paragraphs (lines close below one another that overlap
///     horizontally), split where lines change between text and formula.
///  7. Reading order: recursive XY-cut, top to bottom first, then left to right. A caption (a short
///     text block right under a drawing or picture) stays right after it.
///
/// Geometry can't reliably tell a formula from a word, nor a drawing from a diagram: those kinds
/// are guesses unless `Board.labels` (from `BlockLabeling` or a correction) says otherwise.
public enum InkLayout {
    public struct Options {
        /// Typical height of a written word; nil estimates it from the ink.
        public var textHeight: CGFloat?
        /// Follow `Board.groups` (分块方式「AI 辅助」). Off: geometry only (groups are ignored).
        public var useGroups: Bool

        public init(textHeight: CGFloat? = nil, useGroups: Bool = false) {
            self.textHeight = textHeight
            self.useGroups = useGroups
        }
    }

    /// What `analyze` uses when no options are passed. The app sets `useGroups` from 设置 →
    /// 分块方式, so every caller (canvas, 全局转换, PDF, 自动检查) segments the same way.
    public static var defaultOptions = Options()

    public struct Result {
        /// Top-level blocks in reading order.
        public var blocks: [InkBlock]
        /// The text height `h` used.
        public var textHeight: CGFloat
    }

    public static func analyze(_ board: Board, options: Options = InkLayout.defaultOptions) -> Result {
        let h = options.textHeight ?? estimateTextHeight(board.strokes)
        let blocks = Analyzer(board: board, h: h).run(useGroups: options.useGroups)
        return Result(blocks: blocks, textHeight: h)
    }

    /// Median height of runs of strokes written one after another close together (≈ characters
    /// or words, whatever the script).
    public static func estimateTextHeight(_ strokes: [Stroke]) -> CGFloat {
        guard !strokes.isEmpty else { return 24 }
        let h0 = min(max(median(strokes.map { max($0.bounds.width, $0.bounds.height) }), 4), 400)
        var heights: [CGFloat] = []
        var run = CGRect.null
        for stroke in strokes {
            let b = stroke.bounds
            if max(b.width, b.height) > 4 * h0 {   // drawing strokes don't count
                if !run.isNull { heights.append(run.height) }
                run = .null
            } else if !run.isNull, gap(run, b) <= 0.3 * h0, run.union(b).height <= 2 * h0 {
                run = run.union(b)
            } else {
                if !run.isNull { heights.append(run.height) }
                run = b
            }
        }
        if !run.isNull { heights.append(run.height) }
        guard !heights.isEmpty else { return h0 }
        let estimate = min(max(median(heights), 0.5 * h0), 3 * h0)
        // A few runs are likely a drawing rather than writing: don't let them set a huge scale.
        return heights.count < 4 ? min(estimate, 32) : estimate
    }

    /// Recursive XY-cut, top to bottom first: split the blocks in two at the widest horizontal
    /// blank gap; only where no such gap exists, at the widest vertical one (left before right).
    /// Then split each part again. Returns indices into `rects`.
    public static func readingOrder(_ rects: [CGRect]) -> [Int] {
        /// The widest gap along one axis that no item spans, and the items on each side of it.
        func widestGap(_ items: [Int], rows: Bool) -> (first: [Int], second: [Int], gap: CGFloat)? {
            let lo: (Int) -> CGFloat = { rows ? rects[$0].minY : rects[$0].minX }
            let hi: (Int) -> CGFloat = { rows ? rects[$0].maxY : rects[$0].maxX }
            let sorted = items.sorted { lo($0) < lo($1) }
            var end = hi(sorted[0])
            var best: (index: Int, gap: CGFloat)?
            for (k, i) in sorted.enumerated().dropFirst() {
                if lo(i) > end, lo(i) - end > (best?.gap ?? 0) { best = (k, lo(i) - end) }
                end = max(end, hi(i))
            }
            return best.map { (Array(sorted[..<$0.index]), Array(sorted[$0.index...]), $0.gap) }
        }
        func cut(_ items: [Int]) -> [Int] {
            guard items.count > 1 else { return items }
            if let split = widestGap(items, rows: true) ?? widestGap(items, rows: false) {
                return cut(split.first) + cut(split.second)
            }
            // Overlapping in both directions: top-left first.
            return items.sorted { (rects[$0].minY, rects[$0].minX) < (rects[$1].minY, rects[$1].minX) }
        }
        return cut(Array(rects.indices))
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Distance between two rectangles (0 when they touch or overlap).
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, a.minX - b.maxX, b.minX - a.maxX)
        let dy = max(0, a.minY - b.maxY, b.minY - a.maxY)
        return hypot(dx, dy)
    }
}

// MARK: - Implementation

private final class Analyzer {
    enum Role { case text, rule, graphic }

    struct Line {
        var strokes: [Int]
        var bounds: CGRect
        var hasFraction: Bool
        var hasEquals: Bool
        var kind: InkBlock.Kind
    }

    struct Drawing {
        var graphic: [Int]
        /// Bounds of the graphic strokes only (labels don't count, so drawings don't snowball).
        var graphicBounds: CGRect
        var labels: [Line] = []
    }

    struct Figure {
        var images: [Int]
        var lines: [Line] = []
        var drawings: [Drawing] = []
    }

    let board: Board
    let h: CGFloat
    let n: Int
    var bounds: [CGRect] = []
    var samples: [[CGPoint]] = []
    var length: [CGFloat] = []
    var straight: [Bool] = []
    var role: [Role] = []
    var operators = Set<Int>()
    var isFractionBar: [Bool]
    var isEquals: [Bool]
    /// Glyphs: strokes glued into characters / words / fraction units.
    var glyphs: UnionFind
    var glyphBounds: [CGRect] = []

    init(board: Board, h: CGFloat) {
        self.board = board
        self.h = h
        n = board.strokes.count
        isFractionBar = Array(repeating: false, count: n)
        isEquals = Array(repeating: false, count: n)
        glyphs = UnionFind(n)

        for stroke in board.strokes {
            let points = stroke.points
            var total: CGFloat = 0
            for (a, b) in zip(points, points.dropFirst()) { total += hypot(b.x - a.x, b.y - a.y) }
            let first = points[0].location, last = points[points.count - 1].location
            let chord = hypot(last.x - first.x, last.y - first.y)
            let isStraight = total >= h && chord >= 0.93 * total
            let isHorizontal = isStraight && abs(last.y - first.y) <= 0.27 * abs(last.x - first.x)
            let b = stroke.bounds

            let role: Role
            if b.height > 2.4 * h || (b.width > 3 * h && b.height > 1.7 * h) || (isStraight && !isHorizontal && total > 3 * h) {
                role = .graphic
            } else if isHorizontal {
                role = .rule
            } else {
                role = .text
            }

            let step = max(1, points.count / 48)
            var sampled = stride(from: 0, to: points.count, by: step).map { points[$0].location }
            if sampled.last != last { sampled.append(last) }

            bounds.append(b)
            samples.append(sampled)
            length.append(total)
            straight.append(isStraight)
            self.role.append(role)
        }
        glyphBounds = bounds
    }

    func run(useGroups: Bool) -> [InkBlock] {
        findEqualsSigns()
        resolveRules()
        resolveTallOperators()
        buildGlyphs()
        let lines = buildLines()
        var drawings = buildDrawings()
        var free = absorbLabels(lines, into: &drawings)
        let figures = assignToPictures(lines: &free, drawings: &drawings)

        let paragraphGap = self.paragraphGap(free + figures.flatMap(\.lines))
        var blocks = paragraphs(free, gap: paragraphGap).map(textBlock)
        blocks += drawings.map(drawingBlock)
        blocks += figures.map { figureBlock($0, paragraphGap: paragraphGap) }
        if useGroups && !board.groups.isEmpty {
            return groupedBlocks(blocks)
        }
        return ordered(blocks)
    }

    // MARK: Step 2: "=", fraction bars and underlines

    /// Two short, roughly straight and horizontal bars written one after the other, overlapping
    /// horizontally, a small gap apart, with no other ink between them or within one gap above
    /// and below (which rules out characters made of stacked strokes, like 三 or 言; a lone 二
    /// still looks like "=").
    func findEqualsSigns() {
        var grid = RectGrid(cell: 2 * h)
        for i in 0..<n where role[i] != .graphic { grid.insert(i, bounds[i]) }

        func bar(_ i: Int) -> (minX: CGFloat, maxX: CGFloat, y: CGFloat)? {
            guard role[i] != .graphic, length[i] >= 0.2 * h, length[i] <= 2.5 * h else { return nil }
            let points = board.strokes[i].points
            let first = points[0], last = points[points.count - 1]
            let dx = last.x - first.x, dy = last.y - first.y
            guard hypot(dx, dy) >= 0.7 * length[i], abs(dy) <= 0.5 * abs(dx) else { return nil }
            let y = samples[i].reduce(0) { $0 + $1.y } / CGFloat(samples[i].count)
            return (bounds[i].minX, bounds[i].maxX, y)
        }

        for i in 0..<max(0, n - 1) {
            let j = i + 1
            guard let a = bar(i), let b = bar(j) else { continue }
            let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            let gap = abs(a.y - b.y)
            guard overlap >= 0.5 * min(a.maxX - a.minX, b.maxX - b.minX),
                  gap >= 0.08 * h, gap <= 0.7 * h,
                  min(length[i], length[j]) >= 0.4 * max(length[i], length[j]) else { continue }
            // Clear between the bars, and for one gap above and below them (三, 言 are not "=").
            let around = CGRect(x: max(a.minX, b.minX) + 0.1 * overlap, y: min(a.y, b.y) - gap,
                                width: 0.8 * overlap, height: 3 * gap)
            let crowded = grid.query(around).contains { k in
                k != i && k != j && samples[k].contains { around.contains($0) }
            }
            guard !crowded else { continue }
            isEquals[i] = true
            isEquals[j] = true
            mergeGlyphs(i, j, maxHeight: .infinity)
        }
    }

    func resolveRules() {
        let candidates = (0..<n).filter { role[$0] != .graphic }
        var grid = RectGrid(cell: 2 * h)
        for i in candidates { grid.insert(i, bounds[i]) }
        let graphic = (0..<n).filter { role[$0] == .graphic }
        var graphicGrid = RectGrid(cell: 4 * h)
        for i in graphic { graphicGrid.insert(i, bounds[i]) }

        let reach = 0.8 * h, margin = 1.0 * h
        for r in (0..<n).filter({ role[$0] == .rule && !isEquals[$0] }).sorted(by: { length[$0] > length[$1] }) {
            let bar = bounds[r]
            var above: [Int] = [], below: [Int] = []
            var aboveSpills = false, belowSpills = false
            for s in grid.query(bar.insetBy(dx: -margin, dy: -reach)) where s != r {
                let b = bounds[s]
                let isAbove = b.maxY <= bar.midY && b.maxY >= bar.minY - reach
                let isBelow = b.minY >= bar.midY && b.minY <= bar.maxY + reach
                guard isAbove || isBelow, b.maxX >= bar.minX - margin, b.minX <= bar.maxX + margin else { continue }
                let inside = min(b.maxX, bar.maxX) - max(b.minX, bar.minX) >= 0.5 * max(b.width, 1)
                // Writing continuing past the bar's ends means a line of text (underline), not a
                // numerator or denominator. Flat strokes there ("=", "-") don't count.
                let spills = !inside && b.height >= 0.4 * h
                if isAbove {
                    if inside { above.append(s) } else if spills { aboveSpills = true }
                } else {
                    if inside { below.append(s) } else if spills { belowSpills = true }
                }
            }
            if !above.isEmpty, !below.isEmpty, !aboveSpills, !belowSpills {
                isFractionBar[r] = true   // numerator and denominator stay within the bar
                for s in above + below { mergeGlyphs(r, s, maxHeight: .infinity) }
            } else if !above.isEmpty {
                for s in above { mergeGlyphs(r, s, maxHeight: .infinity) }   // underline
            } else if length[r] >= 4 * h || graphicGrid.query(bar.insetBy(dx: -0.5 * h, dy: -0.5 * h))
                        .contains(where: { distance([r], [$0]) <= 0.5 * h }) {
                role[r] = .graphic   // a long line on its own, or a line joining shapes of a drawing
            }
        }
    }

    /// A tall open pen stroke alongside writing can be an operator. Leave connected
    /// graphics (axes, arrows, multi-stroke frames) together for drawing recognition.
    func resolveTallOperators() {
        let graphics = bounds.indices.filter { role[$0] == .graphic }
        guard !graphics.isEmpty else { return }
        var grid = RectGrid(cell: 3 * h)
        for i in bounds.indices { grid.insert(i, bounds[i]) }
        for i in graphics {
            let r = bounds[i]
            guard r.height > 2.4 * h, r.width <= 1.2 * r.height,
                  let a = samples[i].first, let b = samples[i].last,
                  hypot(a.x - b.x, a.y - b.y) > 0.6 * h else { continue }
            let nearby = grid.query(r.insetBy(dx: -1.5 * h, dy: -0.5 * h)).filter { $0 != i }
            let touchesGraphic = nearby.contains { j in
                role[j] == .graphic && InkLayout.gap(r, bounds[j]) <= 0.5 * h && distance([i], [j]) <= 0.5 * h
            }
            if touchesGraphic { continue }
            let neighbours = nearby.filter { j in
                let t = bounds[j]
                let overlap = min(r.maxY, t.maxY) - max(r.minY, t.minY)
                return role[j] != .graphic && overlap >= 0.5 * t.height && InkLayout.gap(r, t) <= 1.5 * h
            }
            // A vertical separator alongside multiple baselines must not connect the rows.
            let baselines = neighbours.filter { bounds[$0].height >= 0.6 * h }.map { bounds[$0].midY }
            if let top = baselines.min(), let bottom = baselines.max(), bottom - top > 2 * h { continue }
            if neighbours.contains(where: { abs(bounds[$0].midY - r.midY) <= max(h, 0.35 * r.height) }) {
                operators.insert(i)
            }
        }
        for i in operators { role[i] = .text }
    }

    // MARK: Step 3: glyphs and lines

    @discardableResult
    func mergeGlyphs(_ a: Int, _ b: Int, maxHeight: CGFloat) -> Bool {
        let ra = glyphs.find(a), rb = glyphs.find(b)
        guard ra != rb else { return false }
        let united = glyphBounds[ra].union(glyphBounds[rb])
        guard united.height <= maxHeight else { return false }
        glyphs.union(ra, rb)
        glyphBounds[glyphs.find(ra)] = united
        return true
    }

    func buildGlyphs() {
        // Written one after the other, close together, and still one line tall (so the last word
        // of a line and the first of the next don't join when they happen to be close).
        var previous: Int?
        for i in 0..<n where role[i] != .graphic {
            if let p = previous, InkLayout.gap(bounds[p], bounds[i]) <= 0.45 * h {
                mergeGlyphs(p, i, maxHeight: 1.6 * h)
            }
            previous = i
        }

        // Dots, accents and punctuation join the nearest larger glyph.
        let roots = Set((0..<n).filter { role[$0] != .graphic }.map { glyphs.find($0) })
        var grid = RectGrid(cell: 2 * h)
        for r in roots { grid.insert(r, glyphBounds[r]) }
        // (Bounds are kept on the current root of each glyph.)
        func isSmall(_ root: Int) -> Bool { max(glyphBounds[root].width, glyphBounds[root].height) <= 0.35 * h }
        for r in roots.sorted() where isSmall(glyphs.find(r)) {
            let mine = glyphs.find(r)
            var nearest: (root: Int, gap: CGFloat)?
            for candidate in grid.query(glyphBounds[mine].insetBy(dx: -0.6 * h, dy: -0.6 * h)) {
                let other = glyphs.find(candidate)
                guard other != mine, !isSmall(other) else { continue }
                let gap = InkLayout.gap(glyphBounds[mine], glyphBounds[other])
                if gap <= 0.6 * h, gap < (nearest?.gap ?? .infinity) { nearest = (other, gap) }
            }
            if let nearest { mergeGlyphs(mine, nearest.root, maxHeight: 1.8 * h) }
        }
    }

    func buildLines() -> [Line] {
        var members: [Int: [Int]] = [:]
        for i in 0..<n where role[i] != .graphic { members[glyphs.find(i), default: []].append(i) }
        let roots = members.keys.sorted()
        guard !roots.isEmpty else { return [] }
        let rects = roots.map { glyphBounds[$0] }

        var grid = RectGrid(cell: 2 * h)
        for (k, r) in rects.enumerated() { grid.insert(k, r) }
        var graphics = RectGrid(cell: 3 * h)
        for i in bounds.indices where role[i] == .graphic { graphics.insert(i, bounds[i]) }

        // A column gutter repeats on adjacent rows. Look for writing on both sides of
        // the same blank strip at a second baseline, using only the local grid cells.
        func blocked(_ left: CGRect, _ right: CGRect) -> Bool {
            let width = right.minX - left.maxX
            guard width > 0 else { return false }
            let strip = CGRect(x: left.maxX, y: max(left.minY, right.minY), width: width,
                               height: min(left.maxY, right.maxY) - max(left.minY, right.minY))
            // A box around both words has a bounding box across the gap, but its
            // actual edges are outside the gap. Test the sampled segments themselves.
            if graphics.query(strip).contains(where: { graphicIntersects($0, strip) }) { return true }
            guard width >= h else { return false }
            let band = strip.insetBy(dx: -1.5 * h, dy: -3.5 * h)
            let neighbours = grid.query(band).map { rects[$0] }.filter {
                $0.intersects(band) && abs($0.midY - strip.midY) >= h
            }
            let mid = strip.midX
            let margin = 0.25 * h
            let rightBank = neighbours.filter { $0.minX >= mid + margin }
            let across = neighbours.filter { $0.minX < mid + margin && $0.maxX > mid - margin }
            return neighbours.contains { a in
                a.maxX <= mid - margin
                    && !across.contains { $0.minY < a.midY + margin && $0.maxY > a.midY - margin }
                    && rightBank.contains { abs(a.midY - $0.midY) <= 0.6 * h }
            }
        }

        var lines = UnionFind(roots.count)
        for (a, ra) in rects.enumerated() {
            for b in grid.query(ra.insetBy(dx: -3 * h, dy: 0)) where b > a {
                let rb = rects[b]
                let overlap = min(ra.maxY, rb.maxY) - max(ra.minY, rb.minY)
                let shorter = max(min(ra.height, rb.height), 1)
                let gapX = max(ra.minX, rb.minX) - min(ra.maxX, rb.maxX)
                let centres = abs(ra.midY - rb.midY)
                if overlap >= 0.4 * shorter, gapX <= 3 * h, centres <= 0.75 * max(ra.height, rb.height),
                   !(ra.minX < rb.minX ? blocked(ra, rb) : blocked(rb, ra)) {
                    lines.union(a, b)
                }
            }
        }
        var groups = lines.groups(Array(roots.indices))
        var groupRects = groups.map { $0.reduce(CGRect.null) { $0.union(rects[$1]) } }

        // A small fragment right next to a line — a raised superscript, a subscript hanging below
        // the baseline — overlaps it too little vertically to join above. It joins the nearest line.
        let isSmall: (CGRect) -> Bool = { $0.width <= 1.5 * self.h && $0.height <= 1.5 * self.h }
        var fragments = UnionFind(groups.count)
        for (g, rect) in groupRects.enumerated() where isSmall(rect) {
            let nearest = groupRects.indices
                .filter { $0 != g && !isSmall(groupRects[$0]) }
                .map { ($0, InkLayout.gap(rect, groupRects[$0])) }
                .filter { $0.1 <= 0.5 * h }
                .min { $0.1 < $1.1 }
            if let (target, _) = nearest { fragments.union(g, target) }
        }
        groups = fragments.groups(Array(groups.indices)).map { $0.flatMap { groups[$0] } }
        groupRects = groups.map { $0.reduce(CGRect.null) { $0.union(rects[$1]) } }

        return zip(groups, groupRects).map { group, rect in
            let strokes = group.flatMap { members[roots[$0]]! }.sorted()
            let hasFraction = strokes.contains { isFractionBar[$0] }
            let hasEquals = strokes.contains { isEquals[$0] }
            let guess: InkBlock.Kind = hasFraction || hasEquals || strokes.contains(where: operators.contains) ? .formula : .text
            let label = board.labels[Set(strokes.map { board.strokes[$0].id })]
            return Line(strokes: strokes, bounds: rect, hasFraction: hasFraction, hasEquals: hasEquals,
                        kind: label == .text || label == .formula ? label! : guess)
        }
    }

    // MARK: Step 4: drawings

    func buildDrawings() -> [Drawing] {
        let graphic = (0..<n).filter { role[$0] == .graphic }
        guard !graphic.isEmpty else { return [] }
        var grid = RectGrid(cell: 4 * h)
        for (k, i) in graphic.enumerated() { grid.insert(k, bounds[i]) }
        var uf = UnionFind(graphic.count)
        for (a, i) in graphic.enumerated() {
            let reach = bounds[i].insetBy(dx: -0.75 * h, dy: -0.75 * h)
            for b in grid.query(reach) where b > a && reach.intersects(bounds[graphic[b]]) {
                uf.union(a, b)
            }
        }
        return uf.groups(Array(graphic.indices)).map { group in
            let strokes = group.map { graphic[$0] }
            return Drawing(graphic: strokes, graphicBounds: strokes.reduce(CGRect.null) { $0.union(bounds[$1]) })
        }
    }

    /// Lines inside a drawing, or short labels touching it, become part of it. Returns the rest.
    func absorbLabels(_ lines: [Line], into drawings: inout [Drawing]) -> [Line] {
        guard !drawings.isEmpty else { return lines }
        var free: [Line] = []
        for line in lines {
            let area = max(line.bounds.width * line.bounds.height, 1)
            let inside = drawings.indices.first { d in
                let common = line.bounds.intersection(drawings[d].graphicBounds)
                return !common.isNull && common.width * common.height >= 0.6 * area
            }
            let label = line.bounds.width <= 8 * h ? drawings.indices.first { d in
                InkLayout.gap(line.bounds, drawings[d].graphicBounds) <= 0.4 * h
                    && distance(line.strokes, drawings[d].graphic) <= 0.4 * h
            } : nil
            if let d = inside ?? label {
                drawings[d].labels.append(line)
            } else {
                free.append(line)
            }
        }
        return free
    }

    // MARK: Step 5: pictures

    func assignToPictures(lines: inout [Line], drawings: inout [Drawing]) -> [Figure] {
        let images = board.images
        guard !images.isEmpty else { return [] }
        var pictures = UnionFind(images.count)
        for a in images.indices {
            for b in images.indices where b > a && images[a].frame.intersects(images[b].frame) {
                pictures.union(a, b)
            }
        }

        var lineOwner: [Int: Int] = [:]
        for (l, line) in lines.enumerated() {
            let best = images.indices
                .filter { images[$0].frame.intersects(line.bounds) }
                .map { ($0, insideFraction(line.strokes, images[$0].frame)) }
                .max { $0.1 < $1.1 }
            if let (k, fraction) = best, fraction >= 0.5 { lineOwner[l] = k }
        }
        var drawingOwner: [Int: Int] = [:]
        for (d, drawing) in drawings.enumerated() {
            let hits = images.indices
                .filter { images[$0].frame.intersects(drawing.graphicBounds) }
                .map { ($0, insideFraction(drawing.graphic, images[$0].frame)) }
                .filter { $0.1 >= 0.15 }   // ink reaching onto a picture annotates it
            guard let best = hits.max(by: { $0.1 < $1.1 }) else { continue }
            for hit in hits { pictures.union(best.0, hit.0) }   // ink joining two pictures
            drawingOwner[d] = best.0
        }

        var figures: [Int: Figure] = [:]
        for group in pictures.groups(Array(images.indices)) {
            figures[pictures.find(group[0])] = Figure(images: group)
        }
        for (l, k) in lineOwner { figures[pictures.find(k)]!.lines.append(lines[l]) }
        for (d, k) in drawingOwner { figures[pictures.find(k)]!.drawings.append(drawings[d]) }
        lines = lines.indices.filter { lineOwner[$0] == nil }.map { lines[$0] }
        drawings = drawings.indices.filter { drawingOwner[$0] == nil }.map { drawings[$0] }
        return figures.keys.sorted().map { figures[$0]! }
    }

    // MARK: Step 6: paragraphs

    /// Lines further apart than this start a new paragraph: well above the usual gap between
    /// lines of this board, within [0.8h, 1.5h].
    func paragraphGap(_ lines: [Line]) -> CGFloat {
        var gaps: [CGFloat] = []
        for a in lines {
            let below = lines.filter { b in
                b.bounds.midY > a.bounds.midY && overlapsHorizontally(a.bounds, b.bounds)
            }.map { $0.bounds.minY - a.bounds.maxY }
            if let nearest = below.min(), nearest >= -0.5 * h, nearest <= 3 * h { gaps.append(nearest) }
        }
        let typical = gaps.isEmpty ? 0.6 * h : InkLayout.median(gaps)
        return min(max(1.7 * typical, 0.8 * h), 1.5 * h)
    }

    func overlapsHorizontally(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) >= 0.3 * min(a.width, b.width)
    }

    func paragraphs(_ lines: [Line], gap: CGFloat) -> [[Line]] {
        var uf = UnionFind(lines.count)
        for (i, a) in lines.enumerated() {
            for (j, b) in lines.enumerated() where j != i {
                if b.bounds.midY > a.bounds.midY, b.bounds.minY - a.bounds.maxY <= gap,
                   overlapsHorizontally(a.bounds, b.bounds) {
                    uf.union(i, j)
                }
            }
        }
        // Split each paragraph where lines change between text and formula.
        return uf.groups(Array(lines.indices)).flatMap { group -> [[Line]] in
            var runs: [[Line]] = []
            for line in group.map({ lines[$0] }).sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
                if let last = runs.last?.last, last.kind == line.kind {
                    runs[runs.count - 1].append(line)
                } else {
                    runs.append([line])
                }
            }
            return runs
        }
    }

    // MARK: Blocks

    func ids(_ strokes: [Int]) -> [UUID] { strokes.sorted().map { board.strokes[$0].id } }

    func inkLine(_ line: Line) -> InkLine {
        InkLine(bounds: line.bounds, strokeIDs: ids(line.strokes), kind: line.kind,
                hasFraction: line.hasFraction, hasEquals: line.hasEquals)
    }

    func textBlock(_ lines: [Line]) -> InkBlock {
        InkBlock(kind: lines.allSatisfy { $0.kind == .formula } ? .formula : .text,
                 bounds: lines.reduce(CGRect.null) { $0.union($1.bounds) },
                 strokeIDs: ids(lines.flatMap(\.strokes)),
                 lines: lines.map(inkLine))
    }

    func drawingBlock(_ drawing: Drawing) -> InkBlock {
        let all = drawing.graphic + drawing.labels.flatMap(\.strokes)
        let bounds = drawing.labels.reduce(drawing.graphicBounds) { $0.union($1.bounds) }
        let labels = drawing.labels.sorted { $0.bounds.minY < $1.bounds.minY }
        if let kind = board.labels[Set(all.map { board.strokes[$0].id })], kind != .image, kind != .figure {
            // Labelled (by the AI or by hand); it may turn out to be writing, e.g. a big matrix.
            return InkBlock(kind: kind, bounds: bounds, strokeIDs: ids(all))
        }
        if !labels.isEmpty, isEnclosure(drawing) {
            // Only a box / circle drawn around writing: the writing is what matters.
            return InkBlock(kind: labels.allSatisfy { $0.kind == .formula } ? .formula : .text, bounds: bounds,
                            strokeIDs: ids(all), lines: labels.map(inkLine))
        }
        let straightLength = drawing.graphic.filter { straight[$0] }.reduce(0) { $0 + length[$1] }
        let totalLength = drawing.graphic.reduce(0) { $0 + length[$1] }
        let looksLikeDiagram = !labels.isEmpty || straightLength >= 0.4 * totalLength
        return InkBlock(kind: looksLikeDiagram ? .diagram : .drawing, bounds: bounds, strokeIDs: ids(all))
    }

    /// Trace a closed contour, allowing pen lifts at the corners of a hand-drawn box.
    func isEnclosure(_ drawing: Drawing) -> Bool {
        var remaining = drawing.graphic
        var contour = samples[remaining.removeFirst()]
        let tolerance = 0.45 * h
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tolerance }
        while !remaining.isEmpty {
            let end = contour.last!
            guard let next = remaining.firstIndex(where: { near(end, samples[$0].first!) || near(end, samples[$0].last!) }) else { return false }
            let segment = samples[remaining.remove(at: next)]
            contour += near(end, segment.first!) ? segment : Array(segment.reversed())
        }
        guard near(contour.first!, contour.last!) else { return false }
        let path = CGMutablePath()
        path.addLines(between: contour)
        path.closeSubpath()
        return drawing.labels.allSatisfy { line in
            path.contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY))
        }
    }

    func figureBlock(_ figure: Figure, paragraphGap: CGFloat) -> InkBlock {
        let children = ordered(paragraphs(figure.lines, gap: paragraphGap).map(textBlock) + figure.drawings.map(drawingBlock))
        let frames = figure.images.reduce(CGRect.null) { $0.union(board.images[$1].frame) }
        let strokes = figure.lines.flatMap(\.strokes) + figure.drawings.flatMap { $0.graphic + $0.labels.flatMap(\.strokes) }
        return InkBlock(kind: children.isEmpty ? .image : .figure,
                        bounds: children.reduce(frames) { $0.union($1.bounds) },
                        strokeIDs: ids(strokes),
                        imageIDs: figure.images.map { board.images[$0].id },
                        children: children)
    }

    /// Apply explicit membership within each image context. A geometric block votes for
    /// the owner of its unclaimed ink; explicit strokes always retain their own group.
    func groupedBlocks(_ original: [InkBlock]) -> [InkBlock] {
        var owners: [UUID: Int] = [:]
        for (g, group) in board.groups.enumerated() {
            for id in group.ids where owners[id] == nil { owners[id] = g }
        }
        var index: [UUID: Int] = [:]
        for (i, stroke) in board.strokes.enumerated() { index[stroke.id] = i }

        func regroup(_ blocks: [InkBlock]) -> [InkBlock] {
            var result: [InkBlock] = []
            var ink: [Int: [Int]] = [:]
            var lines: [Int: [InkLine]] = [:]
            for var block in blocks {
                if !block.imageIDs.isEmpty {
                    block.children = regroup(block.children)
                    result.append(block)
                    continue
                }
                var votes: [Int: Int] = [:]
                for id in block.strokeIDs {
                    if let g = owners[id] { votes[g, default: 0] += 1 }
                }
                // Break ties in stored group order.
                guard let winner = votes.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key else {
                    result.append(block)
                    continue
                }
                for id in block.strokeIDs {
                    ink[owners[id] ?? winner, default: []].append(index[id]!)
                }
                // Preserve line boundaries within each group. A graphical unit relabelled
                // as writing acts as a single line; frame strokes stay outside the text lines.
                let sourceLines = block.lines.isEmpty
                    ? [InkLine(bounds: block.bounds, strokeIDs: block.strokeIDs)] : block.lines
                for line in sourceLines {
                    for (g, ids) in Dictionary(grouping: line.strokeIDs, by: { owners[$0] ?? winner }) {
                        let kind = board.groups[g].kind
                        guard kind == .formula || kind == .text else { continue }
                        let indices = ids.map { index[$0]! }
                        lines[g, default: []].append(InkLine(bounds: indices.reduce(.null) { $0.union(bounds[$1]) },
                            strokeIDs: ids, kind: kind, hasFraction: indices.contains { isFractionBar[$0] },
                            hasEquals: indices.contains { isEquals[$0] }))
                    }
                }
            }
            for g in ink.keys.sorted() {
                let strokes = ink[g]!
                let fragments = lines[g] ?? []
                result.append(InkBlock(kind: board.groups[g].kind, bounds: strokes.reduce(.null) { $0.union(bounds[$1]) },
                    strokeIDs: ids(strokes), lines: InkLayout.readingOrder(fragments.map(\.bounds)).map { fragments[$0] }))
            }
            return ordered(result)
        }
        return regroup(original)
    }

    func ordered(_ blocks: [InkBlock]) -> [InkBlock] {
        // Each caption is ordered together with the drawing or picture above it.
        var captionOf: [Int: Int] = [:]   // caption → block above
        for (c, caption) in blocks.enumerated() where caption.kind == .text && caption.lines.count <= 2 {
            let above = blocks.indices.filter { a in
                let block = blocks[a]
                guard [.drawing, .diagram, .image, .figure].contains(block.kind), captionOf.values.contains(a) == false else { return false }
                let gap = caption.bounds.minY - block.bounds.maxY
                let overlap = min(caption.bounds.maxX, block.bounds.maxX) - max(caption.bounds.minX, block.bounds.minX)
                return gap >= -0.3 * h && gap <= 2.5 * h && overlap >= 0.5 * caption.bounds.width
            }
            if let nearest = above.min(by: { blocks[$0].bounds.maxY > blocks[$1].bounds.maxY }) { captionOf[c] = nearest }
        }
        let units: [[Int]] = blocks.indices.compactMap { i in
            captionOf[i] != nil ? nil : [i] + captionOf.filter { $0.value == i }.map(\.key)
        }
        let rects = units.map { $0.reduce(CGRect.null) { $0.union(blocks[$1].bounds) } }
        return InkLayout.readingOrder(rects).flatMap { units[$0] }.map { blocks[$0] }
    }

    // MARK: Geometry

    /// Clip each segment to the gap's vertical range, then compare its horizontal extent.
    func graphicIntersects(_ i: Int, _ gap: CGRect) -> Bool {
        guard bounds[i].intersects(gap) else { return false }
        return zip(samples[i], samples[i].dropFirst()).contains { a, b in
            if a.y == b.y {
                return a.y >= gap.minY && a.y <= gap.maxY
                    && max(a.x, b.x) >= gap.minX && min(a.x, b.x) <= gap.maxX
            }
            let t0 = (gap.minY - a.y) / (b.y - a.y), t1 = (gap.maxY - a.y) / (b.y - a.y)
            let lo = max(0, min(t0, t1)), hi = min(1, max(t0, t1))
            guard lo <= hi else { return false }
            let x0 = a.x + lo * (b.x - a.x), x1 = a.x + hi * (b.x - a.x)
            return max(x0, x1) >= gap.minX && min(x0, x1) <= gap.maxX
        }
    }

    /// Share of the strokes' sample points inside `rect`.
    func insideFraction(_ strokes: [Int], _ rect: CGRect) -> CGFloat {
        var inside = 0, total = 0
        for s in strokes {
            total += samples[s].count
            inside += samples[s].lazy.filter { rect.contains($0) }.count
        }
        return total == 0 ? 0 : CGFloat(inside) / CGFloat(total)
    }

    /// Smallest gap between the ink of two sets of strokes (centre lines minus pen radii).
    func distance(_ a: [Int], _ b: [Int]) -> CGFloat {
        var best = CGFloat.infinity
        for i in a {
            for j in b where InkLayout.gap(bounds[i], bounds[j]) < best {
                let pens = (board.strokes[i].width + board.strokes[j].width) / 2
                for p in samples[i] {
                    for q in samples[j] {
                        best = min(best, max(0, hypot(p.x - q.x, p.y - q.y) - pens))
                    }
                }
            }
        }
        return best
    }
}

// MARK: - Helpers

struct UnionFind {
    private var parent: [Int]

    init(_ count: Int) { parent = Array(0..<count) }

    mutating func find(_ i: Int) -> Int {
        var root = i
        while parent[root] != root { root = parent[root] }
        var j = i
        while parent[j] != root {
            let next = parent[j]
            parent[j] = root
            j = next
        }
        return root
    }

    /// The smaller index becomes the root.
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }

    /// `items` grouped by set, each group sorted, groups ordered by their first item.
    mutating func groups(_ items: [Int]) -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for i in items { byRoot[find(i), default: []].append(i) }
        return byRoot.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}

/// Buckets rectangles into square cells for neighbour queries.
struct RectGrid {
    private struct Cell: Hashable { let x: Int, y: Int }
    private let size: CGFloat
    private var cells: [Cell: [Int]] = [:]

    init(cell size: CGFloat) { self.size = max(size, 1) }

    private func span(_ r: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>) {
        (Int((r.minX / size).rounded(.down))...Int((r.maxX / size).rounded(.down)),
         Int((r.minY / size).rounded(.down))...Int((r.maxY / size).rounded(.down)))
    }

    mutating func insert(_ item: Int, _ rect: CGRect) {
        guard !rect.isNull, !rect.isInfinite else { return }
        let (xs, ys) = span(rect)
        for x in xs { for y in ys { cells[Cell(x: x, y: y), default: []].append(item) } }
    }

    /// Items whose cells meet `rect` (a superset of the items intersecting it), each once.
    func query(_ rect: CGRect) -> [Int] {
        guard !rect.isNull, !rect.isInfinite else { return [] }
        let (xs, ys) = span(rect)
        var seen = Set<Int>(), found: [Int] = []
        for x in xs {
            for y in ys {
                for item in cells[Cell(x: x, y: y)] ?? [] where seen.insert(item).inserted { found.append(item) }
            }
        }
        return found
    }
}
