import CoreGraphics
import Foundation

/// One parameter of a command. Names are snake_case: the JSON key in RPC and
/// MCP, and `--kebab-case` as a CLI flag.
public struct ParamSpec: Sendable {
    public enum Kind: Sendable {
        case string
        /// A file path; the CLI makes it absolute from its working directory.
        case path
        /// A capture of the history (id, last…) or an image file, made absolute like a path.
        case reference
        case integer
        case number
        case boolean
        /// `{"x": …, "y": …}`; on the command line `x,y`.
        case point
        /// `{"x", "y", "width", "height"}`; on the command line `x,y,w,h`.
        case rect
        /// `#RRGGBB`, `#RRGGBBAA` or a palette name.
        case color
        case choice([String])
        /// A list of strings; on the command line, a repeated flag or the trailing positionals.
        case strings
        /// Any JSON, described by `schema`; on the command line inline JSON, `@file` or `-` (stdin).
        case json(schema: JSONValue?)
    }

    public var name: String
    public var kind: Kind
    public var summary: String
    public var required: Bool
    /// Given without a flag on the command line, in declaration order.
    public var positional: Bool
    public var defaultValue: JSONValue?

    public init(_ name: String, _ kind: Kind, _ summary: String, required: Bool = false, positional: Bool = false,
                default defaultValue: JSONValue? = nil) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.required = required
        self.positional = positional
        self.defaultValue = defaultValue
    }

    public var flag: String { "--" + name.replacingOccurrences(of: "_", with: "-") }

    /// JSON Schema for MCP.
    public var schema: JSONValue {
        var schema: [String: JSONValue]
        let number: JSONValue = ["type": "number"]
        switch kind {
        case .string: schema = ["type": "string"]
        case .path, .reference: schema = ["type": "string"]
        case .integer: schema = ["type": "integer"]
        case .number: schema = ["type": "number"]
        case .boolean: schema = ["type": "boolean"]
        case .point:
            schema = ["type": "object", "properties": ["x": number, "y": number], "required": ["x", "y"],
                      "additionalProperties": false]
        case .rect:
            schema = ["type": "object", "properties": ["x": number, "y": number, "width": number, "height": number],
                      "required": ["x", "y", "width", "height"], "additionalProperties": false]
        case .color: schema = ["type": "string"]
        case let .choice(values): schema = ["type": "string", "enum": .array(values.map(JSONValue.string))]
        case .strings: schema = ["type": "array", "items": ["type": "string"]]
        case let .json(custom): schema = custom?.objectValue ?? [:]
        }
        schema["description"] = .string(summary)
        if let defaultValue { schema["default"] = defaultValue }
        return .object(schema)
    }

    /// Checks one value's type; returns an error message or nil.
    func problem(with value: JSONValue) -> String? {
        let ok: Bool
        switch kind {
        case .string, .path, .reference: ok = value.stringValue != nil
        case .integer: ok = value.intValue != nil
        case .number: ok = value.doubleValue != nil
        case .boolean: ok = value.boolValue != nil
        case .point: ok = value.point != nil
        case .rect: ok = value.rect.map { $0.width >= 0 && $0.height >= 0 } ?? false
        case .color:
            guard let text = value.stringValue else { return "\(name) must be a colour string" }
            return RGBAColor(string: text) == nil ? "\(name): unknown colour \"\(text)\" (use #RRGGBB or a name: \(RGBAColor.names.joined(separator: ", ")))" : nil
        case let .choice(values):
            guard let text = value.stringValue else { return "\(name) must be one of \(values.joined(separator: ", "))" }
            return values.contains(text) ? nil : "\(name) must be one of \(values.joined(separator: ", ")), not \"\(text)\""
        case .strings: ok = value.arrayValue?.allSatisfy { $0.stringValue != nil } ?? false
        case .json: ok = true
        }
        return ok ? nil : "\(name) must be \(kindDescription)"
    }

    var kindDescription: String {
        switch kind {
        case .string: "a string"
        case .path: "a file path"
        case .reference: "a capture (id, last…) or an image file"
        case .integer: "an integer"
        case .number: "a number"
        case .boolean: "true or false"
        case .point: "a point {x, y}"
        case .rect: "a rectangle {x, y, width, height}"
        case .color: "a colour"
        case let .choice(values): "one of \(values.joined(separator: ", "))"
        case .strings: "a list of strings"
        case .json: "JSON"
        }
    }
}

/// Everything ShotDock can do from outside: one entry per command, shared
/// by the CLI (parsing, help), the MCP server (tools and their schemas) and
/// the app (dispatch and validation).
public struct CommandSpec: Sendable {
    public enum Exposure: Sendable, Equatable {
        /// An RPC method handled by the app, also an MCP tool unless `mcpName` is nil.
        case app
        /// Handled by the `shotdock` binary itself (help, schema, mcp).
        case local
        /// A command-line shortcut for another command: `transform` turns its
        /// parameters into the target's.
        case alias(of: String)
    }

