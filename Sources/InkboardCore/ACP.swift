import Foundation

// MARK: - Agent Client Protocol (ACP) client
//
// ACP (https://agentclientprotocol.com) is JSON-RPC 2.0 over an agent's stdin/stdout, one JSON
// message per line. Inkboard is the *client*: it starts an agent such as `agy acp` (Antigravity)
// or `gemini --experimental-acp`, opens a session per request and sends a prompt made of text and
// images. Inkboard offers the agent no file system or terminal access and declines every
// permission request, so the agent can only answer in text; Inkboard writes any files itself.

public typealias JSONObject = [String: Any]

public enum ACPError: LocalizedError {
    case launchFailed(path: String, reason: String)
    case agentExited(stderr: String)
    case rpc(method: String, code: Int, message: String)
    case authenticationRequired
    case unknownOption(name: String, value: String, available: [String])
    case refused
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(path, reason):
            return "无法启动 agent「\(path)」：\(reason)"
        case let .agentExited(stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "agent 意外退出。" + (detail.isEmpty ? "" : "\n\n" + detail)
        case let .rpc(method, _, message):
            return "agent 返回错误（\(method)）：\(message)"
        case .authenticationRequired:
            return "agent 需要登录。Antigravity 请在终端运行 agy acp --login；Gemini CLI 请先在终端运行一次 gemini 完成登录。登录后再试。"
        case let .unknownOption(name, value, available):
            return "agent 没有提供\(name)「\(value)」，请在「设置」中重新选择。可选：\(available.joined(separator: "、"))"
        case .refused:
            return "模型拒绝了这个请求。"
        case .emptyReply:
            return "agent 没有返回任何文字。"
        }
    }
}

extension NSLock {
    @discardableResult
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Connection (one agent process)

/// One running agent process and the JSON-RPC traffic with it.
public final class ACPConnection: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var nextID = 0
    private var pending: [Int: (method: String, continuation: CheckedContinuation<JSONObject, Error>)] = [:]
    private var sessionHandlers: [String: (JSONObject) -> Void] = [:]
    private var readBuffer = Data()
    private var stderrTail = Data()
    private var failure: Error?

