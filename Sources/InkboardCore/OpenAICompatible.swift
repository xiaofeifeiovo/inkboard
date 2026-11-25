import Foundation

// MARK: - OpenAI-compatible Chat Completions
//
// The request format most hosted and local model servers accept: POST {base}/chat/completions
// with a bearer API key, and GET {base}/models to list models. One user message carries the text
// and the images (as data: URLs).

public struct OpenAIConfiguration: Equatable {
    /// API root, e.g. https://api.openai.com/v1 (the part before /chat/completions).
    public var baseURL: URL
    /// May be empty (local servers often need none).
    public var apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Accepts what people paste: surrounding spaces, a trailing slash, or the full
    /// …/chat/completions endpoint. Nil unless it's an http(s) URL.
    public static func normalizedBaseURL(_ string: String) -> URL? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/chat/completions", "/completions"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

public enum OpenAIError: LocalizedError {
    case missingModel
    case http(status: Int, message: String)
    case badResponse(String)
    case refused(String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return "还没有选择模型。请在「设置」中选择或填写模型。"
        case let .http(status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            switch status {
            case 401, 403: return "API 拒绝了请求（\(status)），请检查 API Key。" + (detail.isEmpty ? "" : "\n\n" + detail)
            case 404: return "API 地址或模型不存在（404），请检查 Base URL 和模型名。" + (detail.isEmpty ? "" : "\n\n" + detail)
            case 429: return "请求太频繁或额度不足（429）。" + (detail.isEmpty ? "" : "\n\n" + detail)
            default: return "API 返回错误（\(status)）。" + (detail.isEmpty ? "" : "\n\n" + detail)
            }
        case .badResponse(let detail):
            return "API 返回的内容无法识别。\n\n\(detail)"
        case .refused(let detail):
            return "模型拒绝了这个请求。" + (detail.isEmpty ? "" : "\n\n" + detail)
        case .emptyReply:
            return "模型没有返回任何文字。"
        }
    }
}

public final class OpenAICompatibleBackend: ModelBackend, @unchecked Sendable {
    public let configuration: OpenAIConfiguration
    private let session: URLSession

    /// `session` is replaceable for tests.
    public init(configuration: OpenAIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func prepare() {}
    public func shutdown() {}

    public func send(_ parts: [PromptPart], model: String, thoughtLevel: String) async throws -> String {
        try await reply(to: [Self.userMessage(parts)], model: model, thoughtLevel: thoughtLevel)
    }

    fileprivate static func userMessage(_ parts: [PromptPart]) -> JSONObject {
        let content = parts.map { part -> JSONObject in
            switch part {
            case .text(let text):
                return ["type": "text", "text": text]
            case .png(let data):
                return ["type": "image_url", "image_url": ["url": "data:image/png;base64," + data.base64EncodedString()]]
            }
        }
        return ["role": "user", "content": content]
    }

    fileprivate func reply(to messages: [JSONObject], model: String, thoughtLevel: String) async throws -> String {
        guard !model.isEmpty else { throw OpenAIError.missingModel }
        var body: JSONObject = ["model": model, "messages": messages]
        if !thoughtLevel.isEmpty { body["reasoning_effort"] = thoughtLevel }

        let json = try await call("chat/completions", body: body)
        guard let choice = (json["choices"] as? [JSONObject])?.first,
              let message = choice["message"] as? JSONObject else {
            throw OpenAIError.badResponse(Self.preview(json))
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw OpenAIError.refused(refusal) }
        if choice["finish_reason"] as? String == "content_filter" { throw OpenAIError.refused("") }
        // `content` is a string, or (some servers) a list of text parts.
        let text = message["content"] as? String
            ?? (message["content"] as? [JSONObject])?.compactMap { $0["text"] as? String }.joined()
            ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenAIError.emptyReply }
        return text
    }

    public func openConversation(model: String, thoughtLevel: String) async throws -> ModelConversation {
        guard !model.isEmpty else { throw OpenAIError.missingModel }
        return ChatConversation(backend: self, model: model, thoughtLevel: thoughtLevel)
    }

    /// GET /models. These servers don't say which models take `reasoning_effort`, so every model
    /// is offered the usual three levels; the default (not sending it) is the safe choice.
    public func modelCatalog() async throws -> ACPModelCatalog {
        let json = try await call("models", body: nil)
        let ids = ((json["data"] as? [JSONObject]) ?? []).compactMap { $0["id"] as? String }.sorted()
        var catalog = ACPModelCatalog()
        catalog.models = ids.map { ACPConfigOption.Value(value: $0, name: $0) }
        let levels = ["low", "medium", "high"].map { ACPConfigOption.Value(value: $0, name: $0) }
        for id in ids { catalog.thoughtLevels[id] = levels }
        return catalog
    }

    private func call(_ path: String, body: JSONObject?) async throws -> JSONObject {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.timeoutInterval = 600   // a whole board can take minutes
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? JSONObject)?["message"] as? String
                ?? json?["error"] as? String
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw OpenAIError.http(status: status, message: message)
        }
        guard let json else { throw OpenAIError.badResponse(String(decoding: data.prefix(300), as: UTF8.self)) }
        return json
    }

    private static func preview(_ json: JSONObject) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

// History contains complete user/assistant pairs only. A failed turn closes the conversation.
private final class ChatConversation: ModelConversation {
    let backend: OpenAICompatibleBackend
    let model: String
    let thoughtLevel: String
    private let lock = NSLock()
    private var closed = false
    private var history: [JSONObject] = []

    init(backend: OpenAICompatibleBackend, model: String, thoughtLevel: String) {
        self.backend = backend
        self.model = model
        self.thoughtLevel = thoughtLevel
    }

    var isUsable: Bool { lock.sync { !closed } }
    func close() { lock.sync { closed = true; history.removeAll() } }

    func send(_ parts: [PromptPart]) async throws -> String {
        do {
            try Task.checkCancellation()
            let messages = try lock.sync {
                guard !closed else { throw CancellationError() }
                return history + [OpenAICompatibleBackend.userMessage(parts)]
            }
            let reply = try await backend.reply(to: messages, model: model, thoughtLevel: thoughtLevel)
            try Task.checkCancellation()
            try lock.sync {
                guard !closed else { throw CancellationError() }
                history = messages + [["role": "assistant", "content": reply]]
            }
            return reply
        } catch {
            lock.sync { closed = true }
            throw error
        }
    }
}
