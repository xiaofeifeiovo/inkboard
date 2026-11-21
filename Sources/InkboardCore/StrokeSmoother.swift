import CoreGraphics
import Foundation

/// Converts raw pen samples into a smooth, densely resampled polyline, incrementally.
///
/// Raw samples are joined with a centripetal Catmull-Rom spline (no overshoot or cusps on
/// uneven spacing). A segment raw[i] → raw[i+1] can only be finalised once raw[i+2] is
/// known, so the most recent segment is exposed as a provisional straight `tail` for live
/// rendering and replaced by the curved version when the next sample arrives.
public struct StrokeSmoother {
    /// Distance between output points, in canvas units.
    public let spacing: CGFloat
    /// Raw samples closer than this to the previous one are dropped.
    public let minInputDistance: CGFloat
    /// Exponential smoothing factor for pressure (1 = no smoothing).
    public let pressureSmoothing: CGFloat

    private var raw: [InkPoint] = []
    private var smoothedPressure: CGFloat?
    /// Number of raw segments already converted into `output`.
    private var emittedSegments = 0

    /// Finalised dense points.
    public private(set) var output: [InkPoint] = []

    public init(spacing: CGFloat = 1, minInputDistance: CGFloat = 0.5, pressureSmoothing: CGFloat = 0.45) {
        self.spacing = max(0.05, spacing)
        self.minInputDistance = minInputDistance
        self.pressureSmoothing = pressureSmoothing
    }

    public var isEmpty: Bool { raw.isEmpty }

    /// Adds a raw sample. Returns the range of `output` that became final.
    @discardableResult
    public mutating func add(_ sample: InkPoint) -> Range<Int> {
        var sample = sample
        if let sp = smoothedPressure {
            sample.pressure = sp + pressureSmoothing * (sample.pressure - sp)
        }

        let start = output.count
        guard let previous = raw.last else {
            smoothedPressure = sample.pressure
            raw.append(sample)
            output.append(sample)
            return start..<output.count
        }
        if distance(previous, sample) < minInputDistance {
            return start..<start
        }
        smoothedPressure = sample.pressure
        raw.append(sample)
        while emittedSegments + 2 < raw.count {
            emitSegment(emittedSegments)
            emittedSegments += 1
        }
        return start..<output.count
    }

    /// Samples not yet finalised, to be drawn as a straight continuation of `output`.
    public var tail: ArraySlice<InkPoint> {
        guard raw.count > emittedSegments + 1 else { return [] }
        return raw[(emittedSegments + 1)...]
    }

    /// Finalises the remaining segments and returns the complete dense polyline.
    public mutating func finish() -> [InkPoint] {
        while emittedSegments + 1 < raw.count {
            emitSegment(emittedSegments)
            emittedSegments += 1
        }
        return output
    }

    // MARK: - Spline

    private mutating func emitSegment(_ i: Int) {
        let p1 = raw[i], p2 = raw[i + 1]
        let p0 = i > 0 ? raw[i - 1] : reflect(p2, about: p1)
        let p3 = i + 2 < raw.count ? raw[i + 2] : reflect(p1, about: p2)

        let chord = distance(p1, p2)
        let steps = max(1, Int((chord / spacing).rounded(.up)))
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            let position = Self.centripetalCatmullRom(p0.location, p1.location, p2.location, p3.location, t: t)
            let pressure = p1.pressure + (p2.pressure - p1.pressure) * t
            output.append(InkPoint(position, pressure: pressure))
        }
    }

    /// Point on the centripetal (α = 0.5) Catmull-Rom segment p1 → p2, `t` in 0...1.
    static func centripetalCatmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            max(1e-4, pow(hypot(b.x - a.x, b.y - a.y), 0.5))
        }
        let t0: CGFloat = 0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)
        let tt = t1 + (t2 - t1) * t

        func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
            let w = (tt - ta) / (tb - ta)
            return CGPoint(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w)
        }
        let a1 = lerp(p0, p1, t0, t1)
        let a2 = lerp(p1, p2, t1, t2)
        let a3 = lerp(p2, p3, t2, t3)
        let b1 = lerp(a1, a2, t0, t2)
        let b2 = lerp(a2, a3, t1, t3)
        return lerp(b1, b2, t1, t2)
    }

    private func reflect(_ p: InkPoint, about c: InkPoint) -> InkPoint {
        InkPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y, pressure: c.pressure)
    }

    private func distance(_ a: InkPoint, _ b: InkPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
