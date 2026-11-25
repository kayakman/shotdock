import AppKit
import Observation
import ShotDockCore

enum EditorTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, highlight, text, step, blur, pixelate, eraser, crop, ruler, colorPicker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: "Flecha"
        case .rectangle: "Rectángulo"
        case .ellipse: "Óvalo"
        case .highlight: "Resaltador"
        case .text: "Texto"
        case .step: "Paso numerado"
        case .blur: "Desenfocar"
        case .pixelate: "Pixelar"
        case .eraser: "Borrador inteligente"
        case .crop: "Recortar"
        case .ruler: "Regla"
        case .colorPicker: "Cuentagotas"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .step: "1.circle.fill"
        case .blur: "drop.halffull"
        case .pixelate: "checkerboard.rectangle"
        case .eraser: "eraser"
        case .crop: "crop"
        case .ruler: "ruler"
        case .colorPicker: "eyedropper"
        }
    }

    /// Single-key shortcut while the canvas has focus.
    var key: String {
        switch self {
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .highlight: "h"
        case .text: "t"
        case .step: "n"
        case .blur: "b"
        case .pixelate: "p"
        case .eraser: "e"
        case .crop: "c"
        case .ruler: "m"
        case .colorPicker: "i"
        }
    }

    /// Tools whose marks take the selected colour.
    var usesColor: Bool { ![.blur, .pixelate, .eraser, .crop, .ruler, .colorPicker].contains(self) }

    /// Tools that inspect the capture instead of drawing on it.
    var isInspector: Bool { self == .ruler || self == .colorPicker }

    /// Each tool remembers its colour; the highlighter starts yellow.
    var defaultColor: RGBAColor { self == .highlight ? .yellow : .red }
}

enum LineWeight: CGFloat, CaseIterable, Identifiable {
    case thin = 3, medium = 6, thick = 10

    var id: CGFloat { rawValue }
    var title: String {
        switch self {
        case .thin: "Fino"
        case .medium: "Medio"
        case .thick: "Grueso"
        }
    }
}

@MainActor
@Observable
final class EditorModel {
    private(set) var document: CaptureDocument {
        didSet { onDocumentChange?() }
    }
    var tool: EditorTool = .arrow
    private var colorsByTool: [EditorTool: RGBAColor] = [:]
    var color: RGBAColor {
        get { colorsByTool[tool] ?? tool.defaultColor }
        set {
            colorsByTool[tool] = newValue
            restyleSelection { $0.color = newValue }
        }
    }
    var weight: LineWeight = .medium {
        didSet {
            let style = currentStyle
            restyleSelection { $0.lineWidth = style.lineWidth; $0.fontSize = style.fontSize }
        }
    }
    var selectedID: UUID? {
        didSet { onDocumentChange?() }
    }
    /// Message shown briefly in the toolbar ("Copiado").
    var status: String?

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var onDocumentChange: (() -> Void)?

    init(document: CaptureDocument) {
        self.document = document
        // Each edit is its own undo step, even when several happen in one event.
        undoManager.groupsByEvent = false
    }

    /// Style for new annotations; sizes scale with the capture so marks look
    /// the same on Retina and non-Retina captures.
    var currentStyle: AnnotationStyle {
        let factor = document.scale / 2
        return AnnotationStyle(color: color, lineWidth: weight.rawValue * factor,
                               fontSize: (20 + weight.rawValue * 3) * factor)
    }

    var selected: Annotation? { document.annotations.first { $0.id == selectedID } }

    func annotation(at point: CGPoint) -> Annotation? {
        let tolerance = 4 * document.scale
        // Vector marks are drawn above pixel effects, so they win the click.
        return document.annotations.last { !$0.isPixelEffect && $0.hitTest(point, tolerance: tolerance) }
            ?? document.annotations.last { $0.isPixelEffect && $0.hitTest(point, tolerance: tolerance) }
    }

    // MARK: Edits (all undoable)

    func add(_ annotation: Annotation) {
        guard !annotation.isDegenerate else { return }
        perform(tool.title) { $0.annotations.append(annotation) }
        selectedID = annotation.id
    }

