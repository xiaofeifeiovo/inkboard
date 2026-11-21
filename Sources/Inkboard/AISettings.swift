import Foundation
import InkboardCore

/// AI settings (「设置」window), stored in UserDefaults under "ai.*".
struct AISettings: Equatable {
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

    static let maxImagePixelsRange = 800...4000
    /// Formula crops are small; this only caps a huge box.
    static let formulaMaxPixels: CGFloat = 1600

    static let defaultFormulaPrompt = """
        图片里是一个手写的数学公式。请只输出它的 LaTeX 代码：不要加 $、$$、\\[ \\] 之类的定界符，不要用代码块包起来，也不要任何解释。公式有多行时用 aligned 环境。不要调用任何工具。
        """

    static let defaultDocumentPrompt = """
        这些图片是同一份手写笔记，按从上到下的顺序切成了几页，内容可能在两页的交界处被分开。请把全部内容整理成一份 Markdown 文档：
        - 忠实保留原文的语言和内容，不要补充或删减观点；
        - 按内容的结构使用标题、列表、表格；
        - 数学公式写成 LaTeX，行内用 $…$，独立成行的用 $$…$$；
        - 看不清的字写成 [?]；图形或草图用一句话描述，写成「> 图：…」。
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
    ]
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
            return settings
        }
        set {
            guard newValue != current else { return }
            let defaults = UserDefaults.standard
            for (key, path) in stringKeys { defaults.set(newValue[keyPath: path], forKey: key) }
            defaults.set(newValue.maxImagePixels, forKey: maxImagePixelsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func reset() {
        let defaults = UserDefaults.standard
        for (key, _) in stringKeys { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: maxImagePixelsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The models last read from the agent, with the command they were read from.
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

    /// The command and arguments as one string (identifies a cached catalog).
    var commandLine: String { "\(command) \(arguments)" }

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

    func transcriberSettings() throws -> ACPTranscriberSettings {
        ACPTranscriberSettings(
            agent: try agentConfiguration(),
            formula: TranscriptionProfile(model: formulaModel, thoughtLevel: formulaThoughtLevel, prompt: formulaPrompt),
            document: TranscriptionProfile(model: documentModel, thoughtLevel: documentThoughtLevel, prompt: documentPrompt))
    }
}

enum AISettingsError: LocalizedError {
    case agentNotFound(String)

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let command):
            let name = command.trimmingCharacters(in: .whitespaces)
            return name.isEmpty
                ? "还没有设置 agent 程序。请在「设置」（⌘,）中填写。"
                : "找不到 agent 程序「\(name)」。请在「设置」（⌘,）中填写完整路径。"
        }
    }
}
