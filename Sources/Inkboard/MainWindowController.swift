import AppKit
import InkboardCore
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let tools = NSToolbarItem.Identifier("tools")
    static let penWidth = NSToolbarItem.Identifier("penWidth")
    static let formula = NSToolbarItem.Identifier("formula")
    static let document = NSToolbarItem.Identifier("document")
    static let autoCheck = NSToolbarItem.Identifier("autoCheck")
}

/// One window per BoardDocument. The document sets the title (file name + "Edited"),
/// and the window uses the document's undo manager.
final class MainWindowController: NSWindowController {
    let canvas = CanvasView(frame: NSRect(origin: .zero, size: CanvasView.minimumCanvasSize))
    private let scrollView = NSScrollView()
    private let toolControl = NSSegmentedControl()
    private let widthControl = NSSegmentedControl()
    private let formulaButton = NSButton()
    /// 自动检查 in the toolbar: the main part switches it on and off, the arrow opens `autoCheckMenu`.
    let autoCheckButton = NSComboButton()
    /// What 自动检查 is doing: rebuilt on every change (and when it opens), never empty.
    let autoCheckMenu = NSMenu()
    private let transcriber: HandwritingTranscriber
    /// 自动检查 (per document: its state is stored in the BoardDocument).
    let checker: AutoChecker
    /// The checker's state changed (the document stores it and marks itself edited).
    var onAutoCheckStateChange: ((AutoCheckState) -> Void)?
    private let checkBanner = StatusBanner()
    private(set) var detailsPopover: NSPopover?
    private var checkSignature = AISettings.current.checkSignature
    private var observers: [NSObjectProtocol] = []

    // AI conversions. Each has its own status banner; `run` counters tell a finished task
    // whether it is still the current one.
    private let formulaBanner = StatusBanner()
    private let documentBanner = StatusBanner()
    private var formulaTask: Task<Void, Never>?
    private var formulaRun = 0
    private var documentTask: Task<Void, Never>?
    private var documentRun = 0
    /// 自动检查 was switched on in「AI 辅助」with ink outside every AI group: AI 识别分块 runs first.
    private var enablingAutoCheck = false {
        didSet {
            guard enablingAutoCheck != oldValue else { return }
            updateAutoCheckButton()
            rebuildAutoCheckMenu()
        }
    }

