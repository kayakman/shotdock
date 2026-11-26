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
        case resizing(handle: Int, original: Annotation)
        case cropping(start: CGPoint, rect: CGRect)
        case measuring(start: CGPoint, end: CGPoint)
        case magnifying(start: CGPoint, rect: CGRect)
        case movingPart(start: CGPoint, original: Annotation, part: Annotation.MagnifierPart)
    }

    private var drag: Drag?
    /// Pointer position while the ruler or the eyedropper is active.
    private var hoverPoint: CGPoint?
    private var textField: NSTextField?
    private var editingText: Annotation?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        syncGeometry()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Matches the view to the visible part of the document, at 1 point per
    /// screen point of the original capture.
    /// Returns true when the canvas got bigger.
    @discardableResult
    func syncGeometry() -> Bool {
        let rect = model.document.layout.canvas
        let scale = model.document.scale
        let size = NSSize(width: rect.width / scale, height: rect.height / scale)
        let grew = size.width > frame.width || size.height > frame.height
        if frame.size != size { setFrameSize(size) }
        if bounds != rect { bounds = rect }
        needsDisplay = true
        return grew
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
        let editingID = editingText?.id
        document.draw(in: context) { $0.id != editingID }

        switch drag {
        case let .drawing(_, annotation):
            AnnotationRenderer.draw(annotation, in: context, source: document.image)
        case let .cropping(_, rect):
            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.addRect(bounds)
            context.addRect(rect)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(pixelsPerScreenPoint)
            context.stroke(rect)
        case let .measuring(start, end):
            drawMeasurement(from: start, to: end, in: context)
        case let .magnifying(_, rect):
            context.setStrokeColor(model.color.cgColor)
            context.setLineWidth(1.5 * pixelsPerScreenPoint)
            context.setLineDash(phase: 0, lengths: [5 * pixelsPerScreenPoint, 3 * pixelsPerScreenPoint])
            if model.magnifierRound { context.strokeEllipse(in: rect) } else { context.stroke(rect) }
            context.setLineDash(phase: 0, lengths: [])
        case .moving, .resizing, .movingPart, nil:
            if let hoverPoint, model.tool == .ruler { drawEdgeRuler(at: hoverPoint, in: context) }
        }
        if let hoverPoint, model.tool == .colorPicker || model.tool == .ruler {
            let unit = pixelsPerScreenPoint
            let viewport = visibleRect
            Loupe.draw(image: document.image, pixel: hoverPoint, at: Loupe.origin(near: hoverPoint, in: viewport, unit: unit),
                       unit: unit, colorFormat: AppSettings.shared.colorFormat, in: context)
        }

        if let selected = model.selected, editingText == nil {
            let unit = pixelsPerScreenPoint
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(unit)
            context.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
            if selected.handles.isEmpty {
                context.stroke(selected.bounds.insetBy(dx: -3 * unit, dy: -3 * unit))
            }
            context.setLineDash(phase: 0, lengths: [])
            for handle in selected.handles {
                let size = handleSize * 0.8
                let rect = CGRect(x: handle.x - size / 2, y: handle.y - size / 2, width: size, height: size)
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: rect)
                context.strokeEllipse(in: rect)
            }
        }
    }

    // MARK: Measuring

    private func drawEdgeRuler(at point: CGPoint, in context: CGContext) {
        guard let m = Measure.edges(in: model.document.image, at: point) else { return }
        let rect = m.rect(around: point)
        let y = floor(point.y) + 0.5, x = floor(point.x) + 0.5
        drawRulerLines([CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y),
                        CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)], in: context)
        drawMeasureLabel(sizeText(width: m.width, height: m.height), above: CGPoint(x: x, y: rect.minY), in: context)
    }

    private func drawMeasurement(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        let rect = CGRect(corner: start, corner: end).pixelAligned
        let unit = pixelsPerScreenPoint
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(unit)
        context.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
        drawMeasureLabel(sizeText(width: Int(rect.width), height: Int(rect.height)), above: CGPoint(x: rect.midX, y: rect.minY), in: context)
    }

    private func drawRulerLines(_ points: [CGPoint], in context: CGContext) {
        let unit = pixelsPerScreenPoint
        context.setLineWidth(3 * unit)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        context.strokeLineSegments(between: points)
        context.setLineWidth(1.2 * unit)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.strokeLineSegments(between: points)
        // End ticks.
        let tick = 5 * unit
        for (i, p) in points.enumerated() {
            let horizontal = i < 2
            let a = horizontal ? CGPoint(x: p.x, y: p.y - tick) : CGPoint(x: p.x - tick, y: p.y)
            let b = horizontal ? CGPoint(x: p.x, y: p.y + tick) : CGPoint(x: p.x + tick, y: p.y)
            context.strokeLineSegments(between: [a, b])
        }
    }

    /// "120 × 32 px", plus points when the capture is Retina.
    private func sizeText(width: Int, height: Int) -> String {
        let scale = model.document.scale
        var text = "\(width) × \(height) px"
        if scale != 1 {
            let w = CGFloat(width) / scale, h = CGFloat(height) / scale
            text += String(format: "  (%g × %g pt)", (w * 10).rounded() / 10, (h * 10).rounded() / 10)
        }
        return text
    }

    /// Label centred above `point` (the loupe sits below and to the side).
    private func drawMeasureLabel(_ text: String, above point: CGPoint, in context: CGContext) {
        let unit = pixelsPerScreenPoint
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * unit, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var box = CGRect(x: point.x - size.width / 2 - 6 * unit, y: point.y - size.height - 12 * unit,
                         width: size.width + 12 * unit, height: size.height + 6 * unit)
        let viewport = visibleRect
        box.origin.x = min(max(box.minX, viewport.minX + 4 * unit), viewport.maxX - box.width - 4 * unit)
        box.origin.y = max(box.minY, viewport.minY + 4 * unit)
        context.setFillColor(CGColor(gray: 0.08, alpha: 0.85))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 5 * unit, cornerHeight: 5 * unit, transform: nil))
        context.fillPath()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6 * unit, y: box.minY + 3 * unit), withAttributes: attributes)
    }

    override func mouseMoved(with event: NSEvent) {
        guard model.tool.isInspector else {
            if hoverPoint != nil { hoverPoint = nil; needsDisplay = true }
            return
        }
        hoverPoint = location(of: event)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .crosshair)
    }

    // MARK: Mouse

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        window?.makeFirstResponder(self)
        let point = location(of: event)

        if model.tool == .colorPicker {
            model.copyColor(at: point)
            return
        }
        if model.tool == .ruler {
            drag = .measuring(start: point, end: point)
            return
        }
        if let selected = model.selected, let handle = handleIndex(of: selected, near: point) {
            drag = .resizing(handle: handle, original: selected)
            return
        }
        if model.tool != .crop, let hit = model.annotation(at: point) {
            model.selectedID = hit.id
            if event.clickCount == 2, case .text = hit.shape {
                beginTextEditing(hit)
            } else if let part = hit.magnifierPart(at: point, tolerance: 4 * model.document.scale) {
                drag = .movingPart(start: point, original: hit, part: part)
            } else {
                drag = .moving(start: point, original: hit)
            }
            return
        }
        model.selectedID = nil

        let style = model.currentStyle
        let box = CGRect(origin: point, size: .zero)
        switch model.tool {
        case .arrow:
            drag = .drawing(start: point, annotation: Annotation(shape: .arrow(from: point, to: point), style: style))
        case .rectangle:
            drag = .drawing(start: point, annotation: Annotation(shape: .rectangle(box), style: style))
        case .ellipse:
            drag = .drawing(start: point, annotation: Annotation(shape: .ellipse(box), style: style))
        case .highlight:
            drag = .drawing(start: point, annotation: Annotation(shape: .highlight(box), style: style))
        case .blur:
            drag = .drawing(start: point, annotation: Annotation(shape: .blur(box), style: style))
        case .pixelate:
            drag = .drawing(start: point, annotation: Annotation(shape: .pixelate(box), style: style))
        case .eraser:
            drag = .drawing(start: point, annotation: Annotation(shape: .erase(box), style: style))
        case .step:
            model.add(Annotation(shape: .step(center: point, number: model.document.nextStepNumber), style: style))
        case .crop:
            drag = .cropping(start: point, rect: box)
        case .ruler, .colorPicker:
            break
        case .magnifier:
            drag = .magnifying(start: point, rect: box)
        case .text:
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
            if case .arrow = annotation.shape {
                if event.modifierFlags.contains(.shift) { point = snapTo45Degrees(point, from: start) }
                updated.shape = .arrow(from: start, to: point)
            } else if annotation.box != nil {
                if event.modifierFlags.contains(.shift) { point = square(point, from: start) }
                updated = annotation.withBox(CGRect(corner: start, corner: point))
            }
            drag = .drawing(start: start, annotation: updated)
        case let .moving(start, original):
            let moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            model.replaceWithoutUndo(moved)
        case let .resizing(handle, original):
            model.replaceWithoutUndo(original.movingHandle(handle, to: point))
        case let .measuring(start, _):
            drag = .measuring(start: start, end: point)
            hoverPoint = point
        case let .magnifying(start, _):
            if event.modifierFlags.contains(.shift) { point = square(point, from: start) }
            drag = .magnifying(start: start, rect: CGRect(corner: start, corner: point).intersection(model.document.visibleRect))
        case let .movingPart(start, original, part):
            model.replaceWithoutUndo(original.movingPart(part, dx: point.x - start.x, dy: point.y - start.y))
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
            commitLiveEdit(from: original, actionName: String(localized: "Move"))
        case let .resizing(_, original):
            commitLiveEdit(from: original, actionName: String(localized: "Change Size"))
        case let .movingPart(_, original, _):
            commitLiveEdit(from: original, actionName: String(localized: "Move"))
        case let .magnifying(_, rect):
            let document = model.document
            let magnifier = Annotation.magnifier(source: rect.integral, round: model.magnifierRound, within: document.visibleRect,
                                                 gap: 16 * document.scale, style: model.currentStyle)
            model.add(magnifier)
        case let .cropping(_, rect):
            model.crop(to: rect)
        case let .measuring(start, end):
            // A drag leaves its size on the clipboard; a click measures the edges.
            let rect = CGRect(corner: start, corner: end).pixelAligned
            if rect.width >= 2 || rect.height >= 2 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(Int(rect.width)) × \(Int(rect.height))", forType: .string)
                model.flash(String(localized: "Copied \(Int(rect.width)) × \(Int(rect.height)) px"))
            } else if let m = Measure.edges(in: model.document.image, at: start) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(m.width) × \(m.height)", forType: .string)
                model.flash(String(localized: "Copied \(m.width) × \(m.height) px"))
            }
        case nil:
            break
        }
    }

    /// Turns a live drag into one undo step.
    private func commitLiveEdit(from original: Annotation, actionName: String) {
        guard let edited = model.document.annotations.first(where: { $0.id == original.id }), edited != original else { return }
        model.replaceWithoutUndo(original)
        model.replace(edited, actionName: actionName)
    }

    private var handleSize: CGFloat { 9 * pixelsPerScreenPoint }

    private func handleIndex(of annotation: Annotation, near point: CGPoint) -> Int? {
        annotation.handles.firstIndex { $0.distance(to: point) <= handleSize }
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
            model.replace(annotation, actionName: String(localized: "Edit Text"))
        } else {
            model.add(annotation)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
