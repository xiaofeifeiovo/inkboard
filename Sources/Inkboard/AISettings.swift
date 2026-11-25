import Foundation
import InkboardCore

/// AI settings (「设置」window), stored in UserDefaults under "ai.*" (API keys are in the
/// keychain, see APIKeychain).
struct AISettings: Equatable {
    enum Backend: String {
        /// An agent run as a subprocess and spoken to over ACP (Antigravity by default).
        case acp
        /// An OpenAI-compatible HTTP API (base URL + API key).
        case openAI
    }

    var backend = Backend.acp
    /// Agent executable: a name looked up in the usual bin folders, or a path.
    var command = "agy"
    var arguments = "acp"
    var formulaModel = "gemini-3.8-flash"
    var formulaThoughtLevel = "low"
    var formulaPrompt = AISettings.defaultFormulaPrompt
    var documentModel = "gemini-4-neon"
    var documentThoughtLevel = "medium"
    var documentPrompt = AISettings.defaultDocumentPrompt
    /// Longest side of each page image sent by 全局转换.
    var maxImagePixels = 2000

    // The API backend keeps its own model choices (its model names differ from the agent's).
    var apiBaseURL = "https://api.openai.com/v1"
    var apiFormulaModel = ""
    var apiFormulaThoughtLevel = ""
    var apiDocumentModel = ""
    var apiDocumentThoughtLevel = ""
    // 自动检查: empty model = the 全局转换 model and thinking level.
    var checkModel = ""
    var checkThoughtLevel = ""
    var apiCheckModel = ""
    var apiCheckThoughtLevel = ""

    static let maxImagePixelsRange = 800...4000

    /// How 全局转换 packs blocks into page images: pages are rendered at no less than 1 pixel per
    /// canvas unit, so the longest page side in canvas units is the pixel limit.
    var pageOptions: PageAssembler.Options {
        var options = PageAssembler.Options()
        options.maxSide = CGFloat(maxImagePixels)
        return options
    }
    /// Formula crops are small; this only caps a huge box.
    static let formulaMaxPixels: CGFloat = 1600

    static let defaultFormulaPrompt = """
        图片里是一个手写的数学公式。请只输出它的 LaTeX 代码：不要加 $、$$、\\[ \\] 之类的定界符，不要用代码块包起来，也不要任何解释。公式有多行时用 aligned 环境。不要调用任何工具。
        """

    static let defaultDocumentPrompt = """
        这些图片是同一份手写笔记，按阅读顺序分成了几页（很长的段落偶尔会跨页）。请把全部内容整理成一份 Markdown 文档：
        - 忠实保留原文的语言和内容，不要补充或删减观点；
        - 按内容的结构使用标题、列表、表格；
        - 数学公式写成 LaTeX，行内用 $…$，独立成行的用 $$…$$；
        - 看不清的字写成 [?]；图形或草图用一句话描述，写成「> 图：…」；
        - 笔记里可能贴有截图或照片（上面可能有手写批注），同样用一句话概括它和批注的要点，写成「> 图：…」，不要逐字抄录截图里的文字。
        只输出 Markdown 正文，不要用代码块包起来，也不要额外说明。不要调用任何工具。
        """

    static let didChange = Notification.Name("InkboardAISettingsDidChange")

    private static let stringKeys: [(String, WritableKeyPath<AISettings, String>)] = [
        ("ai.command", \.command),
        ("ai.arguments", \.arguments),
        ("ai.formula.model", \.formulaModel),
        ("ai.formula.thoughtLevel", \.formulaThoughtLevel),
        ("ai.formula.prompt", \.formulaPrompt),
        ("ai.document.model", \.documentModel),
        ("ai.document.thoughtLevel", \.documentThoughtLevel),
        ("ai.document.prompt", \.documentPrompt),
        ("ai.api.baseURL", \.apiBaseURL),
        ("ai.api.formula.model", \.apiFormulaModel),
        ("ai.api.formula.thoughtLevel", \.apiFormulaThoughtLevel),
        ("ai.api.document.model", \.apiDocumentModel),
        ("ai.api.document.thoughtLevel", \.apiDocumentThoughtLevel),
        ("ai.check.model", \.checkModel),
        ("ai.check.thoughtLevel", \.checkThoughtLevel),
        ("ai.api.check.model", \.apiCheckModel),
        ("ai.api.check.thoughtLevel", \.apiCheckThoughtLevel),
    ]
    private static let backendKey = "ai.backend"
    private static let maxImagePixelsKey = "ai.document.maxImagePixels"
    private static let catalogKey = "ai.modelCatalog"

