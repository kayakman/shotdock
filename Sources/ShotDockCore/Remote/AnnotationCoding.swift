import CoreGraphics
import Foundation

public extension AnnotationStyle {
    /// Stroke widths of the editor's Fino / Medio / Grueso.
    static let weights: [String: CGFloat] = ["thin": 3, "medium": 6, "thick": 10]

    /// The editor's style for new marks: sizes follow the capture's scale so
    /// they look the same on Retina and non-Retina captures.
    static func standard(color: RGBAColor, weight: CGFloat = 6, scale: CGFloat) -> AnnotationStyle {
        let factor = scale / 2
        return AnnotationStyle(color: color, lineWidth: weight * factor, fontSize: (20 + weight * 3) * factor)
    }
}

/// Annotations as agents read and write them: flat JSON with a `type`,
/// positions in image pixels from the top-left corner.
///
///     {"type": "arrow", "from": {"x": 10, "y": 20}, "to": {"x": 200, "y": 90}}
///     {"type": "rectangle" | "oval" | "highlight" | "blur" | "pixelate" | "erase", "rect": {x, y, width, height}}
///     {"type": "text", "at": {x, y}, "text": "Hola"}               at = top-left of the text
///     {"type": "step", "at": {x, y}, "number": 3}                  at = centre; number optional
///     {"type": "magnifier", "source": {rect}, "lens": {rect}, "zoom": 2, "round": true}   lens = the enlargement
///
/// Optional on all: "color" (#RRGGBB or a name), "weight" (thin|medium|thick),
/// "line_width", "font_size", "on_text" (put the mark on that text, found by
/// OCR) and "id" when changing an existing one.
///
/// Positions and sizes are pixels of the image as edited (crop, backdrop and
/// resize applied), which is what agents are shown; `DocumentView` converts.
public enum AnnotationCoding {
    public static let types = ["arrow", "rectangle", "oval", "highlight", "text", "step", "blur", "pixelate", "erase", "magnifier"]

