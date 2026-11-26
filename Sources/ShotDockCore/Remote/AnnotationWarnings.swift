import CoreGraphics
import Foundation

/// What an agent placing marks by numbers cannot see: a mark cut off at the
/// edge of the image, or a label (text or step) drawn over another mark or
/// over the capture's own text. Only warnings: the marks stay as they are.
public enum AnnotationWarnings {
    /// Warnings for `checked` (the marks just added or changed), reading the
    /// capture's text by OCR when one of them is a label.
    public static func check(_ checked: [Annotation], in document: CaptureDocument) async -> [String] {
        let text = checked.contains(where: isLabel) ? await capturedText(document) : []
        return check(checked, in: document, capturedText: text)
    }

    /// `capturedText`: lines of the capture without annotations, in document pixels.
    public static func check(_ checked: [Annotation], in document: CaptureDocument, capturedText: [RecognizedLine]) -> [String] {
        let view = DocumentView(document)
        // Marks are clipped to the capture (inside the backdrop, if any).
        let area = document.layout.content
        var warnings: [String] = []
        for mark in checked {
            let painted = extent(mark)
            let past = [
                ("left", area.minX - painted.minX), ("top", area.minY - painted.minY),
                ("right", painted.maxX - area.maxX), ("bottom", painted.maxY - area.maxY),
            ].filter { $0.1 >= 1 }
            if !past.isEmpty {
                let edges = past.map { "\($0.0) by \(Int(($0.1 * view.factor).rounded(.up))) px" }.joined(separator: ", ")
                warnings.append("\(describe(mark)) is cut off past the edge of the image (\(edges))")
            }
            guard isLabel(mark) else { continue }
            let overlapped = document.annotations.filter { $0.id != mark.id && overlaps(painted, $0) }
            for other in overlapped { warnings.append("\(describe(mark)) overlaps \(describe(other))") }
            let covered = capturedText.filter { $0.box.insetBy(dx: 2, dy: 2).intersects(painted) }.map { "“\($0.text)”" }
            if !covered.isEmpty {
                warnings.append("\(describe(mark)) covers text of the capture: \(covered.prefix(3).joined(separator: ", "))")
            }
        }
        return warnings
    }

    static func isLabel(_ mark: Annotation) -> Bool {
        switch mark.shape {
        case .text, .step: true
        default: false
        }
    }

    /// `text “Quitar permiso” (CDA8301B)`: what the agent wrote, and the start of the id.
    static func describe(_ mark: Annotation) -> String {
        let id = "(\(mark.id.uuidString.prefix(8)))"
        switch mark.shape {
        case let .text(_, string): return "text “\(string.count > 40 ? string.prefix(40) + "…" : string)” \(id)"
        case let .step(_, number): return "step \(number) \(id)"
        case .arrow: return "arrow \(id)"
        case .rectangle: return "rectangle \(id)"
        case .ellipse: return "oval \(id)"
        case .highlight: return "highlight \(id)"
        case .blur: return "blur \(id)"
        case .pixelate: return "pixelation \(id)"
        case .erase: return "erased area \(id)"
        case .redact: return "redaction \(id)"
        case .magnifier: return "magnifier \(id)"
        }
    }

    /// What the mark paints. Tighter than `bounds` for arrows, whose head is
    /// only at one end.
    static func extent(_ mark: Annotation) -> CGRect {
        guard case let .arrow(from, to) = mark.shape else { return mark.bounds }
        let length = from.distance(to: to)
        let half = mark.style.lineWidth / 2
        var rect = CGRect(corner: from, corner: to).insetBy(dx: -half, dy: -half)
        guard length > 0 else { return rect }
        let head = min(mark.style.arrowHeadLength, length), width = head * 0.6
        let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
        let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
        for side in [-1.0, 1.0] {
            rect = rect.union(CGRect(origin: CGPoint(x: base.x - uy * width * side, y: base.y + ux * width * side), size: .zero))
        }
        return rect
    }

    /// Whether a label at `label` is drawn over `other`. A label inside a
    /// rectangle or oval, clear of its line, is a caption and fine.
    static func overlaps(_ label: CGRect, _ other: Annotation) -> Bool {
        switch other.shape {
        case .text, .step:
            return label.intersects(other.bounds)
        case let .rectangle(rect), let .ellipse(rect):
            let line = other.style.lineWidth / 2
            return label.intersects(rect.insetBy(dx: -line, dy: -line)) && !rect.insetBy(dx: line, dy: line).contains(label)
        case let .arrow(from, to):
            // Along the shaft, a few pixels at a time.
            let near = label.insetBy(dx: -other.style.lineWidth / 2, dy: -other.style.lineWidth / 2)
            let steps = max(Int(from.distance(to: to) / 3), 1)
            return (0...steps).contains { step in
                let t = CGFloat(step) / CGFloat(steps)
                return near.contains(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        case let .magnifier(_, target, _):
            return label.intersects(target)
        case .highlight, .blur, .pixelate, .erase, .redact:
            return false
        }
    }

    /// The capture's text where it is shown (the crop), in document pixels.
    static func capturedText(_ document: CaptureDocument) async -> [RecognizedLine] {
        let visible = document.visibleRect
        guard let image = document.image.cropping(to: visible),
              let result = try? await TextRecognition.recognize(image) else { return [] }
        return result.textLines.map { line in
            var moved = line
            moved.box = line.box.offsetBy(dx: visible.minX, dy: visible.minY)
            return moved
        }
    }
}
