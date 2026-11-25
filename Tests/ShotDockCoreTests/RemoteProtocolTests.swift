import Foundation
import Testing
@testable import ShotDockCore

// MARK: JSON and JSON-RPC

@Test func jsonValueRoundTripsAndKeepsIntegersWhole() throws {
    let value: JSONValue = ["id": 12, "scale": 2.5, "ok": true, "name": "a/b", "list": [1, nil], "nested": ["x": 0]]
    let text = value.jsonString()
    #expect(text == #"{"id":12,"list":[1,null],"name":"a/b","nested":{"x":0},"ok":true,"scale":2.5}"#)
    #expect(try JSONValue(parsing: text) == value)
    #expect(value["id"]?.intValue == 12 && value["scale"]?.intValue == nil)
}

@Test func jsonValueConvertsCodables() throws {
    let color = RGBAColor(red: 1, green: 0, blue: 0)
    let json = try JSONValue(encoding: color)
    #expect(json["red"] == 1)
    #expect(try json.decode(RGBAColor.self) == color)
}

@Test func rpcResponsesAlwaysCarryTheirId() throws {
    let error = RPCResponse(id: nil, error: RPCError(code: RPCError.parseErrorCode, message: "bad"))
    #expect(String(data: try LineFraming.frame(error), encoding: .utf8) == #"{"error":{"code":-32700,"message":"bad"},"id":null,"jsonrpc":"2.0"}"# + "\n")
    let ok = RPCResponse(id: .string("a"), result: .null)
    #expect(String(data: try LineFraming.frame(ok), encoding: .utf8) == #"{"id":"a","jsonrpc":"2.0","result":null}"# + "\n")
    let request = try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
    #expect(request.isNotification && request.params == nil)
    let call = try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"jsonrpc":"2.0","id":7,"method":"status","params":{}}"#.utf8))
    #expect(call.id == .number(7) && call.params == [:])
}

@Test func lineBufferSplitsMessagesAcrossReads() throws {
    var buffer = LineBuffer()
    #expect(try buffer.append(Data(#"{"a":1}"#.utf8)).isEmpty)
    let lines = try buffer.append(Data("\n\r\n{\"b\":\"x\\ny\"}\r\n{\"c\"".utf8))
    #expect(lines.map { String(data: $0, encoding: .utf8)! } == [#"{"a":1}"#, #"{"b":"x\ny"}"#])
    #expect(try buffer.append(Data(":3}".utf8)).isEmpty)
    #expect(buffer.flush().map { String(data: $0, encoding: .utf8)! } == #"{"c":3}"#)
    #expect(buffer.flush() == nil)
}

@Test func colorsParseFromHexAndNames() {
    #expect(RGBAColor(string: "#FF5A1F")?.hexString == "#FF5A1F")
    #expect(RGBAColor(string: "f00")?.hexString == "#FF0000")
    #expect(RGBAColor(string: "#00000080")?.hexString == "#00000080")
    #expect(RGBAColor(string: "Yellow") == .yellow)
    #expect(RGBAColor(string: "#12345") == nil && RGBAColor(string: "teal") == nil)
}

// MARK: Specs, validation and schemas

private let captureArea = CommandSpec("capture.area", "Capture an area", params: [
    ParamSpec("rect", .rect, "Area in points", required: true),
    ParamSpec("display", .integer, "Display number"),
    ParamSpec("format", .choice(["png", "jpeg"]), "Image format", default: "png"),
    ParamSpec("shadow", .boolean, "Window shadow", default: true),
    ParamSpec("copy", .boolean, "Copy to the clipboard"),
], returnsImage: true)

private let annotate = CommandSpec("annotate", "Add annotations", params: [
    ParamSpec("target", .string, "Capture", required: true),
    ParamSpec("annotations", .json(schema: ["type": "array"]), "Annotations", required: true),
])

private let arrow = CommandSpec("annotate.arrow", "Draw an arrow", params: [
    ParamSpec("target", .string, "Capture", required: true, positional: true),
    ParamSpec("from", .point, "Start", required: true),
    ParamSpec("to", .point, "End", required: true),
    ParamSpec("color", .color, "Colour"),
], exposure: .alias(of: "annotate")) { params in
    var mark = params
    mark["type"] = "arrow"
    mark["target"] = nil
    return ["target": params["target"] ?? nil, "annotations": [.object(mark)]]
}

private let historyDelete = CommandSpec("history.delete", "Delete captures", params: [
    ParamSpec("ids", .strings, "Capture ids", required: true, positional: true),
    ParamSpec("all", .boolean, "Every capture"),
], destructive: true)

private let parser = CLIParser(commands: [captureArea, annotate, arrow, historyDelete])

private func run(_ args: [String]) throws -> CLIInvocation {
    guard case let .run(invocation) = try parser.parse(args) else { throw CLIError(message: "not a run") }
    return invocation
}

