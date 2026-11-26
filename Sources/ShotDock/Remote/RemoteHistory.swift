import AppKit
import ShotDockCore

/// The history ("the dock") for agents: what the gallery does.
@MainActor
enum RemoteHistory {
    static var store: LibraryStore { LibraryStore.shared }
    static var coordinator: CaptureCoordinator { RemoteCapture.coordinator }

    static let handlers: [String: RemoteHandler] = [
        "history.list": { params, _ in
            var filter = HistoryFilter(search: params["search"]?.stringValue, uploaded: params["uploaded"]?.boolValue,
                                       saved: params["saved"]?.boolValue)
            if let since = params["since"]?.stringValue {
                guard let date = RelativeDate.parse(since) else { throw RPCError.invalidParams("since: use a date (2026-11-25) or an age (2h, 3d)") }
                filter.since = date
            }
            let limit = max(params["limit"]?.intValue ?? 20, 0)
            let matching = store.items(matching: filter)
            return [
                "enabled": .bool(store.isEnabled),
                "total": .number(Double(matching.count)),
                "captures": .array(matching.prefix(limit).map(json)),
            ]
        },
        "history.show": { params, _ in
            let id = try store.resolve(params["target"]?.stringValue ?? "")
            let document = try RemoteDocuments.document(id)
            var result = json(try item(id)).objectValue ?? [:]
            let view = DocumentView(document)
            result["annotations"] = .array(document.annotations.map { AnnotationCoding.json($0, view: view) })
            // The crop in pixels of the original capture.
            result["crop"] = document.crop.map(JSONValue.init) ?? .null
            result["resize"] = document.resize.map { .number($0) } ?? .null
            result["backdrop"] = try document.backdrop.map { try JSONValue(encoding: $0) } ?? .null
            result["original_width"] = .number(Double(document.image.width))
            result["original_height"] = .number(Double(document.image.height))
            result["open_in_editor"] = .bool(RemoteDocuments.editor(for: id) != nil)
            return .object(result.merging(try rendered(document, out: nil, format: nil).objectValue ?? [:]) { _, new in new })
        },
        "history.open": { params, _ in
            let id = try store.resolve(params["target"]?.stringValue ?? "")
            coordinator.openEditor(libraryItem: id)
            return ["id": .string(id.uuidString), "opened": true]
        },
        "history.copy": { params, _ in
            let id = try store.resolve(params["target"]?.stringValue ?? "")
            let (image, document) = try flattened(id)
            return ["id": .string(id.uuidString), "copied": .bool(Pasteboard.copy(image, scale: document.exportScale))]
        },
        "history.save": { params, _ in
            let id = try store.resolve(params["target"]?.stringValue ?? "")
            let (image, document) = try flattened(id)
            let url = try coordinator.save(image, scale: document.exportScale, date: document.createdAt)
            store.markSaved(id, at: url)
            return ["id": .string(id.uuidString), "saved_path": .string(url.path)]
        },
        "history.export": { params, _ in
            let id = try store.resolve(params["target"]?.stringValue ?? "")
            var result = try rendered(try RemoteDocuments.document(id), out: params["out"]?.stringValue, format: params["format"]?.stringValue)
            if case var .object(object) = result { object["id"] = .string(id.uuidString); result = .object(object) }
            return result
        },
        "history.reveal": { params, _ in
            let id = try store.resolve(params["target"]?.stringValue ?? "")
            guard let path = try item(id).savedPath, FileManager.default.fileExists(atPath: path) else {
                throw RPCError.notFound("This capture has not been saved (history save saves it)")
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return ["id": .string(id.uuidString), "saved_path": .string(path)]
        },
        "history.delete": { params, _ in
            let targets = params["targets"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if params["all"]?.boolValue == true {
                guard targets.isEmpty else { throw RPCError.invalidParams("Give captures or all, not both") }
                let count = store.items.count
                store.deleteAll()
                return ["deleted": .number(Double(count))]
            }
            guard !targets.isEmpty else { throw RPCError.invalidParams("history.delete needs captures, or all") }
            let ids = try Set(targets.map { try store.resolve($0) })
            store.delete(ids)
            return ["deleted": .number(Double(ids.count)), "ids": .array(ids.map { .string($0.uuidString) })]
        },
        "history.import": { params, _ in
            let path = params["file"]?.stringValue ?? ""
            let id = try RemoteDocuments.importFile(path, scale: params["scale"]?.doubleValue.map { CGFloat($0) })
            let document = try RemoteDocuments.document(id)
            return ["id": .string(id.uuidString), "path": .string(path), "width": .number(Double(document.image.width)),
                    "height": .number(Double(document.image.height)), "scale": .number(document.scale)]
        },
        "history.duplicate": { params, _ in
            let source = try store.resolve(params["target"]?.stringValue ?? "")
            let edited = try RemoteDocuments.document(source)
            var copy = CaptureDocument(image: edited.image, scale: edited.scale)
            if params["original"]?.boolValue != true {
                // New ids: an annotation id names one mark of one capture.
                copy.annotations = edited.annotations.map { Annotation(shape: $0.shape, style: $0.style) }
                copy.crop = edited.crop
                copy.resize = edited.resize
                copy.backdrop = edited.backdrop
            }
            guard let id = store.add(copy) else { throw RPCError.notFound("The history is off (Preferences › History)") }
            return try RemoteDocuments.result(id, copy, extra: ["source": .string(source.uuidString)])
        },
        "history.gallery": { _, _ in
            (NSApp.delegate as? AppDelegate)?.showGallery()
            return ["opened": true]
        },
    ]

    static func item(_ id: UUID) throws -> CaptureItem {
        guard let item = store.item(id) else { throw RPCError.notFound("No capture \(id.uuidString) in the history") }
        return item
    }

    static func json(_ item: CaptureItem) -> JSONValue {
        [
            "id": .string(item.id.uuidString),
            "created_at": .string(ISO8601DateFormatter().string(from: item.createdAt)),
            "width": .number(Double(item.pixelWidth)),
            "height": .number(Double(item.pixelHeight)),
            "scale": .number(item.exportScale ?? item.scale),
            "annotations": .number(Double(item.annotationCount)),
            "saved_path": item.savedPath.map(JSONValue.string) ?? .null,
            "url": item.uploadedURL.map(JSONValue.string) ?? .null,
            "thumbnail": LibraryStore.shared.thumbnailURL(item.id).map { .string($0.path) } ?? .null,
            "text": item.recognizedText.map { .string(String($0.prefix(200))) } ?? .null,
        ]
    }

    static func flattened(_ id: UUID) throws -> (CGImage, CaptureDocument) {
        let document = try RemoteDocuments.document(id)
        guard let image = document.flattened() else { throw RPCError.internalError("Cannot draw the capture") }
        return (image, document)
    }

    /// The edited image written to a file: the path and its size.
    static func rendered(_ document: CaptureDocument, out: String?, format: String?) throws -> JSONValue {
        guard let image = document.flattened() else { throw RPCError.internalError("Cannot draw the capture") }
        let url = try RemoteFiles.write(image, scale: document.exportScale, date: document.createdAt, to: out, format: format)
        return ["path": .string(url.path), "width": .number(Double(image.width)), "height": .number(Double(image.height)),
                "scale": .number(document.exportScale)]
    }
}

/// Documents of the history as they are now: an open editor has the latest
/// edits (its saves to disk are debounced), otherwise the library.
@MainActor
enum RemoteDocuments {
    static func editor(for id: UUID) -> EditorWindowController? {
        RemoteCapture.coordinator.editors.first { $0.libraryItemID == id }
    }

    static func document(_ id: UUID) throws -> CaptureDocument {
        if let editor = editor(for: id) { return editor.model.document }
        guard let document = LibraryStore.shared.document(id) else { throw RPCError.notFound("No capture \(id.uuidString) in the history") }
        return document
    }
}
