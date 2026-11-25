import AppKit
import ShotDockCore
import SwiftUI

enum PreferencesTab: Int, CaseIterable {
    case general, capture, shortcuts, history, upload, importing

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Captura"
        case .shortcuts: "Atajos"
        case .history: "Historial"
        case .upload: "Subida"
        case .importing: "Importar"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .shortcuts: "keyboard"
        case .history: "clock.arrow.circlepath"
        case .upload: "icloud.and.arrow.up"
        case .importing: "square.and.arrow.down"
        }
    }
}

/// Classic macOS preferences: icon tabs in the toolbar, the window titled
/// after the selected pane and resized to fit it.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let tabs = PreferencesTabController()

    init(settings: AppSettings, shortcuts: ShortcutManager) {
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.identifier = NSUserInterfaceItemIdentifier("preferences")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let parent = { [weak window] in window }
        for tab in PreferencesTab.allCases {
            let view: AnyView = switch tab {
            case .general: AnyView(GeneralPane(settings: settings))
            case .capture: AnyView(CapturePane(settings: settings, window: parent))
            case .shortcuts: AnyView(ShortcutsPane(settings: settings, manager: shortcuts))
            case .history: AnyView(HistoryPane(settings: settings))
            case .upload: AnyView(UploadPreferences(settings: settings, window: parent))
            case .importing: AnyView(ImportPane(settings: settings, window: parent))
            }
            let controller = NSHostingController(rootView: view.padding(.horizontal, 32).frame(width: 680).padding(.vertical, 20))
            controller.sizingOptions = .preferredContentSize
            controller.title = tab.title  // the toolbar tab style titles the window after the selected child
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window.title = PreferencesTab.general.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: PreferencesTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }

    var selectedTab: PreferencesTab { PreferencesTab(rawValue: tabs.selectedTabViewItemIndex) ?? .general }

    func show() {
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        DockPresence.shared.update()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class PreferencesTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? ""
    }
}

// MARK: Panes

