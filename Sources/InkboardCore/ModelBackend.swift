import Foundation

/// One piece of a prompt: text, or a PNG image.
public enum PromptPart: Equatable {
    case text(String)
    case png(Data)
}

/// Something that answers a prompt of text and images with text: an ACP agent (`ACPAgent`), or an
/// OpenAI-compatible HTTP API (`OpenAICompatibleBackend`).
public protocol ModelBackend: AnyObject {
    /// Gets ready ahead of a request (starts the agent process); may do nothing.
    func prepare()
    /// `model` empty means the backend's default, where it has one. An empty `thoughtLevel`
    /// leaves thinking at the model's default.
    func send(_ parts: [PromptPart], model: String, thoughtLevel: String) async throws -> String
    /// The models (and thinking levels) to offer in 设置.
    func modelCatalog() async throws -> ACPModelCatalog
    /// A multi-turn conversation (自动检查). Same `model` / `thoughtLevel` rules as `send`.
    func openConversation(model: String, thoughtLevel: String) async throws -> ModelConversation
    func shutdown()
}

extension ACPAgent: ModelBackend {
    public func send(_ parts: [PromptPart], model: String, thoughtLevel: String) async throws -> String {
        return try await prompt(parts.map(\.acpBlock), model: model, thoughtLevel: thoughtLevel)
    }

    public func openConversation(model: String, thoughtLevel: String) async throws -> ModelConversation {
        try await configuredSession(model: model, thoughtLevel: thoughtLevel)
    }
}

extension PromptPart {
    var acpBlock: JSONObject {
        switch self {
        case .text(let text): return ACPContent.text(text)
        case .png(let data): return ACPContent.image(png: data)
        }
    }
}
