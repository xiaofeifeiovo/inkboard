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

    // MARK: - Public state

    var tool: Tool = .pen {
        didSet {
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

    private(set) var strokes: [Stroke] = []
    private(set) var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { updateCursor() } }
    }

    /// The selection if there is one, otherwise everything (for export / transcription).
    var strokesForExport: [Stroke] {
        selection.isEmpty ? strokes : strokes.filter { selection.contains($0.id) }
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
        let before: [Stroke]
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

    private enum Gesture {
        case draw(LiveStroke)
        case erase(EraseSession)
        case lasso([CGPoint])
        case move(MoveSession)
        case insertSpace(SpaceSession)
        case pan(lastWindowPoint: NSPoint)
    }

    private var gesture: Gesture?
    private var spaceKeyDown = false
    /// The tablet pen's eraser end is in proximity.
    private var penEraserEnd = false
    private var trackpadPressure: CGFloat?
    private var mouseLocation: CGPoint?
    private var proximityMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?

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
        // Hover events come from our tracking area (inside the canvas only). Don't set
        // window.acceptsMouseMovedEvents: that routes *every* mouse move to the first responder,
        // even over the toolbar or outside the window, which made the pen cursor stick everywhere.

        // Releasing space while another window is key would otherwise leave us stuck in pan mode.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.spaceKeyDown = false
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
    func load(_ newStrokes: [Stroke]) {
        strokes = newStrokes
        selection = []
        undoManager?.removeAllActions(withTarget: self)
        ensureCanvasSize()
        needsDisplay = true
    }

    func clearAll() {
        guard !strokes.isEmpty else { return }
        selection = []
        apply([], actionName: "清空画布")
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        selection = []
        apply(strokes.filter { !ids.contains($0.id) }, actionName: "删除")
    }

    override func selectAll(_ sender: Any?) {
        tool = .lasso
        selection = Set(strokes.map(\.id))
        needsDisplay = true
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
            var session = EraseSession(before: strokes, last: p)
            erase(from: p, to: p, session: &session)
            gesture = .erase(session)

        case .lasso:
            if !selection.isEmpty, selectionFrame.contains(p) {
                gesture = .move(MoveSession(start: p))
                NSCursor.closedHand.set()
            } else {
                clearSelection()
                gesture = .lasso([p])
            }

        case .insertSpace:
            clearSelection()
            let ids = InkOps.strokesBelow(p.y, in: strokes)
            let moving = strokes.filter { ids.contains($0.id) }
            gesture = .insertSpace(SpaceSession(
                lineY: p.y, ids: ids,
                minDelta: InkOps.minimumSpaceDelta(lineY: p.y, moving: ids, in: strokes),
                movingBounds: moving.unionBounds))
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
            apply(strokes + [stroke], actionName: "书写")

        case .erase(let session):
            if session.changed {
                registerUndo(restoring: session.before, actionName: "擦除")
                contentDidChange()
            }

        case .lasso(let points):
            let area = InkOps.boundingRect(of: points)
            if max(area.width, area.height) * magnification < 4 {
                // A tap selects the stroke under the pointer.
                let hit = InkOps.hitTest(points[0], in: strokes, tolerance: 4 / magnification)
                selection = hit.map { [$0] } ?? []
            } else {
                selection = InkOps.strokes(inLasso: points, from: strokes)
            }
            setNeedsDisplay(area.union(selectionFrame).insetBy(dx: -8, dy: -8))

        case .move(let session):
            if session.offset != .zero {
                apply(InkOps.translate(strokes, ids: selection, dx: session.offset.dx, dy: session.offset.dy),
                      actionName: "移动")
            }

        case .insertSpace(let session):
            if session.delta != 0, !session.ids.isEmpty {
                apply(InkOps.translate(strokes, ids: session.ids, dx: 0, dy: session.delta),
                      actionName: session.delta > 0 ? "插入空间" : "删除空间")
            }
            setNeedsDisplay(visibleRect)

        case .pan:
            break
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
        guard let result = InkOps.erase(strokes, from: a, to: b, radius: radius) else { return }
        strokes = result.strokes
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
            clearSelection()
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

    /// Commits a new stroke list as one undoable step.
    private func apply(_ newStrokes: [Stroke], actionName: String) {
        let old = strokes
        strokes = newStrokes
        setNeedsDisplay(visibleRect)
        registerUndo(restoring: old, actionName: actionName)
        contentDidChange()
    }

    private func registerUndo(restoring old: [Stroke], actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { view in
            let current = view.strokes
            view.strokes = old
            view.selection = view.selection.intersection(old.map(\.id))
            view.setNeedsDisplay(view.visibleRect)
            view.registerUndo(restoring: current, actionName: actionName)   // becomes the redo
            view.contentDidChange()
        }
        undoManager.setActionName(actionName)
    }

    private func contentDidChange() {
        ensureCanvasSize()
        onContentChange?()
    }

    /// Grows the canvas so there is always room to keep writing right and below the ink.
    private func ensureCanvasSize() {
        let content = strokes.unionBounds
        var size = frame.size
        size.width = max(size.width, Self.minimumCanvasSize.width, content.isNull ? 0 : content.maxX + Self.canvasMargin)
        size.height = max(size.height, Self.minimumCanvasSize.height, content.isNull ? 0 : content.maxY + Self.canvasMargin)
        if size != frame.size { setFrameSize(size) }
    }

    // MARK: - Drawing

    private var selectionBounds: CGRect {
        strokes.lazy.filter { self.selection.contains($0.id) }.reduce(CGRect.null) { $0.union($1.bounds) }
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
        drawDotGrid(in: dirtyRect, ctx: ctx, magnification: mag)

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

        // Selection: accent-coloured ink plus a dashed frame, following a drag.
        if !selection.isEmpty {
            ctx.saveGState()
            if case .move = gesture { ctx.translateBy(x: movingOffset.dx, y: movingOffset.dy) }
            InkRenderer.fill(strokes.filter { selection.contains($0.id) }, in: ctx, color: accent)
            let frame = selectionFrame
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1 / mag)
            ctx.setLineDash(phase: 0, lengths: [5 / mag, 4 / mag])
            ctx.stroke(frame)
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

        // Insert-space hover guide.
        if gesture == nil, activeTool == .insertSpace, let hover = mouseLocation {
            drawHorizontalLine(at: hover.y, ctx: ctx, color: accent, width: 1 / mag, dashed: [6 / mag, 4 / mag])
        }
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
        [penCursor, eraserCursor, .crosshair, .resizeUpDown, .openHand, .closedHand]
    }

    private func cursor(at point: CGPoint?) -> NSCursor {
        if spaceKeyDown { return .openHand }
        switch activeTool {
        case .pen:
            return Self.penCursor
        case .eraser:
            return Self.eraserCursor
        case .lasso:
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
        case #selector(selectAll(_:)): return !strokes.isEmpty
        default: return true
        }
    }
}
