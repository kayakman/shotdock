import Darwin
import Foundation

/// The Unix socket the app listens on and `shotdock` talks to. Only the
/// same user can connect: the file is 0600 and the server checks the peer.
public enum ControlSocket {
    /// `$SHOTDOCK_SOCKET`, or ~/Library/Application Support/ShotDock/control.sock.
    public static var defaultPath: String {
        if let path = ProcessInfo.processInfo.environment["SHOTDOCK_SOCKET"], !path.isEmpty { return path }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotDock/control.sock").path
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case pathTooLong(String)
        case system(String, Int32)
        /// Another process is already serving the socket.
        case inUse(String)

        public var errorDescription: String? {
            switch self {
            case let .pathTooLong(path): "Socket path too long: \(path)"
            case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
            case let .inUse(path): "Another ShotDock is already listening on \(path)"
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// A connected socket, or an error (ENOENT / ECONNREFUSED: nobody is listening).
    public static func connect(path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("connect", code)
        }
        return fd
    }

    /// A listening socket at `path`, replacing a stale file left by a crash.
    static func listen(path: String) throws -> Int32 {
        if FileManager.default.fileExists(atPath: path) {
            if let fd = try? connect(path: path) {
                close(fd)
                throw Failure.inUse(path)
            }
            unlink(path)
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("bind/listen", code)
        }
        return fd
    }
}

/// Serves JSON-RPC over the control socket. Reading and writing happen on a
/// private queue; `handler` gets each request and answers through `reply`
/// whenever it is done (requests of one connection may finish out of order).
public final class ControlServer: @unchecked Sendable {
    public struct Peer: Sendable, Equatable {
        public let pid: pid_t
        public let uid: uid_t
    }

    public typealias Reply = @Sendable (RPCResponse) -> Void
    public typealias Handler = @Sendable (RPCRequest, Peer, @escaping Reply) -> Void

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.shotdock.ShotDock.control")
    private var listener: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var connections: [ObjectIdentifier: Connection] = [:]

    public init(path: String = ControlSocket.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let fd = try ControlSocket.listen(path: path)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.close() }
            connections = [:]
        }
        unlink(path)
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let peer = Peer(pid: pid, uid: uid)
        let connection = Connection(fd: fd, peer: peer, queue: queue)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onRequest = { [handler] request, reply in handler(request, peer, reply) }
        connection.onClose = { [weak self] in self?.connections[key] = nil }
        connection.start()
    }

    /// One client. Everything runs on the server's queue.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let peer: Peer
        private let queue: DispatchQueue
        private var source: DispatchSourceRead?
        private var buffer = LineBuffer()
        private var closed = false
        var onRequest: ((RPCRequest, @escaping Reply) -> Void)?
        var onClose: (() -> Void)?

        init(fd: Int32, peer: Peer, queue: DispatchQueue) {
            self.fd = fd
            self.peer = peer
            self.queue = queue
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            self.source = source
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { return close() }
            do {
                for line in try buffer.append(Data(chunk[0..<count])) { receive(line) }
            } catch {
                send(RPCResponse(id: nil, error: RPCError(code: RPCError.invalidRequestCode, message: "Message too long")))
                close()
            }
        }

        private func receive(_ line: Data) {
            guard let request = try? JSONDecoder().decode(RPCRequest.self, from: line) else {
                return send(RPCResponse(id: nil, error: RPCError(code: RPCError.parseErrorCode, message: "Not a JSON-RPC request")))
            }
            let id = request.id
            onRequest?(request) { [self, queue] response in
                guard id != nil else { return }  // notifications get no answer
                queue.async { self.send(response) }
            }
        }

        private func send(_ response: RPCResponse) {
            // An answer that cannot be encoded (NaN…) still gets a reply, so the client does not wait in vain.
            let fallback = RPCResponse(id: response.id, error: .internalError("The answer could not be encoded"))
            guard !closed, let data = (try? LineFraming.frame(response)) ?? (try? LineFraming.frame(fallback)) else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            source?.cancel()
            onClose?()
        }
    }
}

/// The client side: one connection, one call at a time, blocking. Used by
/// the `shotdock` binary and its MCP server.
public final class ControlClient {
    public enum Failure: Error, LocalizedError {
        case timedOut(String)
        case disconnected

        public var errorDescription: String? {
            switch self {
            case let .timedOut(method): "ShotDock did not answer \(method) in time"
            case .disconnected: "ShotDock closed the connection"
            }
        }
    }

    private let fd: Int32
    private var buffer = LineBuffer()
    private var nextID = 1
    private var pending: [Data] = []

    public init(path: String = ControlSocket.defaultPath) throws {
        fd = try ControlSocket.connect(path: path)
    }

    deinit { close(fd) }

    /// Sends a request and waits for its result; app errors are thrown as `RPCError`.
    public func call(_ method: String, params: JSONValue? = nil, timeout: TimeInterval? = nil) throws -> JSONValue {
        let id = nextID
        nextID += 1
        let data = try LineFraming.frame(RPCRequest(id: .number(id), method: method, params: params))
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw Failure.disconnected }
                offset += written
            }
        }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            while !pending.isEmpty {
                let line = pending.removeFirst()
                guard let response = try? JSONDecoder().decode(RPCResponse.self, from: line), response.id == .number(id) else { continue }
                if let error = response.error { throw error }
                return response.result ?? .null
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = deadline.map { Int32(max(0, $0.timeIntervalSinceNow) * 1000) } ?? -1
            let ready = poll(&poller, 1, wait)
            if ready == 0 { throw Failure.timedOut(method) }
            if ready < 0 { if errno == EINTR { continue } else { throw Failure.disconnected } }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw Failure.disconnected }
            pending += try buffer.append(Data(chunk[0..<count]))
        }
    }
}
