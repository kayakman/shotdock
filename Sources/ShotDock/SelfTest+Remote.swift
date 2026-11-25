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
