import CoreGraphics
import Foundation

/// Turns a list of (position, pressure) samples into a fillable outline.
///
/// A variable-width stroke is drawn as the union of a circle at the ends / joints and a
/// tapered quad between every pair of neighbouring samples (the outer tangents of the two
/// circles). Every sub-shape is wound counter-clockwise, so a single non-zero fill renders
/// the union with no self-intersection artefacts, even on sharp turns.
public enum StrokeGeometry {
    /// Pressure → radius curve. Medium pressure (~0.6) gives roughly the nominal width,
    /// a light touch about a third of it, a firm press ~1.3×.
    public static func radius(pressure: CGFloat, width: CGFloat) -> CGFloat {
        let p = min(max(pressure, 0), 1)
        let factor = 0.3 + 1.0 * pow(p, 0.8)
        return max(0.35, width * 0.5 * factor)
    }

    /// Largest radius a stroke of this width can have (pressure = 1).
    public static func maxRadius(width: CGFloat) -> CGFloat {
        radius(pressure: 1, width: width)
    }

    public static func path(for points: [InkPoint], width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        var stamper = Stamper(width: width)
        for point in points {
            stamper.append(point, to: path)
        }
        stamper.finish(in: path)
        return path
    }

    public static func bounds(of points: [InkPoint], width: CGFloat) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for p in points {
            let r = radius(pressure: p.pressure, width: width)
            minX = min(minX, p.x - r); maxX = max(maxX, p.x + r)
            minY = min(minY, p.y - r); maxY = max(maxY, p.y + r)
        }
        guard minX <= maxX else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Incremental outline builder. It is a value type on purpose: the live-stroke renderer
    /// copies it to draw a provisional tail without disturbing the committed state.
    public struct Stamper {
        public let width: CGFloat
        private var last: (point: CGPoint, radius: CGFloat)?
        private var lastDirection: CGVector?
        /// Add a joint circle when the direction turns more than ~6°.
        private static let joinCosine: CGFloat = cos(6 * .pi / 180)

        public init(width: CGFloat) {
            self.width = width
        }

        public mutating func append(_ sample: InkPoint, to path: CGMutablePath) {
            let p = sample.location
            let r = StrokeGeometry.radius(pressure: sample.pressure, width: width)

            guard let (q, qr) = last else {
                StrokeGeometry.addCircle(to: path, center: p, radius: r)   // start cap
                last = (p, r)
                return
            }

            let dx = p.x - q.x, dy = p.y - q.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d < 1e-6 {
                if r > qr { StrokeGeometry.addCircle(to: path, center: p, radius: r) }
                last = (p, max(r, qr))
                return
            }

            let u = CGVector(dx: dx / d, dy: dy / d)
            if let prev = lastDirection, prev.dx * u.dx + prev.dy * u.dy < Self.joinCosine {
                StrokeGeometry.addCircle(to: path, center: q, radius: qr)   // round joint
            }

            if d > abs(r - qr) {
                StrokeGeometry.addTaperedQuad(to: path, from: q, radius: qr, to: p, radius: r, direction: u, distance: d)
            } else {
                // One circle swallows the other: the bigger circle alone covers the segment.
                StrokeGeometry.addCircle(to: path, center: r > qr ? p : q, radius: max(r, qr))
            }

            lastDirection = u
            last = (p, r)
        }

        /// Adds the end cap.
        public func finish(in path: CGMutablePath) {
            if let (q, qr) = last {
                StrokeGeometry.addCircle(to: path, center: q, radius: qr)
            }
        }
    }

    // MARK: - Primitives (all wound counter-clockwise in path space)

    static func addCircle(to path: CGMutablePath, center c: CGPoint, radius r: CGFloat) {
        let k = 0.552_284_749_8 * r
        path.move(to: CGPoint(x: c.x + r, y: c.y))
        path.addCurve(to: CGPoint(x: c.x, y: c.y + r),
                      control1: CGPoint(x: c.x + r, y: c.y + k), control2: CGPoint(x: c.x + k, y: c.y + r))
        path.addCurve(to: CGPoint(x: c.x - r, y: c.y),
                      control1: CGPoint(x: c.x - k, y: c.y + r), control2: CGPoint(x: c.x - r, y: c.y + k))
        path.addCurve(to: CGPoint(x: c.x, y: c.y - r),
                      control1: CGPoint(x: c.x - r, y: c.y - k), control2: CGPoint(x: c.x - k, y: c.y - r))
        path.addCurve(to: CGPoint(x: c.x + r, y: c.y),
                      control1: CGPoint(x: c.x + k, y: c.y - r), control2: CGPoint(x: c.x + r, y: c.y - k))
        path.closeSubpath()
    }

    /// Quad spanned by the two outer tangent lines of circle(c0, r0) and circle(c1, r1).
    /// Precondition: d > |r0 - r1|.
    static func addTaperedQuad(to path: CGMutablePath,
                               from c0: CGPoint, radius r0: CGFloat,
                               to c1: CGPoint, radius r1: CGFloat,
                               direction u: CGVector, distance d: CGFloat) {
        // Tangent normal v satisfies v·u = (r0 - r1) / d.
        let s = (r0 - r1) / d
        let h = max(0, 1 - s * s).squareRoot()
        let n = CGVector(dx: -u.dy, dy: u.dx)
        let vPlus = CGVector(dx: s * u.dx + h * n.dx, dy: s * u.dy + h * n.dy)
        let vMinus = CGVector(dx: s * u.dx - h * n.dx, dy: s * u.dy - h * n.dy)

        let a = CGPoint(x: c0.x + r0 * vPlus.dx, y: c0.y + r0 * vPlus.dy)
        let b = CGPoint(x: c1.x + r1 * vPlus.dx, y: c1.y + r1 * vPlus.dy)
        let c = CGPoint(x: c1.x + r1 * vMinus.dx, y: c1.y + r1 * vMinus.dy)
        let e = CGPoint(x: c0.x + r0 * vMinus.dx, y: c0.y + r0 * vMinus.dy)

        // e → c → b → a is counter-clockwise (same winding as addCircle).
        path.move(to: e)
        path.addLine(to: c)
        path.addLine(to: b)
        path.addLine(to: a)
        path.closeSubpath()
    }
}
