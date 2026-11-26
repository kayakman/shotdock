import AppKit
import Observation
import ShotDockCore

/// The capture history as the UI sees it: observable items, cached
/// thumbnails and debounced saving of edits.
@MainActor
@Observable
final class LibraryStore {
    static var shared = LibraryStore(root: CaptureLibrary.defaultRoot)

    private(set) var items: [CaptureItem] = []
    @ObservationIgnored private var library: CaptureLibrary?
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    /// Bumped when a thumbnail changes so views reload it.
    private(set) var revision = 0

    init(root: URL) {
        do {
            library = try CaptureLibrary(root: root)
            items = library?.items ?? []
        } catch {
            NSLog("ShotDock: cannot open the capture library: \(error)")
        }
    }

    var isEnabled: Bool { AppSettings.shared.historyLimit != 0 }

    /// Adds a new capture and trims the history to the configured size.
    func add(_ document: CaptureDocument) -> UUID? {
        guard isEnabled, let library, let item = try? library.add(document) else { return nil }
        let removed = (try? library.prune(keeping: AppSettings.shared.historyLimit)) ?? []
        removed.forEach { thumbnails[$0] = nil }
        refresh()
        return item.id
    }

    /// Saves edits a moment after the last change, so dragging does not write on every frame.
    func scheduleUpdate(_ id: UUID, with document: CaptureDocument) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.update(id, with: document)
        }
    }

    func update(_ id: UUID, with document: CaptureDocument) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        guard let library, library.item(id) != nil else { return }
        try? library.update(id, with: document)
        thumbnails[id] = nil
        refresh()
    }

    func markSaved(_ id: UUID, at url: URL) {
        try? library?.markSaved(id, at: url)
        refresh()
    }

    func markUploaded(_ id: UUID, link: URL) {
        try? library?.markUploaded(id, link: link)
        refresh()
    }

    func delete(_ ids: Set<UUID>) {
        ids.forEach { pendingSaves[$0]?.cancel(); thumbnails[$0] = nil }
        try? library?.delete(ids)
        refresh()
    }

    func deleteAll() { delete(Set(items.map(\.id))) }

    func applyLimit() {
        guard let library else { return }
        let limit = AppSettings.shared.historyLimit
        if limit == 0 { return deleteAll() }
        let removed = (try? library.prune(keeping: limit)) ?? []
        removed.forEach { thumbnails[$0] = nil }
        refresh()
    }

    func document(_ id: UUID) -> CaptureDocument? { try? library?.document(id) }

    func item(_ id: UUID) -> CaptureItem? { library?.item(id) }

    func items(matching filter: HistoryFilter) -> [CaptureItem] { library?.items(matching: filter) ?? [] }

    func originalURL(_ id: UUID) -> URL? { library?.originalURL(id) }

    func thumbnailURL(_ id: UUID) -> URL? { library?.thumbnailURL(id) }

    /// A capture named the way agents do: id, id prefix, last, last-1…
    func resolve(_ reference: String) throws -> UUID {
        guard isEnabled else { throw RPCError.notFound("The history is off (Preferences › History)") }
        return try CaptureReference.resolve(reference, in: items)
    }

    func setRecognizedText(_ id: UUID, _ text: String) {
        try? library?.setRecognizedText(id, text)
        refresh()
    }

    func thumbnail(_ id: UUID) -> NSImage? {
        if let cached = thumbnails[id] { return cached }
        guard let url = library?.thumbnailURL(id), let image = NSImage(contentsOf: url) else { return nil }
        thumbnails[id] = image
        return image
    }

    /// Writes the edited image to a temporary file, for drag and drop.
    func exportForDrag(_ id: UUID) -> URL? {
        guard let document = document(id), let image = document.flattened() else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDock Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(FilenameTemplate(AppSettings.shared.filenameTemplate).name(for: document.createdAt))
            .appendingPathExtension("png")
        guard (try? ImageEncoding.write(image, to: url, scale: document.exportScale)) != nil else { return nil }
        return url
    }

    private func refresh() {
        items = library?.items ?? []
        revision += 1
    }
}
