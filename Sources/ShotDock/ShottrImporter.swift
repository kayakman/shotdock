import AppKit
import ShotDockCore
import UniformTypeIdentifiers

/// Imports Shottr's shortcuts. macOS protects other apps' containers, so the
/// file has to be chosen by the user in an open panel, which grants access.
@MainActor
enum ShottrImporter {
    static var isShottrInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ShottrImport.bundleID) != nil
    }

    static func run(into settings: AppSettings, parent: NSWindow?) {
        let panel = NSOpenPanel()
        panel.message = "Selecciona «cc.ffitch.shottr.plist» y pulsa Importar para traer los atajos de Shottr."
        panel.prompt = "Importar"
        panel.directoryURL = ShottrImport.preferencesURL().deletingLastPathComponent()
        panel.allowedContentTypes = [.propertyList]
        panel.showsHiddenFiles = false
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importFile(url, into: settings, parent: parent)
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    static func importFile(_ url: URL, into settings: AppSettings, parent: NSWindow?) {
        let alert = NSAlert()
        do {
            let data = try Data(contentsOf: url)
            let result = try ShottrImport.parse(plistData: data)
            let preferences = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
            let s3 = ShottrImport.s3Configuration(preferences)
            if let s3 { settings.s3 = s3 }
            guard !result.shortcuts.isEmpty || s3 != nil else {
                alert.messageText = "No hay atajos que importar"
                alert.informativeText = "Ese fichero no tiene atajos de Shottr configurados."
                return present(alert, parent)
            }
            settings.shortcuts.apply(result)
            alert.messageText = "Configuración de Shottr importada"
            var text = summary(of: result)
            if let s3 {
                text += "\n\nSubida: bucket «\(s3.bucket)» en \(s3.provider.title). Las claves no se pueden leer de Shottr: escríbelas en Preferencias › Subida."
            }
            alert.informativeText = text
        } catch {
            alert.messageText = "No se pudo leer la configuración de Shottr"
            alert.informativeText = error.localizedDescription
        }
        present(alert, parent)
    }

    static func summary(of result: ShottrImport.Result) -> String {
        let lines = ShortcutAction.allCases.compactMap { action -> String? in
            guard let combo = result.shortcuts[action] else { return nil }
            return "\(action.title): \(combo.map(KeyComboFormatter.string) ?? "desactivado")"
        }
        var text = lines.joined(separator: "\n")
        if !result.unknown.isEmpty { text += "\n\nSin equivalente en ShotDock: \(result.unknown.joined(separator: ", "))" }
        return text
    }

    private static func present(_ alert: NSAlert, _ parent: NSWindow?) {
        if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
    }
}
