import CoreGraphics
import Foundation

/// Pure editing operations on strokes and boards. The app layer owns undo and redraw.
public enum InkOps {

    // MARK: Eraser

    public struct EraseResult {
        public var strokes: [Stroke]
        /// Area that needs redrawing (bounds of every stroke that was cut or removed).
        public var dirty: CGRect
    }

    /// Erases ink touched by a round eraser of `radius` swept from `a` to `b`.
    /// Strokes that are cut in the middle are split into separate strokes.
    /// Returns nil when nothing was touched.
    public static func erase(_ strokes: [Stroke], from a: CGPoint, to b: CGPoint, radius: CGFloat) -> EraseResult? {
        let sweep = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -radius, dy: -radius)

        var result: [Stroke] = []
        result.reserveCapacity(strokes.count)
        var dirty = CGRect.null

        for stroke in strokes {
            guard stroke.bounds.intersects(sweep) else {
                result.append(stroke)
                continue
            }
            let keep = stroke.points.map { p in
                distance(from: p.location, toSegment: a, b) > radius + stroke.radius(at: p)
            }
            guard keep.contains(false) else {
                result.append(stroke)
                continue
            }
            dirty = dirty.union(stroke.bounds)

            // Split into runs of surviving points.
            var run: [InkPoint] = []
            func flush() {
                if run.count >= 2 { result.append(Stroke(points: run, width: stroke.width)) }
                run.removeAll(keepingCapacity: true)
            }
            for (point, kept) in zip(stroke.points, keep) {
                if kept { run.append(point) } else { flush() }
            }
            flush()
        }
        return dirty.isNull ? nil : EraseResult(strokes: result, dirty: dirty)
    }

    // MARK: Selection

    /// Strokes with at least `threshold` of their points inside the closed lasso polygon.
    public static func strokes(inLasso polygon: [CGPoint], from strokes: [Stroke], threshold: CGFloat = 0.5) -> Set<UUID> {
        guard polygon.count >= 3 else { return [] }
        let lassoBounds = boundingRect(of: polygon)
        var selected = Set<UUID>()
        for stroke in strokes where stroke.bounds.intersects(lassoBounds) {
            let step = max(1, stroke.points.count / 200)   // sample long strokes
            var inside = 0, total = 0
            for i in stride(from: 0, to: stroke.points.count, by: step) {
                total += 1
                if contains(polygon, stroke.points[i].location) { inside += 1 }
            }
            if total > 0, CGFloat(inside) / CGFloat(total) >= threshold {
                selected.insert(stroke.id)
            }
        }
        return selected
    }

    /// Topmost stroke whose ink passes within `tolerance` of `point`.
    public static func hitTest(_ point: CGPoint, in strokes: [Stroke], tolerance: CGFloat) -> UUID? {
        for stroke in strokes.reversed() where stroke.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
            for p in stroke.points where hypot(p.x - point.x, p.y - point.y) <= tolerance + stroke.radius(at: p) {
                return stroke.id
            }
        }
        return nil
    }

    /// Lasso over a whole board: strokes as above, and pictures with at least `threshold` of
    /// their area inside the polygon.
    public static func selection(inLasso polygon: [CGPoint], in board: Board, threshold: CGFloat = 0.5) -> Set<UUID> {
        var selected = strokes(inLasso: polygon, from: board.strokes, threshold: threshold)
        guard polygon.count >= 3 else { return selected }
        let lassoBounds = boundingRect(of: polygon)
        let n = 5   // sample a 5×5 grid over each picture
        for image in board.images where image.frame.intersects(lassoBounds) {
            var inside = 0
            for i in 0..<n {
                for j in 0..<n {
                    let p = CGPoint(x: image.frame.minX + image.frame.width * (CGFloat(i) + 0.5) / CGFloat(n),
                                    y: image.frame.minY + image.frame.height * (CGFloat(j) + 0.5) / CGFloat(n))
                    if contains(polygon, p) { inside += 1 }
                }
            }
            if CGFloat(inside) / CGFloat(n * n) >= threshold { selected.insert(image.id) }
        }
        return selected
    }

    /// Topmost item under `point`: ink first (it is drawn above pictures), then the front-most picture.
    public static func hitTest(_ point: CGPoint, in board: Board, tolerance: CGFloat) -> UUID? {
        hitTest(point, in: board.strokes, tolerance: tolerance)
            ?? board.images.last { $0.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }?.id
    }

    /// Even-odd ray casting.
    public static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: Moving

    public static func translate(_ strokes: [Stroke], ids: Set<UUID>, dx: CGFloat, dy: CGFloat) -> [Stroke] {
        strokes.map { ids.contains($0.id) ? $0.translated(dx: dx, dy: dy) : $0 }
    }

    public static func translate(_ board: Board, ids: Set<UUID>, dx: CGFloat, dy: CGFloat) -> Board {
        Board(strokes: translate(board.strokes, ids: ids, dx: dx, dy: dy),
              images: board.images.map { ids.contains($0.id) ? $0.translated(dx: dx, dy: dy) : $0 })
    }

    // MARK: Resizing pictures

    /// Corners of a rectangle in canvas coordinates (y down, so "top" is minY).
    public enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        public func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
        }

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    /// `frame` resized by dragging `corner` to `point`. The opposite corner stays put and the
    /// aspect ratio is kept; the shorter side never goes below `minSide`, and the frame doesn't flip.
    public static func resize(_ frame: CGRect, dragging corner: Corner, to point: CGPoint, minSide: CGFloat) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let anchor = CGPoint(x: corner.isLeft ? frame.maxX : frame.minX, y: corner.isTop ? frame.maxY : frame.minY)
        let reachX = (point.x - anchor.x) * (corner.isLeft ? -1 : 1)
        let reachY = (point.y - anchor.y) * (corner.isTop ? -1 : 1)
        let scale = max(reachX / frame.width, reachY / frame.height, minSide / min(frame.width, frame.height))
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: corner.isLeft ? anchor.x - size.width : anchor.x,
                      y: corner.isTop ? anchor.y - size.height : anchor.y,
                      width: size.width, height: size.height)
    }

    // MARK: Insert space (OneNote-style)

    /// Items that an insert-space gesture starting at `y` pushes: everything whose vertical
    /// centre lies below the line (descenders crossing it don't drag a line of text along).
    public static func itemsBelow(_ y: CGFloat, in board: Board) -> Set<UUID> {
        Set(board.strokes.lazy.filter { $0.bounds.midY > y }.map(\.id))
            .union(board.images.lazy.filter { $0.frame.midY > y }.map(\.id))
    }

    /// Most negative offset allowed when removing space: moved items may not cross above the line.
    public static func minimumSpaceDelta(lineY: CGFloat, moving ids: Set<UUID>, in board: Board) -> CGFloat {
        let top = board.bounds(of: ids)
        guard !top.isNull else { return 0 }
        return min(0, lineY - top.minY)
    }

    // MARK: Helpers

    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        var t: CGFloat = 0
        if len2 > 0 {
            t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
            t = min(1, max(0, t))
        }
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    public static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