    /// JSON Schema of one annotation, for MCP.
    public static var schema: JSONValue {
        let point: JSONValue = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"]]
        let rect: JSONValue = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"],
                                                                "width": ["type": "number"], "height": ["type": "number"]],
                               "required": ["x", "y", "width", "height"]]
        return [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": .array(types.map(JSONValue.string))],
                "id": ["type": "string", "description": "Existing annotation to replace (update_annotation)"],
                "from": point, "to": point, "at": point, "rect": rect, "source": rect,
                "lens": ["type": "object", "description": "Where the enlargement goes (default: beside the source)",
                         "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]]],
                "text": ["type": "string"],
                "number": ["type": "integer"],
                "zoom": ["type": "number", "description": "Magnifier enlargement when no lens is given (default 2)"],
                "round": ["type": "boolean"],
                "on_text": ["type": "string", "description": "Put the mark on this text, found by OCR, instead of giving coordinates"],
                "color": ["type": "string", "description": "#RRGGBB, #RRGGBBAA or red, orange, yellow, green, blue, purple, black, white"],
                "weight": ["type": "string", "enum": ["thin", "medium", "thick"]],
                "line_width": ["type": "number"],
                "font_size": ["type": "number"],
            ],
            "required": ["type"],
        ]
    }

    public static func json(_ annotation: Annotation, view: DocumentView = .identity) -> JSONValue {
        func rounded(_ v: CGFloat) -> Double { (v * 100).rounded() / 100 }
        func point(_ p: CGPoint) -> JSONValue {
            let v = view.toView(p)
            return ["x": .number(rounded(v.x)), "y": .number(rounded(v.y))]
        }
        func rect(_ r: CGRect) -> JSONValue {
            let v = view.toView(r)
            return ["x": .number(rounded(v.minX)), "y": .number(rounded(v.minY)), "width": .number(rounded(v.width)), "height": .number(rounded(v.height))]
        }
        var object: [String: JSONValue] = [
            "id": .string(annotation.id.uuidString),
            "color": .string(annotation.style.color.hexString),
            "line_width": .number(rounded(annotation.style.lineWidth * view.factor)),
            "font_size": .number(rounded(annotation.style.fontSize * view.factor)),
        ]
        switch annotation.shape {
        case let .arrow(from, to):
            object["type"] = "arrow"; object["from"] = point(from); object["to"] = point(to)
        case let .rectangle(r): object["type"] = "rectangle"; object["rect"] = rect(r)
        case let .ellipse(r): object["type"] = "oval"; object["rect"] = rect(r)
        case let .highlight(r): object["type"] = "highlight"; object["rect"] = rect(r)
        case let .blur(r): object["type"] = "blur"; object["rect"] = rect(r)
        case let .pixelate(r): object["type"] = "pixelate"; object["rect"] = rect(r)
        case let .erase(r): object["type"] = "erase"; object["rect"] = rect(r)
        case let .text(origin, string):
            object["type"] = "text"; object["at"] = point(origin); object["text"] = .string(string)
        case let .step(center, number):
            object["type"] = "step"; object["at"] = point(center); object["number"] = .number(Double(number))
        case let .magnifier(source, lens, round):
            object["type"] = "magnifier"; object["source"] = rect(source); object["lens"] = rect(lens); object["round"] = .bool(round)
        }
        return .object(object)
    }

    /// Builds an annotation for `document`, filling what is left out the way
    /// the editor would (colour, size, step number, where the magnifier goes).
    /// Positions and sizes in the JSON are in `view` pixels.
    public static func annotation(from json: JSONValue, for document: CaptureDocument, view: DocumentView = .identity,
                                  nextStep: Int? = nil) throws -> Annotation {
        guard let object = json.objectValue else { throw RPCError.invalidParams("Each annotation must be an object") }
        guard let type = object["type"]?.stringValue, types.contains(type) else {
            throw RPCError.invalidParams("Annotation type must be one of \(types.joined(separator: ", "))")
        }
        func value<T>(_ key: String, _ read: (JSONValue) -> T?, _ what: String) throws -> T {
            guard let raw = object[key], let parsed = read(raw) else { throw RPCError.invalidParams("\(type) needs \(key) (\(what))") }
            return parsed
        }
        func point(_ key: String) throws -> CGPoint { view.toDocument(try value(key, \.point, "{x, y}")) }
        func rect(_ key: String) throws -> CGRect { view.toDocument(try value(key, \.rect, "{x, y, width, height}").standardized) }

        var color = type == "highlight" ? RGBAColor.yellow : RGBAColor.red
        if let text = object["color"]?.stringValue {
            guard let parsed = RGBAColor(string: text) else { throw RPCError.invalidParams("Unknown colour \"\(text)\"") }
            color = parsed
        }
        var weight: CGFloat = 6
        if let name = object["weight"]?.stringValue {
            guard let w = AnnotationStyle.weights[name] else { throw RPCError.invalidParams("weight must be thin, medium or thick") }
            weight = w
        }
        var style = AnnotationStyle.standard(color: color, weight: weight, scale: document.scale)
        if let width = object["line_width"]?.doubleValue { style.lineWidth = width / view.factor }
        if let size = object["font_size"]?.doubleValue { style.fontSize = size / view.factor }

        let shape: AnnotationShape
        switch type {
        case "arrow": shape = .arrow(from: try point("from"), to: try point("to"))
        case "rectangle": shape = .rectangle(try rect("rect"))
        case "oval": shape = .ellipse(try rect("rect"))
        case "highlight": shape = .highlight(try rect("rect"))
        case "blur": shape = .blur(try rect("rect"))
        case "pixelate": shape = .pixelate(try rect("rect"))
        case "erase": shape = .erase(try rect("rect"))
        case "text":
            let string = try value("text", \.stringValue, "a string")
            shape = .text(origin: try point("at"), string: string)
        case "step":
            let number = object["number"]?.intValue ?? nextStep ?? document.nextStepNumber
            shape = .step(center: try point("at"), number: number)
        default:  // magnifier
            let source = try rect("source")
            let round = object["round"]?.boolValue ?? true
            if object["lens"] != nil {
                shape = .magnifier(source: source, target: try rect("lens"), round: round)
            } else {
                let zoom = CGFloat(object["zoom"]?.doubleValue ?? 2)
                shape = Annotation.magnifier(source: source, zoom: zoom, round: round, within: document.visibleRect,
                                             gap: 16 * document.scale, style: style).shape
            }
        }
        var id = UUID()
        if let text = object["id"]?.stringValue {
            guard let parsed = UUID(uuidString: text) else { throw RPCError.invalidParams("id must be an annotation id") }
            id = parsed
        }
        let annotation = Annotation(id: id, shape: shape, style: style)
        if annotation.isDegenerate { throw RPCError.invalidParams("The \(type) is too small to see") }
        return annotation
    }
}

