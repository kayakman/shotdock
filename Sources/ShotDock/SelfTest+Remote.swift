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