    init(transcriber: HandwritingTranscriber, checkService: AutoCheckService) {
        self.transcriber = transcriber
        checker = AutoChecker(service: checkService, pageOptions: AISettings.current.pageOptions)
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
        setUpAutoCheck()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Shows a board and its 自动检查 state (opening, 复原, browsing versions); no undo.
    func load(_ board: Board, autoCheck: AutoCheckState) {
        detailsPopover?.close()
        canvas.load(board)
        checker.load(board: board, state: autoCheck)
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

        let banners = NSStackView(views: [documentBanner, formulaBanner, checkBanner])
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
        guard let image = InkRenderer.renderImage(canvas.boardForExport, scale: 2),
              let png = InkRenderer.pngData(image) else { NSSound.beep(); return }
        save(png, as: .png)
    }

    /// A4 pages with vector ink (see PDFExport); only the selection when there is one.
    @objc func exportPDF(_ sender: Any?) {
        var options = PDFExport.Options()
        options.title = exportBaseName
        guard let pdf = PDFExport.data(canvas.boardForExport, options: options) else { NSSound.beep(); return }
        save(pdf, as: .pdf)
    }

    private func save(_ data: Data, as type: UTType) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = exportBaseName + "." + (type.preferredFilenameExtension ?? "")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { NSApp.presentError(error) }
        }
    }

    /// 编辑 → 插入图片…: pictures from files (⌘V and dropping files onto the canvas work too).
    @objc func insertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "选择要插入的图片"
        panel.prompt = "插入"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let datas = panel.urls.compactMap { try? Data(contentsOf: $0) }
            if !self.canvas.insertImages(datas) {
                self.showAlert(title: "无法插入图片", message: "无法读取所选文件中的图片。")
            }
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

    // MARK: - 识别分块类型 / AI 识别分块

    /// 转换 → 识别分块类型 (分块方式「本地计算」) or AI 识别分块 (「AI 辅助」): the same menu item.
    @objc func recognizeBlocks(_ sender: Any?) {
        if LayoutSettings.segmentationMode == .aiAssisted {
            segmentBlocks(sender)
        } else {
            labelBlocks(sender)
        }
    }

    /// Sends the board with every line / drawing tagged (see BlockLabeling) and stores the answer
    /// in the board's labels, which the segmentation then uses. Undoable; saved with the document.
    @objc func labelBlocks(_ sender: Any?) {
        guard documentTask == nil, !canvas.strokes.isEmpty else { NSSound.beep(); return }
        documentRun += 1
        let run = documentRun
        let board = canvas.board
        let options = AISettings.current.pageOptions
        let layout = LayoutSettings.layoutOptions
        let transcriber = self.transcriber
        transcriber.prepare()
        documentBanner.show("正在识别分块类型…", style: .progress, button: "取消") { [weak self] in
            self?.cancelDocument()
        }

        documentTask = Task { @MainActor [weak self] in
            let result: Result<(labels: [Set<UUID>: InkBlock.Kind], units: [BlockLabeling.Unit]), Error>
            do {
                let request = await Task.detached(priority: .userInitiated) {
                    BlockLabeling.request(for: board, options: options, layout: layout)
                }.value
                try Task.checkCancellation()
                result = .success((try await transcriber.labelBlocks(request), request.units))
            } catch {
                result = .failure(error)
            }
            guard let self, self.documentRun == run else { return }
            self.documentTask = nil
            switch result {
            case .success(let answer):
                // Labels are keyed by strokes: ink edited meanwhile just doesn't match any more.
                self.canvas.setLabels(answer.labels)
                let lines = answer.units.filter(\.isLine).map(\.ids)
                let formulas = lines.filter { answer.labels[$0] == .formula }.count
                let graphics = answer.units.count - lines.count
                var message = "已识别 \(answer.labels.count) 个区域：\(lines.count) 行中有 \(formulas) 行公式"
                if graphics > 0 { message += "，\(graphics) 个图形" }
                if answer.labels.count < answer.units.count { message += "（\(answer.units.count - answer.labels.count) 个没有得到回答）" }
                if CanvasView.showsBlocks {
                    self.documentBanner.show(message, style: .success, autoHide: 8)
                } else {
                    self.documentBanner.show(message, style: .success, button: "显示分块", action: {
                        CanvasView.showsBlocks = true
                    }, autoHide: 12)
                }
            case .failure(let error) where error is CancellationError:
                self.documentBanner.hide()
            case .failure(let error):
                self.documentBanner.hide()
                self.showAlert(title: "识别分块类型失败", message: error.localizedDescription)
            }
        }
    }

    /// AI 识别分块 (分块方式「AI 辅助」): the same tagged pages as 识别分块类型, but the AI groups the
    /// lines and drawings into blocks (BlockSegmentation); the answer replaces the board's groups
    /// (undoable, saved with the document), which the segmentation then follows.
    @objc func segmentBlocks(_ sender: Any?) {
        guard documentTask == nil, !canvas.strokes.isEmpty else { NSSound.beep(); return }
        runSegmentation(progress: "正在用 AI 识别分块…") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let message):
                self.showSegmentationResult(message)
            case .failure(let error):
                self.documentBanner.hide()
                self.showAlert(title: "AI 识别分块失败", message: error.localizedDescription)
            }
        }
    }

    /// Sends the tagged pages, commits the groups (`CanvasView.setGroups`) and reports a summary.
    /// `completion` is not called when the user cancels.
    private func runSegmentation(progress: String, completion: @escaping (Result<String, Error>) -> Void) {
        documentRun += 1
        let run = documentRun
        let board = canvas.board
        let options = AISettings.current.pageOptions
        let layout = LayoutSettings.layoutOptions
        let transcriber = self.transcriber
        transcriber.prepare()
        documentBanner.show(progress, style: .progress, button: "取消") { [weak self] in
            self?.cancelDocument()
        }

        documentTask = Task { @MainActor [weak self] in
            let result: Result<(groups: [BlockGroup], units: [BlockLabeling.Unit]), Error>
            do {
                let request = await Task.detached(priority: .userInitiated) {
                    BlockLabeling.request(for: board, options: options, layout: layout)
                }.value
                try Task.checkCancellation()
                result = .success((try await transcriber.segmentBlocks(request), request.units))
            } catch {
                result = .failure(error)
            }
            guard let self, self.documentRun == run else { return }
            self.documentTask = nil
            switch result {
            case .success(let answer):
                // Groups are keyed by strokes: ink written meanwhile is segmented by geometry.
                self.canvas.setGroups(answer.groups)
                let grouped = answer.groups.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
                let left = answer.units.filter { $0.ids.isDisjoint(with: grouped) }.count
                var message = "AI 把 \(answer.units.count) 个区域分成了 \(answer.groups.count) 个块"
                if left > 0 { message += "（\(left) 个区域未返回，仍按本地分块）" }
                completion(.success(message))
            case .failure(let error) where error is CancellationError:
                self.documentBanner.hide()
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func showSegmentationResult(_ message: String) {
        if CanvasView.showsBlocks {
            documentBanner.show(message, style: .success, autoHide: 8)
        } else {
            documentBanner.show(message, style: .success, button: "显示分块", action: {
                CanvasView.showsBlocks = true
            }, autoHide: 12)
        }
    }

    /// Some ink is in no AI group (written after the last AI 识别分块, or never segmented by the AI).
    private var hasUngroupedInk: Bool {
        let grouped = canvas.board.groups.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
        return canvas.board.strokes.contains { !grouped.contains($0.id) }
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
        let board = canvas.board
        let pageOptions = AISettings.current.pageOptions
        let layout = LayoutSettings.layoutOptions
        let transcriber = self.transcriber
        transcriber.prepare()
        documentBanner.show("正在准备图片…", style: .progress, button: "取消") { [weak self] in
            self?.cancelDocument()
        }

        let fixedPages = checker.state.pages

        documentTask = Task { @MainActor [weak self] in
            let result: Result<Void, Error>
            do {
                let plan = await Task.detached(priority: .userInitiated) {
                    Self.conversionPlan(board, fixed: fixedPages, options: pageOptions, layout: layout)
                }.value
                try Task.checkCancellation()
                var markdown = plan.reused
                if !plan.pages.isEmpty {
                    var text = "正在转换为 Markdown（\(plan.pages.count) 张图片）…"
                    if plan.reusedPages > 0 { text = "正在转换为 Markdown（\(plan.pages.count) 张图片，前 \(plan.reusedPages) 页沿用自动检查的转写）…" }
                    self?.documentBanner.show(text, style: .progress, button: "取消") {
                        self?.cancelDocument()
                    }
                    let converted = try await transcriber.transcribeDocument(plan.pages)
                    markdown = markdown.isEmpty ? converted : markdown + "\n" + converted
                }
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
        enablingAutoCheck = false
        documentRun += 1
        documentTask?.cancel()
        documentTask = nil
        documentBanner.hide()
    }

    /// Splits the board into blocks (InkLayout), packs them into pages (PageAssembler) and renders
    /// each page with only its own blocks (显示 → 显示分块 shows the same blocks and pages).
    ///
    /// Pages fixed by 自动检查 that are unchanged, from the first page on, are not sent again: their
    /// stored transcription is used (without the block comments), and only the rest is rendered.
    private nonisolated static func conversionPlan(_ board: Board, fixed: [FixedPage], options: PageAssembler.Options,
                                                   layout: InkLayout.Options)
        -> (reused: String, reusedPages: Int, pages: [InkImage]) {
        let blocks = InkLayout.analyze(board, options: layout).blocks
        var count = 0
        while count < fixed.count,
              !fixed[count].markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !AutoCheckPages.isModified(fixed[count], at: count, blocks: blocks, fixed: fixed) {
            count += 1
        }
        let reused = fixed.prefix(count)
            .map { AutoCheckReply.stripBlockComments($0.markdown).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let pages = AutoCheckPages.openPages(blocks: blocks, fixed: Array(fixed.prefix(count)), options: options).compactMap {
            InkImage.render(board.subset($0.ids), rect: $0.rect, maxPixels: options.maxSide)
        }
        return (reused.isEmpty ? "" : reused + "\n", count, pages)
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
        [.tools, .penWidth, .flexibleSpace, .autoCheck, .formula, .document]
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

        case .autoCheck:
            autoCheckButton.style = .split
            autoCheckButton.target = self
            autoCheckButton.action = #selector(toggleAutoCheck(_:))
            autoCheckButton.menu = autoCheckMenu
            // NSComboButton greys out (and won't open) its arrow while the menu is empty, so the
            // menu is kept filled at all times rather than only built when it opens.
            rebuildAutoCheckMenu()
            updateAutoCheckButton()
            item.view = autoCheckButton
            item.label = "自动检查"

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
        case #selector(exportPNG(_:)), #selector(exportPDF(_:)), #selector(clearBoard(_:)):
            return !canvas.board.isEmpty
        case #selector(toggleFormulaCapture(_:)):
            menuItem.state = canvas.isCapturingFormula ? .on : .off
            return true
        case #selector(recognizeBlocks(_:)):
            menuItem.title = LayoutSettings.recognizeTitle
            return canConvertDocument
        case #selector(convertDocument(_:)), #selector(labelBlocks(_:)), #selector(segmentBlocks(_:)):
            return canConvertDocument
        case #selector(toggleAutoCheck(_:)):
            // The 自动检查 menu says 打开 / 关闭 in the title instead.
            if menuItem.menu !== autoCheckMenu { menuItem.state = checker.state.enabled ? .on : .off }
            return true
        case #selector(checkLatestBlock(_:)):
            return checker.state.enabled && checker.latestUnit != nil
        default:
            return true
        }
    }
}

// MARK: - 自动检查

extension MainWindowController: NSPopoverDelegate, NSMenuDelegate {
    private func setUpAutoCheck() {
        autoCheckMenu.delegate = self
        autoCheckMenu.autoenablesItems = true
        checker.onStateChange = { [weak self] state in
            self?.onAutoCheckStateChange?(state)
        }
        checker.onDisplayChange = { [weak self] in
            self?.autoCheckDisplayChanged()
        }
        canvas.onBoardCommit = { [weak self] added in
            guard let self else { return }
            self.checker.boardDidChange(self.canvas.board, addedStroke: added)
        }
        canvas.onAutoCheckAction = { [weak self] action, mark, rect in
            self?.autoCheckAction(action, mark: mark, button: rect)
        }
        observers.append(NotificationCenter.default.addObserver(forName: AISettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.aiSettingsChanged() }
        })
        // 分块方式 changed (InkLayout.defaultOptions is already updated): blocks are found again.
        // AI 识别分块 and its undo / redo reach the checker as board commits (boardDidChange sees
        // that only the groups changed).
        observers.append(NotificationCenter.default.addObserver(forName: LayoutSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checker.layoutDidChange() }
        })
        if let window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.detailsPopover?.close()
                    self?.checker.shutdown()
                }
            })
        }
    }

    private func aiSettingsChanged() {
        let settings = AISettings.current
        let options = settings.pageOptions
        if options.maxSide != checker.pageOptions.maxSide { checker.pageOptions = options }
        if settings.checkSignature != checkSignature {
            checkSignature = settings.checkSignature
            checker.settingsDidChange()
        }
    }

    /// 转换 → 自动检查, the toolbar button and the 打开 / 关闭 items of its menu.
    ///
    /// In「AI 辅助」, switching on while some ink is in no AI group runs AI 识别分块 first, so the
    /// full check judges the AI's blocks (a failure falls back to the blocks found locally;
    /// cancelling, or switching again while it runs, leaves 自动检查 off).
    @objc func toggleAutoCheck(_ sender: Any?) {
        defer { window?.makeFirstResponder(canvas) }
        if enablingAutoCheck {
            cancelDocument()
            return
        }
        if !checker.state.enabled, LayoutSettings.segmentationMode == .aiAssisted, documentTask == nil, hasUngroupedInk {
            enablingAutoCheck = true
            runSegmentation(progress: "正在用 AI 识别分块，完成后开始自动检查…") { [weak self] outcome in
                guard let self else { return }
                self.enablingAutoCheck = false
                switch outcome {
                case .success(let message):
                    self.showSegmentationResult(message)
                case .failure(let error):
                    self.documentBanner.hide()
                    self.showAlert(title: "AI 识别分块失败",
                                   message: error.localizedDescription + "\n\n自动检查将改用本地分块继续。")
                }
                self.checker.setEnabled(true)
            }
            return
        }
        checker.setEnabled(!checker.state.enabled)
    }

    /// 转换 → 检查最新的块 (⇧⌘K).
    @objc func checkLatestBlock(_ sender: Any?) {
        if !checker.checkLatest() { NSSound.beep() }
    }

    private func autoCheckAction(_ action: CanvasView.AutoCheckAction, mark: AutoChecker.Mark, button: CGRect) {
        switch action {
        case .details:
            guard let tag = mark.tag, let check = checker.result(tagged: tag) else { return }
            showDetails(check, mark: mark, button: button)
        case .dismiss:
            if let tag = mark.tag { checker.dismiss(tag: tag) }
        case .recheck, .check:
            checker.check(mark.ids)
        }
    }

    /// 重试 in the 自动检查 menu.
    @objc func retryAutoCheck(_ sender: Any?) {
        checker.retry()
    }

    /// A block in the 自动检查 menu: scrolls it into view and outlines it for a moment.
    @objc func revealAutoCheckBlock(_ sender: Any?) {
        guard let ids = (sender as? NSMenuItem)?.representedObject as? Set<UUID>,
              let unit = checker.unit(sharing: ids) else { NSSound.beep(); return }
        let margin = 48 / max(scrollView.magnification, 0.01)
        canvas.scrollToVisible(unit.bounds.insetBy(dx: -margin, dy: -margin))
        canvas.flashAutoCheckBlock(unit.bounds)
    }

    private func autoCheckDisplayChanged() {
        canvas.autoCheckMarks = checker.marks
        updateAutoCheckButton()
        rebuildAutoCheckMenu()   // never empty: an empty menu disables the button's arrow
        // Progress lives in the toolbar button and its menu; only a failure, which waits for the
        // user, gets a banner over the canvas.
        if let message = checker.failureMessage {
            checkBanner.show("自动检查失败：\(message)", style: .error, button: "重试") { [weak self] in
                self?.checker.retry()
            }
        } else {
            checkBanner.hide()
        }
    }

    // MARK: Toolbar button

    /// Image and tooltip of the toolbar button: off, on, checking, failed.
    private func updateAutoCheckButton() {
        let symbol: [String], color: NSColor?, description: String, tip: String
        if enablingAutoCheck {
            (symbol, color, description) = (["arrow.triangle.2.circlepath", "ellipsis.circle"], .controlAccentColor, "自动检查：正在用 AI 识别分块")
            tip = "正在用 AI 识别分块，完成后开始自动检查\n点按按钮取消"
        } else if !checker.state.enabled {
            (symbol, color, description) = (["checkmark.seal", "checkmark.circle"], nil, "自动检查：关")
            tip = "自动检查已关闭：每写完一个块让 AI 检查错误\n点按按钮打开"
        } else if let message = checker.failureMessage {
            (symbol, color, description) = (["exclamationmark.triangle.fill"], .systemRed, "自动检查：失败")
            tip = "自动检查失败：\(message)\n点按按钮关闭；点按箭头可重试"
        } else if checker.stage != nil {
            (symbol, color, description) = (["arrow.triangle.2.circlepath", "ellipsis.circle"], .controlAccentColor, "自动检查：正在检查")
            let waiting = checker.queuedUnits.count + (checker.fullCheck.map { $0.running ? 0 : $0.units.count } ?? 0)
            tip = "自动检查：" + autoCheckStageText + (waiting > 0 ? "，还有 \(waiting) 个块排队" : "")
                + "\n点按按钮关闭；点按箭头查看进度"
        } else {
            (symbol, color, description) = (["checkmark.seal.fill", "checkmark.circle.fill"], .controlAccentColor, "自动检查：开")
            tip = "自动检查已打开：每写完一个块让 AI 检查错误\n点按按钮关闭；点按箭头查看状态（⇧⌘K 检查最新的块）"
        }
        var image = Self.symbol(symbol, description: description)
        if let color {
            // Filled symbols: a white checkmark / exclamation mark on the tinted shape.
            let palette = symbol[0].hasSuffix(".fill") ? [NSColor.white, color] : [color]
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: palette)) ?? image
        }
        autoCheckButton.image = image
        autoCheckButton.toolTip = tip
        autoCheckButton.setAccessibilityLabel(description)
    }

    /// What the running request does, in a few words.
    private var autoCheckStageText: String {
        let checking = checker.checkingUnits.count
        switch checker.stage {
        case .transcribingPage?: return "正在转写当前页"
        case .laterBlocks(let tags)?: return "正在重新判断后面的 \(tags.count) 个块"
        case .starting? where checking == 0: return "正在准备"
        default: return checking > 1 ? "正在检查 \(checking) 个块" : "正在检查 1 个块"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === autoCheckMenu { rebuildAutoCheckMenu() }
    }

    /// The 自动检查 menu: what is being checked, what waits, the block being written, a failure.
    func rebuildAutoCheckMenu() {
        let menu = autoCheckMenu
        menu.removeAllItems()
        func info(_ title: String, indent: Int = 0) {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = indent
        }
        func block(_ unit: CheckUnit) {
            let item = menu.addItem(withTitle: blockTitle(unit), action: #selector(revealAutoCheckBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = unit.ids
            item.indentationLevel = 1
            item.toolTip = "在画布上显示这个块"
        }
        func section(_ title: String) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            info(title)
        }

        if enablingAutoCheck {
            info("正在用 AI 识别分块，完成后开始自动检查…")
            menu.addItem(.separator())
            menu.addItem(withTitle: "取消", action: #selector(toggleAutoCheck(_:)), keyEquivalent: "").target = self
            return
        }
        guard checker.state.enabled else {
            info("自动检查已关闭")
            menu.addItem(.separator())
            menu.addItem(withTitle: "打开自动检查", action: #selector(toggleAutoCheck(_:)), keyEquivalent: "").target = self
            return
        }

        let checking = checker.checkingUnits
        let queued = checker.queuedUnits
        let fullCheck = checker.fullCheck
        let failure = checker.failureMessage
        let checkingIDs = checking.map(\.ids) + queued.map(\.ids)

        if let stage = checker.stage {
            section("正在检查")
            switch stage {
            case .transcribingPage: info("正在转写并固定当前页…", indent: 1)
            case .laterBlocks(let tags): info("正在重新判断后面的 \(tags.count) 个块", indent: 1)
            case .starting where checking.isEmpty: info("正在准备…", indent: 1)
            default: break
            }
            checking.forEach(block)
            if let fullCheck, fullCheck.running {
                let left = fullCheck.units.filter { unit in !checking.contains { $0.ids == unit.ids } }.count
                if left > 0 { info("还有 \(left) 个块待检查", indent: 1) }
            }
        }

        let queuedFull = fullCheck.flatMap { $0.running ? nil : $0.units.count } ?? 0
        if !queued.isEmpty || queuedFull > 0 {
            section("排队中（\(queued.count + queuedFull)）")
            queued.forEach(block)
            if queuedFull > 0 { info("全部检查（\(queuedFull) 个块）", indent: 1) }
        }

        if checker.stage == nil && queued.isEmpty && queuedFull == 0 && failure == nil {
            info("没有正在检查的块")
        }

        if let writing = checker.writingUnit, !checkingIDs.contains(writing.ids),
           !{ if case .checked = checker.status(of: writing) { return true }; return false }() {
            section("正在书写")
            block(writing)
            let item = menu.addItem(withTitle: "检查最新的块", action: #selector(checkLatestBlock(_:)), keyEquivalent: "k")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
        }

        if let failure {
            section("检查失败")
            let short = failure.count > 60 ? String(failure.prefix(60)) + "…" : failure
            info(short.replacingOccurrences(of: "\n", with: " "), indent: 1)
            menu.addItem(withTitle: "重试", action: #selector(retryAutoCheck(_:)), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭自动检查", action: #selector(toggleAutoCheck(_:)), keyEquivalent: "").target = self
    }

    /// 第 3 块 · 公式, plus the start of what the AI read when it was checked before (tags are
    /// never shown on the canvas, so they mean nothing to the user).
    private func blockTitle(_ unit: CheckUnit) -> String {
        let position = (checker.units.firstIndex { $0.ids == unit.ids } ?? 0) + 1
        var title = "第 \(position) 块 · \(unit.kind.title)"
        let tag: String?
        switch checker.status(of: unit) {
        case .checked(let t), .modified(let t): tag = t
        case .unchecked: tag = nil
        }
        if let tag, let reading = checker.result(tagged: tag)?.reading {
            let flat = reading.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !flat.isEmpty { title += "：" + (flat.count > 24 ? String(flat.prefix(24)) + "…" : flat) }
        }
        return title
    }

    // MARK: 详情

    private func showDetails(_ check: BlockCheck, mark: AutoChecker.Mark, button: CGRect) {
        detailsPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = AutoCheckDetailsViewController(check: check)
        detailsPopover = popover
        // The block itself and the blocks its issues point to.
        var highlights = [(tag: check.tag, rect: mark.bounds)]
        var seen: Set<String> = [check.tag]
        for tag in check.issues.flatMap(\.related) where seen.insert(tag).inserted {
            if let rect = checker.bounds(ofTag: tag) { highlights.append((tag, rect)) }
        }
        canvas.autoCheckHighlights = highlights
        popover.show(relativeTo: button, of: canvas, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === detailsPopover else { return }
        detailsPopover = nil
        canvas.autoCheckHighlights = []
    }
}
