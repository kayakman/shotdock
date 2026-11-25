import AppKit
import ServiceManagement

/// ShotDock lives in the menu bar, but while one of its windows (editor,
/// gallery, preferences) is open it shows in the Dock and in ⌘Tab.
@MainActor
final class DockPresence {
    static let shared = DockPresence()
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the close finishes, so the closing window no longer counts.
                DispatchQueue.main.async { MainActor.assumeIsolated { DockPresence.shared.update() } }
            })
        }
    }

    /// Titled windows the user works with; panels, overlays and pins do not count.
    var hasUserWindows: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.level == .normal }
    }

    func update() {
        let wanted: NSApplication.ActivationPolicy = AppSettings.shared.showInDock && hasUserWindows ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate() }
    }
}

/// "Abrir al iniciar sesión" through SMAppService.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
