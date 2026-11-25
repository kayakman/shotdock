import AppKit
import ShotDockCore

/// Editing captures for agents: annotations, crop, resize and backdrop, kept
/// as editable state in the history exactly as the editor keeps them. With
/// the capture open in an editor, changes go through it and can be undone.
@MainActor
enum RemoteEditing {
    static let handlers: [String: RemoteHandler] = [
        "annotate": { params, _ in try await annotate(params) },
        "annotations": { params, _ in
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            let view = DocumentView(document)
            var result = try RemoteDocuments.result(id, document).objectValue ?? [:]
            result["annotations"] = .array(document.annotations.map { AnnotationCoding.json($0, view: view) })
            return .object(result)
        },
        "annotation.update": { params, _ in try update(params) },
        "annotation.remove": { params, _ in
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            let prefixes = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let removed: Set<UUID>
            if params["all"]?.boolValue == true {
                removed = Set(document.annotations.map(\.id))
            } else {
                guard !prefixes.isEmpty else { throw RPCError.invalidParams("annotation.remove needs ids, or all") }
                removed = Set(try prefixes.map { try annotation($0, in: document).id })
            }
            let edited = try RemoteDocuments.edit(id, "Eliminar") { $0.annotations.removeAll { removed.contains($0.id) } }
            return try RemoteDocuments.result(id, edited, extra: ["removed": .number(Double(removed.count))])
        },
        "crop": { params, _ in
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            if params["reset"]?.boolValue == true {
                return try RemoteDocuments.result(id, try RemoteDocuments.edit(id, "Deshacer recorte") { $0.crop = nil })
            }
            guard var rect = params["rect"]?.rect else { throw RPCError.invalidParams("crop needs rect, or reset") }
            if params["space"]?.stringValue == "preview" { rect = rect.scaled(by: 1 / ImagePreview.scale(for: document.outputSize)) }
            let crop = DocumentView(document).toDocument(rect).intersection(document.fullRect).pixelAligned
            guard crop.width >= 4, crop.height >= 4 else { throw RPCError.invalidParams("The crop must be at least 4×4 pixels of the image") }
            return try RemoteDocuments.result(id, try RemoteDocuments.edit(id, "Recortar") { $0.crop = crop })
        },
        "resize": { params, _ in
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            var factor: CGFloat?
            if params["reset"]?.boolValue != true {
                factor = params["scale"]?.doubleValue.map { CGFloat($0) }
                    ?? document.resizeFactor(width: params["width"]?.doubleValue, height: params["height"]?.doubleValue)
                guard let value = factor else { throw RPCError.invalidParams("resize needs width, height, scale or reset") }
                guard value >= 0.05, value <= 8 else { throw RPCError.invalidParams("That is \(Int(value * 100)) % of the size; use 5 % to 800 %") }
                if abs(value - 1) < 0.0001 { factor = nil }
            }
            let edited = try RemoteDocuments.edit(id, factor == nil ? "Tamaño original" : "Redimensionar") { $0.resize = factor }
            return try RemoteDocuments.result(id, edited)
        },
        "backdrop": { params, _ in try backdrop(params) },
        "redact": { params, _ in
            let id = try RemoteDocuments.resolve(params["target"])
            let document = try RemoteDocuments.document(id)
            let kinds = Set(params["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            if let unknown = kinds.first(where: { !SecretScanner.kinds.contains($0) }) {
                throw RPCError.invalidParams("Unknown kind \(unknown); use \(SecretScanner.kinds.joined(separator: ", "))")
            }
            let (boxes, findings) = try await Redaction.annotations(for: document, kinds: kinds)
            let report = findingsJSON(findings)
            if params["dry_run"]?.boolValue == true || boxes.isEmpty {
                return try RemoteDocuments.result(id, document, extra: ["found": report, "covered": .number(0)])
            }
            let edited = try RemoteDocuments.edit(id, "Ocultar secretos") { $0.annotations += boxes }
            return try RemoteDocuments.result(id, edited, extra: ["found": report, "covered": .number(Double(boxes.count))])
        },
    ]

    // MARK: Annotations

    static func annotate(_ params: [String: JSONValue]) async throws -> JSONValue {
        let id = try RemoteDocuments.resolve(params["target"])
        let document = try RemoteDocuments.document(id)
        guard let marks = params["annotations"]?.arrayValue, !marks.isEmpty else {
            throw RPCError.invalidParams("annotations must be a list of annotations")
        }
        let fromPreview = params["space"]?.stringValue == "preview" ? 1 / ImagePreview.scale(for: document.outputSize) : 1
        let view = DocumentView(document)
        var located: [String: CGRect] = [:]
        var nextStep = document.nextStepNumber
        var added: [Annotation] = []
        for mark in marks {
            var json = AnnotationCoding.scaled(mark, by: fromPreview)
            if let text = json["on_text"]?.stringValue {
                let box = try await locate(text, in: document, cache: &located)
                json = AnnotationCoding.placing(json, on: box, imageSize: document.outputSize, scale: document.exportScale)
            }
            let annotation = try AnnotationCoding.annotation(from: json, for: document, view: view, nextStep: nextStep)
            if case let .step(_, number) = annotation.shape { nextStep = max(nextStep, number + 1) }
            added.append(annotation)
        }
        let edited = try RemoteDocuments.edit(id, added.count == 1 ? "Anotar" : "Anotar (\(added.count))") { $0.annotations += added }
        return try RemoteDocuments.result(id, edited, extra: ["added": .array(added.map { .string($0.id.uuidString) })])
    }

    /// Where `text` is on the edited image, by OCR; the error lists what is there.
    static func locate(_ text: String, in document: CaptureDocument, cache: inout [String: CGRect]) async throws -> CGRect {
        if let box = cache[text] { return box }
        guard let image = document.flattened() else { throw RPCError.internalError("Cannot draw the capture") }
        let result = try await TextRecognition.recognize(image, find: text)
        guard let box = result.matches.first else {
            let seen = result.lines.prefix(40).joined(separator: " | ")
            throw RPCError.notFound("\"\(text)\" is not on the image. Text found: \(seen.isEmpty ? "none" : seen)")
        }
        cache[text] = box
        return box
    }

    static func annotation(_ prefix: String, in document: CaptureDocument) throws -> Annotation {
        let text = prefix.lowercased()
        let matches = document.annotations.filter { $0.id.uuidString.lowercased().hasPrefix(text) }
        guard matches.count == 1, text.count >= 4 || matches[0].id.uuidString.lowercased() == text else {
            throw matches.isEmpty ? RPCError.notFound("No annotation \(prefix) on this capture")
                : RPCError.invalidParams("\(prefix) matches several annotations; give more of the id")
        }
        return matches[0]
    }

    static func update(_ params: [String: JSONValue]) throws -> JSONValue {
        let id = try RemoteDocuments.resolve(params["target"])
        let document = try RemoteDocuments.document(id)
        let existing = try annotation(params["id"]?.stringValue ?? "", in: document)
        let view = DocumentView(document)
        guard var merged = AnnotationCoding.json(existing, view: view).objectValue else { throw RPCError.internalError("Cannot read the annotation") }
        let keys = ["from", "to", "at", "rect", "source", "lens", "text", "number", "round", "color", "weight", "line_width", "font_size"]
        var changes: [String: JSONValue] = [:]
        for key in keys { if let value = params[key] { changes[key] = value } }
        guard !changes.isEmpty else { throw RPCError.invalidParams("Nothing to change: give a position, text, colour or size") }
        if params["space"]?.stringValue == "preview" {
            changes = AnnotationCoding.scaled(.object(changes), by: 1 / ImagePreview.scale(for: document.outputSize)).objectValue ?? changes
        }
        // A new weight sets both sizes, unless they are given too.
        if changes["weight"] != nil {
            merged["line_width"] = nil
            merged["font_size"] = nil
        }
        merged.merge(changes) { _, new in new }
        let changed = try AnnotationCoding.annotation(from: .object(merged), for: document, view: view)
        let edited = try RemoteDocuments.edit(id, "Cambiar") { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == existing.id }) else { return }
            document.annotations[index] = changed
        }
        return try RemoteDocuments.result(id, edited, extra: ["annotation": AnnotationCoding.json(changed, view: DocumentView(edited))])
    }

    /// What was found, masked: enough to know what it was, never the secret.
    static func findingsJSON(_ findings: [RecognizedSecret]) -> JSONValue {
        .array(findings.map { ["kind": .string($0.kind), "masked": .string($0.masked), "box": JSONValue($0.box)] })
    }

    // MARK: Backdrop

    static let aspects: [String: Backdrop.Aspect] = ["auto": .auto, "1:1": .square, "16:9": .wide, "4:3": .standard, "4:5": .portrait]

    static func backdrop(_ params: [String: JSONValue]) throws -> JSONValue {
        let id = try RemoteDocuments.resolve(params["target"])
        let document = try RemoteDocuments.document(id)
        if params["off"]?.boolValue == true {
            return try RemoteDocuments.result(id, try RemoteDocuments.edit(id, "Quitar fondo") { $0.backdrop = nil })
        }
        var backdrop = document.backdrop ?? AppSettings.shared.lastBackdrop
        if let preset = params["preset"]?.intValue {
            guard Backdrop.presets.indices.contains(preset - 1) else { throw RPCError.invalidParams("preset must be 1–\(Backdrop.presets.count)") }
            backdrop.fill = Backdrop.presets[preset - 1]
        }
        if let gradient = params["gradient"]?.stringValue {
            let parts = gradient.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 || parts.count == 3, let from = RGBAColor(string: parts[0]), let to = RGBAColor(string: parts[1]),
                  let angle = parts.count == 3 ? Double(parts[2]) : 45 else {
                throw RPCError.invalidParams("gradient: colour,colour[,angle], e.g. #FF8C3D,#EE386E,45")
            }
            backdrop.fill = .gradient(from, to, angle: angle)
        }
        if let solid = params["solid"]?.stringValue.flatMap(RGBAColor.init(string:)) { backdrop.fill = .solid(solid) }
        if let padding = params["padding"]?.doubleValue { backdrop.padding = max(0, padding) }
        if let radius = params["radius"]?.doubleValue { backdrop.cornerRadius = max(0, radius) }
        if let shadow = params["shadow"]?.doubleValue { backdrop.shadow = min(max(shadow, 0), 1) }
        if let aspect = params["aspect"]?.stringValue.flatMap({ aspects[$0] }) { backdrop.aspect = aspect }
        AppSettings.shared.lastBackdrop = backdrop
        let edited = try RemoteDocuments.edit(id, document.backdrop == nil ? "Añadir fondo" : "Cambiar fondo") { $0.backdrop = backdrop }
        return try RemoteDocuments.result(id, edited, extra: ["backdrop": try JSONValue(encoding: backdrop)])
    }
}

