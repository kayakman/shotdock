import AppKit
import ShotDockCore
import SwiftUI
import UniformTypeIdentifiers

/// "Capturas recientes": the dock of captures.
@MainActor
final class GalleryWindowController: NSWindowController, NSWindowDelegate {
    private let state = GalleryState()

    init(store: LibraryStore, coordinator: CaptureCoordinator) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Capturas recientes"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(rootView: GalleryView(store: store, state: state,
                                                          actions: GalleryActions(store: store, coordinator: coordinator, window: { [weak window] in window })))
        // The grid has no natural size; keep the window's.
        hosting.sizingOptions = []
        window.contentView = hosting
        if !window.setFrameUsingName("Gallery") { window.setContentSize(NSSize(width: 900, height: 620)) }
        window.setFrameAutosaveName("Gallery")
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

    var selection: Set<UUID> {
        get { state.selection }
        set { state.selection = newValue }
    }
}

@MainActor
@Observable
final class GalleryState {
    var selection: Set<UUID> = []
}

/// What can be done with captures in the gallery.
@MainActor
struct GalleryActions {
    let store: LibraryStore
    let coordinator: CaptureCoordinator
    let window: () -> NSWindow?

    func open(_ ids: Set<UUID>) {
        for id in ids { coordinator.openEditor(libraryItem: id) }
    }

    func copy(_ id: UUID) {
        guard let document = store.document(id), let image = document.flattened() else { return }
        Pasteboard.copy(image, scale: document.exportScale)
        HUD.show("Copiado", symbol: "checkmark.circle.fill")
    }

    func save(_ id: UUID) {
        guard let document = store.document(id), let image = document.flattened() else { return }
        do {
            let url = try coordinator.save(image, scale: document.exportScale, date: document.createdAt)
            store.markSaved(id, at: url)
            HUD.show("Guardado en \(url.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle.fill")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func upload(_ id: UUID) {
        guard let document = store.document(id), let image = document.flattened() else { return }
        guard Uploader.isConfigured else { return (NSApp.delegate as? AppDelegate)?.openPreferences(tab: .upload) ?? () }
        coordinator.upload(image, scale: document.exportScale, date: document.createdAt, libraryItem: id)
    }

    func copyLink(_ item: CaptureItem) {
        guard let link = item.uploadedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        HUD.show("Enlace copiado", symbol: "link")
    }

    func pin(_ id: UUID) {
        guard let document = store.document(id), let image = document.flattened() else { return }
        coordinator.pin(image, scale: document.exportScale)
    }

    func recognize(_ id: UUID) {
        guard let document = store.document(id), let image = document.flattened(), let window = window() else { return }
        RecognitionPanel.present(for: image, on: window)
    }

    func revealSaved(_ item: CaptureItem) {
        guard let path = item.savedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.delete(ids)
    }

    func deleteAll() {
        let alert = NSAlert()
        alert.messageText = "¿Vaciar el historial?"
        alert.informativeText = "Se borrarán las \(store.items.count) capturas del historial. Los ficheros que hayas guardado no se tocan."
        alert.addButton(withTitle: "Vaciar")
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = window() else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { store.deleteAll() }
        }
    }

    func dragProvider(_ id: UUID) -> NSItemProvider {
        guard let url = store.exportForDrag(id) else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}

struct GalleryView: View {
    @Bindable var store: LibraryStore
    @Bindable var state: GalleryState
    let actions: GalleryActions

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("Sin capturas", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(store.isEnabled ? "Las capturas que hagas aparecerán aquí." : "El historial está desactivado en Preferencias.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(store.items) { item in
                            GalleryCell(item: item, thumbnail: store.thumbnail(item.id), selected: state.selection.contains(item.id),
                                        revision: store.revision)
                                .onTapGesture(count: 2) { actions.open([item.id]) }
                                .simultaneousGesture(TapGesture().onEnded { select(item.id) })
                                .onDrag { actions.dragProvider(item.id) }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(18)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .onTapGesture { state.selection = [] }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Abrir", systemImage: "pencil.and.outline") { actions.open(state.selection) }
                    .disabled(state.selection.isEmpty)
                    .help("Abrir en el editor (↩)")
                Button("Copiar", systemImage: "doc.on.doc") { state.selection.first.map(actions.copy) }
                    .disabled(state.selection.count != 1)
                    .help("Copiar al portapapeles (⌘C)")
                Button("Eliminar", systemImage: "trash") { actions.delete(state.selection); state.selection = [] }
                    .disabled(state.selection.isEmpty)
                    .help("Eliminar del historial (⌫)")
                Menu("Más", systemImage: "ellipsis.circle") {
                    Button("Vaciar historial…", role: .destructive) { actions.deleteAll() }
                        .disabled(store.items.isEmpty)
                }
            }
        }
        .onKeyPress(.return) { actions.open(state.selection); return .handled }
        .onKeyPress(.delete) { actions.delete(state.selection); state.selection = []; return .handled }
        .onCopyCommand {
            state.selection.first.map(actions.copy)
            return []
        }
        .focusable()
        .focusEffectDisabled()
    }

    private func select(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if state.selection.contains(id) { state.selection.remove(id) } else { state.selection.insert(id) }
        } else if flags.contains(.shift), let anchor = state.selection.first,
                  let a = store.items.firstIndex(where: { $0.id == anchor }), let b = store.items.firstIndex(where: { $0.id == id }) {
            state.selection = Set(store.items[min(a, b)...max(a, b)].map(\.id))
        } else {
            state.selection = [id]
        }
    }

    @ViewBuilder
    private func menu(for item: CaptureItem) -> some View {
        Button("Abrir en el editor") { actions.open([item.id]) }
        Button("Copiar") { actions.copy(item.id) }
        Button("Guardar en la carpeta") { actions.save(item.id) }
        Button("Subir y copiar enlace") { actions.upload(item.id) }
        if item.uploadedURL != nil {
            Button("Copiar enlace") { actions.copyLink(item) }
        }
        Button("Fijar encima de todo") { actions.pin(item.id) }
        Button("Reconocer texto") { actions.recognize(item.id) }
        if item.savedPath != nil {
            Button("Mostrar en el Finder") { actions.revealSaved(item) }
        }
        Divider()
        Button("Eliminar", role: .destructive) {
            let ids = state.selection.contains(item.id) ? state.selection : [item.id]
            actions.delete(ids)
            state.selection.subtract(ids)
        }
    }
}

private struct GalleryCell: View {
    let item: CaptureItem
    let thumbnail: NSImage?
    let selected: Bool
    let revision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }
            }
            .frame(height: 150)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1))

            HStack(spacing: 6) {
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.savedPath != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).help("Guardada")
                }
                if item.uploadedURL != nil {
                    Image(systemName: "link").foregroundStyle(.secondary).help("Subida")
                }
                if item.annotationCount > 0 {
                    Image(systemName: "pencil.tip.crop.circle").foregroundStyle(.secondary).help("Con anotaciones")
                }
            }
            Text("\(item.pixelWidth) × \(item.pixelHeight) px · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .id("\(item.id)-\(revision)")
    }
}
