import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything on a board: pictures (drawn first, under all ink) and ink strokes.
/// A value type, so undo can keep whole snapshots; strokes and pictures share one id space
/// (selection is a `Set<UUID>` over both).
public struct Board {
    public var strokes: [Stroke]
    /// Back to front.
    public var images: [BoardImage]
    /// Types given to segmentation units — lines of writing and drawings, each keyed by its set
    /// of stroke ids — by the AI (see `BlockLabeling`) or by hand. `InkLayout` uses them instead
    /// of its own guesses; a key that no longer matches a unit (the ink changed) is ignored.
    public var labels: [Set<UUID>: InkBlock.Kind]

    public init(strokes: [Stroke] = [], images: [BoardImage] = [], labels: [Set<UUID>: InkBlock.Kind] = [:]) {
        self.strokes = strokes
        self.images = images
        self.labels = labels
    }

    public var isEmpty: Bool { strokes.isEmpty && images.isEmpty }

    public var ids: Set<UUID> { Set(strokes.map(\.id)).union(images.map(\.id)) }

    /// Union of everything on the board, or `.null` when empty.
    public var bounds: CGRect { strokes.unionBounds.union(images.unionBounds) }

    /// Bounds of every item (for page slicing).
    public var itemBounds: [CGRect] { strokes.map(\.bounds) + images.map(\.frame) }

    /// Union of the items in `ids`, or `.null`.
    public func bounds(of ids: Set<UUID>) -> CGRect {
        let ink = strokes.lazy.filter { ids.contains($0.id) }.reduce(CGRect.null) { $0.union($1.bounds) }
        return images.lazy.filter { ids.contains($0.id) }.reduce(ink) { $0.union($1.frame) }
    }

    /// Only the items in `ids`, in their original order.
    public func subset(_ ids: Set<UUID>) -> Board {
        Board(strokes: strokes.filter { ids.contains($0.id) }, images: images.filter { ids.contains($0.id) },
              labels: labels.filter { $0.key.isSubset(of: ids) })
    }

    public func removing(_ ids: Set<UUID>) -> Board {
        Board(strokes: strokes.filter { !ids.contains($0.id) }, images: images.filter { !ids.contains($0.id) },
              labels: labels.filter { $0.key.isDisjoint(with: ids) })
    }
}

/// A picture placed on the board (pasted, dropped or inserted from a file).
public struct BoardImage: Identifiable {
    public let id: UUID
    /// Where the picture is shown, in canvas coordinates.
    public var frame: CGRect
    /// The encoded PNG or JPEG, written to the file as is (see `ImageImport`).
    public let data: Data
    /// Decoded from `data` once and shared by every copy (undo snapshots, exports).
    public let image: CGImage

    /// Nil when `data` isn't a readable image.
    public init?(id: UUID = UUID(), data: Data, frame: CGRect) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.id = id
        self.frame = frame
        self.data = data
        self.image = image
    }

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    public func translated(dx: CGFloat, dy: CGFloat) -> BoardImage {
        var copy = self
        copy.frame = frame.offsetBy(dx: dx, dy: dy)
        return copy
    }
}

extension Sequence where Element == BoardImage {
    /// Union of all frames, or `.null` when empty.
    public var unionBounds: CGRect {
        reduce(CGRect.null) { $0.union($1.frame) }
    }
}

/// Turns image data from the clipboard, a drop or a file into what a `BoardImage` stores.
///
/// PNG and JPEG are kept byte for byte. Anything else (TIFF from the clipboard, HEIC, GIF, …),
/// a photo with an EXIF rotation, or an image larger than `maxPixels` is re-encoded upright:
/// as JPEG when it was a photo without transparency, otherwise as PNG.
public enum ImageImport {
    public struct Prepared {
        public let data: Data
        /// Natural size in canvas units (points): pixels at the image's DPI, so a Retina
        /// screenshot comes in at the size it had on screen.
        public let size: CGSize
    }

    /// Longest side kept, in pixels.
    public static let defaultMaxPixels = 4096

    public static func prepare(_ data: Data, maxPixels: Int = defaultMaxPixels) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)

        // A TIFF can hold several resolutions of one picture (1x + 2x from the clipboard): take the largest.
        var index = 0, properties: [CFString: Any] = [:], width = 0, height = 0
        for i in 0..<count {
            guard let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                  let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  w * h > width * height else { continue }
            index = i; properties = p; width = w; height = h
        }
        guard width > 0, height > 0 else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let upright = (5...8).contains(orientation) ? (width: height, height: width) : (width: width, height: height)
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let unit = 72 / CGFloat((72...600).contains(dpi) ? dpi : 72)   // ignore missing or nonsense DPI
        let size = CGSize(width: CGFloat(upright.width) * unit, height: CGFloat(upright.height) * unit)

        let type = CGImageSourceGetType(source) as String?
        let isPNG = type == UTType.png.identifier, isJPEG = type == UTType.jpeg.identifier
        if (isPNG || isJPEG), count == 1, orientation == 1, max(width, height) <= maxPixels {
            return Prepared(data: data, size: size)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // applies the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        let isPhoto = isJPEG || type.flatMap(UTType.init).map { $0.conforms(to: .heic) || $0.conforms(to: .heif) } == true
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let encoded = isPhoto && !hasAlpha ? encode(image, as: .jpeg, quality: 0.9) : encode(image, as: .png)
        return encoded.map { Prepared(data: $0, size: size) }
    }

    /// Encodes as PNG or JPEG; images ImageIO can't write directly (e.g. CMYK as PNG) are redrawn in sRGB first.
    public static func encode(_ image: CGImage, as type: UTType, quality: CGFloat? = nil) -> Data? {
        func write(_ image: CGImage) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
            CGImageDestinationAddImage(dest, image, properties)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        }
        if let data = write(image) { return data }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage().flatMap(write)
    }
}
