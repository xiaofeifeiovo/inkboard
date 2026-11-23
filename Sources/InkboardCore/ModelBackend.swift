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
    func shutdown()
}

extension ACPAgent: ModelBackend {
    public func send(_ parts: [PromptPart], model: String, thoughtLevel: String) async throws -> String {
        let blocks = parts.map { part -> JSONObject in
            switch part {
            case .text(let text): return ACPContent.text(text)
            case .png(let data): return ACPContent.image(png: data)
            }
        }
        return try await prompt(blocks, model: model, thoughtLevel: thoughtLevel)
    }
}
