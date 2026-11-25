import Foundation

/// JSON-RPC 2.0, spoken over the control socket (CLI ↔ app) and on stdio (MCP).

public enum RPCID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) { self = .number(number) } else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(number): try container.encode(number)
        case let .string(string): try container.encode(string)
        }
    }
}

/// A call, or a notification when `id` is nil.
public struct RPCRequest: Codable, Equatable, Sendable {
    public var jsonrpc = "2.0"
    public var id: RPCID?
    public var method: String
    public var params: JSONValue?

    public init(id: RPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }
}

public struct RPCError: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    // Standard codes.
    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let internalErrorCode = -32603

    // ShotDock's own codes.
    /// The app has no Screen Recording (or Accessibility) permission.
    public static let permissionDeniedCode = -32000
    /// Agent control is off in the preferences, or the user said no.
    public static let notAuthorizedCode = -32001
    /// No such capture, window, display or pin.
    public static let notFoundCode = -32002
    /// The user cancelled an interactive step.
    public static let cancelledCode = -32003
    /// Something must be set up first (S3, …).
    public static let notConfiguredCode = -32004
    /// Another capture is in progress.
    public static let busyCode = -32005

    public static func invalidParams(_ message: String) -> RPCError { RPCError(code: invalidParamsCode, message: message) }
    public static func methodNotFound(_ method: String) -> RPCError { RPCError(code: methodNotFoundCode, message: "Unknown method: \(method)") }
    public static func notFound(_ message: String) -> RPCError { RPCError(code: notFoundCode, message: message) }
    public static func internalError(_ message: String) -> RPCError { RPCError(code: internalErrorCode, message: message) }

    /// A short name for scripts (`"error": {"kind": "not_found", …}` in `--json` output).
    public var kind: String {
        switch code {
        case Self.parseErrorCode: "parse_error"
        case Self.invalidRequestCode: "invalid_request"
        case Self.methodNotFoundCode: "unknown_command"
        case Self.invalidParamsCode: "invalid_params"
        case Self.permissionDeniedCode: "permission_denied"
        case Self.notAuthorizedCode: "not_authorized"
        case Self.notFoundCode: "not_found"
        case Self.cancelledCode: "cancelled"
        case Self.notConfiguredCode: "not_configured"
        case Self.busyCode: "busy"
        default: "internal_error"
        }
    }
}

public struct RPCResponse: Codable, Equatable, Sendable {
    public var jsonrpc = "2.0"
    /// Null when the request could not be read.
    public var id: RPCID?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: RPCID?, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: RPCID?, error: RPCError) {
        self.id = id
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        // A response always carries its id, null included.
        if let id { try container.encode(id, forKey: .id) } else { try container.encodeNil(forKey: .id) }
        if let error { try container.encode(error, forKey: .error) } else { try container.encode(result ?? .null, forKey: .result) }
    }
}
