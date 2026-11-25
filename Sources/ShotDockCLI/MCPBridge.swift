import Foundation
import ShotDockCore

/// `shotdock mcp`: the MCP server on stdio, forwarding tool calls to the
/// app. The app is only started (and asked for permission) on the first
/// tool call, so registering the server does not open it.
final class MCPBridge {
    private var client: ControlClient?

    func run() {
        let server = MCPServer(version: AppConnection.version) { [self] spec, params in try forward(spec, params) }
        server.runStdio()
    }

    private func forward(_ spec: CommandSpec, _ params: [String: JSONValue]) throws -> JSONValue {
        let delay = params["delay"]?.doubleValue ?? 0
        let timeout = spec.waitsForUser(params) ? nil : defaultTimeout + delay
        do {
            if client == nil { client = try AppConnection.connect() }
            return try client!.call(spec.name, params: .object(params), timeout: timeout)
        } catch let error as RPCError {
            throw error
        } catch {
            // Reconnect on the next call (the app may have been restarted).
            client = nil
            throw RPCError(code: RPCError.internalErrorCode, message: "ShotDock is not available: \(error.localizedDescription)")
        }
    }
}
