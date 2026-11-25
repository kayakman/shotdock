import AppKit
import ShotDockCore

/// Keeps the global hotkeys in sync with the settings.
@MainActor
final class ShortcutManager {
    private let settings: AppSettings
    private let handler: (ShortcutAction) -> Void
    private let available: Set<ShortcutAction>
    private var suspended = false
    /// Actions whose shortcut could not be registered (taken by another app or macOS).
    private(set) var failed: Set<ShortcutAction> = []

    init(settings: AppSettings, available: Set<ShortcutAction>, handler: @escaping (ShortcutAction) -> Void) {
        self.settings = settings
        self.available = available
        self.handler = handler
        observe()
    }

    func isAvailable(_ action: ShortcutAction) -> Bool { available.contains(action) }

    func registerAll() {
        failed = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            let id = UInt32(index + 1)
            HotKeyCenter.shared.unregister(id: id)
            guard !suspended, available.contains(action), let combo = settings.shortcuts.combo(for: action) else { continue }
            let ok = HotKeyCenter.shared.register(id: id, keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
                self?.handler(action)
            }
            if !ok { failed.insert(action) }
        }
    }

    /// While recording a shortcut the keys must reach the recorder, not trigger captures.
    func setSuspended(_ value: Bool) {
        suspended = value
        registerAll()
    }

    private func observe() {
        withObservationTracking { _ = settings.shortcuts } onChange: { [weak self] in
            Task { @MainActor in
                self?.registerAll()
                self?.observe()
            }
        }
    }
}
