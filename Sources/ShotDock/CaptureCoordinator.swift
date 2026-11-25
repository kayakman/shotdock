import AppKit
import ShotDockCore

/// Runs captures from start to finish: grab the pixels (freezing the screens
/// first when the user has to select), then copy, save and/or edit them as
/// the preferences say.
@MainActor
final class CaptureCoordinator {
    private(set) var selection: AreaSelectionController?
    private(set) var editors: [EditorWindowController] = []
    private(set) var pins: [PinWindowController] = []
    private var isCapturing = false
    /// What the next selection is for.
    private var purpose: Purpose = .capture
    enum Purpose { case capture, recognize }
    private var settings: AppSettings { .shared }

    // MARK: Capture modes

    func captureArea() {
        run { try await self.select(mode: .area) }
    }

    /// Select an area, read its text (or QR code) and copy it.
    func recognizeText() {
        run { try await self.select(mode: .area, purpose: .recognize) }
    }

    func captureWindow() {
        run { try await self.select(mode: .window) }
    }

    func captureActiveWindow() {
        run {
            guard let window = try await ScreenCapturer.activeWindow() else { return try await self.select(mode: .window) }
            try await self.capture(window)
        }
    }

    func captureFullscreen() {
        run {
            let snapshot = try await ScreenCapturer.snapshotDisplay(containing: NSEvent.mouseLocation)
            self.finish(CaptureDocument(image: snapshot.image, scale: snapshot.scale))
        }
    }

    func repeatArea() {
        guard let area = settings.lastArea else { return captureArea() }
        run {
            let snapshot = try await ScreenCapturer.snapshotDisplay(containing: CGPoint(x: area.midX, y: area.midY))
            guard let image = Self.crop(snapshot, toScreenRect: area) else { return try await self.select(mode: .area) }
            self.finish(CaptureDocument(image: image, scale: snapshot.scale))
        }
    }

    /// Freezes the screen and copies the colour of the clicked pixel.
    func pickColor() {
        run { try await self.select(mode: .color) }
    }

    func captureDelayed() {
        guard !isCapturing, ensurePermission() else { return }
        isCapturing = true
        Task {
            let go = await HUD.countdown(seconds: settings.captureDelay)
            isCapturing = false
            if go { captureArea() }
        }
    }

    // MARK: Steps

    private func run(_ body: @escaping () async throws -> Void) {
        guard !isCapturing, ensurePermission() else { return }
        isCapturing = true
        Task {
            do { try await body() } catch { showError(error) }
            if selection == nil { isCapturing = false }
        }
    }

    private func select(mode: AreaSelectionController.Mode, purpose: Purpose = .capture) async throws {
        self.purpose = purpose
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        let windows = (try? await ScreenCapturer.pickableWindows()) ?? []
        beginSelection(over: snapshots, windows: windows, mode: mode)
    }

    func beginSelection(over snapshots: [DisplaySnapshot], windows: [ScreenCapturer.WindowInfo] = [],
                        mode: AreaSelectionController.Mode = .area, purpose: Purpose? = nil) {
        if let purpose { self.purpose = purpose }
        isCapturing = true
        let controller = AreaSelectionController(snapshots: snapshots, windows: windows, mode: mode) { [weak self] outcome in
            guard let self else { return }
            selection = nil
            switch outcome {
            case let .area(result):
                isCapturing = false
                if purpose == .recognize { return recognize(result.image) }
                settings.lastArea = result.screenRect
                finish(CaptureDocument(image: result.image, scale: result.scale))
            case let .window(info):
                Task {
                    do { try await self.capture(info) } catch { self.showError(error) }
                    self.isCapturing = false
                }
            case let .color(color):
                isCapturing = false
                copyColor(color)
            case nil:
                isCapturing = false
            }
        }
        selection = controller
        controller.show()
    }

    private func capture(_ info: ScreenCapturer.WindowInfo) async throws {
        let (image, scale) = try await ScreenCapturer.capture(window: info.window, shadow: settings.windowShadow)
        finish(CaptureDocument(image: image, scale: scale))
    }

