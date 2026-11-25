import AppKit
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
            run = try await shotdock(["windows", "--json"])
            let windows = run.json?["windows"]?.arrayValue ?? []
            check(run.status == 0, "windows listed (\(windows.count))")
            check(windows.allSatisfy { $0["id"]?.intValue != nil && $0["frame"]?.rect != nil }, "windows have ids and frames")
            check(!windows.contains { $0["pid"]?.intValue == Int(ProcessInfo.processInfo.processIdentifier) }, "ShotDock's own windows left out")
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
        check(json["path"]?.stringValue == out && (try? Data(contentsOf: URL(fileURLWithPath: out)).prefix(2)) == Data([0xFF, 0xD8]),
              "--out writes a JPEG where asked")
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
        let box = newID.flatMap { LibraryStore.shared.document($0)?.annotations.first?.box } ?? .zero
        let scale = ImagePreview.scale(for: CGSize(width: 3000, height: 1500))
        check(run.status == 0 && newID != id && abs(box.width - 200 / scale) < 1, "a file becomes a capture; preview positions are scaled (\(box))")
    }
}
