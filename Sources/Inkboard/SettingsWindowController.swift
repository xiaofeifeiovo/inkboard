import AppKit
import InkboardCore

/// 设置 (⌘,): which ACP agent to run, and the model, thinking level and prompt used by
/// 局部转换 and 全局转换. Every edit is saved right away. The model lists come from the agent
/// itself (its session config options) and are cached, since they change between agent versions.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate {
    static let shared = SettingsWindowController()

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

    private func buildUI() {
        commandField.placeholderString = "agy"
        argumentsField.placeholderString = "acp"
        maxPixelsField.alignment = .right
        for field in [commandField, argumentsField, maxPixelsField] {
            field.delegate = self
        }
        commandField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        argumentsField.widthAnchor.constraint(equalToConstant: 300).isActive = true
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
            [section("Agent（ACP）"), empty],
            [label("命令："), row(commandField, choose)],
            [label("参数："), argumentsField],
            [empty, row(refreshButton, refreshSpinner)],
            [empty, agentStatus],
            [section("局部转换：公式 → LaTeX"), empty],
            [label("模型："), formulaModel],
            [label("思考档位："), formulaLevel],
            [label("提示词："), formulaPromptView],
            [section("全局转换：画板 → Markdown"), empty],
            [label("模型："), documentModel],
            [label("思考档位："), documentLevel],
            [label("单张图片最长边："), row(maxPixelsField, NSTextField(labelWithString: "像素"))],
            [label("提示词："), documentPromptView],
            [empty, reset],
        ]
        let grid = NSGridView(views: rows)
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
        if let cached = AISettings.cachedCatalog, cached.command == settings.commandLine {
            catalog = cached.catalog
        } else {
            catalog = nil
        }
        commandField.stringValue = settings.command
        argumentsField.stringValue = settings.arguments
        maxPixelsField.stringValue = String(settings.maxImagePixels)
        if formulaPrompt.string != settings.formulaPrompt { formulaPrompt.string = settings.formulaPrompt }
        if documentPrompt.string != settings.documentPrompt { documentPrompt.string = settings.documentPrompt }
        fillModels(formulaModel, selected: settings.formulaModel)
        fillLevels(formulaLevel, model: settings.formulaModel, selected: settings.formulaThoughtLevel)
        fillModels(documentModel, selected: settings.documentModel)
        fillLevels(documentLevel, model: settings.documentModel, selected: settings.documentThoughtLevel)
        showAgentStatus()
    }

    private func save() {
        guard !isLoading else { return }
        var settings = AISettings.current
        settings.command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.arguments = argumentsField.stringValue
        settings.formulaModel = value(of: formulaModel)
        settings.formulaThoughtLevel = value(of: formulaLevel)
        settings.formulaPrompt = formulaPrompt.string
        settings.documentModel = value(of: documentModel)
        settings.documentThoughtLevel = value(of: documentLevel)
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
        fill(popup, defaultTitle: "agent 默认", values: values, selected: selected)
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
        if text == nil {
            let command = AISettings.current.command
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

    @objc private func popupChanged(_ sender: NSPopUpButton) {
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

    func controlTextDidChange(_ notification: Notification) {
        save()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let field = notification.object as? NSTextField
        if field === maxPixelsField {
            maxPixelsField.stringValue = String(AISettings.current.maxImagePixels)
        } else if field === commandField || field === argumentsField {
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
        let before = AISettings.current.commandLine
        AISettings.reset()
        load()
        if AISettings.current.commandLine != before || catalog == nil { refreshModels(nil) }
    }

    /// The command line changed: the cached model list belongs to the old agent.
    private func agentDidChange() {
        if AISettings.cachedCatalog?.command != AISettings.current.commandLine {
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
        let configuration: ACPAgentConfiguration
        do {
            configuration = try settings.agentConfiguration()
        } catch {
            showAgentStatus()
            return
        }
        refreshButton.isEnabled = false
        refreshSpinner.startAnimation(nil)
        showAgentStatus("正在启动 agent 并读取模型列表…")

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
                AISettings.cachedCatalog = (settings.commandLine, catalog)
                self.load()
                if catalog.models.isEmpty {
                    self.showAgentStatus("这个 agent 没有提供可选的模型，将使用它的默认模型。")
                }
            case .failure(let error):
                self.showAgentStatus("读取失败：\(error.localizedDescription)", isError: true)
            }
        }
    }
}
