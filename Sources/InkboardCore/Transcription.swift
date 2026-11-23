import Foundation

// MARK: - AI transcription
//
// Three requests, all made of images of the board:
//   • 局部转换: one formula image → LaTeX (copied to the clipboard by the app)
//   • 全局转换: the board as page images (see PageAssembler) → Markdown (saved by the app)
//   • 识别分块类型: page images with every line / drawing tagged → their types (see BlockLabeling)
// `AITranscriber` sends them to the backend chosen in 设置: an ACP agent (Antigravity by default,
// see ACP.swift) or an OpenAI-compatible API (see OpenAICompatible.swift).

public protocol HandwritingTranscriber: AnyObject {
    /// Starts the backend ahead of a request (e.g. when the formula box tool is picked).
    func prepare()
    /// Returns LaTeX (no `$` delimiters) for a handwritten formula.
    func transcribeFormula(_ image: InkImage) async throws -> String
    /// Returns Markdown for the pages of a board, given in reading order.
    func transcribeDocument(_ pages: [InkImage]) async throws -> String
    /// Returns the types of the request's units, keyed like `Board.labels`.
    func labelBlocks(_ request: BlockLabeling.Request) async throws -> [Set<UUID>: InkBlock.Kind]
}

/// Model and prompt for one kind of request.
public struct TranscriptionProfile: Equatable {
    /// Model name; empty uses the backend's default (an ACP agent has one, an API doesn't).
    public var model: String
    /// Thinking level; empty, or a level the model doesn't offer, uses the default.
    public var thoughtLevel: String
    public var prompt: String

    public init(model: String, thoughtLevel: String, prompt: String) {
        self.model = model
        self.thoughtLevel = thoughtLevel
        self.prompt = prompt
    }
}

/// Where requests go.
public enum AIBackendConfiguration: Equatable {
    case acp(ACPAgentConfiguration)
    case openAI(OpenAIConfiguration)
}

public struct AITranscriberSettings {
    public var backend: AIBackendConfiguration
    public var formula: TranscriptionProfile
    /// 全局转换; 识别分块类型 uses its model and thinking level with its own fixed prompt.
    public var document: TranscriptionProfile

    public init(backend: AIBackendConfiguration, formula: TranscriptionProfile, document: TranscriptionProfile) {
        self.backend = backend
        self.formula = formula
        self.document = document
    }
}

/// Sends transcription requests to the configured backend. Settings are read for every request;
/// the backend is kept between requests and replaced when its configuration changes (an ACP
/// agent process is restarted then).
public final class AITranscriber: HandwritingTranscriber, @unchecked Sendable {
    private let settings: () throws -> AITranscriberSettings
    private let makeBackend: (AIBackendConfiguration) -> ModelBackend
    private let lock = NSLock()
    private var current: (configuration: AIBackendConfiguration, backend: ModelBackend)?

    /// `makeBackend` is replaceable for tests.
    public init(settings: @escaping () throws -> AITranscriberSettings,
                makeBackend: @escaping (AIBackendConfiguration) -> ModelBackend = AITranscriber.defaultBackend) {
        self.settings = settings
        self.makeBackend = makeBackend
    }

    public static func defaultBackend(_ configuration: AIBackendConfiguration) -> ModelBackend {
        switch configuration {
        case .acp(let agent): return ACPAgent(configuration: agent)
        case .openAI(let api): return OpenAICompatibleBackend(configuration: api)
        }
    }

    public func prepare() {
        guard let settings = try? settings() else { return }
        backend(for: settings.backend).prepare()
    }

    public func transcribeFormula(_ image: InkImage) async throws -> String {
        let settings = try settings()
        let reply = try await backend(for: settings.backend).send(
            [.text(settings.formula.prompt), .png(image.pngData)],
            model: settings.formula.model, thoughtLevel: settings.formula.thoughtLevel)
        return TranscriptCleanup.latex(reply)
    }

    public func transcribeDocument(_ pages: [InkImage]) async throws -> String {
        let settings = try settings()
        var parts: [PromptPart] = [.text(settings.document.prompt)]
        for (i, page) in pages.enumerated() {
            parts.append(.text("第 \(i + 1)/\(pages.count) 页："))
            parts.append(.png(page.pngData))
        }
        let reply = try await backend(for: settings.backend).send(
            parts, model: settings.document.model, thoughtLevel: settings.document.thoughtLevel)
        return TranscriptCleanup.markdown(reply)
    }

    public func labelBlocks(_ request: BlockLabeling.Request) async throws -> [Set<UUID>: InkBlock.Kind] {
        let settings = try settings()
        let reply = try await backend(for: settings.backend).send(
            request.parts, model: settings.document.model, thoughtLevel: settings.document.thoughtLevel)
        return try BlockLabeling.parse(reply, units: request.units)
    }

    /// Models (and their thinking levels) offered by the backend in `configuration`.
    public func modelCatalog(for configuration: AIBackendConfiguration) async throws -> ACPModelCatalog {
        try await backend(for: configuration).modelCatalog()
    }

    /// Stops the backend (at app exit).
    public func shutdown() {
        lock.sync { () -> ModelBackend? in
            defer { current = nil }
            return current?.backend
        }?.shutdown()
    }

    private func backend(for configuration: AIBackendConfiguration) -> ModelBackend {
        let (backend, replaced) = lock.sync { () -> (ModelBackend, ModelBackend?) in
            if let current, current.configuration == configuration { return (current.backend, nil) }
            let old = current?.backend
            let new = makeBackend(configuration)
            current = (configuration, new)
            return (new, old)
        }
        replaced?.shutdown()
        return backend
    }
}

/// Strips the wrapping models tend to add despite being asked not to.
public enum TranscriptCleanup {
    /// Removes code fences and math delimiters around a LaTeX answer.
    public static func latex(_ reply: String) -> String {
        var s = unfence(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] {
            guard s.count > open.count + close.count, s.hasPrefix(open), s.hasSuffix(close) else { continue }
            let inner = String(s.dropFirst(open.count).dropLast(close.count))
            if !inner.contains(open), !inner.contains(close) {   // "$a$ + $b$" is not one wrapped formula
                s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break
        }
        return s
    }

    /// Removes a code fence around the whole Markdown answer; ends with one newline.
    public static func markdown(_ reply: String) -> String {
        unfence(reply.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
    }

    /// "```lang\n…\n```" → "…" when the fence wraps the entire text.
    private static func unfence(_ s: String) -> String {
        guard s.hasPrefix("```"), s.hasSuffix("```"), s.count >= 6,
              let firstNewline = s.firstIndex(of: "\n") else { return s }
        let body = s[s.index(after: firstNewline)...].dropLast(3)
        guard !body.contains("\n```") else { return s }   // several blocks, not a wrapper
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