    /// The agent's answer to `initialize` (capabilities, auth methods).
    public internal(set) var initializeResult: JSONObject = [:]

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) throws {
        // Writing to a dead agent's stdin must raise an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.fail(ACPError.agentExited(stderr: self.stderrText))
            } else {
                self.receive(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self.lock.sync {
                    self.stderrTail.append(data)
                    if self.stderrTail.count > 4000 { self.stderrTail = self.stderrTail.suffix(2000) }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            // Give the stdout reader a moment to deliver what the agent wrote before exiting.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                guard let self else { return }
                self.fail(ACPError.agentExited(stderr: self.stderrText))
            }
        }

        do {
            try process.run()
        } catch {
            throw ACPError.launchFailed(path: executable.path, reason: error.localizedDescription)
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    public var isAlive: Bool {
        lock.sync { failure == nil } && process.isRunning
    }

    private var stderrText: String {
        lock.sync { String(decoding: stderrTail, as: UTF8.self) }
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
        fail(CancellationError())
    }

    /// Sends a request and waits for its result.
    public func request(_ method: String, _ params: JSONObject) async throws -> JSONObject {
        try await withCheckedThrowingContinuation { continuation in
            let id: Int? = lock.sync {
                guard failure == nil else { return nil }
                nextID += 1
                pending[nextID] = (method, continuation)
                return nextID
            }
            guard let id else {
                continuation.resume(throwing: lock.sync { failure } ?? CancellationError())
                return
            }
            do {
                try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                if let entry = lock.sync({ pending.removeValue(forKey: id) }) {
                    entry.continuation.resume(throwing: error)
                }
            }
        }
    }

    public func notify(_ method: String, _ params: JSONObject) {
        try? send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Receives the `update` objects of `session/update` notifications for one session.
    public func setUpdateHandler(for sessionID: String, _ handler: ((JSONObject) -> Void)?) {
        lock.sync { sessionHandlers[sessionID] = handler }
    }

    // MARK: Wire

    private func send(_ message: JSONObject) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try writeLock.sync {
            do {
                try input.write(contentsOf: data)
            } catch {
                throw lock.sync { failure } ?? ACPError.agentExited(stderr: stderrText)
            }
        }
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.sync {
            readBuffer.append(data)
            while let newline = readBuffer.firstIndex(of: 0x0A) {
                lines.append(readBuffer[readBuffer.startIndex..<newline])
                readBuffer.removeSubrange(readBuffer.startIndex...newline)
            }
        }
        for line in lines where !line.isEmpty {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONObject) {
        let params = message["params"] as? JSONObject ?? [:]
        if let method = message["method"] as? String {
            if let id = message["id"] {
                answerRequest(id: id, method: method, params: params)
            } else if method == "session/update",
                      let sessionID = params["sessionId"] as? String,
                      let update = params["update"] as? JSONObject {
                lock.sync { sessionHandlers[sessionID] }?(update)
            }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue,
              let entry = lock.sync({ pending.removeValue(forKey: id) }) else { return }
        if let error = message["error"] as? JSONObject {
            entry.continuation.resume(throwing: ACPError.rpc(
                method: entry.method,
                code: (error["code"] as? NSNumber)?.intValue ?? 0,
                message: error["message"] as? String ?? "未知错误"))
        } else {
            entry.continuation.resume(returning: message["result"] as? JSONObject ?? [:])
        }
    }

    /// Requests from the agent. Inkboard grants nothing: permissions are declined, and the
    /// file system / terminal methods were not advertised in `initialize`.
    private func answerRequest(id: Any, method: String, params: JSONObject) {
        if method == "session/request_permission" {
            let options = params["options"] as? [JSONObject] ?? []
            let reject = ["reject_once", "reject_always"].lazy.compactMap { kind in
                options.first { $0["kind"] as? String == kind }?["optionId"]
            }.first
            let outcome: JSONObject = reject.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
            try? send(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
        } else {
            try? send(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32601, "message": "Inkboard does not support \(method)"]])
        }
    }

    private func fail(_ error: Error) {
        let waiting: [CheckedContinuation<JSONObject, Error>] = lock.sync {
            if failure == nil { failure = error }
            defer { pending.removeAll() }
            return pending.values.map(\.continuation)
        }
        waiting.forEach { $0.resume(throwing: lock.sync { failure } ?? error) }
    }
}

// MARK: - Session options (model, thinking level, …)

/// A `select` session config option from `session/new` / `session/set_config_option`.
public struct ACPConfigOption {
    public struct Value: Equatable, Codable {
        public let value: String
        public let name: String

        public init(value: String, name: String) {
            self.value = value
            self.name = name
        }
    }

    public let id: String
    public let name: String
    public let category: String?
    public let currentValue: String
    public let values: [Value]

    public func matches(_ key: String) -> Bool { category == key || id == key }

    public static func parse(_ json: Any?) -> [ACPConfigOption] {
        (json as? [JSONObject] ?? []).compactMap { item in
            guard let id = item["id"] as? String, item["type"] as? String ?? "select" == "select" else { return nil }
            return ACPConfigOption(
                id: id,
                name: item["name"] as? String ?? id,
                category: item["category"] as? String,
                currentValue: item["currentValue"] as? String ?? "",
                values: flatten(item["options"]))
        }
    }

    /// Options may be grouped: `[{group, name, options: [...]}]`.
    private static func flatten(_ json: Any?) -> [Value] {
        (json as? [JSONObject] ?? []).flatMap { item -> [Value] in
            if let value = item["value"] as? String {
                return [Value(value: value, name: item["name"] as? String ?? value)]
            }
            return flatten(item["options"])
        }
    }
}

/// The models an agent offers, with the thinking levels each one accepts.
public struct ACPModelCatalog: Codable, Equatable {
    public var models: [ACPConfigOption.Value] = []
    public var defaultModel: String = ""
    public var thoughtLevels: [String: [ACPConfigOption.Value]] = [:]

    public init() {}
}

// MARK: - Agent (configuration + lifecycle)

public struct ACPAgentConfiguration: Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    /// The session `cwd`. The agent gets no tools, so an empty scratch folder is enough.
    public var workingDirectory: URL

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// Folders searched for a bare command name. Apps started from Finder get a minimal PATH,
    /// so the usual install locations of agent CLIs are added.
    public static func searchPath(home: String = NSHomeDirectory(), inherited: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/bin"]
        dirs += (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// Resolves "agy", "~/bin/agy" or "/abs/path/agy" to an executable file.
    public static func locate(_ command: String, searchPath: [String] = searchPath(), home: String = NSHomeDirectory(),
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        if command.contains("/") {
            let path = command.hasPrefix("~/") ? home + command.dropFirst() : command
            return isExecutable(path) ? URL(fileURLWithPath: path) : nil
        }
        return searchPath.lazy.map { "\($0)/\(command)" }.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Splits an argument string on whitespace; single or double quotes group words.
    public static func splitArguments(_ string: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in string {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }
}

public enum ACPContent {
    public static func text(_ text: String) -> JSONObject {
        ["type": "text", "text": text]
    }

    public static func image(png: Data) -> JSONObject {
        ["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]
    }
}

/// Starts the agent process on first use and keeps it running; each prompt gets a fresh session
/// so nothing carries over between requests.
public final class ACPAgent: @unchecked Sendable {
    public let configuration: ACPAgentConfiguration
    private let lock = NSLock()
    private var current: ACPConnection?
    private var starting: Task<ACPConnection, Error>?
    /// A session created ahead of time by `prepare()`; the first `session/new` of a process is slow.
    private var spare: (connection: ACPConnection, id: String, result: JSONObject)?

    public init(configuration: ACPAgentConfiguration) {
        self.configuration = configuration
    }

    deinit { shutdown() }

    public func shutdown() {
        let (connection, task) = lock.sync { () -> (ACPConnection?, Task<ACPConnection, Error>?) in
            defer { current = nil; starting = nil; spare = nil }
            return (current, starting)
        }
        task?.cancel()
        connection?.terminate()
        if let task { Task { try? await task.value.terminate() } }
    }

    /// Starts the agent and opens a session in the background, so the next prompt starts sooner.
    public func prepare() {
        Task {
            guard lock.sync({ spare == nil }) else { return }
            guard let connection = try? await connection(),
                  let session = try? await newSession(on: connection) else { return }
            let keep = lock.sync { () -> Bool in
                guard spare == nil else { return false }
                spare = (connection, session.id, session.result)
                return true
            }
            if !keep { close(session.id, on: connection) }
        }
    }

    /// Sends one prompt in a new session and returns the agent's reply text.
    /// `model` must be offered by the agent; an unsupported `thoughtLevel` is ignored.
    public func prompt(_ blocks: [JSONObject], model: String, thoughtLevel: String) async throws -> String {
        try Task.checkCancellation()
        let connection = try await connection()
        let session: (id: String, result: JSONObject)
        if let reused = lock.sync({ () -> (id: String, result: JSONObject)? in
            defer { spare = nil }
            guard let spare, spare.connection === connection else { return nil }
            return (spare.id, spare.result)
        }) {
            session = reused
        } else {
            session = try await newSession(on: connection)
        }
        defer { close(session.id, on: connection) }

        var options = ACPConfigOption.parse(session.result["configOptions"])
        try await setModel(model, session: session, options: &options, on: connection)
        try await setOption("thought_level", to: thoughtLevel, strict: false, session: session.id, options: &options, on: connection)

        let collector = TextCollector()
        connection.setUpdateHandler(for: session.id) { update in
            guard update["sessionUpdate"] as? String == "agent_message_chunk",
                  let content = update["content"] as? JSONObject,
                  content["type"] as? String == "text",
                  let text = content["text"] as? String else { return }
            collector.append(text)
        }
        defer { connection.setUpdateHandler(for: session.id, nil) }

        let result = try await withTaskCancellationHandler {
            try await connection.request("session/prompt", ["sessionId": session.id, "prompt": blocks])
        } onCancel: {
            connection.notify("session/cancel", ["sessionId": session.id])
        }
        switch result["stopReason"] as? String {
        case "cancelled": throw CancellationError()
        case "refusal": throw ACPError.refused
        default: break
        }
        try Task.checkCancellation()
        let text = collector.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ACPError.emptyReply }
        return text
    }

    /// Lists the models and, for each, its thinking levels (both from the session config options).
    public func modelCatalog() async throws -> ACPModelCatalog {
        let connection = try await connection()
        let session = try await newSession(on: connection)
        defer { close(session.id, on: connection) }

        var catalog = ACPModelCatalog()
        let options = ACPConfigOption.parse(session.result["configOptions"])
        if let model = options.first(where: { $0.matches("model") }) {
            catalog.models = model.values
            catalog.defaultModel = model.currentValue
            catalog.thoughtLevels[model.currentValue] = options.first { $0.matches("thought_level") }?.values ?? []
            for value in model.values where value.value != model.currentValue {
                let result = try await connection.request("session/set_config_option",
                                                          ["sessionId": session.id, "configId": model.id, "value": value.value])
                let updated = ACPConfigOption.parse(result["configOptions"])
                catalog.thoughtLevels[value.value] = updated.first { $0.matches("thought_level") }?.values ?? []
            }
        } else if let models = session.result["models"] as? JSONObject {
            // Older agents: the unstable `models` field instead of config options.
            catalog.models = (models["availableModels"] as? [JSONObject] ?? []).compactMap { item in
                (item["modelId"] as? String).map { ACPConfigOption.Value(value: $0, name: item["name"] as? String ?? $0) }
            }
            catalog.defaultModel = models["currentModelId"] as? String ?? ""
        }
        return catalog
    }

    // MARK: Internals

    private func connection() async throws -> ACPConnection {
        let task: Task<ACPConnection, Error> = lock.sync {
            if let starting { return starting }
            if let current, current.isAlive { return Task { current } }
            current = nil
            spare = nil
            let configuration = self.configuration
            let task = Task { try await Self.launch(configuration) }
            starting = task
            return task
        }
        do {
            let connection = try await task.value
            lock.sync {
                if starting == task {
                    current = connection
                    starting = nil
                }
            }
            return connection
        } catch {
            lock.sync { if starting == task { starting = nil } }
            throw error
        }
    }

    private static func launch(_ configuration: ACPAgentConfiguration) async throws -> ACPConnection {
        try? FileManager.default.createDirectory(at: configuration.workingDirectory, withIntermediateDirectories: true)
        let connection = try ACPConnection(executable: configuration.executable, arguments: configuration.arguments,
                                           environment: configuration.environment,
                                           workingDirectory: configuration.workingDirectory)
        do {
            connection.initializeResult = try await connection.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "Inkboard", "version": "1.0"],
            ])
            return connection
        } catch {
            connection.terminate()
            throw error
        }
    }

    private func newSession(on connection: ACPConnection) async throws -> (id: String, result: JSONObject) {
        let params: JSONObject = ["cwd": configuration.workingDirectory.path, "mcpServers": [Any]()]
        var result: JSONObject
        do {
            result = try await connection.request("session/new", params)
        } catch ACPError.rpc(_, -32000, _) {
            // Authentication required: try the agent's first sign-in method (it reuses a cached
            // login when there is one), then retry once.
            guard let method = (connection.initializeResult["authMethods"] as? [JSONObject])?.first?["id"] as? String,
                  (try? await connection.request("authenticate", ["methodId": method])) != nil,
                  let retried = try? await connection.request("session/new", params)
            else { throw ACPError.authenticationRequired }
            result = retried
        }
        guard let id = result["sessionId"] as? String else {
            throw ACPError.rpc(method: "session/new", code: 0, message: "缺少 sessionId")
        }
        return (id, result)
    }

    private func setModel(_ model: String, session: (id: String, result: JSONObject),
                          options: inout [ACPConfigOption], on connection: ACPConnection) async throws {
        guard !model.isEmpty else { return }
        if options.contains(where: { $0.matches("model") }) {
            try await setOption("model", to: model, strict: true, session: session.id, options: &options, on: connection)
        } else if let models = session.result["models"] as? JSONObject {
            guard models["currentModelId"] as? String != model else { return }
            let available = (models["availableModels"] as? [JSONObject] ?? []).compactMap { $0["modelId"] as? String }
            guard available.contains(model) else {
                throw ACPError.unknownOption(name: "模型", value: model, available: available)
            }
            _ = try await connection.request("session/set_model", ["sessionId": session.id, "modelId": model])
        }
        // An agent with neither has no model setting; it uses its own default.
    }

    private func setOption(_ key: String, to value: String, strict: Bool, session: String,
                           options: inout [ACPConfigOption], on connection: ACPConnection) async throws {
        guard !value.isEmpty, let option = options.first(where: { $0.matches(key) }),
              option.currentValue != value else { return }
        guard option.values.contains(where: { $0.value == value }) else {
            if strict {
                throw ACPError.unknownOption(name: key == "model" ? "模型" : option.name, value: value,
                                             available: option.values.map(\.value))
            }
            return
        }
        let result = try await connection.request("session/set_config_option",
                                                  ["sessionId": session, "configId": option.id, "value": value])
        let updated = ACPConfigOption.parse(result["configOptions"])
        if !updated.isEmpty { options = updated }
    }

    private func close(_ session: String, on connection: ACPConnection) {
        let capabilities = connection.initializeResult["agentCapabilities"] as? JSONObject
        guard (capabilities?["sessionCapabilities"] as? JSONObject)?["close"] != nil else { return }
        Task { _ = try? await connection.request("session/close", ["sessionId": session]) }
    }
}

private final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []

    func append(_ text: String) { lock.sync { parts.append(text) } }
    var text: String { lock.sync { parts.joined() } }
}
