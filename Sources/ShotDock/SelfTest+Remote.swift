import AppKit
import ScreenCaptureKit
import ShotDockCore

/// Selftests of the CLI and MCP: the real `shotdock` binary from the bundle
/// against this app, on a socket of its own.
extension SelfTest {
    struct CLIRun {
        let status: Int32
        let stdout: String
        let stderr: String
        var json: JSONValue? { try? JSONValue(parsing: stdout) }
    }

    var socketPath: String { output.deletingLastPathComponent().appendingPathComponent("selftest.sock").path }

    /// Runs `shotdock` with `args` without blocking the main thread (the app answers it).
    func shotdock(_ args: [String], stdin: Data? = nil) async throws -> CLIRun {
        let process = Process()
        process.executableURL = CLIInstaller.helperURL
        process.arguments = args
        // From the repository, like a person typing `shotdock …` there.
        process.currentDirectoryURL = output.deletingLastPathComponent().deletingLastPathComponent()
        process.environment = ProcessInfo.processInfo.environment.merging(["SHOTDOCK_SOCKET": socketPath]) { _, new in new }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try? input.fileHandleForWriting.close()
        async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        let (o, e) = await (stdout, stderr)
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        return CLIRun(status: process.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    /// Starts the control socket with approvals answered by `answer`; returns the clients asked about.
    func startControl(answer: @escaping () -> Bool) -> () -> [AgentClient] {
        var asked: [AgentClient] = []
        ControlService.shared.approve = { client in
            asked.append(client)
            return answer()
        }
        ControlService.shared.start(path: socketPath)
        return { asked }
    }

    func cli() async throws {
        let settings = AppSettings.shared
        check(FileManager.default.isExecutableFile(atPath: CLIInstaller.helperURL.path), "shotdock is in the bundle")
        var allow = false
        let asked = startControl { allow }
        defer { ControlService.shared.stop() }

        // Every app command of the catalog has a handler.
        let missing = CommandCatalog.all.filter { $0.exposure == .app && ControlService.shared.handlers[$0.name] == nil }.map(\.name)
        check(missing.isEmpty, "every command has a handler (missing: \(missing.joined(separator: ", ")))")

        // Off by default: status answers, the rest is refused.
        check(!settings.agentControlEnabled, "agent control is off by default")
        let status = try await shotdock(["status", "--json"])
        check(status.status == 0 && status.json?["agent_control"]?["enabled"] == false, "status answers with control off")
        note("status: client \(status.json?["agent_control"]?["client"]?.stringValue ?? "?"), version \(status.json?["version"]?.stringValue ?? "?")")
        var run = try await shotdock(["displays", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_authorized", "displays refused while control is off")
        check(asked().isEmpty, "nobody asked while control is off")

        // On: the first call asks; "No permitir" refuses that process.
        settings.agentControlEnabled = true
        run = try await shotdock(["displays", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_authorized" && asked().count == 1, "the user is asked and can refuse")
        note("asked about: \(asked().first?.title ?? "-")")

        // Allowed: remembered, not asked again.
        allow = true
        run = try await shotdock(["displays", "--json"])
        let displays = run.json?["displays"]?.arrayValue ?? []
        check(run.status == 0 && displays.count == NSScreen.screens.count, "displays listed (\(displays.count))")
        check(displays.first?["index"] == 1 && displays.first?["frame"]?.rect?.origin == .zero && displays.first?["main"] == true,
              "display 1 is the main one, at 0,0")
        run = try await shotdock(["displays"])
        check(run.status == 0 && run.stdout.hasPrefix("INDEX") && asked().count == 2, "text table, and no second question")
        check(settings.approvedAgents.count == 1 && settings.approvedAgents.first?.lastUsed != nil, "the agent is remembered")

        // Windows, filtered (needs the Screen Recording permission).
        if ScreenCapturer.hasPermission {
            app.openPreferences(tab: .agents)
            HUD.show("selftest", symbol: "terminal", for: .seconds(3))
            try await Task.sleep(for: .milliseconds(500))
            run = try await shotdock(["windows", "--json"])
            let windows = run.json?["windows"]?.arrayValue ?? []
            check(run.status == 0, "windows listed (\(windows.count))")
            check(windows.allSatisfy { $0["id"]?.intValue != nil && $0["frame"]?.rect != nil }, "windows have ids and frames")
            let own = windows.filter { $0["pid"]?.intValue == Int(ProcessInfo.processInfo.processIdentifier) }
            check(own.map { $0["title"]?.stringValue } == ["Agentes"], "ShotDock's preferences listed, its HUD not (\(own.map { $0["title"] ?? nil }))")
            app.preferences?.close()
            if let first = windows.first, let app = first["app"]?.stringValue {
                let filtered = try await shotdock(["windows", "--app", app.uppercased(), "--json"])
                check(filtered.json?["windows"]?.arrayValue?.allSatisfy { $0["app"]?.stringValue == app } == true, "--app matches loosely (\(app))")
            }
        } else {
            note("no Screen Recording permission: windows not checked")
        }

        // Usage errors never reach the app; local commands neither.
        run = try await shotdock(["windows", "--app"])
        check(run.status == 2 && run.stderr.contains("--app needs a value"), "usage errors exit with 2")
        run = try await shotdock(["nonsense", "--json"])
        check(run.status == 2 && run.json?["error"]?["kind"] == "usage", "unknown commands exit with 2")
        run = try await shotdock(["schema"])
        check(run.status == 0 && run.json?.arrayValue?.count == CommandCatalog.all.count, "schema lists every command")
        run = try await shotdock(["--version"])
        check(run.status == 0 && run.stdout.hasPrefix("shotdock "), "version: \(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Revoking asks again.
        settings.approvedAgents = []
        allow = false
        run = try await shotdock(["displays", "--json"])
        check(run.status == 1 && asked().count == 3, "revoked agents are asked again")
    }
}

extension SelfTest {
    /// Agents' captures with the real binary (needs Screen Recording and an awake, unlocked screen).
    func cliCapture() async throws {
        guard ScreenCapturer.hasPermission else { throw ScreenCaptureError.permissionDenied }
        let settings = AppSettings.shared
        settings.agentControlEnabled = true
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        let library = LibraryStore.shared
        let screen = NSScreen.screens[0], scale = screen.backingScaleFactor
        // Agents' captures leave the clipboard alone.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sin tocar", forType: .string)

        var run = try await shotdock(["capture", "screen", "--json"])
        var json = run.json ?? [:]
        check(run.status == 0, "capture screen (\(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
        check(json["width"]?.intValue == Int(screen.frame.width * scale) && json["display"] == 1, "full display at full resolution (\(json["width"] ?? nil))")
        check(json["path"]?.stringValue.map { FileManager.default.fileExists(atPath: $0) } == true, "the image is written to a file")
        check(json["id"]?.stringValue != nil && json["id"]?.stringValue == library.items.first?.id.uuidString, "and kept in the history")
        check(NSPasteboard.general.string(forType: .string) == "sin tocar", "the clipboard is untouched")
        check(app.coordinator.editors.isEmpty, "no editor opens")

        let out = output.deletingLastPathComponent().appendingPathComponent("selftest-cli-area.jpg").path
        run = try await shotdock(["capture", "area", "--rect", "100,80,300,200", "--out", out, "--json"])
        json = run.json ?? [:]
        check(run.status == 0 && json["width"]?.intValue == Int(300 * scale) && json["height"]?.intValue == Int(200 * scale),
              "area in points becomes pixels (\(json["width"] ?? nil)×\(json["height"] ?? nil))")
        check(json["file"]?["path"]?.stringValue == out && json["file"]?["format"] == "jpeg"
              && (try? Data(contentsOf: URL(fileURLWithPath: out)).prefix(2)) == Data([0xFF, 0xD8]), "--out writes a JPEG where asked")
        check(json["rect"]?.rect == CGRect(x: 100, y: 80, width: 300, height: 200), "the result says where it was")

        let before = library.items.count
        run = try await shotdock(["capture", "area", "--rect", "0,0,50,40", "--display", "1", "--no-history", "--copy", "--json"])
        check(run.status == 0 && run.json?["id"] == .null && library.items.count == before, "--no-history keeps it out of the history")
        check(NSPasteboard.general.data(forType: .png) != nil, "--copy puts the image on the clipboard")

        run = try await shotdock(["capture", "repeat", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_found", "repeat without a previous area is not found")
        settings.lastArea = ScreenGeometry.flipped(CGRect(x: 10, y: 20, width: 120, height: 90), primaryHeight: screen.frame.height)
        run = try await shotdock(["capture", "repeat", "--json"])
        check(run.status == 0 && run.json?["width"]?.intValue == Int(120 * scale), "repeat captures the last area")

        let started = Date()
        run = try await shotdock(["capture", "area", "--rect", "0,0,20,20", "--delay", "0.6", "--no-history", "--json"])
        check(run.status == 0 && Date().timeIntervalSince(started) >= 0.6, "--delay waits")

        run = try await shotdock(["capture", "area", "--rect", "0,0,20,20", "--display", "9", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_found", "unknown displays are not found")
        run = try await shotdock(["capture", "area", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "invalid_params", "an area needs rect or --interactive")

        // Windows: by id, and a clear error listing what is open.
        run = try await shotdock(["windows", "--json"])
        if let first = run.json?["windows"]?.arrayValue?.first(where: { $0["on_screen"] == true }), let id = first["id"]?.intValue {
            run = try await shotdock(["capture", "window", "--id", String(id), "--no-shadow", "--json"])
            json = run.json ?? [:]
            let frame = first["frame"]?.rect ?? .zero
            check(run.status == 0 && json["window"]?["id"]?.intValue == id, "capture window --id (\(first["app"]?.stringValue ?? ""))")
            check(abs(Double(json["width"]?.intValue ?? 0) - frame.width * scale) <= 2 * scale, "window size matches its frame")
        } else {
            note("no window to capture")
        }
        run = try await shotdock(["capture", "window", "--app", "NoExisteEstaApp", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_found" && run.json?["error"]?["message"]?.stringValue?.contains("Open windows") == true,
              "no matching window lists the open ones")
        check(run.json?["error"]?["data"] == nil, "once, without the same list again as data")

        // ShotDock's own windows: its preferences, for a manual.
        app.openPreferences(tab: .agents)
        try await Task.sleep(for: .milliseconds(500))
        run = try await shotdock(["capture", "window", "--app", "ShotDock", "--title", "Agentes", "--no-shadow", "--json"])
        let prefsFrame = app.preferences?.window?.frame ?? .zero
        check(run.status == 0 && abs(Double(run.json?["width"]?.intValue ?? 0) - prefsFrame.width * scale) <= 2 * scale,
              "capture window of ShotDock's preferences (\(run.json?["width"] ?? nil), \(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
        app.preferences?.close()

        // A covered window, or part of it, without bringing it forward; minimised, a clear error.
        func plain(_ color: NSColor, _ frame: CGRect) -> NSWindow {
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = color
            window.orderFront(nil)
            return window
        }
        let covered = plain(.red, CGRect(x: 200, y: 200, width: 300, height: 200))
        let cover = plain(.blue, CGRect(x: 150, y: 150, width: 400, height: 300))
        defer { covered.close(); cover.close() }
        cover.order(.above, relativeTo: covered.windowNumber)
        try await Task.sleep(for: .milliseconds(400))
        // The window server's order, front to back.
        func stacking() -> [Int] {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let numbers = list.compactMap { $0[kCGWindowNumber as String] as? Int }
            return [cover.windowNumber, covered.windowNumber].map { numbers.firstIndex(of: $0) ?? -1 }
        }
        let order = stacking()
        if order.contains(-1) {
            note("the test windows are in another Space (a full-screen app in front)")
        } else {
            check(order[0] < order[1], "the test window is covered (\(order))")
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        run = try await shotdock(["capture", "window", "--id", String(covered.windowNumber), "--rect", "20,60,100,50", "--no-history", "--json"])
        json = run.json ?? [:]
        let coveredImage = json["path"]?.stringValue.flatMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let middle = coveredImage.flatMap { Measure.color(in: $0, at: CGPoint(x: $0.width / 2, y: $0.height / 2)) }
        check(run.status == 0 && json["width"]?.intValue == Int(100 * scale) && json["height"]?.intValue == Int(50 * scale),
              "capture window --rect takes part of it (\(json["width"] ?? nil)×\(json["height"] ?? nil), \(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
        check(middle.map { $0.red > 0.8 && $0.blue < 0.3 } == true, "a covered window comes out as itself, not what covers it (\(String(describing: middle)))")
        check(stacking() == order, "the windows keep their order (\(order) → \(stacking()))")
        check(NSWorkspace.shared.frontmostApplication == frontmost,
              "the focus stays where it was (\(frontmost?.localizedName ?? "-") → \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"))")
        check(json["rect"]?.rect?.width == 100 && json["rect"]?.rect?.minX == (json["window"]?["frame"]?.rect?.minX ?? -1) + 20,
              "the result says where that part is on screen")
        run = try await shotdock(["capture", "window", "--id", String(covered.windowNumber), "--rect", "900,900,10,10", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "invalid_params", "a rect outside the window is refused")
        covered.miniaturize(nil)
        try await Task.sleep(for: .seconds(2.5))
        run = try await shotdock(["capture", "window", "--id", String(covered.windowNumber), "--no-history", "--json"])
        let minimised = run.json?["path"]?.stringValue.flatMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            .flatMap { Measure.color(in: $0, at: CGPoint(x: $0.width / 2, y: $0.height / 2)) }
        check(run.status == 0 && minimised.map { $0.red > 0.8 && $0.blue < 0.3 } == true,
              "a minimised window is captured without restoring it (\(run.json?["error"]?["message"] ?? nil))")
        check(covered.isMiniaturized, "and it stays minimised")
        covered.deminiaturize(nil)

        // Interactive: the user drags an area while the CLI waits.
        async let picked = shotdock(["capture", "area", "--interactive", "--json"])
        var waited = 0
        while app.coordinator.selection == nil, waited < 100 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
        if let view = app.coordinator.selection?.selectionViews.first(where: { $0.snapshot.displayID == screen.displayID }), let window = view.window {
            let toWindow = { (p: CGPoint) in view.convert(p, to: nil) }
            send(.leftMouseDown, at: toWindow(CGPoint(x: 200, y: 150)), to: window)
            send(.leftMouseDragged, at: toWindow(CGPoint(x: 300, y: 200)), to: window)
            send(.leftMouseUp, at: toWindow(CGPoint(x: 360, y: 250)), to: window)
        } else {
            fail("the overlay did not appear for --interactive")
        }
        run = try await picked
        check(run.status == 0 && run.json?["width"]?.intValue == Int(160 * scale) && run.json?["rect"]?.rect == CGRect(x: 200, y: 150, width: 160, height: 100),
              "--interactive returns what the user selected (\(run.json?["rect"] ?? nil))")

        // Cancelling (Esc) is reported as such.
        async let cancelled = shotdock(["capture", "area", "--interactive", "--json"])
        waited = 0
        while app.coordinator.selection == nil, waited < 100 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
        app.coordinator.selection?.selectionViews.first?.onCancel?()
        run = try await cancelled
        check(run.status == 1 && run.json?["error"]?["kind"] == "cancelled", "Esc cancels and says so")

        // Scrolling: the session shows its controls; finishing returns the stitched image.
        async let scrolled = shotdock(["capture", "scroll", "--rect", "100,100,400,300", "--json"])
        waited = 0
        while app.coordinator.scrollSession == nil, waited < 100 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
        try await Task.sleep(for: .milliseconds(500))
        app.coordinator.scrollSession?.finish()
        run = try await scrolled
        check(run.status == 0 && run.json?["width"]?.intValue == Int(400 * scale) && (run.json?["height"]?.intValue ?? 0) >= Int(300 * scale),
              "capture scroll returns the stitched image (\(run.json?["width"] ?? nil)×\(run.json?["height"] ?? nil))")
        check(NSPasteboard.general.string(forType: .string) == nil || NSPasteboard.general.data(forType: .png) != nil, "clipboard as left by --copy")
    }
}

extension SelfTest {
    /// `shotdock mcp` as Claude Code runs it: JSON-RPC on stdin, answers on stdout.
    func mcp() async throws {
        AppSettings.shared.agentControlEnabled = true
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        func message(_ id: Int?, _ method: String, _ params: JSONValue = [:]) -> String {
            var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": params]
            if let id { object["id"] = .number(Double(id)) }
            return JSONValue.object(object).jsonString()
        }
        var canCapture = false
        if ScreenCapturer.hasPermission { canCapture = (try? await ScreenCapturer.snapshotAllDisplays()) != nil }
        let input = [
            message(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]]),
            message(nil, "notifications/initialized"),
            message(2, "tools/list"),
            message(3, "tools/call", ["name": "status", "arguments": [:]]),
            message(4, "tools/call", ["name": "list_displays", "arguments": [:]]),
            message(5, "tools/call", ["name": "capture_area", "arguments": ["rect": ["x": 0, "y": 0, "width": 640, "height": 480]]]),
            message(6, "tools/call", ["name": "capture_area", "arguments": ["rect": "0,0,10,10"]]),
        ].joined(separator: "\n") + "\n"
        let run = try await shotdock(["mcp"], stdin: Data(input.utf8))
        let replies = run.stdout.split(separator: "\n").compactMap { try? JSONValue(parsing: String($0)) }
        check(run.status == 0 && replies.map { $0["id"] } == [1, 2, 3, 4, 5, 6], "one answer per request, none for the notification (\(replies.count))")
        func reply(_ id: Int) -> JSONValue? { replies.first { $0["id"] == .number(Double(id)) }?["result"] }

        check(reply(1)?["protocolVersion"] == "2025-06-18" && reply(1)?["serverInfo"]?["name"] == "shotdock", "initialize")
        let tools = reply(2)?["tools"]?.arrayValue ?? []
        check(tools.count == CommandCatalog.tools.count && tools.contains { $0["name"] == "capture_window" }, "tools/list has every tool (\(tools.count))")
        check(reply(3)?["structuredContent"]?["agent_control"]?["enabled"] == true, "status through MCP")
        check(reply(4)?["structuredContent"]?["displays"]?.arrayValue?.count == NSScreen.screens.count, "list_displays through MCP")
        if canCapture {
            let content = reply(5)?["content"]?.arrayValue ?? []
            let structured = reply(5)?["structuredContent"]
            check(content.contains { $0["type"] == "image" } && structured?["path"]?.stringValue != nil, "capture_area returns a preview image and the path")
            let scale = NSScreen.screens[0].backingScaleFactor
            check(structured?["width"]?.intValue == Int(640 * scale) && structured?["preview_scale"]?.doubleValue != nil,
                  "full-size capture with its preview scale (\(structured?["preview_scale"] ?? nil))")
        } else {
            check(reply(5)?["isError"] == true, "capture_area fails cleanly without a capturable screen")
            note("screen not capturable (locked or no permission): preview not checked")
        }
        check(reply(6)?["isError"] == true && reply(6)?["content"]?[0]?["text"]?.stringValue?.hasPrefix("invalid_params") == true,
              "bad arguments are a tool error")
    }
}

extension SelfTest {
    /// The history from the CLI, with imported images (no screen capture needed).
    func cliHistory() async throws {
        let settings = AppSettings.shared
        settings.agentControlEnabled = true
        settings.saveFolder = output.deletingLastPathComponent().appendingPathComponent("selftest-saved", isDirectory: true)
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        let folder = output.deletingLastPathComponent()
        let first = folder.appendingPathComponent("selftest-import-1.png"), second = folder.appendingPathComponent("selftest-import-2.png")
        try ImageEncoding.write(Self.testPattern(width: 800, height: 500, text: "Uno"), to: first, scale: 2)
        try ImageEncoding.write(Self.testPattern(width: 600, height: 400, text: "Dos"), to: second, scale: 1)

        var run = try await shotdock(["history", "list", "--json"])
        check(run.status == 0 && run.json?["captures"] == [] && run.json?["enabled"] == true, "empty history")
        run = try await shotdock(["history", "show", "last", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_found", "last of an empty history is not found")

        run = try await shotdock(["history", "import", first.path, "--json"])
        let firstID = run.json?["id"]?.stringValue ?? ""
        check(run.status == 0 && run.json?["scale"]?.doubleValue == 2 && run.json?["width"] == 800, "import keeps the size and reads the scale from the DPI")
        // Relative paths are resolved where the CLI runs, not in the app.
        run = try await shotdock(["history", "import", "build/selftest-import-2.png", "--json"])
        check(run.status == 0 && run.json?["scale"]?.doubleValue == 1, "relative paths work (\(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")

        run = try await shotdock(["history", "list", "--limit", "1", "--json"])
        check(run.json?["total"] == 2 && run.json?["captures"]?.arrayValue?.count == 1 && run.json?["captures"]?[0]?["width"] == 600,
              "list, newest first, limited")
        run = try await shotdock(["history", "list"])
        check(run.status == 0 && run.stdout.contains("\n\nID ") && run.stdout.hasPrefix("enabled:"), "text table of captures")

        // A text annotation makes the capture findable.
        let id = UUID(uuidString: firstID)!
        var document = LibraryStore.shared.document(id)!
        document.annotations = [Annotation(shape: .text(origin: CGPoint(x: 40, y: 40), string: "Factura de noviembre"), style: AnnotationStyle())]
        LibraryStore.shared.update(id, with: document)
        run = try await shotdock(["history", "list", "--search", "FACTURA", "--json"])
        check(run.json?["captures"]?.arrayValue?.map { $0["id"] } == [.string(firstID)], "search finds text annotations")
        run = try await shotdock(["history", "list", "--since", "1h", "--no-saved", "--json"])
        check(run.json?["total"] == 2, "--since and --no-saved filter")

        run = try await shotdock(["history", "show", String(firstID.prefix(8)), "--json"])
        let shown = run.json ?? [:]
        check(run.status == 0 && shown["id"] == .string(firstID) && shown["annotations"]?[0]?["type"] == "text", "show by id prefix, with annotations")
        check(shown["path"]?.stringValue.map { FileManager.default.fileExists(atPath: $0) } == true && shown["open_in_editor"] == false,
              "show writes the edited image")

        let export = folder.appendingPathComponent("selftest-cli-export.jpg").path
        run = try await shotdock(["history", "export", "last-1", "--out", export, "--json"])
        check(run.status == 0 && (try? Data(contentsOf: URL(fileURLWithPath: export)).prefix(2)) == Data([0xFF, 0xD8]), "export to a JPEG")

        run = try await shotdock(["history", "reveal", "last", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_found", "reveal needs a saved capture")
        run = try await shotdock(["history", "save", "last", "--json"])
        let saved = run.json?["saved_path"]?.stringValue ?? ""
        check(run.status == 0 && saved.hasPrefix(settings.saveFolder.path) && FileManager.default.fileExists(atPath: saved), "save to the preferences' folder")
        check(LibraryStore.shared.items.first?.savedPath == saved, "the history remembers where")
        run = try await shotdock(["history", "list", "--saved", "--json"])
        check(run.json?["total"] == 1, "--saved")

        NSPasteboard.general.clearContents()
        run = try await shotdock(["history", "copy", "last", "--json"])
        check(run.status == 0 && NSPasteboard.general.data(forType: .png) != nil, "copy puts the image on the clipboard")

        run = try await shotdock(["history", "open", firstID, "--json"])
        check(run.status == 0 && app.coordinator.editors.contains { $0.libraryItemID == id }, "open shows the editor")
        run = try await shotdock(["history", "show", firstID, "--json"])
        check(run.json?["open_in_editor"] == true, "show knows the editor is open")
        app.coordinator.editors.forEach { $0.close() }

        run = try await shotdock(["history", "gallery", "--json"])
        check(run.status == 0 && app.gallery?.window?.isVisible == true, "gallery opens")
        app.gallery?.window?.close()

        run = try await shotdock(["history", "delete", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "invalid_params", "delete needs captures or --all")
        run = try await shotdock(["history", "delete", "last", "--json"])
        check(run.status == 0 && run.json?["deleted"] == 1 && LibraryStore.shared.items.count == 1, "delete one")
        run = try await shotdock(["history", "delete", "--all", "--json"])
        check(run.status == 0 && LibraryStore.shared.items.isEmpty, "delete --all empties the history")
    }
}

extension SelfTest {
    /// Annotations, crop, resize and backdrop from the CLI, on an imported image.
    func cliEdit() async throws {
        AppSettings.shared.agentControlEnabled = true
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        let folder = output.deletingLastPathComponent()
        let file = folder.appendingPathComponent("selftest-edit.png")
        try ImageEncoding.write(Self.testPattern(width: 1000, height: 800, text: "Guardar cambios"), to: file, scale: 2)
        var run = try await shotdock(["history", "import", file.path, "--json"])
        guard let idText = run.json?["id"]?.stringValue, let id = UUID(uuidString: idText) else { return fail("import failed: \(run.stdout)") }
        func document() -> CaptureDocument { RemoteDocuments.editor(for: id)?.model.document ?? LibraryStore.shared.document(id)! }
        func marks() async throws -> [JSONValue] { try await shotdock(["annotations", "last", "--json"]).json?["annotations"]?.arrayValue ?? [] }

        run = try await shotdock(["annotate", "arrow", "last", "--from", "100,100", "--to", "300,200", "--color", "blue", "--json"])
        check(run.status == 0 && run.json?["annotation_count"] == 1 && run.json?["added"]?.arrayValue?.count == 1, "annotate arrow (\(run.stderr))")
        check(run.json?["path"]?.stringValue.map { FileManager.default.fileExists(atPath: $0) } == true, "the edited image comes back")
        let batch = #"[{"type":"rectangle","rect":{"x":400,"y":100,"width":200,"height":120}},{"type":"step","at":{"x":120,"y":400}},{"type":"step","at":{"x":200,"y":400}},{"type":"text","at":{"x":300,"y":380},"text":"Paso a paso"}]"#
        run = try await shotdock(["annotate", "last", "--annotations", "-", "--json"], stdin: Data(batch.utf8))
        check(run.status == 0 && run.json?["annotation_count"] == 5, "a batch of annotations from stdin")
        var list = try await marks()
        let steps = list.filter { $0["type"] == "step" }.compactMap { $0["number"]?.intValue }
        check(steps == [1, 2], "steps are numbered in order (\(steps))")
        check(list.first?["from"]?.point == CGPoint(x: 100, y: 100) && list.first?["color"] == .string(RGBAColor.blue.hexString), "annotations list as given")
        check(document().annotations.count == 5, "stored in the history as editable annotations")

        // On text, found by OCR.
        run = try await shotdock(["annotate", "highlight", "last", "--on-text", "cambios", "--json"])
        list = try await marks()
        let highlight = list.last { $0["type"] == "highlight" }?["rect"]?.rect ?? .zero
        check(run.status == 0 && highlight.minY > 640 && highlight.maxY < 740 && highlight.minX > 100, "--on-text places the mark on the text (\(highlight))")
        run = try await shotdock(["annotate", "rect", "last", "--on-text", "inexistente", "--json"])
        check(run.status == 1 && run.json?["error"]?["message"]?.stringValue?.contains("Text found") == true, "missing text lists what is there")

        // Change and remove.
        let arrowID = list.first { $0["type"] == "arrow" }?["id"]?.stringValue ?? ""
        run = try await shotdock(["annotation", "update", "last", String(arrowID.prefix(8)), "--to", "400,250", "--color", "green", "--weight", "thick", "--json"])
        check(run.status == 0 && run.json?["annotation"]?["to"]?.point == CGPoint(x: 400, y: 250)
              && run.json?["annotation"]?["color"] == .string(RGBAColor.green.hexString), "annotation update")
        let rectID = list.first { $0["type"] == "rectangle" }?["id"]?.stringValue ?? ""
        run = try await shotdock(["annotation", "remove", "last", rectID, "--json"])
        check(run.status == 0 && run.json?["annotation_count"] == 5, "annotation remove")

        // Crop: positions follow the edited image.
        run = try await shotdock(["crop", "last", "--rect", "50,50,600,400", "--json"])
        check(run.status == 0 && run.json?["width"] == 600 && run.json?["height"] == 400, "crop to 600×400")
        list = try await marks()
        check(list.first { $0["type"] == "arrow" }?["from"]?.point == CGPoint(x: 50, y: 50), "positions are relative to the crop")
        run = try await shotdock(["resize", "last", "--scale", "0.5", "--json"])
        check(run.status == 0 && run.json?["width"] == 300 && run.json?["scale"]?.doubleValue == 1, "resize to half, 1×")
        list = try await marks()
        check(list.first { $0["type"] == "arrow" }?["from"]?.point == CGPoint(x: 25, y: 25), "and to the resize")
        run = try await shotdock(["resize", "last", "--width", "450", "--json"])
        check(run.json?["width"] == 450 && run.json?["height"] == 300, "resize by width keeps the proportions")
        _ = try await shotdock(["resize", "last", "--reset"])
        run = try await shotdock(["crop", "last", "--reset", "--json"])
        check(run.json?["width"] == 1000 && document().crop == nil && document().resize == nil, "reset crop and size")

        run = try await shotdock(["backdrop", "last", "--preset", "3", "--padding", "20", "--radius", "12", "--json"])
        let framedWidth = run.json?["width"]?.intValue
        check(run.status == 0 && framedWidth == 1080 && document().backdrop?.cornerRadius == 12, "backdrop with 20 pt of margin")
        run = try await shotdock(["backdrop", "last", "--gradient", "#000000,#FFFFFF,90", "--aspect", "1:1", "--json"])
        check(run.json?["width"] == run.json?["height"], "square backdrop")
        run = try await shotdock(["backdrop", "last", "--off", "--json"])
        check(run.json?["width"] == 1000 && document().backdrop == nil, "backdrop off")

        // Warnings for what an agent cannot see in its numbers.
        run = try await shotdock(["annotate", "step", "last", "--at", "995,400", "--json"])
        let cutOff = run.json?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        check(run.status == 0 && cutOff.count == 1 && cutOff[0].contains("cut off"), "a step past the edge is warned about (\(cutOff))")
        run = try await shotdock(["annotate", "text", "last", "--at", "\(Int(highlight.minX)),\(Int(highlight.minY))", "--text", "Encima", "--json"])
        let covering = run.json?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        check(covering.contains { $0.contains("covers text of the capture") }, "a text over the capture's text is warned about (\(covering))")
        run = try await shotdock(["annotate", "arrow", "last", "--from", "300,500", "--to", "500,500", "--json"])
        check(run.status == 0 && run.json?["warnings"] == nil, "no warnings when all is clear")
        _ = try await shotdock(["annotation", "remove", "last"] + (run.json?["added"]?.arrayValue ?? []).compactMap(\.stringValue))
        let added = document().annotations.suffix(2).map(\.id.uuidString)
        _ = try await shotdock(["annotation", "remove", "last"] + added)

        // Duplicates: with the edits, or the capture as taken.
        let count = document().annotations.count
        run = try await shotdock(["history", "duplicate", "last", "--json"])
        let copy = run.json?["id"]?.stringValue ?? ""
        check(run.status == 0 && !copy.isEmpty && copy != idText && run.json?["source"] == .string(idText)
              && run.json?["annotation_count"]?.intValue == count, "history duplicate keeps the annotations (\(count))")
        let copyMarks = UUID(uuidString: copy).flatMap { LibraryStore.shared.document($0) }?.annotations.map(\.id) ?? []
        check(Set(copyMarks).isDisjoint(with: document().annotations.map(\.id)), "with ids of its own")
        run = try await shotdock(["history", "duplicate", idText, "--original", "--json"])
        let bare = run.json?["id"]?.stringValue ?? ""
        check(run.status == 0 && run.json?["annotation_count"] == 0 && run.json?["width"] == 1000, "--original leaves the edits out")
        _ = try await shotdock(["history", "delete", copy, bare])

        // With the editor open, changes go through it and can be undone there.
        _ = try await shotdock(["history", "open", idText])
        guard let editor = RemoteDocuments.editor(for: id) else { return fail("no editor") }
        let before = editor.model.document.annotations.count
        run = try await shotdock(["annotate", "oval", "last", "--rect", "700,300,120,80", "--json"])
        check(run.status == 0 && editor.model.document.annotations.count == before + 1, "the open editor shows the new annotation")
        editor.model.undoManager.undo()
        check(editor.model.document.annotations.count == before, "and can undo it")
        editor.close()
        try await Task.sleep(for: .milliseconds(800))

        // Files are imported, and preview coordinates are scaled.
        let big = folder.appendingPathComponent("selftest-edit-big.png")
        try ImageEncoding.write(Self.testPattern(width: 3000, height: 1500), to: big, scale: 2)
        run = try await shotdock(["annotate", "rect", "build/selftest-edit-big.png", "--rect", "100,100,200,100", "--space", "preview", "--json"])
        let newID = run.json?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let again = try await shotdock(["annotate", "oval", big.path, "--rect", "10,10,50,50", "--json"])
        check(again.json?["id"]?.stringValue == newID?.uuidString && again.json?["annotation_count"] == 2,
              "editing the same unchanged file again continues the same capture")
        let box = newID.flatMap { LibraryStore.shared.document($0)?.annotations.first?.box } ?? .zero
        let scale = ImagePreview.scale(for: CGSize(width: 3000, height: 1500))
        check(run.status == 0 && newID != id && abs(box.width - 200 / scale) < 1, "a file becomes a capture; preview positions are scaled (\(box))")
    }
}

extension SelfTest {
    /// Ruler, eyedropper and OCR from the CLI on a drawn image.
    func cliInspect() async throws {
        AppSettings.shared.agentControlEnabled = true
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        // White, an orange 240 × 120 box at (100, 80), a line of text and a QR code.
        let context = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.flipVertically(height: 600)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        context.setFillColor(red: 1, green: 90.0 / 255, blue: 31.0 / 255, alpha: 1)
        context.fill(CGRect(x: 100, y: 80, width: 240, height: 120))
        TextLayout(string: "Factura 2026", fontSize: 40, color: CGColor(gray: 0, alpha: 1)).draw(at: CGPoint(x: 80, y: 320), in: context)
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://shotdock.app".utf8)])!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let qrImage = CIContext().createCGImage(qr, from: qr.extent)!
        context.drawImageTopLeft(qrImage, in: CGRect(x: 560, y: 260, width: CGFloat(qrImage.width), height: CGFloat(qrImage.height)))
        let file = output.deletingLastPathComponent().appendingPathComponent("selftest-inspect.png")
        try ImageEncoding.write(context.makeImage()!, to: file, scale: 2)

        var run = try await shotdock(["measure", file.path, "--at", "150,100", "--json"])
        check(LibraryStore.shared.items.isEmpty, "reading a file does not add it to the history")
        _ = try await shotdock(["history", "import", file.path])
        check(run.status == 0 && run.json?["width"] == 240 && run.json?["height"] == 120 && run.json?["width_pt"] == 120,
              "measure finds the box (\(run.json?["width"] ?? nil)×\(run.json?["height"] ?? nil))")
        check(run.json?["rect"]?.rect == CGRect(x: 100, y: 80, width: 240, height: 120), "and where it is")
        NSPasteboard.general.clearContents()
        run = try await shotdock(["color", "last", "--at", "150,100", "--copy", "--json"])
        check(run.json?["hex"] == "#FF5A1F" && run.json?["rgb"] == "rgb(255, 90, 31)", "eyedropper reads the colour")
        check(NSPasteboard.general.string(forType: .string) == "#FF5A1F", "--copy uses the preferences' format")
        run = try await shotdock(["color", "last", "--at", "2000,10", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "invalid_params", "points outside the image are refused")

        run = try await shotdock(["ocr", "last", "--copy", "--json"])
        let ocr = run.json ?? [:]
        check(run.status == 0 && ocr["text"]?.stringValue?.contains("Factura 2026") == true, "ocr reads the text")
        let line = ocr["lines"]?.arrayValue?.first { $0["text"]?.stringValue?.contains("Factura") == true }
        check((line?["box"]?.rect?.minY ?? 0) > 300 && (line?["box"]?.rect?.maxY ?? 999) < 380, "lines come with their box (\(line?["box"] ?? nil))")
        check(ocr["codes"]?[0]?["payload"] == "https://shotdock.app" && ocr["codes"]?[0]?["symbology"]?.stringValue?.contains("QR") == true,
              "and the QR code with its content")
        check(NSPasteboard.general.string(forType: .string) == "https://shotdock.app", "--copy copies the QR content, as the shortcut")
        run = try await shotdock(["history", "list", "--search", "factura", "--json"])
        check(run.json?["total"] == 1, "the recognised text makes the capture findable")

        if ScreenCapturer.hasPermission, (try? await ScreenCapturer.snapshotAllDisplays()) != nil {
            run = try await shotdock(["color", "--at", "5,5", "--json"])
            check(run.status == 0 && run.json?["hex"]?.stringValue?.hasPrefix("#") == true, "eyedropper on the screen")
            run = try await shotdock(["measure", "--at", "300,300", "--json"])
            check(run.status == 0 && run.json?["screen_rect"]?.rect != nil, "ruler on the screen")
        } else {
            note("screen not capturable: screen eyedropper and ruler not checked")
        }
    }
}

extension SelfTest {
    /// Pins and uploads from the CLI; uploads go to scripts/mock-s3.py, started here.
    func cliShare() async throws {
        let settings = AppSettings.shared
        settings.agentControlEnabled = true
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        let file = output.deletingLastPathComponent().appendingPathComponent("selftest-share.png")
        try ImageEncoding.write(Self.testPattern(width: 600, height: 400, text: "Fijada"), to: file, scale: 2)
        var run = try await shotdock(["history", "import", file.path, "--json"])
        let captureID = run.json?["id"]?.stringValue ?? ""

        // Pins.
        run = try await shotdock(["pin", "last", "--zoom", "0.5", "--opacity", "0.6", "--at", "100,120", "--json"])
        let pinID = run.json?["id"]?.stringValue ?? ""
        check(run.status == 0 && app.coordinator.pins.count == 1 && run.json?["capture"] == .string(captureID), "pin a capture")
        let frame = run.json?["frame"]?.rect ?? .zero
        check(abs(frame.width - 150) < 1 && abs(frame.minX - 100) < 1 && abs(frame.minY - 120) < 1, "at its zoom and place (\(frame))")
        check(run.json?["opacity"] == 0.6, "with its opacity")
        run = try await shotdock(["pins", "--json"])
        check(run.json?["pins"]?.arrayValue?.count == 1, "pins lists it")
        run = try await shotdock(["pin", "update", String(pinID.prefix(6)), "--click-through", "--zoom", "1", "--json"])
        check(run.status == 0 && app.coordinator.pins.first?.clickThrough == true && run.json?["zoom"] == 1, "pin update: clicks go through, zoom 100 %")
        run = try await shotdock(["pin", "close", "--all", "--json"])
        try await Task.sleep(for: .milliseconds(200))
        check(run.json?["closed"] == 1 && app.coordinator.pins.isEmpty, "pin close --all")

        // Uploads against the mock S3 server.
        run = try await shotdock(["upload", "last", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "not_configured", "upload without settings says so")
        let repo = output.deletingLastPathComponent().deletingLastPathComponent()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", repo.appendingPathComponent("scripts/mock-s3.py").path, "--port", "9556"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(for: .milliseconds(800))
        var config = S3Configuration()
        config.provider = .minio
        config.endpoint = "http://127.0.0.1:9556"
        config.region = "eu-west-1"
        config.bucket = "capturas"
        config.pathStyle = true
        config.linkMode = .presigned
        settings.s3 = config
        defer { Keychain.saveS3Credentials(nil) }
        // The secret is read from stdin when it is not an argument.
        run = try await shotdock(["s3", "credentials", "--access-key-id", "test", "--json"], stdin: Data("testsecret\n".utf8))
        check(run.status == 0 && Keychain.loadS3Credentials()?.secretAccessKey == "testsecret", "s3 credentials reads the secret from stdin")
        run = try await shotdock(["upload", "test", "--json"])
        check(run.status == 0 && run.json?["ok"] == true, "upload test")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sin tocar", forType: .string)
        run = try await shotdock(["upload", "last", "--json"])
        let link = run.json?["url"]?.stringValue ?? ""
        check(run.status == 0 && link.contains("/capturas/") && link.contains("X-Amz-Signature="), "upload returns the link")
        check(NSPasteboard.general.string(forType: .string) == "sin tocar", "without --copy the clipboard is untouched")
        if let url = URL(string: link) {
            let (data, _) = try await URLSession.shared.data(from: url)
            check((try? ImageEncoding.image(from: data))?.width == 600, "the link downloads the capture")
        }
        check(LibraryStore.shared.items.first?.uploadedURL == link, "the history remembers the link")
        run = try await shotdock(["history", "list", "--uploaded", "--json"])
        check(run.json?["total"] == 1, "history list --uploaded")

        // MCP has no tool for the keys.
        check(CommandCatalog.tools.allSatisfy { $0.name != "s3.credentials" }, "S3 keys are not an MCP tool")
    }
}

extension SelfTest {
    /// Preferences and shortcuts from the CLI.
    func cliPrefs() async throws {
        let settings = AppSettings.shared
        settings.agentControlEnabled = true
        _ = startControl { true }
        defer { ControlService.shared.stop() }

        var run = try await shotdock(["prefs", "list", "--json"])
        let all = run.json?["preferences"]?.arrayValue ?? []
        check(run.status == 0 && all.count == Preferences.all.count && all.allSatisfy { $0["value"] != .null }, "prefs list: every preference has a value")
        run = try await shotdock(["prefs", "get", "save_profile", "--json"])
        check(run.json?["value"] == .string(settings.exportProfiles[0].name), "prefs get")
        run = try await shotdock(["prefs", "set", "save_profile", "web", "--json"])
        check(run.status == 0 && settings.profile(for: .save).name == "Web", "prefs set save_profile (any case)")
        run = try await shotdock(["prefs", "set", "capture_delay", "99", "--json"])
        check(run.status == 1 && run.json?["error"]?["kind"] == "invalid_params", "out-of-range values are refused")
        _ = try await shotdock(["prefs", "set", "capture_delay", "5"])
        _ = try await shotdock(["prefs", "set", "copy_after_capture", "false"])
        check(settings.captureDelay == 5 && !settings.copyAfterCapture, "numbers and booleans")
        run = try await shotdock(["prefs", "set", "history_limit", "all", "--json"])
        check(settings.historyLimit == Int.max && run.json?["value"] == "all", "history_limit all")
        let folder = output.deletingLastPathComponent().path
        _ = try await shotdock(["prefs", "set", "save_folder", folder])
        check(settings.saveFolder.path == folder, "save_folder")
        run = try await shotdock(["prefs", "set", "agent_control", "false", "--json"])
        check(run.status == 1 && settings.agentControlEnabled, "agent control cannot be changed from outside")
        _ = try await shotdock(["prefs", "set", "s3.provider", "r2"])
        check(settings.s3.provider == .r2 && settings.s3.pathStyle && settings.s3.endpoint.contains("r2"), "s3.provider brings its endpoint, like the pane")
        run = try await shotdock(["prefs", "set", "nonsense", "1", "--json"])
        check(run.status == 2, "unknown keys are a usage error")

        run = try await shotdock(["shortcuts", "list", "--json"])
        let rows = run.json?["shortcuts"]?.arrayValue ?? []
        let area = rows.first { $0["action"] == "capture_area" }
        check(rows.count == ShortcutNames.all.count && area?["keys"] == "shift+cmd+2" && area?["scope"] == "global", "shortcuts list")
        run = try await shotdock(["shortcuts", "set", "capture_window", "shift+cmd+2", "--json"])
        check(run.status == 0 && run.json?["released"] == ["capture_area"] && settings.shortcuts.combo(for: .captureWindow)?.keyCode == 0x13,
              "a combo moves to its new action")
        run = try await shotdock(["shortcuts", "set", "editor.save", "⌘U", "--json"])
        check(run.json?["released"] == ["editor.upload"] && settings.editorShortcuts.combo(for: .upload) == nil, "editor shortcuts too")
        run = try await shotdock(["shortcuts", "set", "capture_area", "2", "--json"])
        check(run.status == 1 && run.json?["error"]?["message"]?.stringValue?.contains("needs") == true, "global shortcuts need a modifier")
        run = try await shotdock(["shortcuts", "set", "capture_area", "--default", "--json"])
        check(settings.shortcuts.combo(for: .captureArea) == ShortcutAction.captureArea.defaultCombo, "--default")
        run = try await shotdock(["shortcuts", "set", "capture_area", "--off", "--json"])
        check(settings.shortcuts.combo(for: .captureArea) == nil, "--off")

        run = try await shotdock(["open", "preferences", "--tab", "agents", "--json"])
        try await Task.sleep(for: .milliseconds(400))
        let window = NSApp.windows.first { $0.identifier?.rawValue == "preferences" }
        check(run.status == 0 && window?.isVisible == true && window?.title == "Agentes", "open preferences on the Agentes tab")
        if let window, ScreenCapturer.hasPermission, (try? await ScreenCapturer.snapshotAllDisplays()) != nil {
            try await snapshot(window, to: sibling("agentes"))
        } else if let view = window?.contentView {
            render(view, to: sibling("agentes"))
        }
        window?.close()
    }
}

extension SelfTest {
    /// Secret redaction from the CLI and from the editor.
    func cliRedact() async throws {
        AppSettings.shared.agentControlEnabled = true
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        func secretsImage() -> CGImage {
            let context = CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.flipVertically(height: 400)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
            for (i, line) in ["Clave de AWS AKIAIOSFODNN7EXAMPLE", "Correo ricardo@example.com", "Hola, esto no es secreto"].enumerated() {
                TextLayout(string: line, fontSize: 40, color: CGColor(gray: 0, alpha: 1)).draw(at: CGPoint(x: 40, y: 40 + i * 110), in: context)
            }
            return context.makeImage()!
        }
        let file = output.deletingLastPathComponent().appendingPathComponent("selftest-secrets.png")
        try ImageEncoding.write(secretsImage(), to: file, scale: 2)

        var run = try await shotdock(["redact", file.path, "--dry-run", "--json"])
        let found = run.json?["found"]?.arrayValue ?? []
        check(run.status == 0 && Set(found.compactMap { $0["kind"]?.stringValue }) == ["api_key", "email"] && run.json?["covered"] == 0,
              "dry run reports the secrets (\(found.compactMap { $0["masked"]?.stringValue }))")
        check(!run.stdout.contains("AKIAIOSFODNN7EXAMPLE") && !run.stdout.contains("ricardo@example.com"), "findings are masked, never the secret")
        run = try await shotdock(["redact", "last", "--kinds", "email", "--json"])
        check(run.json?["covered"] == 1, "--kinds email covers only the e-mail")
        run = try await shotdock(["redact", "last", "--json"])
        check(run.status == 0 && (run.json?["covered"]?.intValue ?? 0) >= 1, "redact covers the key")
        if let path = run.json?["path"]?.stringValue, let data = FileManager.default.contents(atPath: path) {
            let text = try await TextRecognition.recognize(try ImageEncoding.image(from: data)).text()
            check(!text.contains("AKIA") && !text.contains("@example") && text.contains("Hola"), "the exported image no longer shows them (\(text.replacingOccurrences(of: "\n", with: " | ")))")
        }
        run = try await shotdock(["annotations", "last", "--json"])
        check(run.json?["annotations"]?.arrayValue?.allSatisfy { $0["type"] == "redact" && $0["color"] == "#000000" } == true, "as editable black boxes")

        // The editor's Imagen › Ocultar secretos.
        let editor = app.coordinator.openEditor(with: CaptureDocument(image: secretsImage(), scale: 2))
        editor.redactSecrets(nil)
        try await waitFor(seconds: 20) { editor.model.document.annotations.count >= 2 }
        check(editor.model.document.annotations.count == 2 && editor.model.document.annotations.allSatisfy(\.isPixelEffect), "the editor covers them too")
        editor.model.undoManager.undo()
        check(editor.model.document.annotations.isEmpty, "in one undoable step")
        editor.close()
    }
}

extension SelfTest {
    /// The interface in the language the app was launched with (-AppleLanguages).
    func l10n() async throws {
        let language = AppLanguage.running
        note("running in \(language.rawValue); localizations: \(Bundle.main.localizations.sorted())")
        check(Set(Bundle.main.localizations).isSuperset(of: ["en", "es"]), "the bundle has English and Spanish")
        let spanish = language == .es
        let menus = NSApp.mainMenu?.items.map(\.title) ?? []
        let expectedMenus = spanish ? ["ShotDock", "Archivo", "Edición", "Imagen", "Visualización", "Ventana"]
            : ["ShotDock", "File", "Edit", "Image", "View", "Window"]
        check(menus == expectedMenus, "main menu (\(menus))")
        let tabs = PreferencesTab.allCases.map(\.title)
        let expectedTabs = spanish ? ["General", "Captura", "Exportar", "Atajos", "Historial", "Subida", "Agentes", "Importar"]
            : ["General", "Capture", "Export", "Shortcuts", "History", "Upload", "Agents", "Import"]
        check(tabs == expectedTabs, "preferences tabs (\(tabs))")
        check(ShortcutAction.captureArea.title == (spanish ? "Capturar área" : "Capture area"), "shortcut titles from Core")
        check(FilenameTemplate.defaultTemplate == (spanish ? "ShotDock {fecha} a las {hora}" : "ShotDock {date} at {time}"), "default file name")
        check(EditorTool.magnifier.title == (spanish ? "Lupa" : "Magnifier"), "editor tools")
        let date = Date(timeIntervalSince1970: 1_764_064_720)
        let name = CaptureNaming.defaultName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        check(name == (spanish ? "ShotDock 2025-11-25 a las 09.58.40" : "ShotDock 2025-11-25 at 09.58.40"), "window title of a capture (\(name))")
        check(String(localized: "Close pinned images (\(3))") == (spanish ? "Cerrar las imágenes fijadas (3)" : "Close pinned images (3)"), "formats with numbers")

        app.showPreferences()
        try await Task.sleep(for: .milliseconds(500))
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
            for tab in [PreferencesTab.general, .capture, .agents] {
                app.openPreferences(tab: tab)
                try await Task.sleep(for: .milliseconds(400))
                try await snapshot(window, to: sibling("\(language.rawValue)-\(tab.rawValue)"))
            }
            window.close()
        }
        let editor = app.coordinator.openEditor(with: CaptureDocument(image: Self.testPattern(width: 1000, height: 600, text: "ShotDock"), scale: 2))
        try await Task.sleep(for: .milliseconds(500))
        if let window = editor.window { try await snapshot(window, to: sibling("\(language.rawValue)-editor")) }
        editor.close()
    }
}

extension SelfTest {
    /// Export profiles and formats (WebP, HEIC, AVIF, JPEG) from the CLI.
    func cliFormats() async throws {
        let settings = AppSettings.shared
        settings.agentControlEnabled = true
        settings.saveFolder = output.deletingLastPathComponent().appendingPathComponent("selftest-saved", isDirectory: true)
        try? FileManager.default.removeItem(at: settings.saveFolder)
        _ = startControl { true }
        defer { ControlService.shared.stop() }
        let folder = output.deletingLastPathComponent()
        let file = folder.appendingPathComponent("selftest-formats.png")
        try ImageEncoding.write(Self.testPattern(width: 2400, height: 1200, text: "Formatos"), to: file, scale: 2)
        _ = try await shotdock(["history", "import", file.path])

        func decoded(_ path: String) -> (type: String, width: Int)? {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (CGImageSourceGetType(source) as String? ?? "", image.width)
        }

        var run = try await shotdock(["profiles", "list", "--json"])
        let names = run.json?["profiles"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        check(names.count == 4 && names.contains("Web"), "four default profiles (\(names))")

        let webp = folder.appendingPathComponent("selftest-formats.webp").path
        run = try await shotdock(["history", "export", "last", "--out", webp, "--json"])
        let webpFile = decoded(webp)
        check(run.status == 0 && run.json?["file"]?["format"] == "webp" && webpFile?.type == "org.webmproject.webp" && webpFile?.width == 2400,
              "export to .webp writes lossless WebP that macOS reads")
        let pngSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        note("WebP \(run.json?["file"]?["bytes"]?.intValue ?? 0) B vs PNG \(pngSize) B")

        run = try await shotdock(["history", "export", "last", "--out", folder.appendingPathComponent("selftest-formats-web").path, "--profile", "Web", "--json"])
        check(run.json?["file"]?["width"] == 1600 && run.json?["file"]?["path"]?.stringValue?.hasSuffix(".webp") == true,
              "--profile Web: WebP up to 1600 px, extension added")
        run = try await shotdock(["history", "export", "last", "--out", folder.appendingPathComponent("selftest-formats.heic").path, "--quality", "60", "--max-width", "800", "--json"])
        check(run.json?["file"]?["format"] == "heic" && run.json?["file"]?["width"] == 800, "HEIC from the extension, with quality and size")
        if ImageFormat.avif.isAvailable {
            run = try await shotdock(["history", "export", "last", "--out", folder.appendingPathComponent("selftest-formats.avif").path, "--json"])
            check(run.json?["file"]?["format"] == "avif", "AVIF")
        } else {
            note("this Mac cannot write AVIF")
        }

        // Profiles: create, use for saving, rename, remove.
        run = try await shotdock(["profiles", "set", "Blog", "--format", "jpeg", "--quality", "75", "--max-width", "1000", "--json"])
        check(run.status == 0 && settings.profile(named: "blog")?.maxWidth == 1000 && run.json?["summary"]?.stringValue?.contains("75") == true, "profiles set creates one")
        _ = try await shotdock(["prefs", "set", "save_profile", "Blog"])
        run = try await shotdock(["history", "save", "last", "--json"])
        let saved = run.json?["saved_path"]?.stringValue ?? ""
        check(saved.hasSuffix(".jpg") && decoded(saved)?.width == 1000, "saving uses the save profile (\((saved as NSString).lastPathComponent))")
        run = try await shotdock(["history", "save", "last", "--format", "webp", "--json"])
        check(run.json?["saved_path"]?.stringValue?.hasSuffix(".webp") == true, "--format overrides it for one save")
        _ = try await shotdock(["profiles", "set", "Blog", "--rename", "Blog web"])
        check(settings.profile(for: .save).name == "Blog web", "renaming keeps it in use")
        run = try await shotdock(["profiles", "remove", "Blog web", "--json"])
        check(run.status == 0 && settings.profile(for: .save).id == settings.exportProfiles[0].id, "removing falls back to the first profile")
        run = try await shotdock(["history", "export", "last", "--out", "/tmp/x.png", "--profile", "Nope", "--json"])
        check(run.status == 1 && run.json?["error"]?["message"]?.stringValue?.contains("profiles:") == true, "unknown profiles list the others")

        // The Export tab.
        app.openPreferences(tab: .export)
        try await Task.sleep(for: .milliseconds(500))
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
            check(window.title == PreferencesTab.export.title, "Export tab")
            try await snapshot(window, to: sibling("export"))
            window.close()
        }
    }
}

extension SelfTest {
    /// Screenshots for the README (run in English: `make readme-screenshots`).
    /// ShotDock's own windows are the subject, so nothing private is captured.
    func readme() async throws {
        let docs = output.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        guard ScreenCapturer.hasPermission, (try? await ScreenCapturer.snapshotAllDisplays()) != nil else {
            return fail("needs the Screen Recording permission and an unlocked screen")
        }
        func capture(_ window: NSWindow) async throws -> CGImage {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw ScreenCaptureError.noDisplays
            }
            return try await ScreenCapturer.capture(window: scWindow, shadow: false).image
        }
        func save(_ image: CGImage, _ name: String) throws {
            try ImageEncoding.write(image, to: docs.appendingPathComponent(name + ".png"), scale: 2)
            note("wrote docs/screenshots/\(name).png (\(image.width)×\(image.height))")
        }

        // Subjects: the preferences, in English.
        app.showPreferences()
        try await Task.sleep(for: .milliseconds(600))
        guard let preferences = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) else { return fail("no preferences") }
        var shots: [PreferencesTab: CGImage] = [:]
        for tab in [PreferencesTab.general, .export, .agents, .capture] {
            app.openPreferences(tab: tab)
            try await Task.sleep(for: .milliseconds(500))
            shots[tab] = try await capture(preferences)
        }
        try save(shots[.export]!, "export-profiles")
        try save(shots[.agents]!, "agents")
        preferences.close()

        // The editor: the General tab, annotated where its texts are.
        let base = shots[.general]!
        var document = CaptureDocument(image: base, scale: 2)
        let view = DocumentView(document)
        func box(_ text: String) async throws -> CGRect {
            guard let found = try await TextRecognition.recognize(base, find: text).matches.first else { throw RPCError.notFound(text) }
            return found
        }
        let size = CGSize(width: base.width, height: base.height)
        var marks: [JSONValue] = []
        marks.append(AnnotationCoding.placing(["type": "rectangle", "color": "#FF5A1F"], on: try await box("System"), imageSize: size, scale: 2))
        marks.append(AnnotationCoding.placing(["type": "arrow", "color": "#FF5A1F"], on: try await box("Language"), imageSize: size, scale: 2))
        // Steps to the right of their option, clear of the labels column.
        for option in ["Open ShotDock at login", "Copy to the clipboard", "Save to the folder"] {
            let found = try await box(option)
            marks.append(["type": "step", "at": JSONValue(CGPoint(x: found.maxX + 34, y: found.midY))])
        }
        marks.append(AnnotationCoding.placing(["type": "highlight"], on: try await box("Show in the Dock while windows are open"), imageSize: size, scale: 2))
        let languageBox = try await box("Language")
        marks.append(["type": "text", "text": "Pick a language", "color": "#FF5A1F",
                      "at": JSONValue(CGPoint(x: languageBox.maxX + 560, y: languageBox.minY - 50))])
        var nextStep = 1
        for mark in marks {
            let annotation = try AnnotationCoding.annotation(from: mark, for: document, view: view, nextStep: nextStep)
            if case let .step(_, n) = annotation.shape { nextStep = n + 1 }
            document.annotations.append(annotation)
        }
        // The Export tab (icon and label) enlarged in the empty space on the right.
        let exportTab = try await box("Export")
        let source = CGRect(x: exportTab.midX - 44, y: exportTab.minY - 62, width: 88, height: exportTab.height + 74)
        let lensHeight: CGFloat = 230, lensWidth = lensHeight * source.width / source.height
        document.annotations.append(Annotation(shape: .magnifier(source: source, target: CGRect(x: CGFloat(base.width) - lensWidth - 90,
                                                                                                  y: CGFloat(base.height) - lensHeight - 70,
                                                                                                  width: lensWidth, height: lensHeight), round: false),
                                               style: AnnotationStyle.standard(color: .blue, scale: 2)))
        let editor = app.coordinator.openEditor(with: document)
        try await Task.sleep(for: .milliseconds(800))
        guard let editorWindow = editor.window else { return fail("no editor") }
        try save(try await capture(editorWindow), "editor")

        // Backdrop and frame, with its panel.
        editor.toggleBackdropPanel(nil)
        var backdrop = Backdrop(fill: Backdrop.presets[1], padding: 56, cornerRadius: 12, shadow: 0.6)
        backdrop.aspect = .auto
        editor.model.updateBackdrop(backdrop)
        try await Task.sleep(for: .milliseconds(800))
        try save(try await capture(editorWindow), "backdrop")
        if let framed = editor.model.flattened() { try save(framed, "framed") }

        // The gallery with a few captures.
        for (index, image) in [shots[.capture]!, shots[.agents]!, shots[.export]!, base].enumerated() {
            var item = CaptureDocument(image: image, scale: 2, createdAt: Date(timeIntervalSinceNow: Double(index - 5) * 600))
            if index == 3 { item = editor.model.document }
            _ = LibraryStore.shared.add(item)
        }
        editor.close()
        app.showGallery()
        app.gallery?.window?.setContentSize(NSSize(width: 900, height: 290))
        try await Task.sleep(for: .milliseconds(900))
        if let gallery = app.gallery?.window { try save(try await capture(gallery), "gallery"); gallery.close() }
    }
}
