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
    private var clients: [pid_t: AgentClient] = [:]
    private var deniedPIDs: Set<pid_t> = []
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

    func client(for pid: pid_t) -> AgentClient {
        if let known = clients[pid] { return known }
        let client = AgentClient.identify(chain: ProcessLineage.chain(from: pid))
        clients[pid] = client
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
                HUD.show("\(client.title) quiere usar ShotDock: actívalo en Preferencias › Agentes", symbol: "terminal", for: .seconds(4))
            }
            throw RPCError(code: RPCError.notAuthorizedCode,
                           message: "Agent control is off. Turn it on in ShotDock › Preferencias › Agentes.")
        }
        if let index = settings.approvedAgents.firstIndex(where: { $0.id == client.id }) {
            // Remember when it was last used, at most once a minute.
            if settings.approvedAgents[index].lastUsed.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                settings.approvedAgents[index].lastUsed = Date()
            }
            return
        }
        let denied = RPCError(code: RPCError.notAuthorizedCode, message: "The user did not allow \(client.title) to control ShotDock.")
        if deniedPIDs.contains(pid) { throw denied }
        // Several calls at once share one question.
        let question = pendingApprovals[client.id] ?? Task { await approve(client) }
        pendingApprovals[client.id] = question
        let allowed = await question.value
        pendingApprovals[client.id] = nil
        guard allowed else {
            deniedPIDs.insert(pid)
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
        alert.messageText = "¿Permitir que «\(client.title)» controle ShotDock?"
        alert.informativeText = """
            Podrá hacer capturas de pantalla, editarlas, leer y borrar el historial, subir imágenes y cambiar \
            las preferencias. Puedes retirarle el permiso en Preferencias › Agentes.
            """
        alert.addButton(withTitle: "Permitir")
        alert.addButton(withTitle: "No permitir")
        alert.icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