    static func crop(_ snapshot: DisplaySnapshot, toScreenRect rect: CGRect) -> CGImage? {
        let local = CGRect(x: rect.minX - snapshot.frame.minX, y: snapshot.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        let pixels = CGRect(x: local.minX * snapshot.scale, y: local.minY * snapshot.scale,
                            width: local.width * snapshot.scale, height: local.height * snapshot.scale)
            .pixelAligned
            .intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return snapshot.image.cropping(to: pixels)
    }

    /// What happens to every new capture, per the preferences.
    func finish(_ document: CaptureDocument) {
        let itemID = LibraryStore.shared.add(document)
        var done: [String] = []
        if settings.copyAfterCapture, Pasteboard.copy(document.image, scale: document.scale) { done.append("Copiado") }
        if settings.saveAfterCapture {
            do {
                let url = try save(document.image, scale: document.scale, date: document.createdAt)
                if let itemID { LibraryStore.shared.markSaved(itemID, at: url) }
                done.append("Guardado en \(url.deletingLastPathComponent().lastPathComponent)")
            } catch {
                showError(error)
            }
        }
        if settings.openEditorAfterCapture {
            openEditor(with: document, libraryItem: itemID)
        } else if !done.isEmpty {
            HUD.show(done.joined(separator: " · "), symbol: "checkmark.circle.fill")
        }
    }

    /// OCR for the global shortcut: copies a QR payload if there is one, else the text.
    func recognize(_ image: CGImage) {
        purpose = .capture
        // The first OCR after installing can take a while (Vision loads its models).
        HUD.show("Reconociendo texto…", symbol: "text.viewfinder", for: .seconds(60))
        Task {
            do {
                let result = try await TextRecognition.recognize(image)
                HUD.hide()
                onRecognized?(image, result)
                let pasteboard = NSPasteboard.general
                if let code = result.codes.first {
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)
                    HUD.show("Código QR copiado: \(code.prefix(60))", symbol: "qrcode", for: .seconds(2.5))
                } else if !result.lines.isEmpty {
                    let text = result.text(joinLines: settings.ocrJoinLines)
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    HUD.show("Texto copiado (\(text.count) caracteres)", symbol: "text.viewfinder")
                } else {
                    HUD.show("No se ha encontrado texto", symbol: "exclamationmark.triangle")
                }
            } catch {
                HUD.hide()
                showError(error)
            }
        }
    }

    /// Selftest hook: sees every global OCR result.
    var onRecognized: ((CGImage, RecognitionResult) -> Void)?

    // MARK: Pins

    @discardableResult
    func pin(_ image: CGImage, scale: CGFloat, near point: CGPoint? = nil) -> PinWindowController {
        let pin = PinWindowController(image: image, scale: scale, near: point)
        pin.onClose = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
        pins.append(pin)
        pin.show()
        return pin
    }

    func closeAllPins() { pins.forEach { $0.close() } }

    func restorePinClicks() { pins.forEach { $0.clickThrough = false } }

    func copyColor(_ color: RGBAColor) {
        let text = settings.colorFormat.string(for: color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        HUD.show("Copiado \(text)", symbol: "eyedropper")
    }

    @discardableResult
    func save(_ image: CGImage, scale: CGFloat, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        let url = settings.autoSaveURL(for: date)
        try ImageEncoding.write(image, to: url, format: settings.imageFormat, scale: scale)
        return url
    }

    /// Reopens a capture from the history, or brings its editor forward.
    func openEditor(libraryItem id: UUID) {
        if let open = editors.first(where: { $0.libraryItemID == id }) { return open.show() }
        guard let document = LibraryStore.shared.document(id) else { return }
        openEditor(with: document, libraryItem: id)
    }

    @discardableResult
    func openEditor(with document: CaptureDocument, libraryItem: UUID? = nil) -> EditorWindowController {
        let editor = EditorWindowController(document: document, coordinator: self, libraryItemID: libraryItem)
        editor.onClose = { [weak self] closed in self?.editors.removeAll { $0 === closed } }
        editors.append(editor)
        editor.show()
        return editor
    }

    // MARK: Errors

    private func ensurePermission() -> Bool {
        if ScreenCapturer.hasPermission { return true }
        ScreenCapturer.requestPermission()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "ShotDock necesita permiso de Grabación de pantalla"
        alert.informativeText = "Actívalo en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y vuelve a intentarlo."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    private func showError(_ error: Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }
}
