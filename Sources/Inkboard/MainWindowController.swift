import AppKit
import InkboardCore
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let tools = NSToolbarItem.Identifier("tools")
    static let penWidth = NSToolbarItem.Identifier("penWidth")
    static let formula = NSToolbarItem.Identifier("formula")
    static let document = NSToolbarItem.Identifier("document")
}

/// One window per BoardDocument. The document sets the title (file name + "Edited"),
/// and the window uses the document's undo manager.
final class MainWindowController: NSWindowController {
    let canvas = CanvasView(frame: NSRect(origin: .zero, size: CanvasView.minimumCanvasSize))
    private let scrollView = NSScrollView()
    private let toolControl = NSSegmentedControl()
    private let widthControl = NSSegmentedControl()
    private let formulaButton = NSButton()
    private let transcriber: HandwritingTranscriber

    // AI conversions. Each has its own status banner; `run` counters tell a finished task
    // whether it is still the current one.
    private let formulaBanner = StatusBanner()
    private let documentBanner = StatusBanner()
    private var formulaTask: Task<Void, Never>?
    private var formulaRun = 0
    private var documentTask: Task<Void, Never>?
    private var documentRun = 0

    init(transcriber: HandwritingTranscriber) {
        self.transcriber = transcriber
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true

        setUpCanvas()
        setUpToolbar()
    }

    /// Base name for exported files: the document's name, without extension.
    private var exportBaseName: String {
        let name = (document as? NSDocument)?.displayName ?? "Inkboard"
        return (name as NSString).deletingPathExtension
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUpCanvas() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 5
        scrollView.backgroundColor = NSColor(white: 0.9, alpha: 1)   // shown around the canvas when zoomed out
        scrollView.documentView = canvas

        let banners = NSStackView(views: [documentBanner, formulaBanner])
        banners.orientation = .vertical
        banners.spacing = 8

        let container = NSView()
        for view in [scrollView, banners] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            banners.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            banners.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            banners.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        window?.contentView = container

        canvas.onToolChange = { [weak self] tool in
            self?.toolControl.selectedSegment = tool.rawValue
        }
        canvas.onCaptureModeChange = { [weak self] on in
            self?.captureModeChanged(on)
        }
        canvas.onFormulaCapture = { [weak self] rect in
            self?.convertFormula(in: rect)
        }
    }

    // MARK: - Actions (reached through the responder chain from menus and toolbar)

    @objc func selectTool(_ sender: Any?) {
        let raw = (sender as? NSMenuItem)?.tag ?? (sender as? NSSegmentedControl)?.selectedSegment ?? 0
        if let tool = Tool(rawValue: raw) { canvas.tool = tool }
    }

    @objc func selectPenWidth(_ sender: Any?) {
        let raw = (sender as? NSMenuItem)?.tag ?? (sender as? NSSegmentedControl)?.selectedSegment ?? 1
        guard let width = PenWidth(rawValue: raw) else { return }
        canvas.penWidth = width.value
        widthControl.selectedSegment = raw
        canvas.tool = .pen
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }

    @objc func actualSize(_ sender: Any?) {
        scrollView.animator().setMagnification(1, centeredAt: visibleCenter)
    }

    private func zoom(by factor: CGFloat) {
        let target = min(scrollView.maxMagnification, max(scrollView.minMagnification, scrollView.magnification * factor))
        scrollView.animator().setMagnification(target, centeredAt: visibleCenter)
    }

    private var visibleCenter: NSPoint {
        let visible = scrollView.contentView.bounds
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    @objc func clearBoard(_ sender: Any?) {
        canvas.clearAll()
    }

    @objc func exportPNG(_ sender: Any?) {
        guard let window,
              let image = InkRenderer.renderImage(canvas.strokesForExport, scale: 2),
              let png = InkRenderer.pngData(image) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = exportBaseName + ".png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url) } catch { NSApp.presentError(error) }
        }
    }

    // MARK: - 局部转换 (formula box → LaTeX on the clipboard)

    @objc func toggleFormulaCapture(_ sender: Any?) {
        canvas.isCapturingFormula.toggle()
        window?.makeFirstResponder(canvas)   // so Esc reaches the canvas
    }

    private func captureModeChanged(_ on: Bool) {
        formulaButton.state = on ? .on : .off
        toolControl.selectedSegment = on ? -1 : canvas.tool.rawValue
        if on {
            transcriber.prepare()   // start the agent while the user draws the box
            showCaptureHint()
        } else {
            cancelFormula()
            formulaBanner.hide()
        }
    }

