import AppKit
import ScreenCaptureKit
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
    enum Purpose { case capture, recognize, scroll }
    private var settings: AppSettings { .shared }

    // MARK: Capture modes

    func captureArea() {
        run { try await self.select(mode: .area) }
    }

    private(set) var scrollSession: ScrollCaptureSession?

    /// Select an area, then scroll: the frames become one tall capture.
    func captureScrolling() {
        run { try await self.select(mode: .area, purpose: .scroll) }
    }

    func startScrolling(_ result: AreaSelectionController.Result, frameSource: ScrollCaptureSession.FrameSource? = nil) {
        let source = frameSource ?? { try await ScreenCapturer.capture(rect: result.screenRect, displayID: result.displayID) }
        isCapturing = true
        let session = ScrollCaptureSession(area: result.screenRect, scale: result.scale, firstFrame: result.image,
                                           maxHeight: settings.scrollMaxHeight, frameSource: source) { [weak self] image in
            guard let self else { return }
            scrollSession = nil
            isCapturing = false
            if let image { finish(CaptureDocument(image: image, scale: result.scale)) }
        }
        scrollSession = session
        session.start()
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
            self.finish(try await self.windowDocument(window.window, shadow: self.settings.windowShadow))
        }
    }

    func captureFullscreen() {
        run {
            self.finish(try await self.displayDocument(containing: NSEvent.mouseLocation))
        }
    }

    func repeatArea() {
        guard settings.lastArea != nil else { return captureArea() }
        run {
            guard let document = try await self.repeatAreaDocument() else { return try await self.select(mode: .area) }
            self.finish(document)
        }
    }

    /// Freezes the screen and copies the colour of the clicked pixel.
    func pickColor() {
        run { try await self.select(mode: .color) }
    }

    func captureDelayed() {
        guard !isBusy, ensurePermission() else { return }
        isCapturing = true
        Task {
            let go = await HUD.countdown(seconds: settings.captureDelay)
            isCapturing = false
            if go { captureArea() }
        }
    }

    // MARK: Steps

    private func run(_ body: @escaping () async throws -> Void) {
        guard !isBusy, ensurePermission() else { return }
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
                // self.purpose: the `purpose` parameter shadows it here.
                if self.purpose == .recognize { return recognize(result.image) }
                if self.purpose == .scroll {
                    self.purpose = .capture
                    return startScrolling(result)
                }
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
                self.purpose = .capture
            }
        }
        selection = controller
        controller.show()
    }

    private func capture(_ info: ScreenCapturer.WindowInfo) async throws {
        finish(try await windowDocument(info.window, shadow: settings.windowShadow))
    }

    // MARK: Captures without UI

    // These only grab pixels: the menu, the shortcuts and agents share them,
    // and decide afterwards what to do with the capture.

    /// Busy selecting, scrolling or counting down.
    var isBusy: Bool { isCapturing || reserved || selection != nil || scrollSession != nil }

    /// Held by an agent's capture from its busy check to the end (delays
    /// included), so a shortcut or another agent cannot start one meanwhile.
    var reserved = false

    func displayDocument(containing point: CGPoint) async throws -> CaptureDocument {
        let snapshot = try await ScreenCapturer.snapshotDisplay(containing: point)
        return CaptureDocument(image: snapshot.image, scale: snapshot.scale)
    }

    func displayDocument(_ displayID: CGDirectDisplayID) async throws -> CaptureDocument {
        guard let snapshot = try await ScreenCapturer.snapshotAllDisplays(only: displayID).first else { throw ScreenCaptureError.noDisplays }
        return CaptureDocument(image: snapshot.image, scale: snapshot.scale)
    }

    func windowDocument(_ window: SCWindow, shadow: Bool) async throws -> CaptureDocument {
        let (image, scale) = try await ScreenCapturer.capture(window: window, shadow: shadow)
        return CaptureDocument(image: image, scale: scale)
    }

    /// Part of the screen, `rect` in AppKit global coordinates, from one
    /// snapshot of the display under its centre.
    func areaDocument(_ rect: CGRect) async throws -> CaptureDocument? {
        let snapshot = try await ScreenCapturer.snapshotDisplay(containing: CGPoint(x: rect.midX, y: rect.midY))
        guard let image = Self.crop(snapshot, toScreenRect: rect) else { return nil }
        return CaptureDocument(image: image, scale: snapshot.scale)
    }

    /// The last selected area again, or nil if there is none (or it is off screen).
    func repeatAreaDocument() async throws -> CaptureDocument? {
        guard let area = settings.lastArea else { return nil }
        return try await areaDocument(area)
    }

    /// Shows the selection overlay and returns what the user picked, or nil
    /// if they cancelled. The capture is not finished: the caller decides.
    func pick(mode: AreaSelectionController.Mode) async throws -> AreaSelectionController.Outcome? {
        guard selection == nil, scrollSession == nil else { throw RemoteCapture.busy }
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        let windows = mode == .window ? (try? await ScreenCapturer.pickableWindows()) ?? [] : []
        isCapturing = true
        defer { isCapturing = false }
        return await withCheckedContinuation { continuation in
            guard selection == nil else { return continuation.resume(returning: nil) }
            let controller = AreaSelectionController(snapshots: snapshots, windows: windows, mode: mode) { [weak self] outcome in
                self?.selection = nil
                // Everything here stays on the main actor.
                nonisolated(unsafe) let picked = outcome
                continuation.resume(returning: picked)
            }
            selection = controller
            controller.show()
        }
    }

    /// Runs a scrolling capture over `area` (AppKit coordinates) and returns
    /// the stitched image, or nil if cancelled. `auto` scrolls by itself
    /// (needs Accessibility); otherwise the user scrolls and presses Return.
    func scroll(area: CGRect, auto: Bool, maxHeight: Int) async throws -> CaptureDocument? {
        let snapshot = try await ScreenCapturer.snapshotDisplay(containing: CGPoint(x: area.midX, y: area.midY))
        guard let first = Self.crop(snapshot, toScreenRect: area) else { return nil }
        let displayID = snapshot.displayID
        isCapturing = true
        defer { isCapturing = false }
        let image: CGImage? = await withCheckedContinuation { continuation in
            let session = ScrollCaptureSession(area: area, scale: snapshot.scale, firstFrame: first, maxHeight: maxHeight,
                                               frameSource: { try await ScreenCapturer.capture(rect: area, displayID: displayID) }) { [weak self] image in
                self?.scrollSession = nil
                continuation.resume(returning: image)
            }
            scrollSession = session
            session.start()
            if auto { session.autoScroll() }
        }
        return image.map { CaptureDocument(image: $0, scale: snapshot.scale) }
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
        if settings.copyAfterCapture, Pasteboard.copy(document.image, scale: document.scale) { done.append(String(localized: "Copied")) }
        if settings.saveAfterCapture {
            do {
                let url = try save(document.image, scale: document.scale, date: document.createdAt)
                if let itemID { LibraryStore.shared.markSaved(itemID, at: url) }
                done.append(String(localized: "Saved in \(url.deletingLastPathComponent().lastPathComponent)"))
            } catch {
                showError(error)
            }
        }
        if settings.uploadAfterCapture {
            upload(document.image, scale: document.scale, date: document.createdAt, libraryItem: itemID)
        }
        if settings.openEditorAfterCapture {
            openEditor(with: document, libraryItem: itemID)
        } else if !done.isEmpty {
            HUD.show(done.joined(separator: " · "), symbol: "checkmark.circle.fill")
        }
    }

    func upload(_ image: CGImage, scale: CGFloat, date: Date, libraryItem: UUID?) {
        Task {
            do {
                try await Uploader.upload(image, scale: scale, date: date, libraryItem: libraryItem)
            } catch {
                showError(error)
            }
        }
    }

    /// OCR for the global shortcut: copies a QR payload if there is one, else the text.
    func recognize(_ image: CGImage) {
        purpose = .capture
        // The first OCR after installing can take a while (Vision loads its models).
        HUD.show(String(localized: "Recognizing text…"), symbol: "text.viewfinder", for: .seconds(60))
        Task {
            do {
                let result = try await TextRecognition.recognize(image)
                HUD.hide()
                onRecognized?(image, result)
                let pasteboard = NSPasteboard.general
                if let code = result.codes.first {
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)
                    HUD.show(String(localized: "QR code copied: \(String(code.prefix(60)))"), symbol: "qrcode", for: .seconds(2.5))
                } else if !result.lines.isEmpty {
                    let text = result.text(joinLines: settings.ocrJoinLines)
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    HUD.show(String(localized: "Text copied (\(text.count) characters)"), symbol: "text.viewfinder")
                } else {
                    HUD.show(String(localized: "No text found"), symbol: "exclamationmark.triangle")
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
        HUD.show(String(localized: "Copied \(text)"), symbol: "eyedropper")
    }

    /// Saves to the folder from the preferences, as the save profile (or `profile`) says.
    @discardableResult
    func save(_ image: CGImage, scale: CGFloat, date: Date, profile: ExportProfile? = nil) throws -> URL {
        let encoded = try ImageEncoding.encode(image, scale: scale, profile: profile ?? settings.profile(for: .save))
        try FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        let url = settings.autoSaveURL(for: date, format: encoded.format)
        try encoded.data.write(to: url, options: .atomic)
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
        alert.messageText = String(localized: "ShotDock needs the Screen Recording permission")
        alert.informativeText = String(localized: "Turn it on in System Settings › Privacy & Security › Screen Recording and try again.")
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
