import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let permissionItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { return }
        setUpStatusItem()
        if !ScreenCapturer.hasPermission { ScreenCapturer.requestPermission() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShotDock")

        let menu = NSMenu()
        menu.delegate = self
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

    @objc private func openScreenRecordingSettings() {
        ScreenCapturer.requestPermission()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
