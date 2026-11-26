import AppKit

/// The app's language: the system's, or one chosen in Preferences. macOS
/// reads it from AppleLanguages when the app starts, so a change applies
/// after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, es

    var id: String { rawValue }

    /// Languages are named in themselves, as macOS does.
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .en: "English"
        case .es: "Español"
        }
    }

    /// Writes AppleLanguages in the app's own domain (only for the real settings).
    static func apply(_ language: AppLanguage, to defaults: UserDefaults) {
        guard defaults === UserDefaults.standard else { return }
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }

    /// The language the app is showing now.
    static var running: AppLanguage { Bundle.main.preferredLocalizations.first == "es" ? .es : .en }

    /// Quits and opens the app again.
    @MainActor
    static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }
}
