import AppKit
import UniformTypeIdentifiers

/// Reads pictures from a pasteboard: ⌘V (the general pasteboard) and drag & drop.
enum ImagePasteboard {
    /// Image data types, best first. TIFF last: the clipboard's TIFF is uncompressed and often
    /// sits next to a PNG of the same picture.
    private static let dataTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        .tiff,
    ]

    /// Types the canvas registers for drops.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL] + dataTypes + [.pdf]

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = fileURLs(on: pasteboard) { return urls.contains(where: isImageFile) }
        return pasteboard.availableType(from: dataTypes) != nil || NSImage.canInit(with: pasteboard)
    }

    /// The pictures on the pasteboard, as encoded image data (see `ImageImport.prepare`).
    static func imageData(from pasteboard: NSPasteboard) -> [Data] {
        // Files copied in Finder (or dragged in): only the image files. Finder also puts each file's
        // icon on the pasteboard, which must not be pasted in place of a non-image file.
        if let urls = fileURLs(on: pasteboard) {
            return urls.filter(isImageFile).compactMap { try? Data(contentsOf: $0) }
        }
        // Each pasteboard item is one picture (copying several images gives several items).
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.availableType(from: dataTypes).flatMap(item.data(forType:))
        }
        if !items.isEmpty { return items }
        // Anything else NSImage understands (e.g. PDF only).
        return NSImage(pasteboard: pasteboard)?.tiffRepresentation.map { [$0] } ?? []
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
    }
}
