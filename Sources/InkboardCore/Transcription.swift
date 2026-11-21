import CoreGraphics
import Foundation

// MARK: - AI transcription hook (not implemented yet)
//
// The app builds a `TranscriptionRequest` from the current selection (or the whole board)
// and hands it to whatever `HandwritingTranscriber` is installed in `AppDelegate`.
// To add AI, implement the protocol — e.g. send `pngData` to a vision model with a prompt like
// "Transcribe this handwriting into Markdown, keeping headings, lists, tables and LaTeX math" —
// and swap it in for `UnconfiguredTranscriber`.

public struct TranscriptionRequest {
    /// Strokes to transcribe, in canvas coordinates (y down), in drawing order.
    public let strokes: [Stroke]
    /// Canvas area covered by `image`.
    public let bounds: CGRect
    /// The ink rendered black on white.
    public let image: CGImage
    /// `image` encoded as PNG, ready to upload.
    public let pngData: Data

    /// Renders `strokes` into an image request. Returns nil for no ink.
    public init?(strokes: [Stroke], scale: CGFloat = 2, padding: CGFloat = 24) {
        guard !strokes.isEmpty else { return nil }
        let bounds = strokes.unionBounds.insetBy(dx: -padding, dy: -padding).integral
        guard let image = InkRenderer.renderImage(strokes, rect: bounds, scale: scale),
              let png = InkRenderer.pngData(image) else { return nil }
        self.strokes = strokes
        self.bounds = bounds
        self.image = image
        self.pngData = png
    }
}

public protocol HandwritingTranscriber {
    /// Returns Markdown for the handwriting in the request.
    func transcribeToMarkdown(_ request: TranscriptionRequest) async throws -> String
}

public enum TranscriptionError: LocalizedError {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI 转写还没有接入。实现 HandwritingTranscriber 协议（Sources/InkboardCore/Transcription.swift），并在 AppDelegate 中替换 UnconfiguredTranscriber 即可。"
        }
    }
}

/// Placeholder used until a real model is wired in.
public struct UnconfiguredTranscriber: HandwritingTranscriber {
    public init() {}

    public func transcribeToMarkdown(_ request: TranscriptionRequest) async throws -> String {
        throw TranscriptionError.notConfigured
    }
}
