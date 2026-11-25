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
///     {"type": "magnifier", "source": {rect}, "target": {rect}, "zoom": 2, "round": true}
///
/// Optional on all: "color" (#RRGGBB or a name), "weight" (thin|medium|thick),
/// "line_width", "font_size", and "id" when changing an existing one.
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
                "from": point, "to": point, "at": point, "rect": rect, "source": rect, "target": rect,
                "text": ["type": "string"],
                "number": ["type": "integer"],
                "zoom": ["type": "number", "description": "Magnifier enlargement when no target is given (default 2)"],
                "round": ["type": "boolean"],
                "target_text": ["type": "string", "description": "Place the mark on this text, found by OCR, instead of giving coordinates"],
                "color": ["type": "string", "description": "#RRGGBB, #RRGGBBAA or red, orange, yellow, green, blue, purple, black, white"],
                "weight": ["type": "string", "enum": ["thin", "medium", "thick"]],
                "line_width": ["type": "number"],
                "font_size": ["type": "number"],
            ],
            "required": ["type"],
        ]
    }

    public static func json(_ annotation: Annotation) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(annotation.id.uuidString),
            "color": .string(annotation.style.color.hexString),
            "line_width": .number(annotation.style.lineWidth),
            "font_size": .number(annotation.style.fontSize),
        ]
        switch annotation.shape {
        case let .arrow(from, to):
            object["type"] = "arrow"; object["from"] = JSONValue(from); object["to"] = JSONValue(to)
        case let .rectangle(rect): object["type"] = "rectangle"; object["rect"] = JSONValue(rect)
        case let .ellipse(rect): object["type"] = "oval"; object["rect"] = JSONValue(rect)
        case let .highlight(rect): object["type"] = "highlight"; object["rect"] = JSONValue(rect)
        case let .blur(rect): object["type"] = "blur"; object["rect"] = JSONValue(rect)
        case let .pixelate(rect): object["type"] = "pixelate"; object["rect"] = JSONValue(rect)
        case let .erase(rect): object["type"] = "erase"; object["rect"] = JSONValue(rect)
        case let .text(origin, string):
            object["type"] = "text"; object["at"] = JSONValue(origin); object["text"] = .string(string)
        case let .step(center, number):
            object["type"] = "step"; object["at"] = JSONValue(center); object["number"] = .number(Double(number))
        case let .magnifier(source, target, round):
            object["type"] = "magnifier"; object["source"] = JSONValue(source); object["target"] = JSONValue(target)
            object["round"] = .bool(round)
        }
        return .object(object)
    }

    /// Builds an annotation for `document`, filling what is left out the way
    /// the editor would (colour, size, step number, where the magnifier goes).
    /// `scale` multiplies every coordinate (preview → pixels).
    public static func annotation(from json: JSONValue, for document: CaptureDocument, scale factor: CGFloat = 1,
                                  nextStep: Int? = nil) throws -> Annotation {
        guard let object = json.objectValue else { throw RPCError.invalidParams("Each annotation must be an object") }
        guard let type = object["type"]?.stringValue, types.contains(type) else {
            throw RPCError.invalidParams("Annotation type must be one of \(types.joined(separator: ", "))")
        }
        func value<T>(_ key: String, _ read: (JSONValue) -> T?, _ what: String) throws -> T {
            guard let raw = object[key], let parsed = read(raw) else { throw RPCError.invalidParams("\(type) needs \(key) (\(what))") }
            return parsed
        }
        func point(_ key: String) throws -> CGPoint {
            let p = try value(key, \.point, "{x, y}")
            return CGPoint(x: p.x * factor, y: p.y * factor)
        }
        func rect(_ key: String) throws -> CGRect {
            let r = try value(key, \.rect, "{x, y, width, height}")
            return CGRect(x: r.minX * factor, y: r.minY * factor, width: r.width * factor, height: r.height * factor).standardized
        }

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
        if let width = object["line_width"]?.doubleValue { style.lineWidth = width }
        if let size = object["font_size"]?.doubleValue { style.fontSize = size }

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
            if object["target"] != nil {
                shape = .magnifier(source: source, target: try rect("target"), round: round)
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
