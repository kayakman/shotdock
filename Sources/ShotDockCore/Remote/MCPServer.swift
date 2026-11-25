import CoreGraphics
import Foundation
import ImageIO

/// The Model Context Protocol server behind `shotdock mcp`: JSON-RPC on
/// stdio, one tool per catalog command, each call forwarded to the app.
/// Captures come back as a preview image the model can see plus JSON with
/// the full-resolution path.
public final class MCPServer {
    public typealias Call = (CommandSpec, [String: JSONValue]) throws -> JSONValue

    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public static let instructions = """
        ShotDock is a macOS screenshot app (captures, annotations, OCR, history, uploads). \
        Capture and edit tools return a preview image plus JSON with `id` (history id, what other tools \
        take as `target`), `path` (the full-resolution PNG) and `preview_scale`. \
        Positions on an image (annotations, crop, measure, OCR boxes) are pixels of the full-resolution \
        image from its top-left corner: divide what you read on the preview by preview_scale. \
        Screen rectangles (capture_area, list_windows, list_displays) are points from the top-left of the \
        main display. Captures are silent unless copy, save, upload, edit or pin are set. \
        If a tool fails with not_authorized, ask the user to turn on agent control in \
        ShotDock › Preferencias › Agentes and to allow this client.
        """

    private let tools: [CommandSpec]
    private let version: String
    private let call: Call
    public var workingDirectory = FileManager.default.currentDirectoryPath

    public init(tools: [CommandSpec] = CommandCatalog.tools, version: String, call: @escaping Call) {
        self.tools = tools
        self.version = version
        self.call = call
    }

    // MARK: Messages

    /// Answers one line of input; nil for notifications.
    public func handle(_ line: Data) -> Data? {
        guard let request = try? JSONDecoder().decode(RPCRequest.self, from: line) else {
            return try? LineFraming.frame(RPCResponse(id: nil, error: RPCError(code: RPCError.parseErrorCode, message: "Parse error")))
        }
        guard let response = respond(to: request) else { return nil }
        return try? LineFraming.frame(response)
    }

    public func respond(to request: RPCRequest) -> RPCResponse? {
        let result: JSONValue
        do {
            switch request.method {
            case "initialize": result = initialize(request.params)
            case "ping": result = [:]
            case "tools/list": result = ["tools": .array(tools.map(describe))]
            case "tools/call": result = try callTool(request.params)
            default:
                if request.isNotification { return nil }  // notifications/initialized, cancelled…
                throw RPCError.methodNotFound(request.method)
            }
        } catch let error as RPCError {
            return request.isNotification ? nil : RPCResponse(id: request.id, error: error)
        } catch {
            return request.isNotification ? nil : RPCResponse(id: request.id, error: .internalError(error.localizedDescription))
        }
        return request.isNotification ? nil : RPCResponse(id: request.id, result: result)
    }

    private func initialize(_ params: JSONValue?) -> JSONValue {
        let asked = params?["protocolVersion"]?.stringValue ?? Self.protocolVersions[0]
        return [
            "protocolVersion": .string(Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "shotdock", "title": "ShotDock", "version": .string(version)],
            "instructions": .string(Self.instructions),
        ]
    }

    func describe(_ spec: CommandSpec) -> JSONValue {
        var description = spec.summary
        if !spec.details.isEmpty { description += "\n\n" + spec.details }
        return [
            "name": .string(spec.mcpName ?? spec.name),
            "title": .string(spec.summary),
            "description": .string(description),
            "inputSchema": spec.inputSchema,
            "annotations": [
                "readOnlyHint": .bool(spec.readOnly),
                "destructiveHint": .bool(spec.destructive),
                "openWorldHint": false,
            ],
        ]
    }

    // MARK: Tool calls

