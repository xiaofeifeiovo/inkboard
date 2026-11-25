import AppKit
import InkboardCore

/// The drawing surface. Lives inside an NSScrollView, which provides scrolling and
/// pinch-zoom (magnification); all coordinates here are canvas coordinates (y down).
final class CanvasView: NSView {

    // MARK: - Configuration

    static let minimumCanvasSize = NSSize(width: 3000, height: 4000)
    /// Empty room kept to the right of / below the ink so the canvas can keep growing.
    private static let canvasMargin: CGFloat = 1500
    /// Eraser radius in screen points; it stays the same size on screen at any zoom.
    private static let eraserScreenRadius: CGFloat = 9

    /// Dot grid behind the ink (显示 → 显示点格). App-wide and remembered; on screen only —
    /// exports and AI images are rendered by InkRenderer and never have it.
    static var showsDotGrid: Bool = UserDefaults.standard.object(forKey: dotGridKey) as? Bool ?? true {
        didSet {
            guard showsDotGrid != oldValue else { return }
            UserDefaults.standard.set(showsDotGrid, forKey: dotGridKey)
            NotificationCenter.default.post(name: displayOptionsDidChange, object: nil)
        }
    }
    private static let dotGridKey = "canvas.showsDotGrid"

    /// 显示 → 显示分块: outlines the blocks found by InkLayout (numbered in reading order) and the
    /// pages 全局转换 would send. App-wide, off by default; for checking and tuning the segmentation.
    static var showsBlocks: Bool = UserDefaults.standard.bool(forKey: blocksKey) {
        didSet {
            guard showsBlocks != oldValue else { return }
            UserDefaults.standard.set(showsBlocks, forKey: blocksKey)
            NotificationCenter.default.post(name: displayOptionsDidChange, object: nil)
        }
    }
    private static let blocksKey = "canvas.showsBlocks"
    private static let displayOptionsDidChange = Notification.Name("InkboardDisplayOptionsDidChange")

    // MARK: - Public state

    var tool: Tool = .pen {
        didSet {
            isCapturingFormula = false   // picking any tool (even the current one) ends formula capture
            guard tool != oldValue else { return }
            if tool != .lasso { clearSelection() }
            hoverGuideInvalidate()
            updateCursor()
            onToolChange?(tool)
        }
    }
    var penWidth: CGFloat = PenWidth.medium.value

    var onToolChange: ((Tool) -> Void)?
    /// Called after every committed edit (and undo/redo) — used for autosave.
    var onContentChange: (() -> Void)?
    /// Also called after every committed edit (and undo/redo), with the new stroke's id when the
    /// edit was writing a stroke (自动检查 counts only writing as finishing a block).
    var onBoardCommit: ((_ addedStroke: UUID?) -> Void)?

    /// 自动检查 boxes and buttons (see AutoChecker.Mark). Only an overlay: never touches the ink.
    var autoCheckMarks: [AutoChecker.Mark] = [] {
        didSet { if autoCheckMarks != oldValue { setNeedsDisplay(visibleRect) } }
    }
    /// Blocks highlighted while 详情 is open (the block itself and its 相关 blocks).
    var autoCheckHighlights: [(tag: String, rect: CGRect)] = [] {
        didSet { setNeedsDisplay(visibleRect) }
    }
    /// A block picked in the 自动检查 menu: outlined, then faded out (`flashAutoCheckBlock`).
    private(set) var autoCheckFlash: (rect: CGRect, alpha: CGFloat)? {
        didSet { setNeedsDisplay(visibleRect) }
    }
    private var autoCheckFlashTimer: Timer?
    /// A button of a mark was clicked; `rect` is the button (canvas coordinates).
    var onAutoCheckAction: ((AutoCheckAction, AutoChecker.Mark, CGRect) -> Void)?

    enum AutoCheckAction {
        case details, dismiss, recheck, check
    }

    /// 局部转换 mode: dragging draws a box instead of using the tool; each finished box is
    /// reported through `onFormulaCapture`. The box is only an overlay and never touches the ink.
    var isCapturingFormula = false {
        didSet {
            guard isCapturingFormula != oldValue else { return }
            if isCapturingFormula {
                clearSelection()
            } else {
                if case .capture = gesture { gesture = nil }
                captureRect = nil
                captureBusy = false
            }
            needsDisplay = true
            updateCursor()
            onCaptureModeChange?(isCapturingFormula)
        }
    }
    /// The box being converted is drawn highlighted.
    var captureBusy = false {
        didSet { if captureBusy != oldValue { invalidateCaptureBox() } }
    }
    private(set) var captureRect: CGRect?
    var onFormulaCapture: ((CGRect) -> Void)?
    var onCaptureModeChange: ((Bool) -> Void)?

