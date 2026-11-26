import AppKit
import Observation
import ShotDockCore

enum EditorTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, highlight, text, step, magnifier, blur, pixelate, eraser, crop, ruler, colorPicker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: String(localized: "Arrow")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Oval")
        case .highlight: String(localized: "Highlighter")
        case .text: String(localized: "Text")
        case .step: String(localized: "Numbered Step")
        case .magnifier: String(localized: "Magnifier")
        case .blur: String(localized: "Blur")
        case .pixelate: String(localized: "Pixelate")
        case .eraser: String(localized: "Smart Eraser")
        case .crop: String(localized: "Crop")
        case .ruler: String(localized: "Ruler")
        case .colorPicker: String(localized: "Color Picker")
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
        case .magnifier: "plus.magnifyingglass"
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
        case .magnifier: "z"
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
        case .thin: String(localized: "Thin")
        case .medium: String(localized: "Medium")
        case .thick: String(localized: "Thick")
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
    /// Shape of new magnifiers; also applied to the selected one.
    var magnifierRound = true {
        didSet {
            guard var annotation = selected, case let .magnifier(source, target, round) = annotation.shape,
                  round != magnifierRound else { return }
            annotation.shape = .magnifier(source: source, target: target, round: magnifierRound)
            replace(annotation, actionName: String(localized: "Change Magnifier Shape"))
        }
    }

    var showsMagnifierOptions: Bool {
        if tool == .magnifier { return true }
        if case .magnifier = selected?.shape { return true }
        return false
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
        AnnotationStyle.standard(color: color, weight: weight.rawValue, scale: document.scale)
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
        perform(String(localized: "Delete")) { $0.annotations.removeAll { $0.id == id } }
        if selectedID == id { selectedID = nil }
    }

    func crop(to rect: CGRect) {
        let rect = rect.intersection(document.visibleRect).pixelAligned
        guard rect.width >= 4, rect.height >= 4 else { return }
        perform(String(localized: "Crop")) { $0.crop = rect }
    }

    private func restyleSelection(_ change: (inout AnnotationStyle) -> Void) {
        guard var annotation = selected else { return }
        change(&annotation.style)
        if annotation != selected { replace(annotation, actionName: String(localized: "Change Style")) }
    }

    /// The undoable part of a document.
    private struct EditState {
        var annotations: [Annotation]
        var crop: CGRect?
        var backdrop: Backdrop?
        var resize: CGFloat?
    }

    private var editState: EditState {
        get { EditState(annotations: document.annotations, crop: document.crop, backdrop: document.backdrop, resize: document.resize) }
        set {
            document.annotations = newValue.annotations
            document.crop = newValue.crop
            document.backdrop = newValue.backdrop
            document.resize = newValue.resize
        }
    }

    /// Export size as a fraction of the drawn size; nil or 1 is the original.
    func resize(to factor: CGFloat?) {
        let factor = factor.flatMap { abs($0 - 1) < 0.0001 ? nil : $0 }
        guard factor != document.resize else { return }
        perform(factor == nil ? String(localized: "Original Size") : String(localized: "Resize")) { $0.resize = factor }
    }

    /// A change made from outside the editor (an agent), undoable like the user's own.
    func applyExternal(_ actionName: String, _ change: (inout CaptureDocument) -> Void) {
        perform(actionName, change)
        if let id = selectedID, !document.annotations.contains(where: { $0.id == id }) { selectedID = nil }
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
        perform(enabled ? String(localized: "Add Backdrop") : String(localized: "Remove Backdrop")) { $0.backdrop = backdrop }
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
            registerUndoGroup(restoring: before, actionName: String(localized: "Change Backdrop"))
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
        guard let image = flattened(), Pasteboard.copy(image, scale: document.exportScale) else { return }
        flash(String(localized: "Copied"))
    }

    /// Copies the colour of a pixel in the format chosen in Preferences.
    func copyColor(at point: CGPoint) {
        guard let color = Measure.color(in: document.image, at: point) else { return }
        let text = AppSettings.shared.colorFormat.string(for: color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(String(localized: "Copied \(text)"))
    }

    func flash(_ message: String) {
        status = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.status == message { self?.status = nil }
        }
    }
}
