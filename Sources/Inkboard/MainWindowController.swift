import AppKit
import InkboardCore
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let tools = NSToolbarItem.Identifier("tools")
    static let penWidth = NSToolbarItem.Identifier("penWidth")
    static let transcribe = NSToolbarItem.Identifier("transcribe")
}

/// One window per BoardDocument. The document sets the title (file name + "Edited"),
/// and the window uses the document's undo manager.
final class MainWindowController: NSWindowController {
    let canvas = CanvasView(frame: NSRect(origin: .zero, size: CanvasView.minimumCanvasSize))
    private let scrollView = NSScrollView()
    private let toolControl = NSSegmentedControl()
    private let widthControl = NSSegmentedControl()
    private let transcriber: HandwritingTranscriber

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
        window?.contentView = scrollView

        canvas.onToolChange = { [weak self] tool in
            self?.toolControl.selectedSegment = tool.rawValue
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

    /// AI hook: renders the selection (or the whole board) and asks the transcriber for Markdown.
    @objc func transcribeToMarkdown(_ sender: Any?) {
        guard let request = TranscriptionRequest(strokes: canvas.strokesForExport) else { NSSound.beep(); return }
        let transcriber = self.transcriber
        Task { @MainActor [weak self] in
            do {
                let markdown = try await transcriber.transcribeToMarkdown(request)
                self?.saveMarkdown(markdown)
            } catch {
                self?.showAlert(title: "无法转写为 Markdown", message: error.localizedDescription)
            }
        }
    }

    private func saveMarkdown(_ markdown: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = exportBaseName + ".md"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try markdown.write(to: url, atomically: true, encoding: .utf8) } catch { NSApp.presentError(error) }
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
        [.tools, .penWidth, .flexibleSpace, .transcribe]
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

        case .transcribe:
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "转写为 Markdown")
            item.label = "转写 MD"
            item.toolTip = "AI 转写为 Markdown（接口已预留，尚未接入）"
            item.isBordered = true
            item.target = self
            item.action = #selector(transcribeToMarkdown(_:))

        default:
            return nil
        }
        return item
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
        case #selector(exportPNG(_:)), #selector(transcribeToMarkdown(_:)), #selector(clearBoard(_:)):
            return !canvas.strokes.isEmpty
        default:
            return true
        }
    }
}
