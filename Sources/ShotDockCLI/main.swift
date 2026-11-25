import Foundation
import ShotDockCore

/// `shotdock`: ShotDock from the command line. Every command is sent to the
/// app; see CommandCatalog for the list.
enum ExitCode {
    static let ok: Int32 = 0
    /// The command ran and failed (not found, cancelled, no permission…).
    static let failed: Int32 = 1
    static let usage: Int32 = 2
    /// ShotDock could not be reached or started.
    static let unavailable: Int32 = 3
}

/// Seconds to wait for an answer unless `--timeout` says otherwise.
let defaultTimeout: TimeInterval = 120

func printError(_ message: String, kind: String, code: Int?, json: Bool) {
    if json {
        var error: [String: JSONValue] = ["kind": .string(kind), "message": .string(message)]
        if let code { error["code"] = .number(Double(code)) }
        print(JSONValue.object(["error": .object(error)]).jsonString(pretty: true))
    } else {
        FileHandle.standardError.write(Data("shotdock: \(message)\n".utf8))
    }
}

func run(_ arguments: [String]) -> Int32 {
    let wantsJSON = arguments.contains("--json")
    let request: CLIRequest
    do {
        request = try CLIParser().parse(arguments)
    } catch let error as CLIError {
        printError(error.message, kind: "usage", code: nil, json: wantsJSON)
        if let usage = error.usage, !wantsJSON { FileHandle.standardError.write(Data("\n\(usage)\n".utf8)) }
        return ExitCode.usage
    } catch {
        printError(error.localizedDescription, kind: "usage", code: nil, json: wantsJSON)
        return ExitCode.usage
    }

    switch request {
    case let .help(text):
        print(text)
        return ExitCode.ok
    case .version:
        print("shotdock \(AppConnection.version)")
        return ExitCode.ok
    case let .run(invocation):
        if invocation.command.exposure == .local { return runLocal(invocation) }
        var invocation = invocation
        if invocation.command.name == "s3.credentials", invocation.params["clear"]?.boolValue != true {
            // Asked for on the terminal so the secret stays out of the shell history.
            if invocation.params["access_key_id"] == nil, let id = prompt("Access key id: ", secret: false) {
                invocation.params["access_key_id"] = .string(id)
            }
            if invocation.params["secret_access_key"] == nil, let secret = prompt("Secret access key: ", secret: true) {
                invocation.params["secret_access_key"] = .string(secret)
            }
        }
        let client: ControlClient
        do {
            client = try AppConnection.connect()
        } catch {
            printError(error.localizedDescription, kind: "unavailable", code: nil, json: invocation.json)
            return ExitCode.unavailable
        }
        do {
            // Interactive calls wait for the user as long as it takes.
            let delay = invocation.params["delay"]?.doubleValue ?? 0
            let timeout = invocation.timeout ?? (invocation.command.waitsForUser(invocation.params) ? nil : defaultTimeout + delay)
            let result = try client.call(invocation.command.name, params: .object(invocation.params), timeout: timeout)
            print(invocation.json ? result.jsonString(pretty: true) : TextRendering.render(result))
            return ExitCode.ok
        } catch let error as RPCError {
            printError(error.message, kind: error.kind, code: error.code, json: invocation.json)
            return ExitCode.failed
        } catch {
            printError(error.localizedDescription, kind: "unavailable", code: nil, json: invocation.json)
            return ExitCode.unavailable
        }
    }
}

/// Reads a line from the terminal (without echo for secrets), or from stdin when piped.
func prompt(_ label: String, secret: Bool) -> String? {
    if isatty(STDIN_FILENO) == 0 { return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) }
    if secret {
        var buffer = [CChar](repeating: 0, count: 512)
        guard let line = readpassphrase(label, &buffer, buffer.count, 0) else { return nil }
        return String(cString: line)
    }
    FileHandle.standardError.write(Data(label.utf8))
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Commands the binary answers itself.
func runLocal(_ invocation: CLIInvocation) -> Int32 {
    switch invocation.command.name {
    case "schema":
        print(CommandCatalog.schema().jsonString(pretty: true))
        return ExitCode.ok
    case "mcp":
        MCPBridge().run()
        return ExitCode.ok
    default:
        printError("\(invocation.command.name) is not available", kind: "unknown_command", code: nil, json: invocation.json)
        return ExitCode.usage
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())))