    private func callTool(_ params: JSONValue?) throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else { throw RPCError.invalidParams("tools/call needs a name") }
        guard let spec = tools.first(where: { $0.mcpName == name }) else { throw RPCError.invalidParams("Unknown tool: \(name)") }
        do {
            let arguments = try resolvingPaths(spec.validate(params?["arguments"]), of: spec)
            let result = try call(spec, arguments)
            return toolResult(result, images: spec.returnsImage)
        } catch let error as RPCError {
            // Tool failures go back to the model as results it can read and act on.
            var text = "\(error.kind): \(error.message)"
            if let data = error.data { text += "\n" + data.jsonString(pretty: true) }
            return ["content": [["type": "text", "text": .string(text)]], "isError": true]
        } catch {
            return ["content": [["type": "text", "text": .string("error: \(error.localizedDescription)")]], "isError": true]
        }
    }

    /// Relative paths are taken from the directory the client started us in.
    private func resolvingPaths(_ params: [String: JSONValue], of spec: CommandSpec) -> [String: JSONValue] {
        var params = params
        for param in spec.params {
            guard case .path = param.kind, let text = params[param.name]?.stringValue else { continue }
            let expanded = (text as NSString).expandingTildeInPath
            if !expanded.hasPrefix("/") {
                params[param.name] = .string(URL(fileURLWithPath: workingDirectory).appendingPathComponent(expanded).standardized.path)
            } else {
                params[param.name] = .string(expanded)
            }
        }
        return params
    }

    /// JSON for the model, plus a preview of every image the result points at.
    func toolResult(_ result: JSONValue, images: Bool) -> JSONValue {
        var structured = result
        var content: [JSONValue] = []
        if images {
            // A capture, or {"captures": [...]} for several.
            func attach(_ value: JSONValue) -> JSONValue {
                guard var object = value.objectValue, let path = object["path"]?.stringValue,
                      let preview = ImagePreview.make(path: path) else { return value }
                object["preview_scale"] = .number((preview.scale * 10000).rounded() / 10000)
                object["preview_width"] = .number(Double(preview.width))
                object["preview_height"] = .number(Double(preview.height))
                content.append(["type": "image", "data": .string(preview.data.base64EncodedString()), "mimeType": .string(preview.mimeType)])
                return .object(object)
            }
            if let captures = result["captures"]?.arrayValue {
                structured = ["captures": .array(captures.map(attach))]
            } else {
                structured = attach(result)
            }
        }
        content.insert(["type": "text", "text": .string(structured.jsonString(pretty: true))], at: 0)
        if structured.objectValue == nil { structured = ["result": structured] }
        return ["content": .array(content), "structuredContent": structured]
    }

    // MARK: Stdio

    /// Reads requests from stdin until it closes, answering on stdout.
    public func runStdio(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = LineBuffer()
        while true {
            let chunk = input.availableData
            var lines: [Data]
            if chunk.isEmpty {
                lines = buffer.flush().map { [$0] } ?? []
            } else {
                do {
                    lines = try buffer.append(chunk)
                } catch {
                    lines = []
                    buffer = LineBuffer()
                }
            }
            for line in lines {
                if let answer = handle(line) { output.write(answer) }
            }
            if chunk.isEmpty { return }
        }
    }
}

/// A smaller copy of a capture for the model to look at: at most 1568 px on
/// the long side and about 1.15 megapixels, PNG unless that is over 1 MB.
public enum ImagePreview {
    public struct Preview {
        public var data: Data
        public var mimeType: String
        public var width: Int
        public var height: Int
        /// Preview pixels per full-resolution pixel.
        public var scale: Double
    }

    public static let maxSide = 1568.0
    public static let maxPixels = 1_150_000.0
    public static let maxPNGBytes = 1 << 20

    public static func make(path: String) -> Preview? {
        guard let data = FileManager.default.contents(atPath: path), let image = try? ImageEncoding.image(from: data) else { return nil }
        return make(image)
    }

    public static func make(_ image: CGImage) -> Preview? {
        let w = Double(image.width), h = Double(image.height)
        let scale = min(1, maxSide / max(w, h), (maxPixels / (w * h)).squareRoot())
        let width = max(1, Int((w * scale).rounded())), height = max(1, Int((h * scale).rounded()))
        var small = image
        if scale < 1 {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let made = context.makeImage() else { return nil }
            small = made
        }
        if let png = try? ImageEncoding.data(from: small, format: .png), png.count <= maxPNGBytes {
            return Preview(data: png, mimeType: "image/png", width: width, height: height, scale: Double(width) / w)
        }
        guard let jpeg = try? ImageEncoding.data(from: small, format: .jpeg, jpegQuality: 0.85) else { return nil }
        return Preview(data: jpeg, mimeType: "image/jpeg", width: width, height: height, scale: Double(width) / w)
    }
}