private struct GeneralPane: View {
    @Bindable var settings: AppSettings
    @State private var loginError: String?

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { LaunchAtLogin.isEnabled }, set: { value in
            do { try LaunchAtLogin.set(value) } catch { loginError = error.localizedDescription }
        })
    }

    var body: some View {
        Form {
            LabeledContent("Inicio:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Abrir ShotDock al iniciar sesión", isOn: launchAtLogin)
                    Toggle("Mostrar en el Dock mientras haya ventanas abiertas", isOn: $settings.showInDock)
                        .onChange(of: settings.showInDock) { DockPresence.shared.update() }
                }
            }
            LabeledContent("Después de capturar:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Copiar al portapapeles", isOn: $settings.copyAfterCapture)
                    Toggle("Abrir el editor", isOn: $settings.openEditorAfterCapture)
                    Toggle("Guardar en la carpeta", isOn: $settings.saveAfterCapture)
                    Toggle("Subir y copiar el enlace", isOn: $settings.uploadAfterCapture)
                        .disabled(!settings.s3.isComplete)
                    if !settings.s3.isComplete {
                        Text("Para subir, configura la pestaña Subida.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.columns)
        .alert("No se pudo cambiar el inicio de sesión", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
    }
}

private struct CapturePane: View {
    @Bindable var settings: AppSettings
    let window: () -> NSWindow?

    private var preview: String {
        FilenameTemplate(settings.filenameTemplate).name(for: Date()) + "." + settings.imageFormat.fileExtension
    }

    var body: some View {
        Form {
            LabeledContent("Guardar en:") {
                HStack {
                    Text(settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    Button("Elegir…", action: chooseFolder)
                }
            }
            LabeledContent("Nombre:") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $settings.filenameTemplate).labelsHidden()
                    Text("\(preview)\nMarcadores: \(FilenameTemplate.tokens.joined(separator: " "))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Formato:", selection: $settings.imageFormat) {
                Text("PNG").tag(ImageFormat.png)
                Text("JPEG").tag(ImageFormat.jpeg)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            Divider()

            LabeledContent("Retardo:") {
                Stepper("\(settings.captureDelay) s", value: $settings.captureDelay, in: 1...30)
            }
            LabeledContent("Ventanas:") {
                Toggle("Incluir la sombra", isOn: $settings.windowShadow)
            }
            Picker("Captura con scroll:", selection: $settings.scrollMaxHeight) {
                Text("Hasta 10 000 px").tag(10_000)
                Text("Hasta 20 000 px").tag(20_000)
                Text("Hasta 50 000 px").tag(50_000)
            }
            .fixedSize()

            Divider()

            Picker("Cuentagotas:", selection: $settings.colorFormat) {
                Text("HEX  #FF5A1F").tag(ColorFormat.hex)
                Text("RGB  rgb(255, 90, 31)").tag(ColorFormat.rgb)
            }
            .fixedSize()
            LabeledContent("OCR:") {
                Toggle("Unir las líneas en un párrafo", isOn: $settings.ocrJoinLines)
            }
        }
        .formStyle(.columns)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Elegir"
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { settings.saveFolder = url }
        }
        if let window = window() { panel.beginSheetModal(for: window, completionHandler: apply) } else { apply(panel.runModal()) }
    }
}

private struct ShortcutsPane: View {
    @Bindable var settings: AppSettings
    let manager: ShortcutManager

    var body: some View {
        Form {
            Text("Globales: funcionan desde cualquier app.").font(.headline)
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                LabeledContent(action.title + ":") {
                    ShortcutRecorder(combo: globalBinding(action)) { manager.setSuspended($0) }.fixedSize()
                }
            }
            Divider()
            Text("En el editor de capturas.").font(.headline)
            ForEach(EditorAction.allCases, id: \.self) { action in
                LabeledContent(action.title + ":") {
                    ShortcutRecorder(combo: editorBinding(action)) { manager.setSuspended($0) }.fixedSize()
                }
            }
            Divider()
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Haz clic en un atajo y pulsa la nueva combinación. ⌫ lo quita, Esc cancela. Una combinación solo puede tener un uso: si ya lo tenía otro atajo, se le quita.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Button("Restablecer los atajos") {
                        settings.shortcuts = ShortcutSettings()
                        settings.editorShortcuts = EditorShortcutSettings()
                    }
                }
            }
        }
        .formStyle(.columns)
    }

    // A combo belongs to one action across both sets: global hotkeys would swallow it otherwise.
    private func globalBinding(_ action: ShortcutAction) -> Binding<KeyCombo?> {
        Binding(get: { settings.shortcuts.combo(for: action) }, set: { combo in
            if let combo { settings.editorShortcuts.release(combo) }
            settings.shortcuts.set(combo, for: action)
        })
    }

    private func editorBinding(_ action: EditorAction) -> Binding<KeyCombo?> {
        Binding(get: { settings.editorShortcuts.combo(for: action) }, set: { combo in
            if let combo { settings.shortcuts.release(combo) }
            settings.editorShortcuts.set(combo, for: action)
        })
    }
}

private struct HistoryPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Guardar:", selection: $settings.historyLimit) {
                Text("Las últimas 50 capturas").tag(50)
                Text("Las últimas 200 capturas").tag(200)
                Text("Las últimas 1000 capturas").tag(1000)
                Text("Todas").tag(Int.max)
                Text("Nada (historial desactivado)").tag(0)
            }
            .fixedSize()
            .onChange(of: settings.historyLimit) { LibraryStore.shared.applyLimit() }
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cada captura se guarda con sus anotaciones, que se pueden seguir editando desde Capturas recientes. Los ficheros que guardes en tu carpeta no se tocan.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Abrir capturas recientes") { (NSApp.delegate as? AppDelegate)?.showGallery() }
                        Button("Vaciar historial…", role: .destructive, action: confirmClear)
                            .disabled(LibraryStore.shared.items.isEmpty)
                    }
                }
            }
        }
        .formStyle(.columns)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "¿Vaciar el historial?"
        alert.informativeText = "Se borrarán las \(LibraryStore.shared.items.count) capturas del historial."
        alert.addButton(withTitle: "Vaciar")
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { LibraryStore.shared.deleteAll() }
    }
}

private struct ImportPane: View {
    @Bindable var settings: AppSettings
    let window: () -> NSWindow?

    var body: some View {
        Form {
            LabeledContent("Shottr:") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trae los atajos de Shottr y su configuración de subida a S3 (bucket, endpoint, región, carpeta y enlace). Las claves de S3 no se pueden leer: escríbelas en Subida.")
                        .frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text("macOS protege la configuración de otras apps: selecciona «cc.ffitch.shottr.plist» en el panel que se abre.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Button("Importar de Shottr…") { ShottrImporter.run(into: settings, parent: window()) }
                        .disabled(!ShottrImporter.isShottrInstalled)
                    if !ShottrImporter.isShottrInstalled {
                        Text("Shottr no está instalado en este Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.columns)
    }
}
