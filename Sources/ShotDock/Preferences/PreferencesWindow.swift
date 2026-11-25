import AppKit
import ShotDockCore
import SwiftUI

enum PreferencesTab: Hashable { case general, shortcuts }

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
        }
        .frame(width: 580, height: 640)
        .padding(20)
    }
}

private struct GeneralPreferences: View {
    @Bindable var settings: AppSettings
    let window: () -> NSWindow?

    private var preview: String {
        FilenameTemplate(settings.filenameTemplate).name(for: Date()) + "." + settings.imageFormat.fileExtension
    }

    var body: some View {
        Form {
            Section("Después de capturar") {
                Toggle("Copiar al portapapeles", isOn: $settings.copyAfterCapture)
                Toggle("Abrir el editor", isOn: $settings.openEditorAfterCapture)
                Toggle("Guardar automáticamente", isOn: $settings.saveAfterCapture)
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
            Section("Captura") {
                Stepper("Retardo: \(settings.captureDelay) s", value: $settings.captureDelay, in: 1...30)
                Toggle("Incluir la sombra al capturar ventanas", isOn: $settings.windowShadow)
            }
        }
        .formStyle(.grouped)
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