    /// Pictures and ink. Pictures are drawn under all ink; the eraser and the AI conversions
    /// only deal with ink.
    private(set) var board = Board() {
        didSet { layoutOverlay = nil }
    }
    var strokes: [Stroke] { board.strokes }
    /// Ids of selected strokes and pictures.
    private(set) var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { updateCursor() } }
    }

    /// The selection if there is one, otherwise everything (for export).
    var boardForExport: Board {
        selection.isEmpty ? board : board.subset(selection)
    }

    // MARK: - Gesture state

    private final class LiveStroke {
        var smoother: StrokeSmoother
        var stamper: StrokeGeometry.Stamper
        let committedPath = CGMutablePath()
        let width: CGFloat
        /// Area covered by the provisional tail at the last redraw.
        var tailRect = CGRect.null

        init(width: CGFloat, smoother: StrokeSmoother) {
            self.width = width
            self.smoother = smoother
            self.stamper = StrokeGeometry.Stamper(width: width)
        }
    }

    private struct EraseSession {
        let before: Board
        var last: CGPoint
        var changed = false
    }

    private struct MoveSession {
        let start: CGPoint
        var offset = CGVector.zero
    }

    private struct SpaceSession {
        let lineY: CGFloat
        var delta: CGFloat = 0
        let ids: Set<UUID>
        let minDelta: CGFloat
        let movingBounds: CGRect
    }

    /// Dragging a corner handle of the one selected picture.
    private struct ResizeSession {
        let id: UUID
        let original: CGRect
        let corner: InkOps.Corner
        var frame: CGRect
    }

    private enum Gesture {
        case draw(LiveStroke)
        case erase(EraseSession)
        case lasso([CGPoint])
        case move(MoveSession)
        case resize(ResizeSession)
        case insertSpace(SpaceSession)
        case pan(lastWindowPoint: NSPoint)
        case capture(start: CGPoint, current: CGPoint)
    }

    private var gesture: Gesture?
    private var spaceKeyDown = false
    /// The tablet pen's eraser end is in proximity.
    private var penEraserEnd = false
    private var trackpadPressure: CGFloat?
    private var mouseLocation: CGPoint?
    private var proximityMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var displayObservers: [NSObjectProtocol] = []
    /// Blocks and pages for 显示分块, computed when first drawn after a change; `aiLabels`: the
    /// labels ("3", "3.1") of blocks that come from an AI group.
    private var layoutOverlay: (blocks: [InkBlock], pages: [InkPage], aiLabels: Set<String>)?

    // MARK: - NSView

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var activeTool: Tool { penEraserEnd ? .eraser : tool }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = resignKeyObserver { NotificationCenter.default.removeObserver(observer) }
        resignKeyObserver = nil
        guard let window else { return }
        window.makeFirstResponder(self)
        registerForDraggedTypes(ImagePasteboard.dropTypes)
        // Hover events come from our tracking area (inside the canvas only). Don't set
        // window.acceptsMouseMovedEvents: that routes *every* mouse move to the first responder,
        // even over the toolbar or outside the window, which made the pen cursor stick everywhere.

        // Releasing space while another window is key would otherwise leave us stuck in pan mode.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.spaceKeyDown = false
        }

        if displayObservers.isEmpty {
            // Display options, AI settings (the page size) and 分块方式 for the 显示分块 overlay.
            displayObservers = [Self.displayOptionsDidChange, AISettings.didChange, LayoutSettings.didChange].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.layoutOverlay = nil
                    self?.needsDisplay = true
                }
            }
        }

        // Flipping a Wacom-style pen switches to the eraser while the eraser end is near the tablet.
        if proximityMonitor == nil {
            proximityMonitor = NSEvent.addLocalMonitorForEvents(matching: .tabletProximity) { [weak self] event in
                self?.handleProximity(event)
                return event
            }
        }
    }

    deinit {
        if let monitor = proximityMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = resignKeyObserver { NotificationCenter.default.removeObserver(observer) }
        displayObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // MARK: - Document API

    /// Replaces the content without undo (used when opening the saved board).
    func load(_ newBoard: Board) {
        board = newBoard
        selection = []
        undoManager?.removeAllActions(withTarget: self)
        ensureCanvasSize()
        needsDisplay = true
    }

    func clearAll() {
        guard !board.isEmpty else { return }
        selection = []
        apply(Board(), actionName: "清空画布")
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        selection = []
        apply(board.removing(ids), actionName: "删除")
    }

    override func selectAll(_ sender: Any?) {
        tool = .lasso
        selection = board.ids
        needsDisplay = true
    }

    // MARK: - Pictures

    /// Smallest side a picture can be resized to, in screen points.
    private static let minImageScreenSide: CGFloat = 16
    /// Corner handles of a selected picture, in screen points.
    private static let handleScreenSize: CGFloat = 8

    @objc func paste(_ sender: Any?) {
        if !insertImages(from: .general) { NSSound.beep() }
    }

    /// Inserts the pictures on `pasteboard`, centred on `center` (default: the middle of the view).
    @discardableResult
    func insertImages(from pasteboard: NSPasteboard, centeredAt center: CGPoint? = nil) -> Bool {
        insertImages(ImagePasteboard.imageData(from: pasteboard), centeredAt: center)
    }

    /// Adds pictures as one undoable step. Each comes in at its natural size, scaled down to fit
    /// in the visible area; several are cascaded. They end up selected with the lasso tool, so
    /// they can be moved or resized right away. Returns false when none of the data is an image.
    @discardableResult
    func insertImages(_ datas: [Data], centeredAt center: CGPoint? = nil) -> Bool {
        let prepared = datas.compactMap { ImageImport.prepare($0) }
        let visible = visibleRect.isEmpty ? CGRect(x: 0, y: 0, width: 1200, height: 800) : visibleRect
        let fit = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let step = 24 / magnification
        var center = center ?? CGPoint(x: visible.midX, y: visible.midY)

        var added: [BoardImage] = []
        for item in prepared {
            let scale = min(1, fit.width / item.size.width, fit.height / item.size.height)
            let size = CGSize(width: item.size.width * scale, height: item.size.height * scale)
            let origin = CGPoint(x: max(0, center.x - size.width / 2), y: max(0, center.y - size.height / 2))
            if let image = BoardImage(data: item.data, frame: CGRect(origin: origin, size: size)) {
                added.append(image)
                center.x += step
                center.y += step
            }
        }
        guard !added.isEmpty else { return false }

        var next = board
        next.images += added
        tool = .lasso
        selection = Set(added.map(\.id))
        apply(next, actionName: "插入图片")
        return true
    }

    /// The selected picture when it is the whole selection: it gets corner handles for resizing.
    private var resizableImage: BoardImage? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return board.images.first { $0.id == id }
    }

    private func resizeCorner(at point: CGPoint) -> InkOps.Corner? {
        guard let image = resizableImage else { return nil }
        let reach = Self.handleScreenSize / magnification
        return InkOps.Corner.allCases.first { corner in
            let c = corner.point(in: image.frame)
            return abs(point.x - c.x) <= reach && abs(point.y - c.y) <= reach
        }
    }

    /// Where a picture is drawn right now: following a move, insert-space or resize gesture.
    private func displayFrame(of image: BoardImage) -> CGRect {
        switch gesture {
        case .resize(let session) where session.id == image.id:
            return session.frame
        case .move(let session) where selection.contains(image.id):
            return image.frame.offsetBy(dx: session.offset.dx, dy: session.offset.dy)
        case .insertSpace(let session) where session.ids.contains(image.id):
            return image.frame.offsetBy(dx: 0, dy: session.delta)
        default:
            return image.frame
        }
    }

    // MARK: - Drag & drop (pictures)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImagePasteboard.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        return insertImages(from: sender.draggingPasteboard, centeredAt: point)
    }

    /// Replaces the board's labels (see BlockLabeling) as one undoable step.
    func setLabels(_ labels: [Set<UUID>: InkBlock.Kind]) {
        var next = board
        next.labels = labels
        apply(next, actionName: "识别分块类型")
    }

    /// Replaces the board's AI groups (分块方式「AI 辅助」, see BlockSegmentation) as one undoable step.
    func setGroups(_ groups: [BlockGroup]) {
        var next = board
        next.groups = groups
        apply(next, actionName: "AI 识别分块")
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        setNeedsDisplay(selectionFrame.insetBy(dx: -4, dy: -4))
        selection = []
    }

    // MARK: - Mouse / pen input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = location(of: event)
        mouseLocation = p
        trackpadPressure = nil

        if spaceKeyDown {
            gesture = .pan(lastWindowPoint: event.locationInWindow)
            NSCursor.closedHand.set()
            return
        }

        // 自动检查 buttons come before any tool: no stroke starts on a button.
        if let hit = autoCheckButton(at: p) {
            gesture = nil
            onAutoCheckAction?(hit.action, hit.mark, hit.rect)
            return
        }

        if isCapturingFormula {
            invalidateCaptureBox()
            gesture = .capture(start: p, current: p)
            return
        }

        switch activeTool {
        case .pen:
            clearSelection()
            let mag = magnification
            let smoother = StrokeSmoother(spacing: min(1, max(0.25, 1 / mag)), minInputDistance: 0.5 / mag)
            let live = LiveStroke(width: penWidth, smoother: smoother)
            gesture = .draw(live)
            addSample(from: event, to: live)

        case .eraser:
            clearSelection()
            var session = EraseSession(before: board, last: p)
            erase(from: p, to: p, session: &session)
            gesture = .erase(session)

        case .lasso:
            if let image = resizableImage, let corner = resizeCorner(at: p) {
                gesture = .resize(ResizeSession(id: image.id, original: image.frame, corner: corner, frame: image.frame))
                Self.resizeCursor(for: corner).set()
            } else if !selection.isEmpty, selectionFrame.contains(p) {
                gesture = .move(MoveSession(start: p))
                NSCursor.closedHand.set()
            } else {
                clearSelection()
                gesture = .lasso([p])
            }

        case .insertSpace:
            clearSelection()
            let ids = InkOps.itemsBelow(p.y, in: board)
            gesture = .insertSpace(SpaceSession(
                lineY: p.y, ids: ids,
                minDelta: InkOps.minimumSpaceDelta(lineY: p.y, moving: ids, in: board),
                movingBounds: board.bounds(of: ids)))
            setNeedsDisplay(visibleRect)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(of: event)
        mouseLocation = p
        guard let gesture else { return }

        switch gesture {
        case .draw(let live):
            addSample(from: event, to: live)

        case .erase(var session):
            erase(from: session.last, to: p, session: &session)
            session.last = p
            self.gesture = .erase(session)

        case .lasso(var points):
            guard let last = points.last, hypot(p.x - last.x, p.y - last.y) * magnification >= 2 else { return }
            points.append(p)
            self.gesture = .lasso(points)
            setNeedsDisplay(InkOps.boundingRect(of: points).insetBy(dx: -4 / magnification, dy: -4 / magnification))
            autoscroll(with: event)

        case .move(var session):
            let old = selectionFrame.offsetBy(dx: session.offset.dx, dy: session.offset.dy)
            session.offset = CGVector(dx: p.x - session.start.x, dy: p.y - session.start.y)
            self.gesture = .move(session)
            let new = selectionFrame.offsetBy(dx: session.offset.dx, dy: session.offset.dy)
            setNeedsDisplay(old.union(new).insetBy(dx: -4, dy: -4))
            autoscroll(with: event)

        case .resize(var session):
            let old = session.frame
            session.frame = InkOps.resize(session.original, dragging: session.corner, to: p,
                                          minSide: Self.minImageScreenSide / magnification)
            self.gesture = .resize(session)
            let pad = Self.handleScreenSize / magnification + 2
            setNeedsDisplay(old.union(session.frame).insetBy(dx: -pad, dy: -pad))
            autoscroll(with: event)

        case .insertSpace(var session):
            session.delta = max(session.minDelta, p.y - session.lineY)
            self.gesture = .insertSpace(session)
            if !session.movingBounds.isNull {
                let needed = session.movingBounds.maxY + session.delta + Self.canvasMargin
                if needed > frame.height { setFrameSize(NSSize(width: frame.width, height: needed)) }
            }
            setNeedsDisplay(visibleRect)
            autoscroll(with: event)

        case .pan(let lastWindowPoint):
            pan(by: event.locationInWindow, from: lastWindowPoint)
            self.gesture = .pan(lastWindowPoint: event.locationInWindow)

        case .capture(let start, _):
            invalidateCaptureBox()
            self.gesture = .capture(start: start, current: p)
            invalidateCaptureBox()
            autoscroll(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        self.gesture = nil
        trackpadPressure = nil

        switch gesture {
        case .draw(let live):
            let points = live.smoother.finish()
            guard !points.isEmpty else { return }
            let stroke = Stroke(points: points, width: live.width)
            setNeedsDisplay(stroke.bounds.union(live.tailRect).insetBy(dx: -2, dy: -2))
            var next = board
            next.strokes.append(stroke)
            apply(next, actionName: "书写", addedStroke: stroke.id)

        case .erase(let session):
            if session.changed {
                registerUndo(restoring: session.before, actionName: "擦除")
                contentDidChange()
            }

        case .lasso(let points):
            let area = InkOps.boundingRect(of: points)
            if max(area.width, area.height) * magnification < 4 {
                // A tap selects the stroke (or else the picture) under the pointer.
                let hit = InkOps.hitTest(points[0], in: board, tolerance: 4 / magnification)
                selection = hit.map { [$0] } ?? []
            } else {
                selection = InkOps.selection(inLasso: points, in: board)
            }
            setNeedsDisplay(area.union(selectionFrame).insetBy(dx: -8, dy: -8))

        case .move(let session):
            if session.offset != .zero {
                apply(InkOps.translate(board, ids: selection, dx: session.offset.dx, dy: session.offset.dy),
                      actionName: "移动")
            }

        case .resize(let session):
            let pad = Self.handleScreenSize / magnification + 2
            setNeedsDisplay(session.original.union(session.frame).insetBy(dx: -pad, dy: -pad))
            if session.frame != session.original, let i = board.images.firstIndex(where: { $0.id == session.id }) {
                var next = board
                next.images[i].frame = session.frame
                apply(next, actionName: "调整图片大小")
            }

        case .insertSpace(let session):
            if session.delta != 0, !session.ids.isEmpty {
                apply(InkOps.translate(board, ids: session.ids, dx: 0, dy: session.delta),
                      actionName: session.delta > 0 ? "插入空间" : "删除空间")
            }
            setNeedsDisplay(visibleRect)

        case .pan:
            break

        case .capture(let start, let end):
            let box = Self.rect(from: start, to: end)
            setNeedsDisplay(box.insetBy(dx: -4 / magnification, dy: -4 / magnification))
            // A click (no real box) keeps the previous box.
            guard min(box.width, box.height) * magnification >= 6 else { invalidateCaptureBox(); break }
            invalidateCaptureBox()
            captureRect = box
            invalidateCaptureBox()
            onFormulaCapture?(box)
        }
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = location(of: event)
        if tool == .insertSpace { hoverGuideInvalidate() }
        mouseLocation = p
        if tool == .insertSpace { hoverGuideInvalidate() }
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        hoverGuideInvalidate()
        mouseLocation = nil
        if gesture == nil { updateCursor() }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    /// Force Touch trackpads report pressure separately from drag events.
    override func pressureChange(with event: NSEvent) {
        guard case .draw = gesture else { return }
        let p = CGFloat(event.pressure)
        trackpadPressure = event.stage >= 2 ? 0.85 + 0.15 * p : 0.25 + 0.6 * p
    }

    private func handleProximity(_ event: NSEvent) {
        let eraserEnd = event.isEnteringProximity && event.pointingDeviceType == .eraser
        guard eraserEnd != penEraserEnd else { return }
        penEraserEnd = eraserEnd
        if eraserEnd { clearSelection() }
        updateCursor()
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func pressure(of event: NSEvent) -> CGFloat {
        if event.subtype == .tabletPoint {
            return max(0.02, CGFloat(event.pressure))     // tablet / Sidecar Apple Pencil
        }
        return trackpadPressure ?? 0.6                    // mouse: constant medium pressure
    }

    // MARK: - Pen

    private func addSample(from event: NSEvent, to live: LiveStroke) {
        let sample = InkPoint(location(of: event), pressure: pressure(of: event))
        let added = live.smoother.add(sample)
        let output = live.smoother.output
        for point in output[added] {
            live.stamper.append(point, to: live.committedPath)
        }

        let pad = StrokeGeometry.maxRadius(width: live.width) + 2
        var fresh = Array(live.smoother.tail)
        if let last = output.last { fresh.append(last) }
        let tailRect = StrokeGeometry.bounds(of: fresh, width: live.width).insetBy(dx: -pad, dy: -pad)
        var dirty = live.tailRect.union(tailRect)
        if !added.isEmpty {
            let lo = max(0, added.lowerBound - 1)
            dirty = dirty.union(StrokeGeometry.bounds(of: Array(output[lo..<added.upperBound]), width: live.width)
                .insetBy(dx: -pad, dy: -pad))
        }
        live.tailRect = tailRect
        setNeedsDisplay(dirty)
    }

    // MARK: - Eraser

    private func erase(from a: CGPoint, to b: CGPoint, session: inout EraseSession) {
        let radius = Self.eraserScreenRadius / magnification
        guard let result = InkOps.erase(board.strokes, from: a, to: b, radius: radius) else { return }
        board.strokes = result.strokes
        session.changed = true
        setNeedsDisplay(result.dirty.insetBy(dx: -2, dy: -2))
    }

    // MARK: - Panning (hold space)

    private func pan(by windowPoint: NSPoint, from lastWindowPoint: NSPoint) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let mag = magnification
        var origin = clip.bounds.origin
        origin.x -= (windowPoint.x - lastWindowPoint.x) / mag
        origin.y += (windowPoint.y - lastWindowPoint.y) / mag   // window is y-up, canvas is y-down
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // space: hold to pan
            if !spaceKeyDown {
                spaceKeyDown = true
                updateCursor()
            }
            return
        case 51, 117: // delete, forward delete
            deleteSelection()
            return
        case 53: // escape
            if isCapturingFormula { isCapturingFormula = false } else { clearSelection() }
            return
        default:
            break
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let newTool = Tool.allCases.first(where: { $0.shortcut == key }) {
            tool = newTool
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceKeyDown = false
            updateCursor()
        } else {
            super.keyUp(with: event)
        }
    }

    // MARK: - Undo & canvas size

    /// Commits a new board as one undoable step.
    private func apply(_ newBoard: Board, actionName: String, addedStroke: UUID? = nil) {
        let old = board
        board = newBoard
        setNeedsDisplay(visibleRect)
        registerUndo(restoring: old, actionName: actionName)
        contentDidChange(addedStroke: addedStroke)
    }

    private func registerUndo(restoring old: Board, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { view in
            let current = view.board
            view.board = old
            view.selection = view.selection.intersection(old.ids)
            view.setNeedsDisplay(view.visibleRect)
            view.registerUndo(restoring: current, actionName: actionName)   // becomes the redo
            view.contentDidChange()
        }
        undoManager.setActionName(actionName)
    }

    private func contentDidChange(addedStroke: UUID? = nil) {
        ensureCanvasSize()
        if Self.showsBlocks { setNeedsDisplay(visibleRect) }   // blocks can change anywhere
        onContentChange?()
        onBoardCommit?(addedStroke)
    }

    /// Grows the canvas so there is always room to keep writing right and below the content.
    private func ensureCanvasSize() {
        let content = board.bounds
        var size = frame.size
        size.width = max(size.width, Self.minimumCanvasSize.width, content.isNull ? 0 : content.maxX + Self.canvasMargin)
        size.height = max(size.height, Self.minimumCanvasSize.height, content.isNull ? 0 : content.maxY + Self.canvasMargin)
        if size != frame.size { setFrameSize(size) }
    }

    // MARK: - Drawing

    private var selectionBounds: CGRect {
        board.bounds(of: selection)
    }

    /// The dashed frame around the selection; dragging inside it moves the selection.
    private var selectionFrame: CGRect {
        let b = selectionBounds
        return b.isNull ? .null : b.insetBy(dx: -6 / magnification, dy: -6 / magnification)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let mag = magnification
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(dirtyRect)
        if Self.showsDotGrid { drawDotGrid(in: dirtyRect, ctx: ctx, magnification: mag) }

        // Pictures, under all ink.
        for image in board.images {
            let frame = displayFrame(of: image)
            if frame.intersects(dirtyRect) { InkRenderer.draw(image.image, in: frame, ctx: ctx) }
        }

        var moving: Set<UUID> = []
        var movingOffset = CGVector.zero
        switch gesture {
        case .move(let session):
            moving = selection
            movingOffset = session.offset
        case .insertSpace(let session):
            moving = session.ids
            movingOffset = CGVector(dx: 0, dy: session.delta)
            drawSpaceBand(session, ctx: ctx, accent: accent, magnification: mag)
        default:
            break
        }

        // Resting ink, filled in one pass.
        let resting = strokes.filter { !selection.contains($0.id) && !moving.contains($0.id) }
        InkRenderer.fill(resting, in: ctx, clip: dirtyRect)

        // Ink being pushed by insert-space.
        if case .insertSpace = gesture {
            ctx.saveGState()
            ctx.translateBy(x: movingOffset.dx, y: movingOffset.dy)
            InkRenderer.fill(strokes.filter { moving.contains($0.id) }, in: ctx,
                             clip: dirtyRect.offsetBy(dx: -movingOffset.dx, dy: -movingOffset.dy))
            ctx.restoreGState()
        }

        // Selection: accent-coloured ink, outlined pictures and a dashed frame, following a drag.
        // A lone picture gets corner handles for resizing instead of the frame.
        if !selection.isEmpty {
            ctx.saveGState()
            if case .move = gesture { ctx.translateBy(x: movingOffset.dx, y: movingOffset.dy) }
            InkRenderer.fill(strokes.filter { selection.contains($0.id) }, in: ctx, color: accent)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(2 / mag)
            for image in board.images where selection.contains(image.id) {
                let frame: CGRect
                if case .resize(let session) = gesture, session.id == image.id { frame = session.frame } else { frame = image.frame }
                ctx.stroke(frame.insetBy(dx: -1 / mag, dy: -1 / mag))
            }
            if let image = resizableImage {
                let frame: CGRect
                if case .resize(let session) = gesture { frame = session.frame } else { frame = image.frame }
                drawHandles(around: frame, ctx: ctx, accent: accent, magnification: mag)
            } else {
                ctx.setLineWidth(1 / mag)
                ctx.setLineDash(phase: 0, lengths: [5 / mag, 4 / mag])
                ctx.stroke(selectionFrame)
            }
            ctx.restoreGState()
        }

        // Live pen stroke: finalised part + provisional tail.
        if case .draw(let live) = gesture {
            ctx.addPath(live.committedPath)
            let tailPath = CGMutablePath()
            var stamper = live.stamper
            for point in live.smoother.tail { stamper.append(point, to: tailPath) }
            stamper.finish(in: tailPath)
            ctx.addPath(tailPath)
            ctx.setFillColor(InkRenderer.inkColor)
            ctx.fillPath(using: .winding)
        }

        // Lasso outline.
        if case .lasso(let points) = gesture, points.count > 1 {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(accent.copy(alpha: 0.06) ?? accent)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.2 / mag)
            ctx.setLineDash(phase: 0, lengths: [4 / mag, 3 / mag])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // 局部转换 box: the one being dragged, else the last one.
        if isCapturingFormula {
            if case .capture(let start, let end) = gesture {
                drawCaptureBox(Self.rect(from: start, to: end), busy: false, dashed: true, ctx: ctx, accent: accent, magnification: mag)
            } else if let box = captureRect {
                drawCaptureBox(box, busy: captureBusy, dashed: false, ctx: ctx, accent: accent, magnification: mag)
            }
        }

        // Insert-space hover guide.
        if gesture == nil, !isCapturingFormula, activeTool == .insertSpace, let hover = mouseLocation {
            drawHorizontalLine(at: hover.y, ctx: ctx, color: accent, width: 1 / mag, dashed: [6 / mag, 4 / mag])
        }

        if Self.showsBlocks { drawLayoutOverlay(ctx: ctx, magnification: mag) }
        drawAutoCheckOverlay(ctx: ctx, magnification: mag, dirtyRect: dirtyRect)
    }

    // MARK: - 显示分块 overlay

    private func drawLayoutOverlay(ctx: CGContext, magnification mag: CGFloat) {
        if layoutOverlay == nil {
            let blocks = InkLayout.analyze(board).blocks
            var aiLabels: Set<String> = []
            for (i, block) in blocks.enumerated() {
                if Self.isAIGrouped(block, in: board) { aiLabels.insert("\(i + 1)") }
                for (j, child) in block.children.enumerated() where Self.isAIGrouped(child, in: board) {
                    aiLabels.insert("\(i + 1).\(j + 1)")
                }
            }
            layoutOverlay = (blocks, PageAssembler.pages(for: blocks, options: AISettings.current.pageOptions), aiLabels)
        }
        guard let overlay = layoutOverlay else { return }

        ctx.saveGState()
        let grey = CGColor(gray: 0.45, alpha: 0.9)
        for (i, page) in overlay.pages.enumerated() {
            ctx.setStrokeColor(grey)
            ctx.setLineWidth(1 / mag)
            ctx.setLineDash(phase: 0, lengths: [8 / mag, 5 / mag])
            ctx.stroke(page.rect)
            ctx.setLineDash(phase: 0, lengths: [])
            drawTag("第 \(i + 1) 页", at: CGPoint(x: page.rect.maxX, y: page.rect.minY), alignRight: true,
                    color: grey, magnification: mag)
        }
        for (i, block) in overlay.blocks.enumerated() {
            drawBlockOutline(block, label: "\(i + 1)", ai: overlay.aiLabels.contains("\(i + 1)"), dashed: false,
                             ctx: ctx, magnification: mag)
            for (j, child) in block.children.enumerated() {
                let label = "\(i + 1).\(j + 1)"
                drawBlockOutline(child, label: label, ai: overlay.aiLabels.contains(label), dashed: true, ctx: ctx, magnification: mag)
            }
        }
        ctx.restoreGState()
    }

    /// A block made from an AI group (分块方式「AI 辅助」): most of its ink is in one `Board.groups` entry.
    static func isAIGrouped(_ block: InkBlock, in board: Board) -> Bool {
        guard InkLayout.defaultOptions.useGroups, block.imageIDs.isEmpty, !block.strokeIDs.isEmpty else { return false }
        let ids = Set(block.strokeIDs)
        return board.groups.contains { $0.ids.intersection(ids).count * 2 > ids.count }
    }

    /// Outline, line boxes and tag ("3 公式", "3 公式 · AI" for a block from an AI group).
    private func drawBlockOutline(_ block: InkBlock, label: String, ai: Bool, dashed: Bool, ctx: CGContext,
                                  magnification mag: CGFloat) {
        let color = block.kind.overlayColor
        let frame = block.bounds.insetBy(dx: -3 / mag, dy: -3 / mag)
        ctx.setFillColor(color.copy(alpha: 0.07) ?? color)
        ctx.fill(frame)
        ctx.setStrokeColor(color.copy(alpha: 0.35) ?? color)
        ctx.setLineWidth(0.75 / mag)
        for line in block.lines { ctx.stroke(line.bounds) }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5 / mag)
        if dashed { ctx.setLineDash(phase: 0, lengths: [4 / mag, 3 / mag]) }
        ctx.stroke(frame)
        ctx.setLineDash(phase: 0, lengths: [])
        drawTag("\(label) \(block.kind.title)" + (ai ? " · AI" : ""), at: CGPoint(x: frame.minX, y: frame.minY), alignRight: false,
                color: color, magnification: mag)
    }

    /// A small label sitting on top of a frame's corner; constant size on screen.
    private func drawTag(_ text: String, at corner: CGPoint, alignRight: Bool, color: CGColor, magnification mag: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10 / mag, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padX = 3 / mag, padY = 1 / mag
        let width = size.width + 2 * padX, height = size.height + 2 * padY
        var tag = CGRect(x: alignRight ? corner.x - width : corner.x, y: corner.y - height, width: width, height: height)
        if tag.minY < bounds.minY { tag.origin.y = corner.y }   // no room above: inside the frame
        NSColor(cgColor: color)?.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 2 / mag, yRadius: 2 / mag).fill()
        string.draw(at: CGPoint(x: tag.minX + padX, y: tag.minY + padY))
    }

    private func drawDotGrid(in rect: CGRect, ctx: CGContext, magnification mag: CGFloat) {
        var spacing: CGFloat = 24
        while spacing * mag < 14 { spacing *= 2 }
        let size = 1.6 / mag
        let path = CGMutablePath()
        var x = (rect.minX / spacing).rounded(.down) * spacing
        while x <= rect.maxX + spacing {
            var y = (rect.minY / spacing).rounded(.down) * spacing
            while y <= rect.maxY + spacing {
                path.addRect(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
                y += spacing
            }
            x += spacing
        }
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.80, alpha: 1))
        ctx.fillPath()
    }

    private func drawSpaceBand(_ session: SpaceSession, ctx: CGContext, accent: CGColor, magnification mag: CGFloat) {
        let visible = visibleRect
        if session.delta != 0 {
            let band = CGRect(x: visible.minX, y: min(session.lineY, session.lineY + session.delta),
                              width: visible.width, height: abs(session.delta))
            let tint = session.delta > 0 ? accent : CGColor(srgbRed: 1, green: 0.25, blue: 0.2, alpha: 1)
            ctx.setFillColor(tint.copy(alpha: 0.08) ?? tint)
            ctx.fill(band)
            drawHorizontalLine(at: session.lineY + session.delta, ctx: ctx, color: accent, width: 1 / mag, dashed: [6 / mag, 4 / mag])
        }
        drawHorizontalLine(at: session.lineY, ctx: ctx, color: accent, width: 1.5 / mag, dashed: nil)
    }

    private func drawHorizontalLine(at y: CGFloat, ctx: CGContext, color: CGColor, width: CGFloat, dashed: [CGFloat]?) {
        let visible = visibleRect
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        if let dashed { ctx.setLineDash(phase: 0, lengths: dashed) }
        ctx.move(to: CGPoint(x: visible.minX, y: y))
        ctx.addLine(to: CGPoint(x: visible.maxX, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawHandles(around frame: CGRect, ctx: CGContext, accent: CGColor, magnification mag: CGFloat) {
        let side = Self.handleScreenSize / mag
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(1 / mag)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setStrokeColor(accent)
        for corner in InkOps.Corner.allCases {
            let c = corner.point(in: frame)
            let handle = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            ctx.fill(handle)
            ctx.stroke(handle)
        }
        ctx.restoreGState()
    }

    private func drawCaptureBox(_ box: CGRect, busy: Bool, dashed: Bool, ctx: CGContext, accent: CGColor, magnification mag: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(accent.copy(alpha: busy ? 0.14 : 0.05) ?? accent)
        ctx.fill(box)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5 / mag)
        if dashed { ctx.setLineDash(phase: 0, lengths: [5 / mag, 4 / mag]) }
        ctx.stroke(box)
        ctx.restoreGState()
    }

    /// Marks the area of the current capture box (dragged or settled) for redraw.
    private func invalidateCaptureBox() {
        var box = captureRect ?? .null
        if case .capture(let start, let end) = gesture { box = box.union(Self.rect(from: start, to: end)) }
        guard !box.isNull else { return }
        let pad = 4 / magnification
        setNeedsDisplay(box.insetBy(dx: -pad, dy: -pad))
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func hoverGuideInvalidate() {
        guard let y = mouseLocation?.y else { return }
        let visible = visibleRect
        let pad = 3 / magnification
        setNeedsDisplay(CGRect(x: visible.minX, y: y - pad, width: visible.width, height: 2 * pad))
    }

    // MARK: - Cursors

    /// The cursor is global: whatever is set stays until someone sets another one. So the tool
    /// cursor is only shown while the pointer is over the visible canvas, and when it isn't
    /// (e.g. a drag ended outside the window) a cursor we set is handed back as the arrow.
    private func updateCursor() {
        guard let window, window.isKeyWindow else { return }
        if isPointerOverCanvas(in: window) {
            cursor(at: mouseLocation).set()
        } else if Self.canvasCursors.contains(where: { $0 === NSCursor.current }) {
            NSCursor.arrow.set()
        }
    }

    private func isPointerOverCanvas(in window: NSWindow) -> Bool {
        // Another window (another app, a sheet, a panel) may be covering the canvas.
        guard NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private static var canvasCursors: [NSCursor] {
        [penCursor, eraserCursor, .crosshair, .resizeUpDown, .openHand, .closedHand,
         diagonalResizeCursors.down, diagonalResizeCursors.up]
    }

    /// ↖↘ and ↗↙ cursors for picture corner handles (macOS 15+; a crosshair before that).
    private static let diagonalResizeCursors: (down: NSCursor, up: NSCursor) = {
        if #available(macOS 15, *) {
            return (NSCursor.frameResize(position: .topLeft, directions: .all),
                    NSCursor.frameResize(position: .topRight, directions: .all))
        }
        return (.crosshair, .crosshair)
    }()

    private static func resizeCursor(for corner: InkOps.Corner) -> NSCursor {
        switch corner {
        case .topLeft, .bottomRight: return diagonalResizeCursors.down
        case .topRight, .bottomLeft: return diagonalResizeCursors.up
        }
    }

    private func cursor(at point: CGPoint?) -> NSCursor {
        if spaceKeyDown { return .openHand }
        if let point, autoCheckButton(at: point) != nil { return .arrow }
        if isCapturingFormula { return .crosshair }
        switch activeTool {
        case .pen:
            return Self.penCursor
        case .eraser:
            return Self.eraserCursor
        case .lasso:
            if let point, let corner = resizeCorner(at: point) { return Self.resizeCursor(for: corner) }
            if let point, !selection.isEmpty, selectionFrame.contains(point) { return .openHand }
            return .crosshair
        case .insertSpace:
            return .resizeUpDown
        }
    }

    private static let penCursor: NSCursor = {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 4.5, y: 4.5))
    }()

    private static let eraserCursor: NSCursor = {
        let d = eraserScreenRadius * 2 + 2
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(white: 1, alpha: 0.6).setFill()
            circle.fill()
            NSColor(white: 0.35, alpha: 1).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: d / 2, y: d / 2))
    }()
}

