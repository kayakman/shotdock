import AppKit
import ShotDockCore

/// Shows the capture and handles drawing. Its bounds are the document's
/// visible rect in image pixels, so mouse locations and drawing need no
/// conversion beyond `convert(_:from:)`.
final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel

    private enum Drag {
        case drawing(start: CGPoint, annotation: Annotation)
        case moving(start: CGPoint, original: Annotation)
        case cropping(start: CGPoint, rect: CGRect)
    }

    private var drag: Drag?
    private var textField: NSTextField?
    private var editingText: Annotation?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        syncGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Matches the view to the visible part of the document, at 1 point per
    /// screen point of the original capture.
    func syncGeometry() {
        let rect = model.document.visibleRect
        let scale = model.document.scale
        let size = NSSize(width: rect.width / scale, height: rect.height / scale)
        if frame.size != size { setFrameSize(size) }
        if bounds != rect { bounds = rect }
        needsDisplay = true
    }

    private var pixelsPerScreenPoint: CGFloat {
        let magnification = enclosingScrollView?.magnification ?? 1
        return model.document.scale / max(magnification, 0.01)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let document = model.document
        context.interpolationQuality = (enclosingScrollView?.magnification ?? 1) > 1.5 ? .none : .high
        context.drawImageTopLeft(document.image, in: document.fullRect)
        AnnotationRenderer.draw(document.annotations.filter { $0.id != editingText?.id }, in: context)

        switch drag {
        case let .drawing(_, annotation):
            AnnotationRenderer.draw(annotation, in: context)
        case let .cropping(_, rect):
            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.addRect(bounds)
            context.addRect(rect)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(pixelsPerScreenPoint)
            context.stroke(rect)
        case .moving, nil:
            break
        }

        if let selected = model.selected, editingText == nil {
            let unit = pixelsPerScreenPoint
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(unit)
            context.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
            context.stroke(selected.bounds.insetBy(dx: -3 * unit, dy: -3 * unit))
        }
    }

    // MARK: Mouse

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        window?.makeFirstResponder(self)
        let point = location(of: event)

        if model.tool != .crop, let hit = model.annotation(at: point) {
            model.selectedID = hit.id
            if event.clickCount == 2, case .text = hit.shape {
                beginTextEditing(hit)
            } else {
                drag = .moving(start: point, original: hit)
            }
            return
        }
        model.selectedID = nil

        switch model.tool {
        case .arrow:
            drag = .drawing(start: point, annotation: Annotation(shape: .arrow(from: point, to: point), style: model.currentStyle))
        case .rectangle:
            drag = .drawing(start: point, annotation: Annotation(shape: .rectangle(CGRect(origin: point, size: .zero)), style: model.currentStyle))
        case .crop:
            drag = .cropping(start: point, rect: CGRect(origin: point, size: .zero))
        case .text:
            let style = model.currentStyle
            let origin = CGPoint(x: point.x, y: point.y - style.fontSize * 0.6)
            beginTextEditing(Annotation(shape: .text(origin: origin, string: ""), style: style))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var point = location(of: event)
        switch drag {
        case let .drawing(start, annotation):
            var updated = annotation
            switch annotation.shape {
            case .arrow:
                if event.modifierFlags.contains(.shift) { point = snapTo45Degrees(point, from: start) }
                updated.shape = .arrow(from: start, to: point)
            case .rectangle:
                if event.modifierFlags.contains(.shift) { point = square(point, from: start) }
                updated.shape = .rectangle(CGRect(corner: start, corner: point))
            case .text:
                break
            }
            drag = .drawing(start: start, annotation: updated)
        case let .moving(start, original):
            let moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            model.replaceWithoutUndo(moved)
        case let .cropping(start, _):
            drag = .cropping(start: start, rect: CGRect(corner: start, corner: point).intersection(bounds))
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        switch drag {
        case let .drawing(_, annotation):
            model.add(annotation)
        case let .moving(_, original):
            if let moved = model.selected, moved != original {
                model.replaceWithoutUndo(original)
                model.replace(moved, actionName: "Mover")
            }
        case let .cropping(_, rect):
            model.crop(to: rect)
        case nil:
            break
        }
    }

    private func snapTo45Degrees(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private func square(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let side = max(abs(point.x - start.x), abs(point.y - start.y))
        return CGPoint(x: start.x + (point.x < start.x ? -side : side), y: start.y + (point.y < start.y ? -side : side))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117:  // Delete, Forward Delete
            model.deleteSelected()
            return
        case 53:  // Esc
            if model.selectedID != nil { model.selectedID = nil } else { window?.performClose(nil) }
            return
        default:
            break
        }
        if flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = EditorTool.allCases.first(where: { $0.key == key }) {
            model.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    @objc func delete(_ sender: Any?) { model.deleteSelected() }

    // MARK: Text

    private func beginTextEditing(_ annotation: Annotation) {
        guard case let .text(origin, string) = annotation.shape else { return }
        editingText = annotation
        let field = NSTextField(string: string)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .bold)
        field.textColor = NSColor(cgColor: annotation.style.color.cgColor)
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.frame = CGRect(origin: origin, size: .zero)
        addSubview(field)
        textField = field
        resizeTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func resizeTextField() {
        guard let field = textField, let annotation = editingText else { return }
        let layout = TextLayout(string: field.stringValue.isEmpty ? "M" : field.stringValue, fontSize: annotation.style.fontSize)
        field.setFrameSize(NSSize(width: layout.size.width + annotation.style.fontSize, height: layout.size.height))
    }

    func controlTextDidChange(_ obj: Notification) { resizeTextField() }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            resizeTextField()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    func commitTextEditing() {
        guard let field = textField, var annotation = editingText,
              case let .text(origin, _) = annotation.shape else { return }
        textField = nil
        editingText = nil
        annotation.shape = .text(origin: origin, string: field.stringValue)
        field.removeFromSuperview()
        if model.document.annotations.contains(where: { $0.id == annotation.id }) {
            model.replace(annotation, actionName: "Editar texto")
        } else {
            model.add(annotation)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