    static var current: AISettings {
        get {
            let defaults = UserDefaults.standard
            var settings = AISettings()
            for (key, path) in stringKeys {
                if let value = defaults.string(forKey: key) { settings[keyPath: path] = value }
            }
            if defaults.object(forKey: maxImagePixelsKey) != nil {
                settings.maxImagePixels = defaults.integer(forKey: maxImagePixelsKey)
            }
            if let raw = defaults.string(forKey: backendKey), let backend = Backend(rawValue: raw) {
                settings.backend = backend
            }
            return settings
        }
        set {
            guard newValue != current else { return }
            let defaults = UserDefaults.standard
            for (key, path) in stringKeys { defaults.set(newValue[keyPath: path], forKey: key) }
            defaults.set(newValue.maxImagePixels, forKey: maxImagePixelsKey)
            defaults.set(newValue.backend.rawValue, forKey: backendKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func reset() {
        let defaults = UserDefaults.standard
        for (key, _) in stringKeys { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: maxImagePixelsKey)
        defaults.removeObject(forKey: backendKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The models last read from the backend, with `catalogSource` at the time.
    static var cachedCatalog: (command: String, catalog: ACPModelCatalog)? {
        get {
            guard let data = UserDefaults.standard.data(forKey: catalogKey),
                  let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data) else { return nil }
            return (cached.command, cached.catalog)
        }
        set {
            let data = newValue.flatMap { try? JSONEncoder().encode(CachedCatalog(command: $0.command, catalog: $0.catalog)) }
            UserDefaults.standard.set(data, forKey: catalogKey)
        }
    }

    private struct CachedCatalog: Codable {
        var command: String
        var catalog: ACPModelCatalog
    }

    /// Scratch folder used as the agent session's working directory.
    static let workingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Inkboard-ACP", isDirectory: true)

    /// The command and arguments as one string.
    var commandLine: String { "\(command) \(arguments)" }

    /// Identifies which backend a cached model list belongs to.
    var catalogSource: String { backend == .openAI ? "api \(apiBaseURL)" : commandLine }

    /// Model and thinking level of the chosen backend.
    var activeFormulaModel: String {
        get { backend == .openAI ? apiFormulaModel : formulaModel }
        set { if backend == .openAI { apiFormulaModel = newValue } else { formulaModel = newValue } }
    }
    var activeFormulaThoughtLevel: String {
        get { backend == .openAI ? apiFormulaThoughtLevel : formulaThoughtLevel }
        set { if backend == .openAI { apiFormulaThoughtLevel = newValue } else { formulaThoughtLevel = newValue } }
    }
    var activeDocumentModel: String {
        get { backend == .openAI ? apiDocumentModel : documentModel }
        set { if backend == .openAI { apiDocumentModel = newValue } else { documentModel = newValue } }
    }
    var activeDocumentThoughtLevel: String {
        get { backend == .openAI ? apiDocumentThoughtLevel : documentThoughtLevel }
        set { if backend == .openAI { apiDocumentThoughtLevel = newValue } else { documentThoughtLevel = newValue } }
    }

    /// 自动检查's own model; empty means 「与全局转换相同」.
    var activeCheckModel: String {
        get { backend == .openAI ? apiCheckModel : checkModel }
        set { if backend == .openAI { apiCheckModel = newValue } else { checkModel = newValue } }
    }
    var activeCheckThoughtLevel: String {
        get { backend == .openAI ? apiCheckThoughtLevel : checkThoughtLevel }
        set { if backend == .openAI { apiCheckThoughtLevel = newValue } else { checkThoughtLevel = newValue } }
    }

    /// The model and thinking level 自动检查 uses (its own, or 全局转换's when none is chosen).
    var checkProfile: TranscriptionProfile? {
        activeCheckModel.isEmpty ? nil
            : TranscriptionProfile(model: activeCheckModel, thoughtLevel: activeCheckThoughtLevel, prompt: documentPrompt)
    }

    /// Changes when a 自动检查 conversation can't go on: another backend, agent, API or model.
    var checkSignature: String {
        let profile = checkProfile
        return [backend.rawValue, catalogSource,
                profile?.model ?? activeDocumentModel, profile?.thoughtLevel ?? activeDocumentThoughtLevel]
            .joined(separator: "\n")
    }

    func agentConfiguration() throws -> ACPAgentConfiguration {
        guard let executable = ACPAgentConfiguration.locate(command) else {
            throw AISettingsError.agentNotFound(command)
        }
        var environment = ProcessInfo.processInfo.environment
        // Apps started from Finder get a minimal PATH; agents written in Node need theirs.
        environment["PATH"] = ACPAgentConfiguration.searchPath().joined(separator: ":")
        return ACPAgentConfiguration(executable: executable,
                                     arguments: ACPAgentConfiguration.splitArguments(arguments),
                                     environment: environment,
                                     workingDirectory: Self.workingDirectory)
    }

    /// The API key is read from the keychain here, i.e. only when a request is made.
    func backendConfiguration() throws -> AIBackendConfiguration {
        switch backend {
        case .acp:
            return .acp(try agentConfiguration())
        case .openAI:
            guard let url = OpenAIConfiguration.normalizedBaseURL(apiBaseURL) else {
                throw AISettingsError.invalidBaseURL(apiBaseURL)
            }
            return .openAI(OpenAIConfiguration(baseURL: url, apiKey: APIKeychain.key(for: url) ?? ""))
        }
    }

    func transcriberSettings() throws -> AITranscriberSettings {
        AITranscriberSettings(
            backend: try backendConfiguration(),
            formula: TranscriptionProfile(model: activeFormulaModel, thoughtLevel: activeFormulaThoughtLevel, prompt: formulaPrompt),
            document: TranscriptionProfile(model: activeDocumentModel, thoughtLevel: activeDocumentThoughtLevel, prompt: documentPrompt),
            check: checkProfile)
    }
}

enum AISettingsError: LocalizedError {
    case agentNotFound(String)
    case invalidBaseURL(String)

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let command):
            let name = command.trimmingCharacters(in: .whitespaces)
            return name.isEmpty
                ? "还没有设置 agent 程序。请在「设置」（⌘,）中填写。"
                : "找不到 agent 程序「\(name)」。请在「设置」（⌘,）中填写完整路径。"
        case .invalidBaseURL(let text):
            let value = text.trimmingCharacters(in: .whitespaces)
            return value.isEmpty
                ? "还没有填写 API 的 Base URL。请在「设置」（⌘,）中填写，例如 https://api.openai.com/v1。"
                : "API 的 Base URL「\(value)」不是有效的 http(s) 地址。请在「设置」（⌘,）中修改。"
        }
    }
}