extension AnnotationCoding {
    /// Fills the position of a mark from the box of a text it should point
    /// at (`on_text`): a box around it, an arrow or a step beside it, a label
    /// below it. Coordinates the JSON already has are kept. All in view pixels;
    /// `scale` is the capture's pixels per point, for the gaps.
    public static func placing(_ json: JSONValue, on box: CGRect, imageSize: CGSize, scale: CGFloat) -> JSONValue {
        guard var object = json.objectValue, let type = object["type"]?.stringValue else { return json }
        object["on_text"] = nil
        let gap = 8 * scale
        func padded(_ amount: CGFloat) -> JSONValue { JSONValue(box.insetBy(dx: -amount * scale, dy: -amount * scale)) }
        switch type {
        case "rectangle", "oval": if object["rect"] == nil { object["rect"] = padded(4) }
        case "highlight": if object["rect"] == nil { object["rect"] = padded(1) }
        case "blur", "pixelate", "erase": if object["rect"] == nil { object["rect"] = padded(2) }
        case "magnifier": if object["source"] == nil { object["source"] = padded(2) }
        case "text": if object["at"] == nil { object["at"] = JSONValue(CGPoint(x: box.minX, y: box.maxY + gap)) }
        case "step":
            if object["at"] == nil {
                let radius = 14 * scale
                var x = box.minX - radius - gap / 2
                if x - radius < 0 { x = box.maxX + radius + gap / 2 }
                object["at"] = JSONValue(CGPoint(x: x, y: box.midY))
            }
        case "arrow":
            if object["to"] == nil {
                // From the upper left, or the upper right when there is no room.
                let length = CGSize(width: 60 * scale, height: 40 * scale)
                var to = CGPoint(x: box.minX - gap, y: box.midY)
                var from = CGPoint(x: to.x - length.width, y: to.y - length.height)
                if from.x < 0 {
                    to = CGPoint(x: box.maxX + gap, y: box.midY)
                    from = CGPoint(x: min(to.x + length.width, imageSize.width), y: to.y - length.height)
                }
                if from.y < 0 { from.y = min(to.y + length.height, imageSize.height) }
                object["to"] = JSONValue(to)
                if object["from"] == nil { object["from"] = JSONValue(from) }
            }
        default: break
        }
        return .object(object)
    }

    /// Multiplies every position and size in the JSON (preview → pixels).
    public static func scaled(_ json: JSONValue, by factor: CGFloat) -> JSONValue {
        guard factor != 1, var object = json.objectValue else { return json }
        for key in ["from", "to", "at"] {
            if let p = object[key]?.point { object[key] = JSONValue(CGPoint(x: p.x * factor, y: p.y * factor)) }
        }
        for key in ["rect", "source", "lens"] {
            if let r = object[key]?.rect { object[key] = JSONValue(CGRect(x: r.minX * factor, y: r.minY * factor, width: r.width * factor, height: r.height * factor)) }
        }
        for key in ["line_width", "font_size"] {
            if let v = object[key]?.doubleValue { object[key] = .number(v * factor) }
        }
        return .object(object)
    }
}

/// Image coordinates as agents see them: the image as edited, after crop,
/// backdrop and resize (and, for MCP previews, scaled down), mapped to the
/// document's own pixels where annotations live.
public struct DocumentView: Equatable, Sendable {
    /// Document pixel shown at the view's top-left corner.
    public var origin: CGPoint
    /// View pixels per document pixel.
    public var factor: CGFloat

    public init(origin: CGPoint, factor: CGFloat) {
        self.origin = origin
        self.factor = factor
    }

    public static let identity = DocumentView(origin: .zero, factor: 1)

    /// The edited image's pixels; `preview` for the MCP preview of it.
    public init(_ document: CaptureDocument, preview: Bool = false) {
        origin = document.layout.canvas.origin
        factor = (document.resize ?? 1) * (preview ? CGFloat(ImagePreview.scale(for: document.outputSize)) : 1)
    }

    public func toDocument(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x / factor, y: origin.y + p.y / factor) }
    public func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) * factor, y: (p.y - origin.y) * factor) }

    public func toDocument(_ r: CGRect) -> CGRect {
        CGRect(origin: toDocument(r.origin), size: CGSize(width: r.width / factor, height: r.height / factor))
    }

    public func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * factor, height: r.height * factor))
    }
}
