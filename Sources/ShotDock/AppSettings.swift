import AppKit
import Observation
import ShotDockCore

/// User preferences, persisted in UserDefaults. Selftests use a throwaway
/// suite so they never touch the real settings.
@MainActor
@Observable
final class AppSettings {
    static var shared = AppSettings(defaults: .standard)

    @ObservationIgnored private let defaults: UserDefaults

    var shortcuts: ShortcutSettings { didSet { save(shortcuts, "shortcuts") } }
    var editorShortcuts: EditorShortcutSettings { didSet { save(editorShortcuts, "editorShortcuts") } }
    var copyAfterCapture: Bool { didSet { defaults.set(copyAfterCapture, forKey: "copyAfterCapture") } }
    var openEditorAfterCapture: Bool { didSet { defaults.set(openEditorAfterCapture, forKey: "openEditorAfterCapture") } }
    var saveAfterCapture: Bool { didSet { defaults.set(saveAfterCapture, forKey: "saveAfterCapture") } }
    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: "filenameTemplate") } }
    var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: "imageFormat") } }
    var captureDelay: Int { didSet { defaults.set(captureDelay, forKey: "captureDelay") } }
    var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: "windowShadow") } }
    var colorFormat: ColorFormat { didSet { defaults.set(colorFormat.rawValue, forKey: "colorFormat") } }
    /// How many captures the history keeps; 0 turns it off.
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    /// OCR joins the recognised lines into one paragraph.
    var ocrJoinLines: Bool { didSet { defaults.set(ocrJoinLines, forKey: "ocrJoinLines") } }
    /// The backdrop used last, offered when the backdrop is turned on.
    var lastBackdrop: Backdrop { didSet { save(lastBackdrop, "lastBackdrop") } }
    var s3: S3Configuration { didSet { save(s3, "s3") } }
    /// Tallest scrolling capture, in pixels.
    var scrollMaxHeight: Int { didSet { defaults.set(scrollMaxHeight, forKey: "scrollMaxHeight") } }
    /// Show in the Dock while an editor, the gallery or the preferences are open.
    var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    var uploadAfterCapture: Bool { didSet { defaults.set(uploadAfterCapture, forKey: "uploadAfterCapture") } }
    /// `shotdock` and its MCP server may drive the app (off until the user turns it on).
    var agentControlEnabled: Bool { didSet { defaults.set(agentControlEnabled, forKey: "agentControlEnabled") } }
    /// Agents the user allowed, asked the first time each one connects.
    var approvedAgents: [AgentClient] { didSet { save(approvedAgents, "approvedAgents") } }
    /// Last selected area in AppKit global coordinates, for "repeat area".
    var lastArea: CGRect? {
        didSet { lastArea.map { defaults.set(NSStringFromRect($0), forKey: "lastArea") } ?? defaults.removeObject(forKey: "lastArea") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        shortcuts = (defaults.data(forKey: "shortcuts")).flatMap { try? JSONDecoder().decode(ShortcutSettings.self, from: $0) } ?? ShortcutSettings()
        editorShortcuts = defaults.data(forKey: "editorShortcuts").flatMap { try? JSONDecoder().decode(EditorShortcutSettings.self, from: $0) }
            ?? EditorShortcutSettings()
        copyAfterCapture = defaults.object(forKey: "copyAfterCapture") as? Bool ?? true
        openEditorAfterCapture = defaults.object(forKey: "openEditorAfterCapture") as? Bool ?? true
        saveAfterCapture = defaults.object(forKey: "saveAfterCapture") as? Bool ?? false
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        saveFolder = defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? desktop
        filenameTemplate = defaults.string(forKey: "filenameTemplate") ?? FilenameTemplate.defaultTemplate
        imageFormat = defaults.string(forKey: "imageFormat").flatMap(ImageFormat.init(rawValue:)) ?? .png
        captureDelay = defaults.object(forKey: "captureDelay") as? Int ?? 3
        windowShadow = defaults.object(forKey: "windowShadow") as? Bool ?? true
        colorFormat = defaults.string(forKey: "colorFormat").flatMap(ColorFormat.init(rawValue:)) ?? .hex
        historyLimit = defaults.object(forKey: "historyLimit") as? Int ?? 200
        ocrJoinLines = defaults.object(forKey: "ocrJoinLines") as? Bool ?? false
        s3 = defaults.data(forKey: "s3").flatMap { try? JSONDecoder().decode(S3Configuration.self, from: $0) } ?? S3Configuration()
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        scrollMaxHeight = defaults.object(forKey: "scrollMaxHeight") as? Int ?? 20_000
        uploadAfterCapture = defaults.object(forKey: "uploadAfterCapture") as? Bool ?? false
        agentControlEnabled = defaults.object(forKey: "agentControlEnabled") as? Bool ?? false
        approvedAgents = defaults.data(forKey: "approvedAgents").flatMap { try? JSONDecoder().decode([AgentClient].self, from: $0) } ?? []
        lastBackdrop = defaults.data(forKey: "lastBackdrop").flatMap { try? JSONDecoder().decode(Backdrop.self, from: $0) } ?? Backdrop()
        lastArea = defaults.string(forKey: "lastArea").map { NSRectFromString($0) }
    }

    /// A combo belongs to one action across both sets: a global hotkey would
    /// swallow it in the editor otherwise.
    func setShortcut(_ combo: KeyCombo?, for action: ShortcutAction) {
        if let combo { editorShortcuts.release(combo) }
        shortcuts.set(combo, for: action)
    }

    func setShortcut(_ combo: KeyCombo?, for action: EditorAction) {
        if let combo { shortcuts.release(combo) }
        editorShortcuts.set(combo, for: action)
    }

    /// A clean, temporary settings store for selftests.
    static func useSelfTestStore() {
        let name = "app.shotdock.ShotDock.selftest"
        UserDefaults().removePersistentDomain(forName: name)
        shared = AppSettings(defaults: UserDefaults(suiteName: name)!)
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDock Selftest Library")
        try? FileManager.default.removeItem(at: library)
        LibraryStore.shared = LibraryStore(root: library)
        Keychain.service = "app.shotdock.ShotDock.s3.selftest"
        RemoteFiles.folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDock Selftest Agent")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Where a capture is saved without asking.
    func autoSaveURL(for date: Date) -> URL {
        FilenameTemplate(filenameTemplate).uniqueURL(in: saveFolder, for: date, format: imageFormat)
    }
}
