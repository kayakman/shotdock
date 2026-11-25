import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let coordinator = CaptureCoordinator()
    private var statusItem: NSStatusItem?
    private let permissionItem = NSMenuItem()

    private enum HotKey: UInt32 { case captureArea = 1 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self)
        if SelfTest.runIfRequested(app: self) { return }
        setUpStatusItem()
        HotKeyCenter.shared.register(id: HotKey.captureArea.rawValue, keyCode: kVK_ANSI_2,
                                     modifiers: cmdKey | shiftKey) { [weak self] in self?.captureArea() }
        if !ScreenCapturer.hasPermission { ScreenCapturer.requestPermission() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "ShotDock"
        item.button?.image = icon

        let menu = NSMenu()
        menu.delegate = self
        let capture = NSMenuItem(title: "Capturar área", action: #selector(captureArea), keyEquivalent: "2")
        capture.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(capture)
        menu.addItem(.separator())
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Acerca de ShotDock", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Salir de ShotDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if ScreenCapturer.hasPermission {
            permissionItem.title = "Permiso de grabación de pantalla: concedido"
            permissionItem.action = nil
        } else {
            permissionItem.title = "Conceder permiso de grabación de pantalla…"
            permissionItem.action = #selector(openScreenRecordingSettings)
        }
    }

    @objc func captureArea() { coordinator.captureArea() }

    @objc private func openScreenRecordingSettings() {
        ScreenCapturer.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc func showAbout() { AboutWindowController.shared.show() }
}
