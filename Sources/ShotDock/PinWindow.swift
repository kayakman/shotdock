import AppKit
import ShotDockCore

/// A capture pinned above every window. Drag to move, scroll or pinch to
/// zoom, ⌥-scroll or 1–9 for opacity, Esc or double-click to close.
@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate {
    let image: CGImage
    let scale: CGFloat
    /// How agents name it (`shotdock pins`).
    let id = UUID()
    /// The capture it shows, if it came from the history.
    var libraryItemID: UUID?
    private let pinView: PinView
    var onClose: ((PinWindowController) -> Void)?

    private(set) var zoom: CGFloat = 1
    var opacity: CGFloat {
        get { window?.alphaValue ?? 1 }
        set { window?.alphaValue = min(max(newValue, 0.15), 1) }
    }

    init(image: CGImage, scale: CGFloat, near screenPoint: CGPoint? = nil) {
        self.image = image
        self.scale = scale
        pinView = PinView(image: image)
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let panel = PinPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        panel.minSize = NSSize(width: 40, height: 40 * size.height / max(size.width, 1))
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = pinView
        pinView.controller = self
        place(size: size, near: screenPoint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func place(size: NSSize, near point: CGPoint?) {
        guard let window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(point ?? NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        // Too big for the screen: start zoomed out.
        let fit = min(1, visible.width * 0.8 / size.width, visible.height * 0.8 / size.height)
        zoom = fit
        let shown = NSSize(width: size.width * fit, height: size.height * fit)
        var origin = point.map { CGPoint(x: $0.x, y: $0.y - shown.height) } ?? CGPoint(x: visible.midX - shown.width / 2, y: visible.midY - shown.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - shown.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - shown.height)
        window.setFrame(CGRect(origin: origin, size: shown), display: true)
    }

    /// Moves the window so its top-left corner is at `point` (AppKit coordinates).
    func move(topLeft point: CGPoint) {
        guard let window else { return }
        window.setFrameTopLeftPoint(point)
    }

    func show() {
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    /// Zooms around the window centre.
    func setZoom(_ value: CGFloat) {
        guard let window else { return }
        let base = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        zoom = min(max(value, 0.1), 8)
        let size = NSSize(width: base.width * zoom, height: base.height * zoom)
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        window.setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                        display: true, animate: false)
    }

    var clickThrough: Bool {
        get { window?.ignoresMouseEvents ?? false }
        set {
            window?.ignoresMouseEvents = newValue
            pinView.needsDisplay = true
        }
    }

    func copyImage() {
        Pasteboard.copy(image, scale: scale)
        HUD.show(String(localized: "Copied"), symbol: "checkmark.circle.fill")
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        zoom = window.frame.width / (CGFloat(image.width) / scale)
    }

    func windowWillClose(_ notification: Notification) { onClose?(self) }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(menuCopy), keyEquivalent: "c").target = self
        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(percent) %", action: #selector(menuOpacity(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = abs(opacity * 100 - CGFloat(percent)) < 5 ? .on : .off
            opacityMenu.addItem(item)
        }
        menu.addItem(withTitle: String(localized: "Opacity"), action: nil, keyEquivalent: "").submenu = opacityMenu
        let zoomMenu = NSMenu()
        for percent in [50, 100, 200] {
            let item = NSMenuItem(title: "\(percent) %", action: #selector(menuZoom(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = abs(zoom * 100 - CGFloat(percent)) < 2 ? .on : .off
            zoomMenu.addItem(item)
        }
        menu.addItem(withTitle: String(localized: "Zoom"), action: nil, keyEquivalent: "").submenu = zoomMenu
        menu.addItem(withTitle: String(localized: "Let Clicks Through"), action: #selector(menuClickThrough), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close"), action: #selector(menuClose), keyEquivalent: "").target = self
        return menu
    }

    @objc private func menuCopy() { copyImage() }
    @objc private func menuOpacity(_ sender: NSMenuItem) { opacity = CGFloat(sender.tag) / 100 }
    @objc private func menuZoom(_ sender: NSMenuItem) { setZoom(CGFloat(sender.tag) / 100) }
    @objc private func menuClickThrough() {
        clickThrough = true
        HUD.show(String(localized: "Clicks go through the image. Get it back from the ShotDock menu."), symbol: "cursorarrow.motionlines")
    }
    @objc private func menuClose() { close() }
}

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PinView: NSView {
    let image: CGImage
    weak var controller: PinWindowController?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = bounds.width > CGFloat(image.width) ? .none : .high
        context.draw(image, in: bounds)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.2).cgColor)
        context.setLineWidth(1)
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { controller?.close() } else { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        if event.modifierFlags.contains(.option) {
            controller.opacity += delta
        } else {
            controller.setZoom(controller.zoom * (1 + delta))
        }
    }

    override func magnify(with event: NSEvent) {
        guard let controller else { return }
        controller.setZoom(controller.zoom * (1 + event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        let characters = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 53 { return controller.close() }  // Esc
        if event.modifierFlags.contains(.command), characters == "c" { return controller.copyImage() }
        if let digit = Int(characters), event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            controller.opacity = digit == 0 ? 1 : CGFloat(digit) / 10
            return
        }
        switch characters {
        case "+", "=": controller.setZoom(controller.zoom * 1.25)
        case "-": controller.setZoom(controller.zoom / 1.25)
        default: super.keyDown(with: event)
        }
    }
}
