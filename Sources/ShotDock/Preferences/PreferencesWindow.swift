import AppKit
import ShotDockCore
import SwiftUI

enum PreferencesTab: Int, CaseIterable {
    case general, capture, export, shortcuts, history, upload, agents, importing

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .capture: String(localized: "Capture")
        case .export: String(localized: "Export")
        case .shortcuts: String(localized: "Shortcuts")
        case .history: String(localized: "History")
        case .upload: String(localized: "Upload")
        case .agents: String(localized: "Agents")
        case .importing: String(localized: "Import")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .export: "photo.on.rectangle.angled"
        case .shortcuts: "keyboard"
        case .history: "clock.arrow.circlepath"
        case .upload: "icloud.and.arrow.up"
        case .agents: "terminal"
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
            case .export: AnyView(ExportPreferences(settings: settings))
            case .shortcuts: AnyView(ShortcutsPane(settings: settings, manager: shortcuts))
            case .history: AnyView(HistoryPane(settings: settings))
            case .upload: AnyView(UploadPreferences(settings: settings, window: parent))
            case .agents: AnyView(AgentsPreferences(settings: settings))
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

    @State private var askRestart = false

    private var language: Binding<AppLanguage> {
        Binding(get: { settings.language }, set: { value in
            guard value != settings.language else { return }
            settings.language = value
            askRestart = true
        })
    }

    var body: some View {
        Form {
            Picker("Language:", selection: language) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .fixedSize()
            LabeledContent("Startup:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Open ShotDock at login", isOn: launchAtLogin)
                    Toggle("Show in the Dock while windows are open", isOn: $settings.showInDock)
                        .onChange(of: settings.showInDock) { DockPresence.shared.update() }
                }
            }
            LabeledContent("After capturing:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Copy to the clipboard", isOn: $settings.copyAfterCapture)
                    Toggle("Open the editor", isOn: $settings.openEditorAfterCapture)
                    Toggle("Save to the folder", isOn: $settings.saveAfterCapture)
                    Toggle("Upload and copy the link", isOn: $settings.uploadAfterCapture)
                        .disabled(!settings.s3.isComplete)
                    if !settings.s3.isComplete {
                        Text("To upload, set up the Upload tab.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.columns)
        .alert("The language changes when ShotDock restarts", isPresented: $askRestart) {
            Button("Restart Now") { AppLanguage.relaunch() }
            Button("Later", role: .cancel) {}
        }
        .alert("Could not change the login item", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
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
        FilenameTemplate(settings.filenameTemplate).name(for: Date()) + "." + settings.profile(for: .save).format.fileExtension
    }

    var body: some View {
        Form {
            LabeledContent("Save to:") {
                HStack {
                    Text(settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
            }
            LabeledContent("Name:") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $settings.filenameTemplate).labelsHidden()
                    Text(verbatim: preview + "\n" + String(localized: "Tokens: {date} {time} {year} {month} {day} {h} {min} {s} {n}"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Format:") {
                HStack {
                    ProfilePicker(settings: settings, destination: .save)
                    Button("Edit Profiles…") { (NSApp.delegate as? AppDelegate)?.openPreferences(tab: .export) }
                }
            }

            Divider()

            LabeledContent("Delay:") {
                Stepper("\(settings.captureDelay) s", value: $settings.captureDelay, in: 1...30)
            }
            LabeledContent("Windows:") {
                Toggle("Include the shadow", isOn: $settings.windowShadow)
            }
            Picker("Scrolling capture:", selection: $settings.scrollMaxHeight) {
                Text("Up to 10,000 px").tag(10_000)
                Text("Up to 20,000 px").tag(20_000)
                Text("Up to 50,000 px").tag(50_000)
            }
            .fixedSize()

            Divider()

            Picker("Color picker:", selection: $settings.colorFormat) {
                Text(verbatim: "HEX  #FF5A1F").tag(ColorFormat.hex)
                Text(verbatim: "RGB  rgb(255, 90, 31)").tag(ColorFormat.rgb)
            }
            .fixedSize()
            LabeledContent(String(localized: "OCR:")) {
                Toggle("Join the lines into one paragraph", isOn: $settings.ocrJoinLines)
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
        panel.prompt = String(localized: "Choose")
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
            Text("Global: they work from any app.").font(.headline)
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                LabeledContent(action.title + ":") {
                    ShortcutRecorder(combo: globalBinding(action)) { manager.setSuspended($0) }.fixedSize()
                }
            }
            Divider()
            Text("In the capture editor.").font(.headline)
            ForEach(EditorAction.allCases, id: \.self) { action in
                LabeledContent(action.title + ":") {
                    ShortcutRecorder(combo: editorBinding(action)) { manager.setSuspended($0) }.fixedSize()
                }
            }
            Divider()
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Click a shortcut and press the new combination. ⌫ removes it, Esc cancels. A combination can only have one use: if another shortcut had it, it loses it.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Button("Reset the shortcuts") {
                        settings.shortcuts = ShortcutSettings()
                        settings.editorShortcuts = EditorShortcutSettings()
                    }
                }
            }
        }
        .formStyle(.columns)
    }

    private func globalBinding(_ action: ShortcutAction) -> Binding<KeyCombo?> {
        Binding(get: { settings.shortcuts.combo(for: action) }, set: { settings.setShortcut($0, for: action) })
    }

    private func editorBinding(_ action: EditorAction) -> Binding<KeyCombo?> {
        Binding(get: { settings.editorShortcuts.combo(for: action) }, set: { settings.setShortcut($0, for: action) })
    }
}

private struct HistoryPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Keep:", selection: $settings.historyLimit) {
                Text("The last 50 captures").tag(50)
                Text("The last 200 captures").tag(200)
                Text("The last 1,000 captures").tag(1000)
                Text("All of them").tag(Int.max)
                Text("None (history off)").tag(0)
            }
            .fixedSize()
            .onChange(of: settings.historyLimit) { LibraryStore.shared.applyLimit() }
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Each capture is kept with its annotations, which stay editable from Recent captures. Files you save in your folder are not touched.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open recent captures") { (NSApp.delegate as? AppDelegate)?.showGallery() }
                        Button("Empty history…", role: .destructive, action: confirmClear)
                            .disabled(LibraryStore.shared.items.isEmpty)
                    }
                }
            }
        }
        .formStyle(.columns)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Empty the history?")
        alert.informativeText = String(localized: "The \(LibraryStore.shared.items.count) captures in the history will be deleted.")
        alert.addButton(withTitle: String(localized: "Empty"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { LibraryStore.shared.deleteAll() }
    }
}

private struct ImportPane: View {
    @Bindable var settings: AppSettings
    let window: () -> NSWindow?

    var body: some View {
        Form {
            LabeledContent(String(localized: "Shottr:")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Brings Shottr's shortcuts and its S3 upload settings (bucket, endpoint, region, folder and link). The S3 keys cannot be read: type them in Upload.")
                        .frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text("macOS protects other apps' settings: select “cc.ffitch.shottr.plist” in the panel that opens.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Button("Import from Shottr…") { ShottrImporter.run(into: settings, parent: window()) }
                        .disabled(!ShottrImporter.isShottrInstalled)
                    if !ShottrImporter.isShottrInstalled {
                        Text("Shottr is not installed on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.columns)
    }
}
