import AppKit
import ShotDockCore

/// A full-screen panel showing a frozen display. Non-activating so it takes
/// keyboard focus without pulling the user out of the app they are in.
final class OverlayPanel: NSPanel {
    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screenFrame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the user drag a rectangle over frozen snapshots of every display and
/// returns the selected pixels.
@MainActor
final class AreaSelectionController {
    struct Result {
        let image: CGImage
        let scale: CGFloat
        /// Selection in AppKit global coordinates (points).
        let screenRect: CGRect
    }

    enum Mode { case area, window }

    enum Outcome {
        case area(Result)
        case window(ScreenCapturer.WindowInfo)
    }

    private var panels: [OverlayPanel] = []
    private var completion: ((Outcome?) -> Void)?
    private let windows: [ScreenCapturer.WindowInfo]
    private(set) var mode: Mode
    /// Window under the pointer in window mode.
    private(set) var hoveredWindow: ScreenCapturer.WindowInfo?

    init(snapshots: [DisplaySnapshot], windows: [ScreenCapturer.WindowInfo] = [], mode: Mode = .area,
         completion: @escaping (Outcome?) -> Void) {
        self.completion = completion
        self.windows = windows
        self.mode = windows.isEmpty ? .area : mode
        for snapshot in snapshots {
            let panel = OverlayPanel(screenFrame: snapshot.frame)
            let view = SelectionView(snapshot: snapshot, controller: self)
            view.onFinish = { [weak self] rect in self?.finish(snapshot: snapshot, viewRect: rect) }
            view.onCancel = { [weak self] in self?.finish(snapshot: snapshot, viewRect: nil) }
            panel.contentView = view
            panels.append(panel)
        }
    }

    /// Space switches between dragging an area and picking a window.
    func toggleMode() {
        guard !windows.isEmpty else { return }
        mode = mode == .area ? .window : .area
        updateHover(at: NSEvent.mouseLocation)
    }

    func updateHover(at screenPoint: CGPoint) {
        let hovered = mode == .window ? windows.first { $0.frame.contains(screenPoint) } : nil
        if hovered?.window.windowID != hoveredWindow?.window.windowID || mode == .area {
            hoveredWindow = hovered
            for view in selectionViews { view.needsDisplay = true }
        }
    }

    func pickHoveredWindow() {
        guard let window = hoveredWindow, let completion else { return }
        self.completion = nil
        close()
        completion(.window(window))
    }

    private func close() {
        NSCursor.pop()
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    var selectionViews: [SelectionView] { panels.compactMap { $0.contentView as? SelectionView } }

    func show() {
        for panel in panels { panel.orderFrontRegardless() }
        // Focus the display under the pointer so Esc works right away.
        let mouse = NSEvent.mouseLocation
        let focused = panels.first { $0.frame.contains(mouse) } ?? panels.first
        focused?.makeKey()
        focused?.makeFirstResponder(focused?.contentView)
        NSCursor.crosshair.push()
        updateHover(at: mouse)
    }

    private func finish(snapshot: DisplaySnapshot, viewRect: CGRect?) {
        guard let completion else { return }
        self.completion = nil
        close()

        guard let viewRect else { return completion(nil) }
        let pixelRect = CGRect(x: viewRect.minX * snapshot.scale, y: viewRect.minY * snapshot.scale,
                               width: viewRect.width * snapshot.scale, height: viewRect.height * snapshot.scale)
            .pixelAligned
            .intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = snapshot.image.cropping(to: pixelRect) else { return completion(nil) }
        // View coordinates are top-left; AppKit screen coordinates are bottom-left.
        let screenRect = CGRect(x: snapshot.frame.minX + viewRect.minX,
                                y: snapshot.frame.maxY - viewRect.maxY,
                                width: viewRect.width, height: viewRect.height)
        completion(.area(Result(image: cropped, scale: snapshot.scale, screenRect: screenRect)))
    }
}

final class SelectionView: NSView {
    let snapshot: DisplaySnapshot
    private weak var controller: AreaSelectionController?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var anchor: CGPoint?
    private var current: CGPoint?
    private var pointer: CGPoint?

    init(snapshot: DisplaySnapshot, controller: AreaSelectionController) {
        self.snapshot = snapshot
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var selection: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(corner: anchor, corner: current).intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.drawImageTopLeft(snapshot.image, in: bounds)

        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        if controller?.mode == .window {
            drawWindowHighlight(in: context)
        } else if let selection, selection.width > 0, selection.height > 0 {
            context.addRect(bounds)
            context.addRect(selection)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
            drawSizeLabel(for: selection, in: context)
        } else {
            context.fill(bounds)
            if let pointer { drawCrosshair(at: pointer, in: context) }
        }
    }

    /// Converts a frame in AppKit global coordinates to this view (top-left origin).
    private func viewRect(fromScreen frame: CGRect) -> CGRect {
        CGRect(x: frame.minX - snapshot.frame.minX, y: snapshot.frame.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    private func drawWindowHighlight(in context: CGContext) {
        guard let window = controller?.hoveredWindow else { return context.fill(bounds) }
        let rect = viewRect(fromScreen: window.frame)
        context.addRect(bounds)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(3)
        context.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
        if !window.title.isEmpty, rect.intersects(bounds) {
            drawLabel(window.title, near: rect.intersection(bounds), in: context)
        }
    }

    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        let x = floor(point.x) + 0.5, y = floor(point.y) + 0.5
        context.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: bounds.height),
                                             CGPoint(x: 0, y: y), CGPoint(x: bounds.width, y: y)])
        context.setLineDash(phase: 0, lengths: [])
    }

    private func drawSizeLabel(for selection: CGRect, in context: CGContext) {
        let width = Int((selection.width * snapshot.scale).rounded())
        let height = Int((selection.height * snapshot.scale).rounded())
        drawLabel("\(width) × \(height)", near: selection, in: context)
    }

    private func drawLabel(_ string: String, near selection: CGRect, in context: CGContext) {
        let text = string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var box = CGRect(x: selection.minX, y: selection.maxY + 6, width: size.width + 12, height: size.height + 6)
        if box.maxY > bounds.maxY { box.origin.y = selection.minY - box.height - 6 }
        if box.minY < bounds.minY { box.origin.y = selection.minY + 6 }
        box.origin.x = min(max(box.minX, bounds.minX + 4), bounds.maxX - box.width - 4)
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
        text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if let window { controller?.updateHover(at: window.convertPoint(toScreen: event.locationInWindow)) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if controller?.mode == .window {
            if let window { controller?.updateHover(at: window.convertPoint(toScreen: event.locationInWindow)) }
            controller?.pickHoveredWindow()
            return
        }
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        if let selection, selection.width >= 2, selection.height >= 2 {
            onFinish?(selection)
        } else {
            anchor = nil
            current = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                     // Esc
        case 49: controller?.toggleMode()        // Space
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