extension CanvasView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)): return !selection.isEmpty
        case #selector(selectAll(_:)): return !board.isEmpty
        case #selector(paste(_:)): return ImagePasteboard.canRead(.general)
        default: return true
        }
    }
}

extension InkBlock.Kind {
    var title: String {
        switch self {
        case .text: return "文字"
        case .formula: return "公式"
        case .drawing: return "手绘图"
        case .diagram: return "示意图"
        case .image: return "图片"
        case .figure: return "图片+墨迹"
        }
    }

    fileprivate var overlayColor: CGColor {
        switch self {
        case .text: return CGColor(srgbRed: 0.24, green: 0.47, blue: 0.85, alpha: 1)
        case .formula: return CGColor(srgbRed: 0.58, green: 0.32, blue: 0.85, alpha: 1)
        case .drawing: return CGColor(srgbRed: 0.93, green: 0.52, blue: 0.12, alpha: 1)
        case .diagram: return CGColor(srgbRed: 0.18, green: 0.62, blue: 0.33, alpha: 1)
        case .image: return CGColor(srgbRed: 0.08, green: 0.58, blue: 0.68, alpha: 1)
        case .figure: return CGColor(srgbRed: 0.85, green: 0.28, blue: 0.5, alpha: 1)
        }
    }
}

