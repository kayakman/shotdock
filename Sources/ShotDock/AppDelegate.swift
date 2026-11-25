import AppKit
import ShotDockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let coordinator = CaptureCoordinator()
    private(set) var shortcuts: ShortcutManager!
    private var statusItem: NSStatusItem?
    private var preferences: PreferencesWindowController?

    /// Actions that already work; the rest keep their shortcut for later phases.
    static let availableActions: Set<ShortcutAction> = [
        .captureArea, .repeatArea, .captureActiveWindow, .captureWindow, .captureFullscreen, .captureDelayed,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let selfTest = SelfTest.isRequested
        if selfTest { AppSettings.useSelfTestStore() }
        NSApp.mainMenu = MainMenu.build(target: self)
        shortcuts = ShortcutManager(settings: .shared, available: Self.availableActions) { [weak self] in self?.perform($0) }
        if SelfTest.runIfRequested(app: self) { return }

        setUpStatusItem()
        shortcuts.registerAll()
        if !ScreenCapturer.hasPermission { ScreenCapturer.requestPermission() }
        offerShottrImportOnce()
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .captureArea: coordinator.captureArea()
        case .repeatArea: coordinator.repeatArea()
        case .captureActiveWindow: coordinator.captureActiveWindow()
        case .captureWindow: coordinator.captureWindow()
        case .captureFullscreen: coordinator.captureFullscreen()
        case .captureDelayed: coordinator.captureDelayed()
        case .captureScrolling, .recognizeText, .pickColor, .showHistory: NSSound.beep()
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "ShotDock"
        item.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt on every open so it shows the current shortcuts and permission state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for action in ShortcutAction.allCases where Self.availableActions.contains(action) {
            let item = NSMenuItem(title: action.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = self
            if let combo = AppSettings.shared.shortcuts.combo(for: action),
               let key = KeyComboFormatter.layoutCharacter(combo.keyCode) ?? KeyNames.ansiName(combo.keyCode)?.lowercased() {
                item.keyEquivalent = key.lowercased()
                item.keyEquivalentModifierMask = KeyComboFormatter.appKitModifiers(combo.modifiers)
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if !ScreenCapturer.hasPermission {
            menu.addItem(withTitle: "Conceder permiso de grabación de pantalla…", action: #selector(openScreenRecordingSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Preferencias…", action: #selector(showPreferences), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Acerca de ShotDock", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir de ShotDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        // Let the menu close before the screen is frozen.
        DispatchQueue.main.async { self.perform(action) }
    }

    @objc func captureArea() { coordinator.captureArea() }

    @objc private func openScreenRecordingSettings() {
        ScreenCapturer.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc func showPreferences() { openPreferences(tab: nil) }

    func openPreferences(tab: PreferencesTab?) {
        if preferences == nil { preferences = PreferencesWindowController(settings: .shared, shortcuts: shortcuts) }
        if let tab { preferences?.state.tab = tab }
        preferences?.show()
    }

    @objc func showAbout() { AboutWindowController.shared.show() }

    // MARK: Shottr

    private func offerShottrImportOnce() {
        let key = "offeredShottrImport"
        guard ShottrImporter.isShottrInstalled, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "¿Importar los atajos de Shottr?"
        alert.informativeText = "ShotDock puede usar los mismos atajos que tenías en Shottr. macOS te pedirá que selecciones su fichero de configuración."
        alert.addButton(withTitle: "Importar…")
        alert.addButton(withTitle: "Ahora no")
        if alert.runModal() == .alertFirstButtonReturn { ShottrImporter.run(into: .shared, parent: nil) }
    }
}
