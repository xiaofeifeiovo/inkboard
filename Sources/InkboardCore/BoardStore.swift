import CoreGraphics
import Foundation

/// JSON persistence. Points are stored flat as [x, y, pressure, x, y, pressure, ...]
/// rounded to 1/100 unit, which keeps files small and diff-friendly.
public enum BoardStore {
    struct File: Codable {
        var version = 1
        var strokes: [Record]
    }

    struct Record: Codable {
        var id: UUID
        var width: Double
        var points: [Double]
    }

    public static func encode(_ strokes: [Stroke]) throws -> Data {
        func r(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }
        let records = strokes.map { stroke in
            Record(id: stroke.id,
                   width: Double(stroke.width),
                   points: stroke.points.flatMap { [r($0.x), r($0.y), r($0.pressure)] })
        }
        return try JSONEncoder().encode(File(strokes: records))
    }

    public static func decode(_ data: Data) throws -> [Stroke] {
        let file = try JSONDecoder().decode(File.self, from: data)
        return file.strokes.compactMap { record in
            let flat = record.points
            guard flat.count >= 3 else { return nil }
            let points = stride(from: 0, to: flat.count - 2, by: 3).map {
                InkPoint(x: flat[$0], y: flat[$0 + 1], pressure: flat[$0 + 2])
            }
            return Stroke(id: record.id, points: points, width: record.width)
        }
    }
}