// MARK: - 自动检查 overlay

extension CanvasView {
    /// A button below the bottom-right corner of a mark's box.
    fileprivate struct AutoCheckButton {
        let action: AutoCheckAction
        let title: String
        let rect: CGRect
        let fontSize: CGFloat
        let color: CGColor
        let mark: AutoChecker.Mark
    }

    private static let checkRed = CGColor(srgbRed: 0.86, green: 0.13, blue: 0.11, alpha: 1)
    /// Yellow leaning to orange, so it reads on white.
    private static let checkYellow = CGColor(srgbRed: 0.93, green: 0.56, blue: 0.0, alpha: 1)
    private static let checkGrey = CGColor(gray: 0.5, alpha: 1)
    private static let checkBlue = CGColor(srgbRed: 0.22, green: 0.45, blue: 0.78, alpha: 1)

    private static func color(of mark: AutoChecker.Mark) -> CGColor {
        switch mark.kind {
        case .issue(.error): return checkRed
        case .issue(.warning): return checkYellow
        case .modifiedBox, .recheck: return checkGrey
        case .check: return checkBlue
        }
    }

    /// The box drawn around a unit (and the corner the buttons hang from).
    private func autoCheckBox(_ mark: AutoChecker.Mark, magnification mag: CGFloat) -> CGRect {
        mark.bounds.insetBy(dx: -4 / mag, dy: -4 / mag)
    }

