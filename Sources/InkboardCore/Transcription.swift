import Foundation

// MARK: - AI transcription
//
// Two requests, both made of images of the ink:
//   • 局部转换: one formula image → LaTeX (copied to the clipboard by the app)
//   • 全局转换: the whole board as page images (see PageSlicer) → Markdown (saved by the app)
// `ACPTranscriber` sends them to an ACP agent (Antigravity by default, see ACP.swift).

public protocol HandwritingTranscriber: AnyObject {
    /// Starts the backend ahead of a request (e.g. when the formula box tool is picked).
    func prepare()
    /// Returns LaTeX (no `$` delimiters) for a handwritten formula.
    func transcribeFormula(_ image: InkImage) async throws -> String
    /// Returns Markdown for the pages of a board, given top to bottom.
    func transcribeDocument(_ pages: [InkImage]) async throws -> String
}

/// Model and prompt for one kind of request.
public struct TranscriptionProfile: Equatable {
    /// Config option value of the model; empty uses the agent's default.
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

public struct ACPTranscriberSettings {
    public var agent: ACPAgentConfiguration
    public var formula: TranscriptionProfile
    public var document: TranscriptionProfile

    public init(agent: ACPAgentConfiguration, formula: TranscriptionProfile, document: TranscriptionProfile) {
        self.agent = agent
        self.formula = formula
        self.document = document
    }
}

/// Sends transcription requests to an ACP agent. Settings are read for every request, and the
/// agent process is restarted when its command line changes.
public final class ACPTranscriber: HandwritingTranscriber, @unchecked Sendable {
    private let settings: () throws -> ACPTranscriberSettings
    private let lock = NSLock()
    private var agent: ACPAgent?

    public init(settings: @escaping () throws -> ACPTranscriberSettings) {
        self.settings = settings
    }

    public func prepare() {
        guard let settings = try? settings() else { return }
        agent(for: settings.agent).prepare()
    }

    public func transcribeFormula(_ image: InkImage) async throws -> String {
        let settings = try settings()
        let reply = try await agent(for: settings.agent).prompt(
            [ACPContent.text(settings.formula.prompt), ACPContent.image(png: image.pngData)],
            model: settings.formula.model, thoughtLevel: settings.formula.thoughtLevel)
        return TranscriptCleanup.latex(reply)
    }

    public func transcribeDocument(_ pages: [InkImage]) async throws -> String {
        let settings = try settings()
        var blocks = [ACPContent.text(settings.document.prompt)]
        for (i, page) in pages.enumerated() {
            blocks.append(ACPContent.text("第 \(i + 1)/\(pages.count) 页："))
            blocks.append(ACPContent.image(png: page.pngData))
        }
        let reply = try await agent(for: settings.agent).prompt(
            blocks, model: settings.document.model, thoughtLevel: settings.document.thoughtLevel)
        return TranscriptCleanup.markdown(reply)
    }

    /// Models (and their thinking levels) offered by the agent in `configuration`.
    public func modelCatalog(for configuration: ACPAgentConfiguration) async throws -> ACPModelCatalog {
        try await agent(for: configuration).modelCatalog()
    }

    /// Stops the agent process (at app exit).
    public func shutdown() {
        lock.sync { () -> ACPAgent? in
            defer { agent = nil }
            return agent
        }?.shutdown()
    }

    private func agent(for configuration: ACPAgentConfiguration) -> ACPAgent {
        let (agent, replaced) = lock.sync { () -> (ACPAgent, ACPAgent?) in
            if let agent = self.agent, agent.configuration == configuration { return (agent, nil) }
            let old = self.agent
            let new = ACPAgent(configuration: configuration)
            self.agent = new
            return (new, old)
        }
        replaced?.shutdown()
        return agent
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