extension RemoteDocuments {
    /// The `target` parameter: a capture of the history, or an image file
    /// (absolute, as the CLI and MCP server pass it) added to the history.
    static func resolve(_ target: JSONValue?) throws -> UUID {
        let text = target?.stringValue ?? ""
        if text.hasPrefix("/") { return try importFile(text, scale: nil) }
        return try LibraryStore.shared.resolve(text)
    }

    static func importFile(_ path: String, scale: CGFloat?) throws -> UUID {
        guard let data = FileManager.default.contents(atPath: path) else { throw RPCError.notFound("Cannot read \(path)") }
        guard let image = try? ImageEncoding.image(from: data) else { throw RPCError.invalidParams("\(path) is not an image") }
        let scale = scale ?? ImageEncoding.scale(of: data)
        guard scale > 0 else { throw RPCError.invalidParams("scale must be positive") }
        guard let id = LibraryStore.shared.add(CaptureDocument(image: image, scale: scale)) else {
            throw RPCError.notFound("The history is off (Preferencias › Historial)")
        }
        return id
    }

    /// Applies a change: through the open editor (undoable there), or to the library.
    @discardableResult
    static func edit(_ id: UUID, _ actionName: String, _ change: (inout CaptureDocument) -> Void) throws -> CaptureDocument {
        if let editor = editor(for: id) {
            editor.model.applyExternal(actionName, change)
            return editor.model.document
        }
        var document = try document(id)
        change(&document)
        LibraryStore.shared.update(id, with: document)
        return document
    }

    /// What edit commands return: the edited image written to a file.
    static func result(_ id: UUID, _ document: CaptureDocument, extra: [String: JSONValue] = [:]) throws -> JSONValue {
        var result = try RemoteHistory.rendered(document, out: nil, format: nil).objectValue ?? [:]
        result["id"] = .string(id.uuidString)
        result["annotation_count"] = .number(Double(document.annotations.count))
        result.merge(extra) { _, new in new }
        return .object(result)
    }
}

extension CGRect {
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}