    /// Buttons of a mark, right-aligned under its box; constant size on screen.
    fileprivate func autoCheckButtons(for mark: AutoChecker.Mark, magnification mag: CGFloat) -> [AutoCheckButton] {
        let items: [(String, AutoCheckAction)]
        var small = false
        switch mark.kind {
        case .issue: items = [("详情", .details), ("忽视", .dismiss), ("重新检查", .recheck)]
        case .modifiedBox, .recheck: items = [("重新检查", .recheck)]
        case .check: items = [("检查", .check)]; small = true
        }
        let fontSize = (small ? 10 : 11) / mag
        let height = (small ? 16 : 19) / mag
        let padX = 6 / mag, gap = 4 / mag
        let box = autoCheckBox(mark, magnification: mag)
        let color = Self.color(of: mark)
        let widths = items.map { Self.buttonTitle($0.0, fontSize: fontSize, color: color).size().width + 2 * padX }
        // Right-aligned with the box; a row wider than the box starts at its left edge instead.
        let total = widths.reduce(0, +) + gap * CGFloat(items.count - 1)
        var right = max(box.maxX, box.minX + total)
        let top = box.maxY + 3 / mag
        var buttons: [AutoCheckButton] = []
        for ((title, action), width) in zip(items, widths).reversed() {
            let rect = CGRect(x: right - width, y: top, width: width, height: height)
            buttons.insert(AutoCheckButton(action: action, title: title, rect: rect, fontSize: fontSize, color: color, mark: mark), at: 0)
            right -= width + gap
        }
        return buttons
    }

