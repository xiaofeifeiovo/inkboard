import AppKit
import InkboardCore

/// 设置 (⌘,): where AI requests go — an ACP agent or an OpenAI-compatible API — and the model,
/// thinking level and prompt used by 局部转换 and 全局转换 (识别分块类型 uses 全局转换's model).
/// Every edit is saved right away. Model lists come from the backend itself (the agent's session
/// config options, or the API's /models) and are cached; a model can also be typed in.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate {
    static let shared = SettingsWindowController()

    /// Marks the 「其他模型…」 menu item.
    private static let otherModel = "\u{1}other"

    private let backendPopup = NSPopUpButton()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private var grid: NSGridView!
    private let commandField = NSTextField()
    private let argumentsField = NSTextField()
    private let agentStatus = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "读取模型列表", target: nil, action: nil)
    private let refreshSpinner = NSProgressIndicator()
    private let formulaModel = NSPopUpButton()
    private let formulaLevel = NSPopUpButton()
    private let documentModel = NSPopUpButton()
    private let documentLevel = NSPopUpButton()
    private let maxPixelsField = NSTextField()
    private var formulaPrompt: NSTextView!
    private var documentPrompt: NSTextView!

    private var catalog: ACPModelCatalog?
    private var fetchTask: Task<Void, Never>?
    /// Set while controls are being filled, so filling them doesn't save.
    private var isLoading = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        load()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
        // First visit, or the agent changed since the list was read.
        if catalog == nil, fetchTask == nil { refreshModels(nil) }
    }

    // MARK: - Layout

    // Rows shown for one backend only.
    private static let agentRows = [2, 3], apiRows = [4, 5]

    private func buildUI() {
        for (title, backend) in [("ACP agent（Antigravity、Gemini CLI 等）", AISettings.Backend.acp),
                                 ("OpenAI 兼容 API", .openAI)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = backend.rawValue
            backendPopup.menu?.addItem(item)
        }
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged(_:))

        commandField.placeholderString = "agy"
        argumentsField.placeholderString = "acp"
        baseURLField.placeholderString = "https://api.openai.com/v1"
        apiKeyField.placeholderString = "存在钥匙串中；本地服务可留空"
        maxPixelsField.alignment = .right
        for field in [commandField, argumentsField, baseURLField, apiKeyField, maxPixelsField] {
            field.delegate = self
        }
        for field in [commandField, argumentsField, baseURLField, apiKeyField] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        maxPixelsField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseCommand(_:)))
        refreshButton.target = self
        refreshButton.action = #selector(refreshModels(_:))
        refreshSpinner.style = .spinning
        refreshSpinner.controlSize = .small
        refreshSpinner.isDisplayedWhenStopped = false
        agentStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        agentStatus.preferredMaxLayoutWidth = 420

        for popup in [formulaModel, formulaLevel, documentModel, documentLevel] {
            popup.target = self
            popup.action = #selector(popupChanged(_:))
        }
        formulaModel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        documentModel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let formulaPromptView = makePromptEditor(height: 70)
        formulaPrompt = formulaPromptView.documentView as? NSTextView
        let documentPromptView = makePromptEditor(height: 130)
        documentPrompt = documentPromptView.documentView as? NSTextView

        let reset = NSButton(title: "恢复默认设置", target: self, action: #selector(resetToDefaults(_:)))
        let empty = NSGridCell.emptyContentView

        let rows: [[NSView]] = [
            [section("调用方式"), empty],
            [label("方式："), backendPopup],
            [label("命令："), row(commandField, choose)],
            [label("参数："), argumentsField],
            [label("Base URL："), baseURLField],
            [label("API Key："), apiKeyField],
            [empty, row(refreshButton, refreshSpinner)],
            [empty, agentStatus],
            [section("局部转换：公式 → LaTeX"), empty],
            [label("模型："), formulaModel],
            [label("思考档位："), formulaLevel],
            [label("提示词："), formulaPromptView],
            [section("全局转换：画板 → Markdown（识别分块类型也用这个模型）"), empty],
            [label("模型："), documentModel],
            [label("思考档位："), documentLevel],
            [label("单张图片最长边："), row(maxPixelsField, NSTextField(labelWithString: "像素"))],
            [label("提示词："), documentPromptView],
            [empty, reset],
        ]
        let grid = NSGridView(views: rows)
        self.grid = grid
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for (index, cells) in rows.enumerated() {
            let row = grid.row(at: index)
            if cells[1] === empty {
                row.mergeCells(in: NSRange(location: 0, length: 2))
                row.topPadding = index == 0 ? 0 : 12
                row.cell(at: 0).xPlacement = .leading
            }
            if cells[1] is NSScrollView { row.rowAlignment = .none; row.yPlacement = .top }
        }
        grid.row(at: rows.count - 1).topPadding = 8

        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
    }

    private func section(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private func label(_ title: String) -> NSTextField {
        NSTextField(labelWithString: title)
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    private func makePromptEditor(height: CGFloat) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isRichText = false
            textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            textView.textContainerInset = NSSize(width: 2, height: 4)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.allowsUndo = true
            textView.delegate = self
        }
        return scroll
    }

    // MARK: - Settings ↔ controls

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let settings = AISettings.current
        if let cached = AISettings.cachedCatalog, cached.command == settings.catalogSource {
            catalog = cached.catalog
        } else {
            catalog = nil
        }
        backendPopup.selectItem(at: settings.backend == .openAI ? 1 : 0)
        showRows(for: settings.backend)
        commandField.stringValue = settings.command
        argumentsField.stringValue = settings.arguments
        baseURLField.stringValue = settings.apiBaseURL
        loadAPIKey()
        maxPixelsField.stringValue = String(settings.maxImagePixels)
        if formulaPrompt.string != settings.formulaPrompt { formulaPrompt.string = settings.formulaPrompt }
        if documentPrompt.string != settings.documentPrompt { documentPrompt.string = settings.documentPrompt }
        fillModels(formulaModel, selected: settings.activeFormulaModel)
        fillLevels(formulaLevel, model: settings.activeFormulaModel, selected: settings.activeFormulaThoughtLevel)
        fillModels(documentModel, selected: settings.activeDocumentModel)
        fillLevels(documentLevel, model: settings.activeDocumentModel, selected: settings.activeDocumentThoughtLevel)
        showAgentStatus()
    }

    private func showRows(for backend: AISettings.Backend) {
        for index in Self.agentRows { grid.row(at: index).isHidden = backend != .acp }
        for index in Self.apiRows { grid.row(at: index).isHidden = backend != .openAI }
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
    }

    /// The keychain is only read when the API backend is in use.
    private func loadAPIKey() {
        let settings = AISettings.current
        guard settings.backend == .openAI, let url = OpenAIConfiguration.normalizedBaseURL(settings.apiBaseURL) else {
            apiKeyField.stringValue = ""
            return
        }
        apiKeyField.stringValue = APIKeychain.key(for: url) ?? ""
    }

    private func save() {
        guard !isLoading else { return }
        var settings = AISettings.current
        settings.backend = backendPopup.indexOfSelectedItem == 1 ? .openAI : .acp
        settings.command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.arguments = argumentsField.stringValue
        settings.apiBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.activeFormulaModel = value(of: formulaModel)
        settings.activeFormulaThoughtLevel = value(of: formulaLevel)
        settings.formulaPrompt = formulaPrompt.string
        settings.activeDocumentModel = value(of: documentModel)
        settings.activeDocumentThoughtLevel = value(of: documentLevel)
        settings.documentPrompt = documentPrompt.string
        if let pixels = Int(maxPixelsField.stringValue.trimmingCharacters(in: .whitespaces)) {
            settings.maxImagePixels = min(max(pixels, AISettings.maxImagePixelsRange.lowerBound),
                                          AISettings.maxImagePixelsRange.upperBound)
        }
        AISettings.current = settings
    }

    private func value(of popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? ""
    }

    private func fillModels(_ popup: NSPopUpButton, selected: String) {
        var values = catalog?.models ?? []
        if !selected.isEmpty, !values.contains(where: { $0.value == selected }) {
            values.append(ACPConfigOption.Value(value: selected, name: selected))
        }
        // An API has no default model; an agent does.
        let isAPI = AISettings.current.backend == .openAI
        fill(popup, defaultTitle: isAPI ? "（未选择）" : "agent 默认", values: values, selected: selected)
        popup.menu?.addItem(.separator())
        let other = NSMenuItem(title: "其他模型…", action: nil, keyEquivalent: "")
        other.representedObject = Self.otherModel
        popup.menu?.addItem(other)
    }

    private func fillLevels(_ popup: NSPopUpButton, model: String, selected: String) {
        let key = model.isEmpty ? catalog?.defaultModel ?? "" : model
        var values = catalog?.thoughtLevels[key] ?? []
        if !selected.isEmpty, !values.contains(where: { $0.value == selected }) {
            values.append(ACPConfigOption.Value(value: selected, name: selected))
        }
        fill(popup, defaultTitle: "默认", values: values, selected: selected)
    }

    private func fill(_ popup: NSPopUpButton, defaultTitle: String, values: [ACPConfigOption.Value], selected: String) {
        popup.removeAllItems()
        // Items are added through the menu: NSPopUpButton.addItem(withTitle:) drops duplicate titles.
        for (title, value) in [(defaultTitle, "")] + values.map({ ($0.name, $0.value) }) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = value
            popup.menu?.addItem(item)
            if value == selected { popup.select(item) }
        }
    }

    private func showAgentStatus(_ message: String? = nil, isError: Bool = false) {
        var text = message
        var error = isError
        let settings = AISettings.current
        if text == nil, settings.backend == .openAI {
            if let url = OpenAIConfiguration.normalizedBaseURL(settings.apiBaseURL) {
                text = "地址：\(url.absoluteString)/chat/completions"
                if let catalog { text! += "（\(catalog.models.count) 个模型）" }
                if apiKeyField.stringValue.isEmpty { text! += "\n未填写 API Key（本地服务通常不需要）。" }
            } else {
                text = "请填写 Base URL，例如 https://api.openai.com/v1。"
                error = true
            }
        }
        if text == nil {
            let command = settings.command
            if let url = ACPAgentConfiguration.locate(command) {
                text = "程序：\(url.path)"
                if let catalog { text! += "（\(catalog.models.count) 个模型）" }
            } else {
                text = command.isEmpty ? "请填写 agent 程序。" : "找不到「\(command)」。请填写完整路径，或点「选择…」。"
                error = true
            }
        }
        agentStatus.stringValue = text ?? ""
        agentStatus.textColor = error ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func backendChanged(_ sender: Any?) {
        save()
        load()
        if catalog == nil { refreshModels(nil) }
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        if value(of: sender) == Self.otherModel {
            askForModelName(for: sender)
            return
        }
        // A new model may not offer the chosen thinking level; fall back to its default.
        if sender === formulaModel || sender === documentModel {
            let levels = sender === formulaModel ? formulaLevel : documentLevel
            let model = value(of: sender)
            let key = model.isEmpty ? catalog?.defaultModel ?? "" : model
            let current = value(of: levels)
            let offered = catalog?.thoughtLevels[key]?.contains { $0.value == current } ?? true
            isLoading = true
            fillLevels(levels, model: model, selected: offered ? current : "")
            isLoading = false
        }
        save()
    }

    /// 「其他模型…」: a model the list doesn't offer (or no list could be read).
    private func askForModelName(for popup: NSPopUpButton) {
        let settings = AISettings.current
        let current = popup === formulaModel ? settings.activeFormulaModel : settings.activeDocumentModel
        isLoading = true
        fillModels(popup, selected: current)   // undo the selection of 「其他模型…」 for now
        isLoading = false
        guard let window else { return }
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        let alert = NSAlert()
        alert.messageText = "填写模型名"
        alert.informativeText = "例如 gpt-4o、gemini-2.5-pro、qwen-vl-max。需要是支持图片输入的模型。"
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.isLoading = true
            self.fillModels(popup, selected: name)
            let levels = popup === self.formulaModel ? self.formulaLevel : self.documentLevel
            self.fillLevels(levels, model: name, selected: "")
            self.isLoading = false
            self.save()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === apiKeyField {
            if let url = OpenAIConfiguration.normalizedBaseURL(baseURLField.stringValue) {
                APIKeychain.setKey(apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), for: url)
            }
            showAgentStatus()
            return
        }
        save()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let field = notification.object as? NSTextField
        if field === maxPixelsField {
            maxPixelsField.stringValue = String(AISettings.current.maxImagePixels)
        } else if field === commandField || field === argumentsField {
            agentDidChange()
        } else if field === baseURLField {
            loadAPIKey()   // each base URL has its own key
            agentDidChange()
        }
    }

    func textDidChange(_ notification: Notification) {
        save()
    }

    @objc private func chooseCommand(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "选择支持 ACP 的 agent 程序（例如 ~/.local/bin/agy）"
        let localBin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        if FileManager.default.fileExists(atPath: localBin.path) { panel.directoryURL = localBin }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.commandField.stringValue = url.path
            self.save()
            self.agentDidChange()
        }
    }

    @objc private func resetToDefaults(_ sender: Any?) {
        let before = AISettings.current.catalogSource
        AISettings.reset()
        load()
        if AISettings.current.catalogSource != before || catalog == nil { refreshModels(nil) }
    }

    /// The agent command or the API address changed: the cached model list belongs to the old one.
    private func agentDidChange() {
        if AISettings.cachedCatalog?.command != AISettings.current.catalogSource {
            load()
            refreshModels(nil)
        } else {
            showAgentStatus()
        }
    }

    @objc private func refreshModels(_ sender: Any?) {
        fetchTask?.cancel()
        fetchTask = nil
        let settings = AISettings.current
        let configuration: AIBackendConfiguration
        do {
            configuration = try settings.backendConfiguration()
        } catch {
            showAgentStatus()
            return
        }
        refreshButton.isEnabled = false
        refreshSpinner.startAnimation(nil)
        showAgentStatus(settings.backend == .openAI ? "正在读取模型列表…" : "正在启动 agent 并读取模型列表…")

        fetchTask = Task { @MainActor [weak self] in
            let result: Result<ACPModelCatalog, Error>
            do {
                result = .success(try await AppDelegate.transcriber.modelCatalog(for: configuration))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.fetchTask = nil
            self.refreshButton.isEnabled = true
            self.refreshSpinner.stopAnimation(nil)
            switch result {
            case .success(let catalog):
                AISettings.cachedCatalog = (settings.catalogSource, catalog)
                self.load()
                if catalog.models.isEmpty {
                    self.showAgentStatus(settings.backend == .openAI
                        ? "这个 API 没有返回模型列表，请用「其他模型…」填写模型名。"
                        : "这个 agent 没有提供可选的模型，将使用它的默认模型。")
                }
            case .failure(let error):
                self.showAgentStatus("读取失败：\(error.localizedDescription)" + (settings.backend == .openAI
                    ? "\n也可以用「其他模型…」直接填写模型名。" : ""), isError: true)
            }
        }
    }
}
