import AppKit
import ShotDockCore

/// Runs captures from start to finish: grab the pixels (freezing the screens
/// first when the user has to select), then copy, save and/or edit them as
/// the preferences say.
@MainActor
final class CaptureCoordinator {
    private(set) var selection: AreaSelectionController?
    private(set) var editors: [EditorWindowController] = []
    private var isCapturing = false
    private var settings: AppSettings { .shared }

    // MARK: Capture modes

    func captureArea() {
        run { try await self.select(mode: .area) }
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

    private func select(mode: AreaSelectionController.Mode) async throws {
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        let windows = (try? await ScreenCapturer.pickableWindows()) ?? []
        beginSelection(over: snapshots, windows: windows, mode: mode)
    }

    func beginSelection(over snapshots: [DisplaySnapshot], windows: [ScreenCapturer.WindowInfo] = [],
                        mode: AreaSelectionController.Mode = .area) {
        isCapturing = true
        let controller = AreaSelectionController(snapshots: snapshots, windows: windows, mode: mode) { [weak self] outcome in
            guard let self else { return }
            selection = nil
            switch outcome {
            case let .area(result):
                isCapturing = false
                settings.lastArea = result.screenRect
                finish(CaptureDocument(image: result.image, scale: result.scale))
            case let .window(info):
                Task {
                    do { try await self.capture(info) } catch { self.showError(error) }
                    self.isCapturing = false
                }
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
        var done: [String] = []
        if settings.copyAfterCapture, Pasteboard.copy(document.image, scale: document.scale) { done.append("Copiado") }
        if settings.saveAfterCapture {
            do {
                let url = try save(document.image, scale: document.scale, date: document.createdAt)
                done.append("Guardado en \(url.deletingLastPathComponent().lastPathComponent)")
            } catch {
                showError(error)
            }
        }
        if settings.openEditorAfterCapture {
            openEditor(with: document)
        } else if !done.isEmpty {
            HUD.show(done.joined(separator: " · "), symbol: "checkmark.circle.fill")
        }
    }

    @discardableResult
    func save(_ image: CGImage, scale: CGFloat, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        let url = settings.autoSaveURL(for: date)
        try ImageEncoding.write(image, to: url, format: settings.imageFormat, scale: scale)
        return url
    }

    @discardableResult
    func openEditor(with document: CaptureDocument) -> EditorWindowController {
        let editor = EditorWindowController(document: document, coordinator: self)
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