    private func showCaptureHint() {
        formulaBanner.show("拖出一个方框，框住要转换的公式。按 Esc 退出。", style: .info)
    }

    private func convertFormula(in rect: CGRect) {
        cancelFormula()
        guard let image = InkImage.render(canvas.strokes, rect: rect, maxPixels: AISettings.formulaMaxPixels) else {
            formulaBanner.show("方框里没有笔迹，请重新框选。按 Esc 退出。", style: .info)
            return
        }
        formulaRun += 1
        let run = formulaRun
        canvas.captureBusy = true
        formulaBanner.show("正在识别公式…", style: .progress, button: "取消") { [weak self] in
            self?.cancelFormula()
            self?.showCaptureHint()
        }

        let transcriber = self.transcriber
        formulaTask = Task { @MainActor [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await transcriber.transcribeFormula(image))
            } catch {
                result = .failure(error)
            }
            guard let self, self.formulaRun == run, !Task.isCancelled else { return }
            self.formulaTask = nil
            self.canvas.captureBusy = false
            switch result {
            case .success(let latex):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(latex, forType: .string)
                self.formulaBanner.show("已复制 LaTeX：\(latex)", style: .success)
            case .failure(let error) where error is CancellationError:
                self.showCaptureHint()
            case .failure(let error):
                self.showCaptureHint()
                self.showAlert(title: "无法转换这个公式", message: error.localizedDescription)
            }
        }
    }

    private func cancelFormula() {
        formulaRun += 1
        formulaTask?.cancel()
        formulaTask = nil
        canvas.captureBusy = false
    }

    // MARK: - 全局转换 (whole board → Markdown next to the document)

    @objc func convertDocument(_ sender: Any?) {
        guard documentTask == nil, !canvas.strokes.isEmpty, let window,
              let document = document as? NSDocument else { NSSound.beep(); return }

        guard let fileURL = document.fileURL else {
            let alert = NSAlert()
            alert.messageText = "请先存储这个文稿"
            alert.informativeText = "全局转换会把 Markdown 文件存到文稿所在的文件夹，所以文稿需要先存储。"
            alert.addButton(withTitle: "存储…")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                DispatchQueue.main.async {
                    document.save(withDelegate: self, didSave: #selector(self.boardDocument(_:didSaveForConversion:contextInfo:)),
                                  contextInfo: nil)
                }
            }
            return
        }

        let output = fileURL.deletingPathExtension().appendingPathExtension("md")
        guard FileManager.default.fileExists(atPath: output.path) else {
            startDocumentConversion(to: output)
            return
        }
        let alert = NSAlert()
        alert.messageText = "“\(output.lastPathComponent)”已存在。要替换它吗？"
        alert.informativeText = "全局转换的结果会存储为这个文件，原来的内容会被覆盖。"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.startDocumentConversion(to: output) }
        }
    }

    @objc private func boardDocument(_ document: NSDocument, didSaveForConversion didSave: Bool,
                                contextInfo: UnsafeMutableRawPointer?) {
        if didSave, document.fileURL != nil { convertDocument(nil) }
    }

    private func startDocumentConversion(to output: URL) {
        documentRun += 1
        let run = documentRun
        let strokes = canvas.strokes
        let maxPixels = CGFloat(AISettings.current.maxImagePixels)
        let transcriber = self.transcriber
        transcriber.prepare()
        documentBanner.show("正在准备图片…", style: .progress, button: "取消") { [weak self] in
            self?.cancelDocument()
        }

        documentTask = Task { @MainActor [weak self] in
            let result: Result<Void, Error>
            do {
                let pages = await Task.detached(priority: .userInitiated) {
                    Self.pageImages(strokes, maxPixels: maxPixels)
                }.value
                try Task.checkCancellation()
                self?.documentBanner.show("正在转换为 Markdown（\(pages.count) 张图片）…", style: .progress, button: "取消") {
                    self?.cancelDocument()
                }
                let markdown = try await transcriber.transcribeDocument(pages)
                try Task.checkCancellation()
                try markdown.write(to: output, atomically: true, encoding: .utf8)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            guard let self, self.documentRun == run else { return }
            self.documentTask = nil
            switch result {
            case .success:
                self.documentBanner.show("已存储“\(output.lastPathComponent)”", style: .success,
                                         button: "在 Finder 中显示", action: {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }, autoHide: 10)
            case .failure(let error) where error is CancellationError:
                self.documentBanner.hide()
            case .failure(let error):
                self.documentBanner.hide()
                self.showAlert(title: "全局转换失败", message: error.localizedDescription)
            }
        }
    }

    private func cancelDocument() {
        documentRun += 1
        documentTask?.cancel()
        documentTask = nil
        documentBanner.hide()
    }

    /// Cuts the board into pages (see PageSlicer) and renders each one.
    private nonisolated static func pageImages(_ strokes: [Stroke], maxPixels: CGFloat) -> [InkImage] {
        var options = PageSlicer.Options()
        options.maxSide = maxPixels   // pages are rendered at no less than 1 pixel per canvas unit
        return PageSlicer.pages(for: strokes, options: options).compactMap {
            InkImage.render(strokes, rect: $0, maxPixels: maxPixels)
        }
    }

    private func showAlert(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Toolbar

extension MainWindowController: NSToolbarDelegate {
    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: "InkboardToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tools, .penWidth, .flexibleSpace, .formula, .document]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .tools:
            toolControl.segmentCount = Tool.allCases.count
            toolControl.trackingMode = .selectOne
            for tool in Tool.allCases {
                toolControl.setImage(tool.image, forSegment: tool.rawValue)
                toolControl.setWidth(38, forSegment: tool.rawValue)
                toolControl.setToolTip("\(tool.title)（\(tool.shortcut.uppercased())）", forSegment: tool.rawValue)
            }
            toolControl.selectedSegment = canvas.tool.rawValue
            toolControl.target = self
            toolControl.action = #selector(selectTool(_:))
            item.view = toolControl
            item.label = "工具"

        case .penWidth:
            widthControl.segmentCount = PenWidth.allCases.count
            widthControl.trackingMode = .selectOne
            for width in PenWidth.allCases {
                let config = NSImage.SymbolConfiguration(pointSize: width.dotSize, weight: .regular)
                let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: width.title)?
                    .withSymbolConfiguration(config)
                widthControl.setImage(image, forSegment: width.rawValue)
                widthControl.setWidth(30, forSegment: width.rawValue)
                widthControl.setToolTip("笔宽：\(width.title)", forSegment: width.rawValue)
            }
            widthControl.selectedSegment = PenWidth.allCases.firstIndex { $0.value == canvas.penWidth } ?? 1
            widthControl.target = self
            widthControl.action = #selector(selectPenWidth(_:))
            item.view = widthControl
            item.label = "笔宽"

        case .formula:
            formulaButton.image = Self.symbol(["x.squareroot", "function"], description: "局部转换")
            formulaButton.setButtonType(.pushOnPushOff)
            formulaButton.bezelStyle = .texturedRounded
            formulaButton.target = self
            formulaButton.action = #selector(toggleFormulaCapture(_:))
            formulaButton.toolTip = "局部转换：框住一个公式，转换为 LaTeX 并复制（⇧⌘L）"
            item.view = formulaButton
            item.label = "局部转换"

        case .document:
            item.image = Self.symbol(["doc.text", "doc"], description: "全局转换")
            item.label = "全局转换"
            item.toolTip = "全局转换：整个画板转换为 Markdown，存到文稿所在的文件夹（⇧⌘M）"
            item.isBordered = true
            item.target = self
            item.action = #selector(convertDocument(_:))

        default:
            return nil
        }
        return item
    }

    private static func symbol(_ names: [String], description: String) -> NSImage? {
        names.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: description) }.first
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.action == #selector(convertDocument(_:)) ? canConvertDocument : true
    }

    private var canConvertDocument: Bool {
        documentTask == nil && !canvas.strokes.isEmpty
    }
}

// MARK: - Menu validation

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectTool(_:)):
            menuItem.state = menuItem.tag == canvas.tool.rawValue ? .on : .off
            return true
        case #selector(selectPenWidth(_:)):
            menuItem.state = PenWidth(rawValue: menuItem.tag)?.value == canvas.penWidth ? .on : .off
            return true
        case #selector(exportPNG(_:)), #selector(clearBoard(_:)):
            return !canvas.strokes.isEmpty
        case #selector(toggleFormulaCapture(_:)):
            menuItem.state = canvas.isCapturingFormula ? .on : .off
            return true
        case #selector(convertDocument(_:)):
            return canConvertDocument
        default:
            return true
        }
    }
}