@Test func validationChecksTypesAndFillsDefaults() throws {
    let params = try captureArea.validate(["rect": ["x": 0, "y": 0, "width": 10, "height": 5]])
    #expect(params["format"] == "png" && params["shadow"] == true && params["display"] == nil)
    #expect(throws: RPCError.self) { try captureArea.validate([:]) }
    #expect(throws: RPCError.self) { try captureArea.validate(["rect": ["x": 0, "y": 0, "width": 10]]) }
    #expect(throws: RPCError.self) { try captureArea.validate(["rect": ["x": 0, "y": 0, "width": 1, "height": 1], "format": "gif"]) }
    #expect(throws: RPCError.self) { try captureArea.validate(["rect": ["x": 0, "y": 0, "width": 1, "height": 1], "colour": "red"]) }
    #expect(throws: RPCError.self) { try captureArea.validate(["rect": ["x": 0, "y": 0, "width": 1, "height": 1], "display": 1.5]) }
}

@Test func inputSchemaDescribesEveryParameter() {
    let schema = captureArea.inputSchema
    #expect(schema["type"] == "object" && schema["required"] == ["rect"] && schema["additionalProperties"] == false)
    #expect(schema["properties"]?["rect"]?["required"] == ["x", "y", "width", "height"])
    #expect(schema["properties"]?["format"]?["enum"] == ["png", "jpeg"])
    #expect(schema["properties"]?["shadow"]?["default"] == true)
    #expect(captureArea.mcpName == "capture_area" && arrow.mcpName == nil)
}

// MARK: Command line

@Test func parsesFlagsIntoTypedParameters() throws {
    let call = try run(["capture", "area", "--rect", "10,20,300,200.5", "--display=2", "--no-shadow", "--copy", "--json"])
    #expect(call.command.name == "capture.area" && call.json)
    #expect(call.params["rect"]?.rect == CGRect(x: 10, y: 20, width: 300, height: 200.5))
    #expect(call.params["display"] == 2 && call.params["shadow"] == false && call.params["copy"] == true)
    #expect(call.params["format"] == "png")
}

@Test func aliasesBecomeTheirTargetCommand() throws {
    let call = try run(["annotate", "arrow", "last", "--from", "1,2", "--to", "30,40", "--color", "blue", "--timeout", "5"])
    #expect(call.command.name == "annotate" && call.timeout == 5)
    #expect(call.params["target"] == "last")
    #expect(call.params["annotations"] == [["type": "arrow", "from": ["x": 1, "y": 2], "to": ["x": 30, "y": 40], "color": "blue"]])
}

@Test func trailingPositionalsCollectIntoAList() throws {
    let call = try run(["history", "delete", "a", "b", "--", "--c"])
    #expect(call.params["ids"] == ["a", "b", "--c"])
}

@Test func badInputExplainsItselfWithUsage() {
    func message(_ args: [String]) -> String? {
        do { _ = try parser.parse(args); return nil } catch let error as CLIError { return error.message } catch { return "\(error)" }
    }
    #expect(message(["capture", "area"]) == "missing rect (a rectangle {x, y, width, height})")
    #expect(message(["capture", "area", "--rect", "1,2,3"])?.contains("not a rectangle") == true)
    #expect(message(["capture", "area", "--rect", "1,2,3,4", "--colour", "red"]) == "Unknown option --colour for capture area")
    #expect(message(["capture", "area", "--rect"]) == "--rect needs a value (x,y,w,h)")
    #expect(message(["capture", "zone"]) == "Unknown command: capture zone")
    #expect(message(["annotate", "arrow", "last", "--from", "1,2", "--to", "3,4", "--color", "teal"])?.contains("unknown colour") == true)
}

@Test func helpComesFromTheSpecs() throws {
    guard case let .help(text) = try parser.parse(["help", "capture", "area"]) else { Issue.record("no help"); return }
    #expect(text.hasPrefix("Usage: shotdock capture area [options]"))
    #expect(text.contains("--rect x,y,w,h") && text.contains("(required)") && text.contains("--[no-]shadow"))
    guard case let .help(group) = try parser.parse(["capture"]) else { Issue.record("no group help"); return }
    #expect(group.contains("capture area") && !group.contains("history delete"))
    guard case .help = try parser.parse([]) else { Issue.record("no general help"); return }
    guard case .version = try parser.parse(["--version"]) else { Issue.record("no version"); return }
}

@Test func jsonParametersReadInlineFilesAndStdin() throws {
    var p = CLIParser(commands: [annotate])
    p.readStdin = { Data(#"[{"type":"step"}]"#.utf8) }
    p.readFile = { path in path == "marks.json" ? Data("[]".utf8) : Data() }
    func marks(_ value: String) throws -> JSONValue? {
        guard case let .run(call) = try p.parse(["annotate", "--target", "last", "--annotations", value]) else { return nil }
        return call.params["annotations"]
    }
    #expect(try marks(#"[{"type":"text"}]"#) == [["type": "text"]])
    #expect(try marks("-") == [["type": "step"]])
    #expect(try marks("@marks.json") == [])
}

@Test func catalogHasUniqueNamesAndValidAliases() {
    let names = CommandCatalog.all.map(\.name)
    #expect(Set(names).count == names.count)
    let tools = CommandCatalog.tools.compactMap(\.mcpName)
    #expect(Set(tools).count == tools.count)
    for spec in CommandCatalog.all {
        if case let .alias(of: target) = spec.exposure {
            #expect(CommandCatalog.command(target)?.exposure == .app, "\(spec.name) → \(target)")
            #expect(spec.transform != nil)
        }
    }
    #expect(CommandCatalog.schema().arrayValue?.count == CommandCatalog.all.count)
}
