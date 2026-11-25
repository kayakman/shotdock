import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

private func request(_ id: Int?, _ method: String, _ params: JSONValue? = nil) -> Data {
    var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
    if let id { object["id"] = .number(Double(id)) }
    if let params { object["params"] = params }
    return Data(JSONValue.object(object).jsonString().utf8)
}

private func answer(_ server: MCPServer, _ line: Data) throws -> JSONValue? {
    guard let data = server.handle(line) else { return nil }
    #expect(data.last == UInt8(ascii: "\n"))
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

/// A 3000 × 1500 PNG on disk, like a Retina capture.
private func bigCapture() throws -> String {
    let context = CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0.35, blue: 0.12, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
    let path = NSTemporaryDirectory() + "mcp-\(UUID().uuidString).png"
    try ImageEncoding.write(context.makeImage()!, to: URL(fileURLWithPath: path))
    return path
}

@Test func initializeNegotiatesTheProtocol() throws {
    let server = MCPServer(version: "1.2.3") { _, _ in .null }
    let reply = try #require(try answer(server, request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])))
    #expect(reply["id"] == 1 && reply["result"]?["protocolVersion"] == "2025-06-18")
    #expect(reply["result"]?["serverInfo"]?["version"] == "1.2.3" && reply["result"]?["capabilities"]?["tools"] != nil)
    #expect(reply["result"]?["instructions"]?.stringValue?.contains("preview_scale") == true)
    let future = try #require(try answer(server, request(2, "initialize", ["protocolVersion": "2099-01-01"])))
    #expect(future["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
    #expect(try answer(server, request(nil, "notifications/initialized")) == nil)
    #expect(try answer(server, request(3, "ping"))?["result"] == [:])
    #expect(try answer(server, request(4, "resources/list"))?["error"]?["code"] == .number(Double(RPCError.methodNotFoundCode)))
    #expect(try answer(server, Data("not json".utf8))?["error"]?["code"] == .number(Double(RPCError.parseErrorCode)))
}

@Test func everyAppCommandIsATool() throws {
    let server = MCPServer(version: "1") { _, _ in .null }
    let tools = try #require(try answer(server, request(1, "tools/list"))?["result"]?["tools"]?.arrayValue)
    let names = tools.compactMap { $0["name"]?.stringValue }
    #expect(Set(names) == Set(CommandCatalog.all.filter { $0.exposure == .app }.compactMap(\.mcpName)))
    #expect(names.contains("capture_area") && names.contains("list_windows") && !names.contains("schema") && !names.contains("mcp"))
    let capture = try #require(tools.first { $0["name"] == "capture_area" })
    #expect(capture["inputSchema"]?["properties"]?["rect"]?["type"] == "object")
    #expect(capture["annotations"]?["readOnlyHint"] == false)
    #expect(tools.first { $0["name"] == "list_windows" }?["annotations"]?["readOnlyHint"] == true)
}

@Test func toolCallsForwardCheckedArguments() throws {
    var forwarded: (String, [String: JSONValue])?
    let server = MCPServer(version: "1") { spec, params in
        forwarded = (spec.name, params)
        return ["windows": []]
    }
    let reply = try #require(try answer(server, request(7, "tools/call", ["name": "list_windows", "arguments": ["app": "Safari"]])))
    #expect(forwarded?.0 == "windows" && forwarded?.1["app"] == "Safari")
    #expect(reply["result"]?["isError"] == nil && reply["result"]?["structuredContent"] == ["windows": []])
    #expect(reply["result"]?["content"]?[0]?["type"] == "text")

    // Bad arguments and app failures come back as tool errors the model can read.
    let bad = try #require(try answer(server, request(8, "tools/call", ["name": "list_windows", "arguments": ["colour": "red"]])))
    #expect(bad["result"]?["isError"] == true)
    #expect(bad["result"]?["content"]?[0]?["text"]?.stringValue?.hasPrefix("invalid_params: windows: unknown parameter") == true)
    let unknown = try #require(try answer(server, request(9, "tools/call", ["name": "nope"])))
    #expect(unknown["error"]?["code"] == .number(Double(RPCError.invalidParamsCode)))
}

@Test func appErrorsAreToolErrors() throws {
    let server = MCPServer(version: "1") { _, _ in throw RPCError(code: RPCError.notAuthorizedCode, message: "Agent control is off.") }
    let reply = try #require(try answer(server, request(1, "tools/call", ["name": "list_displays"])))
    #expect(reply["result"]?["isError"] == true)
    #expect(reply["result"]?["content"]?[0]?["text"] == "not_authorized: Agent control is off.")
}

@Test func capturesComeBackAsPreviewAndPath() throws {
    let path = try bigCapture()
    defer { try? FileManager.default.removeItem(atPath: path) }
    var server = MCPServer(version: "1") { _, params in
        ["id": "ABC", "path": .string(params["out"]?.stringValue ?? path), "width": 3000, "height": 1500, "scale": 2]
    }
    server.workingDirectory = "/tmp/proyecto"
    let reply = try #require(try answer(server, request(1, "tools/call", ["name": "capture_screen", "arguments": [:]])))
    let result = try #require(reply["result"])
    let content = try #require(result["content"]?.arrayValue)
    #expect(content.count == 2 && content[1]["type"] == "image" && content[1]["mimeType"] == "image/png")
    let preview = try ImageEncoding.image(from: Data(base64Encoded: content[1]["data"]?.stringValue ?? "")!)
    #expect(preview.width == 1517 && preview.height == 758)  // ~1.15 MP, under 1568 px
    #expect(result["structuredContent"]?["path"]?.stringValue == path)
    #expect(result["structuredContent"]?["preview_scale"]?.doubleValue == 0.5057)
    #expect(content[0]["text"]?.stringValue?.contains("\"preview_scale\" : 0.5057") == true)

    // Relative paths are resolved from where the client started the server.
    server = MCPServer(version: "1") { _, params in ["out": params["out"] ?? nil] }
    server.workingDirectory = "/tmp/proyecto"
    let relative = try #require(try answer(server, request(2, "tools/call", ["name": "capture_screen", "arguments": ["out": "shots/a.png"]])))
    #expect(relative["result"]?["structuredContent"]?["out"] == "/tmp/proyecto/shots/a.png")
}

@Test func smallImagesAreNotScaled() throws {
    let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let preview = try #require(ImagePreview.make(context.makeImage()!))
    #expect(preview.width == 200 && preview.scale == 1)
}

@Test func stdioLoopAnswersEveryRequestUntilEOF() throws {
    let server = MCPServer(version: "1") { _, _ in ["displays": []] }
    let input = Pipe(), output = Pipe()
    var lines = request(1, "initialize", [:]) + Data("\n".utf8)
    lines += request(nil, "notifications/initialized") + Data("\n".utf8)
    lines += request(2, "tools/call", ["name": "list_displays"])  // last line without a newline
    input.fileHandleForWriting.write(lines)
    try input.fileHandleForWriting.close()
    server.runStdio(input: input.fileHandleForReading, output: output.fileHandleForWriting)
    try output.fileHandleForWriting.close()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let replies = text.split(separator: "\n").compactMap { try? JSONValue(parsing: String($0)) }
    #expect(replies.map { $0["id"] } == [1, 2])
}
