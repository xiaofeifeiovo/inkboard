import CoreGraphics
import Foundation

/// One sample of ink in canvas coordinates (y grows downward, like the on-screen canvas).
public struct InkPoint: Equatable {
    public var x: CGFloat
    public var y: CGFloat
    /// Normalised pen pressure, 0...1.
    public var pressure: CGFloat

    public init(x: CGFloat, y: CGFloat, pressure: CGFloat) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    public init(_ location: CGPoint, pressure: CGFloat) {
        self.init(x: location.x, y: location.y, pressure: pressure)
    }

    public var location: CGPoint { CGPoint(x: x, y: y) }
}

/// A finished pen stroke. `points` are already smoothed and densely resampled
/// (about one point per screen pixel), so erasing and hit-testing can work point by point.
public struct Stroke: Identifiable {
    public let id: UUID
    /// Nominal pen width (diameter at medium pressure).
    public let width: CGFloat
    public private(set) var points: [InkPoint]
    /// Cached fill path (see `StrokeGeometry`).
    public private(set) var path: CGPath
    /// Bounds of the inked area, including the stroke's thickness.
    public private(set) var bounds: CGRect

    public init(id: UUID = UUID(), points: [InkPoint], width: CGFloat) {
        precondition(!points.isEmpty, "A stroke needs at least one point")
        self.id = id
        self.width = width
        self.points = points
        self.path = StrokeGeometry.path(for: points, width: width)
        self.bounds = StrokeGeometry.bounds(of: points, width: width)
    }

    public func radius(at point: InkPoint) -> CGFloat {
        StrokeGeometry.radius(pressure: point.pressure, width: width)
    }

    public mutating func translate(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        for i in points.indices {
            points[i].x += dx
            points[i].y += dy
        }
        var transform = CGAffineTransform(translationX: dx, y: dy)
        path = path.copy(using: &transform) ?? StrokeGeometry.path(for: points, width: width)
        bounds = bounds.offsetBy(dx: dx, dy: dy)
    }

    public func translated(dx: CGFloat, dy: CGFloat) -> Stroke {
        var copy = self
        copy.translate(dx: dx, dy: dy)
        return copy
    }
}

extension Sequence where Element == Stroke {
    /// Union of all stroke bounds, or `.null` when empty.
    public var unionBounds: CGRect {
        reduce(CGRect.null) { $0.union($1.bounds) }
    }
}