    private static func buttonTitle(_ title: String, fontSize: CGFloat, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor(cgColor: color) ?? .labelColor,
        ])
    }

    /// A mark's buttons as laid out at the current zoom: titles and canvas rects.
    func autoCheckButtonFrames(for mark: AutoChecker.Mark) -> [(title: String, rect: CGRect)] {
        autoCheckButtons(for: mark, magnification: magnification).map { ($0.title, $0.rect) }
    }

    /// The button under `point`.
    fileprivate func autoCheckButton(at point: CGPoint) -> AutoCheckButton? {
        let mag = magnification
        for mark in autoCheckMarks.reversed() {
            if let button = autoCheckButtons(for: mark, magnification: mag).first(where: { $0.rect.contains(point) }) {
                return button
            }
        }
        return nil
    }

    /// Outlines a block for a moment (picked in the 自动检查 menu); fades out after about 2 s.
    /// Only an overlay: never touches the ink or the undo stack.
    func flashAutoCheckBlock(_ rect: CGRect) {
        autoCheckFlashTimer?.invalidate()
        autoCheckFlash = (rect, 1)
        let start = Date()
        let hold: TimeInterval = 1.4, fade: TimeInterval = 0.6
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(start)
            guard t > hold else { return }
            let alpha = 1 - (t - hold) / fade
            if alpha <= 0 {
                timer.invalidate()
                self.autoCheckFlashTimer = nil
                self.autoCheckFlash = nil
            } else {
                self.autoCheckFlash?.alpha = CGFloat(alpha)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCheckFlashTimer = timer
    }

    fileprivate func drawAutoCheckOverlay(ctx: CGContext, magnification mag: CGFloat, dirtyRect: CGRect) {
        guard !autoCheckMarks.isEmpty || !autoCheckHighlights.isEmpty || autoCheckFlash != nil else { return }
        ctx.saveGState()
        // 详情 open: its block and the related ones.
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? Self.checkBlue
        for highlight in autoCheckHighlights {
            drawHighlight(highlight.rect, tag: highlight.tag, color: accent, ctx: ctx, magnification: mag)
        }
        if let flash = autoCheckFlash {
            drawHighlight(flash.rect, tag: nil, color: accent.copy(alpha: flash.alpha) ?? accent, ctx: ctx, magnification: mag)
        }

        for mark in autoCheckMarks {
            let box = autoCheckBox(mark, magnification: mag)
            let color = Self.color(of: mark)
            switch mark.kind {
            case .issue:
                ctx.setFillColor(color.copy(alpha: 0.05) ?? color)
                ctx.fill(box)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(2 / mag)
                ctx.stroke(box)
            case .modifiedBox:
                ctx.setStrokeColor(color)
                ctx.setLineWidth(1.5 / mag)
                ctx.setLineDash(phase: 0, lengths: [5 / mag, 4 / mag])
                ctx.stroke(box)
                ctx.setLineDash(phase: 0, lengths: [])
            case .recheck, .check:
                break
            }
            for button in autoCheckButtons(for: mark, magnification: mag) where button.rect.intersects(dirtyRect) {
                let path = CGPath(roundedRect: button.rect, cornerWidth: 4 / mag, cornerHeight: 4 / mag, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.97))
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(button.color.copy(alpha: 0.85) ?? button.color)
                ctx.setLineWidth(1 / mag)
                ctx.strokePath()
                let title = Self.buttonTitle(button.title, fontSize: button.fontSize, color: button.color)
                let size = title.size()
                title.draw(at: CGPoint(x: button.rect.midX - size.width / 2, y: button.rect.midY - size.height / 2))
            }
        }
        ctx.restoreGState()
    }

    /// A tinted, outlined frame around a block, with its tag above the corner when there is one.
    private func drawHighlight(_ rect: CGRect, tag: String?, color: CGColor, ctx: CGContext, magnification mag: CGFloat) {
        let frame = rect.insetBy(dx: -6 / mag, dy: -6 / mag)
        ctx.setFillColor(color.copy(alpha: 0.12 * color.alpha) ?? color)
        ctx.fill(frame)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5 / mag)
        ctx.stroke(frame)
        if let tag {
            drawTag(tag, at: CGPoint(x: frame.minX, y: frame.minY), alignRight: false, color: color, magnification: mag)
        }
    }
}