    /// Dotted name, also the RPC method: "capture.area". Words become the CLI path.
    public var name: String
    public var summary: String
    /// Longer help: units, examples.
    public var details: String
    public var params: [ParamSpec]
    public var exposure: Exposure
    /// MCP tool name, or nil when it is not a tool.
    public var mcpName: String?
    /// Returns a capture image: the MCP server attaches a preview.
    public var returnsImage: Bool
    public var readOnly: Bool
    public var destructive: Bool
    /// Always waits for the user (scrolling capture): no timeout by default.
    public var waitsForUser: Bool
    public var transform: (@Sendable ([String: JSONValue]) throws -> JSONValue)?

    public init(_ name: String, _ summary: String, details: String = "", params: [ParamSpec] = [], exposure: Exposure = .app,
                mcp: String? = nil, tool: Bool = true, returnsImage: Bool = false, readOnly: Bool = false, destructive: Bool = false,
                waitsForUser: Bool = false, transform: (@Sendable ([String: JSONValue]) throws -> JSONValue)? = nil) {
        self.name = name
        self.summary = summary
        self.details = details
        self.params = params
        self.exposure = exposure
        // `tool: false` keeps an app command off MCP (secrets must not pass through a model).
        mcpName = exposure == .app && tool ? (mcp ?? name.replacingOccurrences(of: ".", with: "_")) : nil
        self.returnsImage = returnsImage
        self.readOnly = readOnly
        self.destructive = destructive
        self.waitsForUser = waitsForUser
        self.transform = transform
    }

    /// Makes path parameters absolute from `directory`, where the caller runs
    /// (the app runs elsewhere). References become paths only if the file exists.
    public func resolvingPaths(_ params: [String: JSONValue], from directory: String) -> [String: JSONValue] {
        var params = params
        for param in self.params {
            guard let text = params[param.name]?.stringValue else { continue }
            switch param.kind {
            case .path: params[param.name] = .string(Self.absolute(text, from: directory))
            case .reference:
                let path = Self.absolute(text, from: directory)
                if (text.contains("/") || text.contains(".")), FileManager.default.fileExists(atPath: path) { params[param.name] = .string(path) }
            default: break
            }
        }
        return params
    }

    static func absolute(_ text: String, from directory: String) -> String {
        let expanded = (text as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: directory).appendingPathComponent(expanded).standardized.path
    }

    /// The call may wait for the user (an interactive selection), so it should not time out.
    public func waitsForUser(_ params: [String: JSONValue]) -> Bool {
        waitsForUser || params["interactive"]?.boolValue == true
    }

    /// Words typed after `shotdock`.
    public var path: [String] { name.split(separator: ".").map(String.init) }

    public func param(_ name: String) -> ParamSpec? { params.first { $0.name == name } }

    /// JSON Schema of the parameters, for MCP's `inputSchema`.
    public var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for param in params { properties[param.name] = param.schema }
        let required = params.filter(\.required).map { JSONValue.string($0.name) }
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    /// Checks parameters against the spec and fills in defaults.
    public func validate(_ params: JSONValue?) throws -> [String: JSONValue] {
        guard let params, !params.isNull else { return try validate(.object([:])) }
        guard var object = params.objectValue else { throw RPCError.invalidParams("\(name): parameters must be an object") }
        for key in object.keys where param(key) == nil {
            let known = self.params.map(\.name).joined(separator: ", ")
            throw RPCError.invalidParams("\(name): unknown parameter \"\(key)\"" + (known.isEmpty ? "" : " (known: \(known))"))
        }
        for spec in self.params {
            if let value = object[spec.name], !value.isNull {
                if let problem = spec.problem(with: value) { throw RPCError.invalidParams("\(name): \(problem)") }
            } else if let defaultValue = spec.defaultValue {
                object[spec.name] = defaultValue
            } else if spec.required {
                throw RPCError.invalidParams("\(name): missing \(spec.name) (\(spec.kindDescription))")
            } else {
                object[spec.name] = nil
            }
        }
        return object
    }
}

// MARK: Geometry in JSON

public extension JSONValue {
    init(_ point: CGPoint) { self = ["x": .number(point.x), "y": .number(point.y)] }

    init(_ rect: CGRect) {
        self = ["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)]
    }

    var point: CGPoint? {
        guard let x = self["x"]?.doubleValue, let y = self["y"]?.doubleValue, objectValue?.count == 2 else { return nil }
        return CGPoint(x: x, y: y)
    }

    var rect: CGRect? {
        guard let x = self["x"]?.doubleValue, let y = self["y"]?.doubleValue,
              let width = self["width"]?.doubleValue, let height = self["height"]?.doubleValue, objectValue?.count == 4 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
