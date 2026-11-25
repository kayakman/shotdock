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
    var copyAfterCapture: Bool { didSet { defaults.set(copyAfterCapture, forKey: "copyAfterCapture") } }
    var openEditorAfterCapture: Bool { didSet { defaults.set(openEditorAfterCapture, forKey: "openEditorAfterCapture") } }
    var saveAfterCapture: Bool { didSet { defaults.set(saveAfterCapture, forKey: "saveAfterCapture") } }
    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: "filenameTemplate") } }
    var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: "imageFormat") } }
    var captureDelay: Int { didSet { defaults.set(captureDelay, forKey: "captureDelay") } }
    var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: "windowShadow") } }
    /// Last selected area in AppKit global coordinates, for "repeat area".
    var lastArea: CGRect? {
        didSet { lastArea.map { defaults.set(NSStringFromRect($0), forKey: "lastArea") } ?? defaults.removeObject(forKey: "lastArea") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        shortcuts = (defaults.data(forKey: "shortcuts")).flatMap { try? JSONDecoder().decode(ShortcutSettings.self, from: $0) } ?? ShortcutSettings()
        copyAfterCapture = defaults.object(forKey: "copyAfterCapture") as? Bool ?? true
        openEditorAfterCapture = defaults.object(forKey: "openEditorAfterCapture") as? Bool ?? true
        saveAfterCapture = defaults.object(forKey: "saveAfterCapture") as? Bool ?? false
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        saveFolder = defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? desktop
        filenameTemplate = defaults.string(forKey: "filenameTemplate") ?? FilenameTemplate.defaultTemplate
        imageFormat = defaults.string(forKey: "imageFormat").flatMap(ImageFormat.init(rawValue:)) ?? .png
        captureDelay = defaults.object(forKey: "captureDelay") as? Int ?? 3
        windowShadow = defaults.object(forKey: "windowShadow") as? Bool ?? true
        lastArea = defaults.string(forKey: "lastArea").map { NSRectFromString($0) }
    }

    /// A clean, temporary settings store for selftests.
    static func useSelfTestStore() {
        let name = "app.shotdock.ShotDock.selftest"
        UserDefaults().removePersistentDomain(forName: name)
        shared = AppSettings(defaults: UserDefaults(suiteName: name)!)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Where a capture is saved without asking.
    func autoSaveURL(for date: Date) -> URL {
        FilenameTemplate(filenameTemplate).uniqueURL(in: saveFolder, for: date, format: imageFormat)
    }
}
