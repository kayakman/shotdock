import AppKit
import ShotDockCore
import SwiftUI

enum PreferencesTab: Hashable { case general, shortcuts, upload }

@MainActor
@Observable
final class PreferencesState {
    var tab: PreferencesTab = .general
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    let state = PreferencesState()

    init(settings: AppSettings, shortcuts: ShortcutManager) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Preferencias de ShotDock"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = PreferencesView(settings: settings, state: state, shortcutManager: shortcuts, window: { [weak window] in window })
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(window.contentView!.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        DockPresence.shared.update()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @Bindable var settings: AppSettings
    @Bindable var state: PreferencesState
    let shortcutManager: ShortcutManager
    let window: () -> NSWindow?

    var body: some View {
        TabView(selection: $state.tab) {
            GeneralPreferences(settings: settings, window: window)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PreferencesTab.general)
            ShortcutPreferences(settings: settings, manager: shortcutManager, window: window)
                .tabItem { Label("Atajos", systemImage: "command") }
                .tag(PreferencesTab.shortcuts)
            UploadPreferences(settings: settings, window: window)
                .tabItem { Label("Subida", systemImage: "icloud.and.arrow.up") }
                .tag(PreferencesTab.upload)
        }
        .frame(width: 580, height: 640)
        .padding(20)
    }
}

private struct GeneralPreferences: View {
    @Bindable var settings: AppSettings
    let window: () -> NSWindow?

    @State private var loginError: String?

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { LaunchAtLogin.isEnabled }, set: { value in
            do { try LaunchAtLogin.set(value) } catch { loginError = error.localizedDescription }
        })
    }

    private var preview: String {
        FilenameTemplate(settings.filenameTemplate).name(for: Date()) + "." + settings.imageFormat.fileExtension
    }

    var body: some View {
        Form {
            Section("ShotDock") {
                Toggle("Abrir al iniciar sesión", isOn: launchAtLogin)
                Toggle("Mostrar en el Dock mientras haya ventanas abiertas", isOn: $settings.showInDock)
                    .onChange(of: settings.showInDock) { DockPresence.shared.update() }
            }
            Section("Después de capturar") {
                Toggle("Copiar al portapapeles", isOn: $settings.copyAfterCapture)
                Toggle("Abrir el editor", isOn: $settings.openEditorAfterCapture)
                Toggle("Guardar automáticamente", isOn: $settings.saveAfterCapture)
                Toggle("Subir y copiar el enlace", isOn: $settings.uploadAfterCapture)
                    .disabled(!settings.s3.isComplete)
                    .help("Configúralo en la pestaña Subida")
            }
            Section("Guardar") {
                LabeledContent("Carpeta") {
                    HStack {
                        Text(settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Elegir…", action: chooseFolder)
                    }
                }
                TextField("Nombre", text: $settings.filenameTemplate)
                Text("\(preview)\nMarcadores: \(FilenameTemplate.tokens.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Picker("Formato", selection: $settings.imageFormat) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                }
                .pickerStyle(.segmented)
            }
            Section("Historial") {
                Picker("Guardar en el historial", selection: $settings.historyLimit) {
                    Text("Las últimas 50").tag(50)
                    Text("Las últimas 200").tag(200)
                    Text("Las últimas 1000").tag(1000)
                    Text("Todas").tag(Int.max)
                    Text("Nada (desactivado)").tag(0)
                }
                .onChange(of: settings.historyLimit) { LibraryStore.shared.applyLimit() }
            }
            Section("Captura") {
                Stepper("Retardo: \(settings.captureDelay) s", value: $settings.captureDelay, in: 1...30)
                Toggle("Incluir la sombra al capturar ventanas", isOn: $settings.windowShadow)
                Toggle("OCR: unir las líneas en un párrafo", isOn: $settings.ocrJoinLines)
                Picker("Formato de color", selection: $settings.colorFormat) {
                    Text("HEX  #FF5A1F").tag(ColorFormat.hex)
                    Text("RGB  rgb(255, 90, 31)").tag(ColorFormat.rgb)
                }
            }
        }
        .formStyle(.grouped)
        .alert("No se pudo cambiar el inicio de sesión", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
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

private struct ShortcutPreferences: View {
    @Bindable var settings: AppSettings
    let manager: ShortcutManager
    let window: () -> NSWindow?

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent {
                        ShortcutRecorder(combo: binding(for: action)) { manager.setSuspended($0) }
                            .fixedSize()
                    } label: {
                        Text(action.title)
                        if !manager.isAvailable(action) {
                            Text("Próximamente").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Haz clic en un atajo y pulsa la nueva combinación. ⌫ lo quita, Esc cancela.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    if ShottrImporter.isShottrInstalled {
                        Button("Importar de Shottr…") { ShottrImporter.run(into: settings, parent: window()) }
                    }
                    Spacer()
                    Button("Restablecer") { settings.shortcuts = ShortcutSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: ShortcutAction) -> Binding<KeyCombo?> {
        Binding(get: { settings.shortcuts.combo(for: action) },
                set: { settings.shortcuts.set($0, for: action) })
    }
}
