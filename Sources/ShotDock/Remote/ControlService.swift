import AppKit
import ShotDockCore

/// What a command handler knows about the call.
struct RemoteContext {
    let client: AgentClient
    let peer: ControlServer.Peer
}

typealias RemoteHandler = @MainActor ([String: JSONValue], RemoteContext) async throws -> JSONValue

/// Serves the control socket: checks that agents may drive the app, then
/// runs the command's handler. Requests come from `shotdock`, the CLI and
/// MCP server in the bundle; the work happens here, under the app's own
/// Screen Recording permission.
@MainActor
final class ControlService {
    static let shared = ControlService()

    private var server: ControlServer?
    var handlers: [String: RemoteHandler] = RemoteHandlers.all
    /// Asks the user whether a new agent may drive the app. Selftests answer it themselves.
    var approve: (AgentClient) async -> Bool = AgentApproval.ask
    /// Keyed by pid and start time, so a reused pid is a new caller.
    private var clients: [String: AgentClient] = [:]
    private var denied: Set<String> = []
    private var pendingApprovals: [String: Task<Bool, Never>] = [:]
    private var lastDisabledHint: Date?

    var socketPath: String? { server?.path }

    func start(path: String = ControlSocket.defaultPath) {
        stop()
        let server = ControlServer(path: path) { [weak self] request, peer, reply in
            Task { @MainActor in
                guard let self else { return }
                reply(await self.handle(request, peer: peer))
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("ShotDock: cannot listen on \(path): \(error.localizedDescription)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func handle(_ request: RPCRequest, peer: ControlServer.Peer) async -> RPCResponse {
        do {
            guard let spec = CommandCatalog.command(request.method), spec.exposure == .app else {
                throw RPCError.methodNotFound(request.method)
            }
            let params = try spec.validate(request.params)
            let client = client(for: peer.pid)
            // status answers anyone, so `shotdock status` can explain what is missing.
            if spec.name != "status" { try await authorize(client, pid: peer.pid) }
            guard let handler = handlers[spec.name] else {
                throw RPCError(code: RPCError.methodNotFoundCode, message: "\(spec.name) is not available in this version of ShotDock")
            }
            return RPCResponse(id: request.id, result: try await handler(params, RemoteContext(client: client, peer: peer)))
        } catch {
            return RPCResponse(id: request.id, error: Self.rpcError(error))
        }
    }

    static func processKey(_ pid: pid_t) -> String { "\(pid)@\(ProcessLineage.startTime(pid) ?? 0)" }

    func client(for pid: pid_t) -> AgentClient {
        let key = Self.processKey(pid)
        if let known = clients[key] { return known }
        let client = AgentClient.identify(chain: ProcessLineage.chain(from: pid))
        if clients.count > 500 { clients = [:] }
        clients[key] = client
        return client
    }

    func isApproved(_ client: AgentClient) -> Bool {
        AppSettings.shared.approvedAgents.contains { $0.id == client.id }
    }

    // MARK: Authorization

    private func authorize(_ client: AgentClient, pid: pid_t) async throws {
        let settings = AppSettings.shared
        guard settings.agentControlEnabled else {
            if lastDisabledHint.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                lastDisabledHint = Date()
                HUD.show(String(localized: "\(client.title) wants to use ShotDock: turn it on in Preferences › Agents"), symbol: "terminal", for: .seconds(4))
            }
            throw RPCError(code: RPCError.notAuthorizedCode,
                           message: "Agent control is off. Turn it on in ShotDock › Preferences › Agents.")
        }
        if let index = settings.approvedAgents.firstIndex(where: { $0.id == client.id }) {
            // Remember when it was last used, at most once a minute.
            if settings.approvedAgents[index].lastUsed.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                settings.approvedAgents[index].lastUsed = Date()
            }
            return
        }
        let denied = RPCError(code: RPCError.notAuthorizedCode, message: "The user did not allow \(client.title) to control ShotDock.")
        let process = Self.processKey(pid)
        if self.denied.contains(process) { throw denied }
        // Several calls at once share one question.
        let question = pendingApprovals[client.id] ?? Task { await approve(client) }
        pendingApprovals[client.id] = question
        let allowed = await question.value
        pendingApprovals[client.id] = nil
        guard allowed else {
            self.denied.insert(process)
            throw denied
        }
        if !isApproved(client) {
            var approved = client
            approved.approvedAt = Date()
            approved.lastUsed = Date()
            settings.approvedAgents.append(approved)
        }
    }

    // MARK: Errors

    static func rpcError(_ error: Error) -> RPCError {
        switch error {
        case let error as RPCError: error
        case ScreenCaptureError.permissionDenied:
            RPCError(code: RPCError.permissionDeniedCode,
                     message: "ShotDock has no Screen Recording permission. Grant it in System Settings › Privacy & Security › Screen Recording.")
        case is CancellationError: RPCError(code: RPCError.cancelledCode, message: "Cancelled")
        default: RPCError.internalError(error.localizedDescription)
        }
    }
}

/// The question shown the first time an agent connects.
@MainActor
enum AgentApproval {
    static func ask(_ client: AgentClient) async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow “\(client.title)” to control ShotDock?")
        alert.informativeText = String(localized: """
            It will be able to take screenshots, edit them, read and delete the history, upload images and change \
            the preferences. You can take the permission back in Preferences › Agents.
            """)
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        alert.icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
