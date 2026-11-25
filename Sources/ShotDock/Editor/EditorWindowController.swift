import AppKit
import ShotDockCore
import SwiftUI
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    let canvas: CanvasView
    private let scrollView = NSScrollView()
    private weak var coordinator: CaptureCoordinator?
    /// The history entry this editor writes its changes to.
    let libraryItemID: UUID?
    var onClose: ((EditorWindowController) -> Void)?

    init(document: CaptureDocument, coordinator: CaptureCoordinator? = nil, libraryItemID: UUID? = nil) {
        self.coordinator = coordinator
        self.libraryItemID = libraryItemID
        model = EditorModel(document: document)
        canvas = CanvasView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = CaptureNaming.defaultName(for: document.createdAt)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        buildContent()
        model.onDocumentChange = { [weak self] in
            guard let self else { return }
            canvas.syncGeometry()
            if let libraryItemID { LibraryStore.shared.scheduleUpdate(libraryItemID, with: model.document) }
        }
        sizeWindowToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }
        let toolbar = NSHostingView(rootView: EditorToolbar(
            model: model,
            onSave: { [weak self] in self?.saveDocument(nil) },
            onPin: { [weak self] in self?.pinImage(nil) },
            onRecognize: { [weak self] in self?.recognizeText(nil) }))
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 16
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true

        let content = NSView()
        content.addSubview(toolbar)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.contentMinSize = NSSize(width: 1040, height: 240)
    }

    /// Opens at 100 % when the capture fits the screen, otherwise zoomed out to fit.
    private func sizeWindowToFit() {
        guard let window else { return }
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let toolbarHeight: CGFloat = 44
        let margin: CGFloat = 24
        let imageSize = canvas.frame.size
        let available = CGSize(width: screen.width * 0.9 - margin * 2,
                               height: screen.height * 0.9 - toolbarHeight - margin * 2)
        let fit = min(1, available.width / imageSize.width, available.height / imageSize.height)
        scrollView.magnification = fit
        let contentSize = NSSize(width: max(1040, imageSize.width * fit + margin * 2),
                                 height: max(240, imageSize.height * fit + toolbarHeight + margin * 2))
        window.setContentSize(contentSize)
        window.center()
    }

    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    // MARK: Actions (reached through the responder chain from the main menu)

    @objc func copy(_ sender: Any?) {
        canvas.commitTextEditing()
        model.copyToClipboard()
    }

    /// ⌘S: straight to the folder and name pattern from the preferences.
    @objc func saveDocument(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let coordinator, let image = model.flattened() else { return saveDocumentAs(sender) }
        do {
            let url = try coordinator.save(image, scale: model.document.scale, date: model.document.createdAt)
            if let libraryItemID { LibraryStore.shared.markSaved(libraryItemID, at: url) }
            model.flash("Guardado: \(url.lastPathComponent)")
        } catch {
            window.map { NSAlert(error: error).beginSheetModal(for: $0) }
        }
    }

    /// ⇧⌘S: asks where.
    @objc func saveDocumentAs(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let window, let image = model.flattened() else { return }
        let settings = AppSettings.shared
        let format = settings.imageFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = settings.autoSaveURL(for: model.document.createdAt).lastPathComponent
        panel.directoryURL = settings.saveFolder
        panel.beginSheetModal(for: window) { [model] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ImageEncoding.write(image, to: url, format: format, scale: model.document.scale)
                model.flash("Guardado")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Pins the edited image where the editor is and closes the editor.
    @objc func pinImage(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let image = model.flattened(), let window else { return }
        let topLeft = CGPoint(x: window.frame.minX + 20, y: window.frame.maxY - 60)
        coordinator?.pin(image, scale: model.document.scale, near: topLeft)
        window.performClose(nil)
    }

    @objc func recognizeText(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let image = model.flattened(), let window else { return }
        RecognitionPanel.present(for: image, on: window)
    }

    @objc func zoomToActualSize(_ sender: Any?) { scrollView.animator().magnification = 1 }
    @objc func zoomIn(_ sender: Any?) { scrollView.animator().magnification *= 1.5 }
    @objc func zoomOut(_ sender: Any?) { scrollView.animator().magnification /= 1.5 }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

    func windowWillClose(_ notification: Notification) {
        canvas.commitTextEditing()
        if let libraryItemID { LibraryStore.shared.update(libraryItemID, with: model.document) }
        onClose?(self)
    }
}

/// Keeps a document smaller than the viewport centred instead of pinned to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let documentFrame = documentView.frame
        if rect.width > documentFrame.width { rect.origin.x = (documentFrame.width - rect.width) / 2 }
        if rect.height > documentFrame.height { rect.origin.y = (documentFrame.height - rect.height) / 2 }
        return rect
    }
}
