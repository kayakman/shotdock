import Darwin
import Foundation
import Testing
@testable import ShotDockCore

private func temporarySocket() -> String {
    NSTemporaryDirectory() + "sd-\(UUID().uuidString.prefix(8)).sock"
}

/// Echoes params back; "fail" answers an error, "slow" never answers in time.
private func echoServer(_ path: String) throws -> ControlServer {
    let server = ControlServer(path: path) { request, peer, reply in
        switch request.method {
        case "fail": reply(RPCResponse(id: request.id, error: .notFound("no such capture")))
        case "slow": DispatchQueue.global().asyncAfter(deadline: .now() + 2) { reply(RPCResponse(id: request.id, result: .null)) }
        case "peer": reply(RPCResponse(id: request.id, result: ["pid": .number(Double(peer.pid)), "uid": .number(Double(peer.uid))]))
        default: reply(RPCResponse(id: request.id, result: request.params ?? .null))
        }
    }
    try server.start()
    return server
}

@Test func clientAndServerExchangeCallsAndErrors() throws {
    let path = temporarySocket()
    let server = try echoServer(path)
    defer { server.stop() }
    let client = try ControlClient(path: path)
    #expect(try client.call("echo", params: ["a": [1, 2]]) == ["a": [1, 2]])
    #expect(try client.call("echo", params: ["b": "ü\nñ"]) == ["b": "ü\nñ"])
    #expect(throws: RPCError.notFound("no such capture")) { try client.call("fail") }
    let peer = try client.call("peer")
    #expect(peer["pid"]?.intValue == Int(getpid()) && peer["uid"]?.intValue == Int(getuid()))
    #expect(throws: ControlClient.Failure.self) { try client.call("slow", timeout: 0.2) }
    // The late answer to "slow" is skipped, not mistaken for the next one.
    #expect(try client.call("echo", params: ["c": 3], timeout: 5) == ["c": 3])
}

@Test func socketIsPrivateAndStaleFilesAreReplaced() throws {
    let path = temporarySocket()
    // A file left by a crash.
    FileManager.default.createFile(atPath: path, contents: nil)
    let server = try echoServer(path)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // A second server on a live socket is refused.
    #expect(throws: ControlSocket.Failure.inUse(path)) { _ = try echoServer(path) }
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(throws: ControlSocket.Failure.self) { _ = try ControlClient(path: path) }
}

@Test func garbageGetsAParseError() throws {
    let path = temporarySocket()
    let server = try echoServer(path)
    defer { server.stop() }
    let fd = try ControlSocket.connect(path: path)
    defer { close(fd) }
    _ = "hello\n".withCString { write(fd, $0, 6) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(fd, &buffer, buffer.count)
    let response = try JSONDecoder().decode(RPCResponse.self, from: Data(buffer[0..<max(count, 0)]))
    #expect(response.error?.code == RPCError.parseErrorCode && response.id == nil)
}

// MARK: Who is calling

private let bundles = [
    "/System/Applications/Utilities/Terminal.app": "com.apple.Terminal",
    "/Applications/Cursor.app": "com.todesktop.230313mzl4w4u92",
    "/Applications/iTerm.app": "com.googlecode.iterm2",
]

private func identify(_ chain: [AgentClient.Process]) -> AgentClient {
    AgentClient.identify(chain: chain) { bundles[$0] }
}

@Test func identifiesClaudeCodeInTerminal() {
    let client = identify([
        .init(path: "/usr/local/bin/shotdock"),
        .init(path: "/Users/rick/.local/share/claude/versions/2.3.1/claude"),
        .init(path: "/bin/zsh"),
        .init(path: "/usr/bin/login"),
        .init(path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
    ])
    #expect(client.agent == "claude" && client.appName == "Terminal" && client.title == "claude en Terminal")
    #expect(client.id == "claude|com.apple.Terminal")
}

@Test func identifiesClaudeCodeInsideAnApp() {
    let client = identify([
        .init(path: "/usr/local/bin/shotdock"),
        .init(path: "/bin/bash"),
        .init(path: "/Users/rick/.elias/harnesses/claude/node_modules/@anthropic-ai/claude-code/bin/claude.exe"),
        .init(path: "/Users/rick/Applications/Elias.app/Contents/Resources/elias"),
    ])
    #expect(client.title == "claude en Elias")
}

@Test func identifiesScriptsRunByAnInterpreter() {
    let client = identify([
        .init(path: "/Applications/ShotDock.app/Contents/Helpers/shotdock"),
        .init(path: "/opt/homebrew/bin/node", arguments: ["node", "--no-warnings", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"]),
        .init(path: "/bin/zsh"),
        .init(path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
    ])
    #expect(client.title == "codex en iTerm")
}

@Test func identifiesAppHelpersByTheirApp() {
    let client = identify([
        .init(path: "/usr/local/bin/shotdock"),
        .init(path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
        .init(path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
    ])
    #expect(client.agent == "Cursor" && client.title == "Cursor" && client.appBundleID == "com.todesktop.230313mzl4w4u92")
}

@Test func lineageOfThisProcessIsReadable() {
    let chain = ProcessLineage.chain(from: getpid())
    #expect(!chain.isEmpty && chain[0].path.hasPrefix("/"))
    #expect(!ProcessLineage.arguments(getpid()).isEmpty)
}

// MARK: Matching and text output

@Test func looseMatchingIgnoresCaseAccentsAndSpaces() {
    #expect(TextMatch.loosely("Visual Studio Code", contains: "visualstudio"))
    #expect(TextMatch.loosely("Línea de órdenes", contains: "LINEA DE"))
    #expect(!TextMatch.loosely("Safari", contains: "chrome"))
    #expect(TextMatch.loosely(nil, contains: ""))
}

@Test func screenGeometryFlipsBetweenOrigins() {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
    let flipped = ScreenGeometry.flipped(rect, primaryHeight: 1000)
    #expect(flipped == CGRect(x: 10, y: 930, width: 100, height: 50))
    #expect(ScreenGeometry.flipped(flipped, primaryHeight: 1000) == rect)
}

@Test func textRenderingMakesTablesAndRecords() {
    let table = TextRendering.render(["displays": [
        ["index": 1, "name": "Built-in", "frame": ["x": 0, "y": 0, "width": 1512, "height": 982], "main": true],
        ["index": 2, "name": "LG", "frame": ["x": 1512, "y": -200, "width": 2560, "height": 1440], "main": false],
    ]])
    #expect(table.split(separator: "\n") == [
        "INDEX  NAME      FRAME                MAIN",
        "1      Built-in  0,0 1512×982         yes",
        "2      LG        1512,-200 2560×1440  no",
    ])
    #expect(TextRendering.render(["version": "1.0", "permissions": ["screen_recording": true]]) == "permissions:\n  screen_recording: yes\nversion:     1.0")
}