    func replace(_ annotation: Annotation, actionName: String) {
        if annotation.isDegenerate { return delete(id: annotation.id) }
        perform(actionName) { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
            document.annotations[index] = annotation
        }
    }

    /// Live update while dragging; the drag registers one undo step at the end.
    func replaceWithoutUndo(_ annotation: Annotation) {
        guard let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        document.annotations[index] = annotation
    }

    func deleteSelected() {
        if let selectedID { delete(id: selectedID) }
    }

    func delete(id: UUID) {
        perform("Eliminar") { $0.annotations.removeAll { $0.id == id } }
        if selectedID == id { selectedID = nil }
    }

    func crop(to rect: CGRect) {
        let rect = rect.intersection(document.visibleRect).pixelAligned
        guard rect.width >= 4, rect.height >= 4 else { return }
        perform("Recortar") { $0.crop = rect }
    }

    private func restyleSelection(_ change: (inout AnnotationStyle) -> Void) {
        guard var annotation = selected else { return }
        change(&annotation.style)
        if annotation != selected { replace(annotation, actionName: "Cambiar estilo") }
    }

    /// The undoable part of a document.
    private struct EditState {
        var annotations: [Annotation]
        var crop: CGRect?
        var backdrop: Backdrop?
    }

    private var editState: EditState {
        get { EditState(annotations: document.annotations, crop: document.crop, backdrop: document.backdrop) }
        set {
            document.annotations = newValue.annotations
            document.crop = newValue.crop
            document.backdrop = newValue.backdrop
        }
    }

    private func perform(_ actionName: String, _ change: (inout CaptureDocument) -> Void) {
        let before = editState
        change(&document)
        registerUndoGroup(restoring: before, actionName: actionName)
    }

    private func registerUndoGroup(restoring state: EditState, actionName: String) {
        undoManager.beginUndoGrouping()
        registerUndo(restoring: state, actionName: actionName)
        undoManager.endUndoGrouping()
    }

    private func registerUndo(restoring state: EditState, actionName: String) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.editState
                model.editState = state
                if let id = model.selectedID, !state.annotations.contains(where: { $0.id == id }) { model.selectedID = nil }
                model.registerUndo(restoring: current, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: Backdrop

    @ObservationIgnored private var backdropBeforeEdit: EditState?

    var backdrop: Backdrop? { document.backdrop }

    /// Turns the backdrop on (with the last one used) or off.
    func setBackdropEnabled(_ enabled: Bool) {
        guard enabled != (document.backdrop != nil) else { return }
        let backdrop = enabled ? AppSettings.shared.lastBackdrop : nil
        perform(enabled ? "Añadir fondo" : "Quitar fondo") { $0.backdrop = backdrop }
    }

    /// Live change (sliders): call `commitBackdropEdit` when the gesture ends.
    func updateBackdrop(_ backdrop: Backdrop, live: Bool = false) {
        if live {
            if backdropBeforeEdit == nil { backdropBeforeEdit = editState }
            document.backdrop = backdrop
        } else {
            let before = backdropBeforeEdit ?? editState
            backdropBeforeEdit = nil
            document.backdrop = backdrop
            registerUndoGroup(restoring: before, actionName: "Cambiar fondo")
        }
        AppSettings.shared.lastBackdrop = backdrop
    }

    func commitBackdropEdit() {
        guard let backdrop = document.backdrop, backdropBeforeEdit != nil else { return }
        updateBackdrop(backdrop)
    }

    // MARK: Output

    func flattened() -> CGImage? { document.flattened() }

    func copyToClipboard() {
        guard let image = flattened(), Pasteboard.copy(image, scale: document.scale) else { return }
        flash("Copiado")
    }

    /// Copies the colour of a pixel in the format chosen in Preferences.
    func copyColor(at point: CGPoint) {
        guard let color = Measure.color(in: document.image, at: point) else { return }
        let text = AppSettings.shared.colorFormat.string(for: color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copiado \(text)")
    }

    func flash(_ message: String) {
        status = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.status == message { self?.status = nil }
        }
    }
}
