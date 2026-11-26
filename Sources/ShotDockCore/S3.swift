import CryptoKit
import Foundation

/// Where uploads go. Any S3-compatible service works: AWS S3, Cloudflare
/// R2, Backblaze B2, MinIO…; the provider only fills in sensible defaults.
public struct S3Configuration: Codable, Equatable, Sendable {
    public enum Provider: String, CaseIterable, Codable, Sendable {
        case aws, r2, b2, minio, custom

        public var title: String {
            switch self {
            case .aws: "Amazon S3"
            case .r2: "Cloudflare R2"
            case .b2: "Backblaze B2"
            case .minio: "MinIO"
            case .custom: String(localized: "Other (S3-compatible)")
            }
        }

        /// Endpoint for a region; R2 needs the account id in place of `<cuenta>`.
        public func defaultEndpoint(region: String) -> String {
            switch self {
            case .aws: "https://s3.\(region).amazonaws.com"
            case .r2: "https://<cuenta>.r2.cloudflarestorage.com"
            case .b2: "https://s3.\(region).backblazeb2.com"
            case .minio: "http://localhost:9000"
            case .custom: ""
            }
        }

        public var defaultRegion: String {
            switch self {
            case .aws: "eu-west-1"
            case .r2: "auto"
            case .b2: "eu-central-003"
            case .minio, .custom: "us-east-1"
            }
        }

        /// R2 and MinIO address buckets in the path, not in the host name.
        public var usesPathStyle: Bool { self == .r2 || self == .minio || self == .custom }
    }

    public enum LinkMode: String, CaseIterable, Codable, Sendable {
        /// Public base URL (CDN, custom domain or public bucket) + key.
        case publicURL
        /// Signed, expiring link to a private bucket.
        case presigned
    }

    public var provider: Provider = .aws
    public var endpoint: String = Provider.aws.defaultEndpoint(region: Provider.aws.defaultRegion)
    public var region: String = Provider.aws.defaultRegion
    public var bucket: String = ""
    /// Folder inside the bucket, e.g. "capturas/".
    public var prefix: String = ""
    public var pathStyle: Bool = false
    public var linkMode: LinkMode = .publicURL
    /// Base for public links, e.g. "https://cdn.example.com/". Empty: the bucket URL.
    public var publicBaseURL: String = ""
    /// Lifetime of presigned links, in seconds (S3 allows up to 7 days).
    public var presignExpiry: Int = 7 * 24 * 3600
    /// Sends `x-amz-acl: public-read` (AWS buckets with ACLs; R2 does not support it).
    public var publicReadACL: Bool = false

    public init() {}

    /// Changes the service, with its usual region, endpoint and addressing.
    public mutating func switchProvider(to provider: Provider) {
        self.provider = provider
        region = provider.defaultRegion
        endpoint = provider.defaultEndpoint(region: region)
        pathStyle = provider.usesPathStyle
        if provider == .r2 { publicReadACL = false }  // R2 has no ACLs
    }

    public var isComplete: Bool { !bucket.isEmpty && URL(string: endpoint)?.host != nil && !region.isEmpty }

    /// Object key for an upload: prefix + name.
    public func key(for name: String) -> String {
        var folder = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !folder.isEmpty { folder += "/" }
        return folder + name
    }

    /// The object's address on the S3 endpoint.
    public func objectURL(key: String) -> URL? {
        guard var components = URLComponents(string: endpoint), let host = components.host else { return nil }
        let encodedKey = S3Signer.encodePath(key)
        if pathStyle {
            let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
            components.percentEncodedPath = base + "/" + S3Signer.encodePath(bucket) + "/" + encodedKey
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/" + encodedKey
        }
        return components.url
    }

    /// The link to share for a public object.
    public func publicLink(key: String) -> URL? {
        let base = publicBaseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return objectURL(key: key) }
        return URL(string: (base.hasSuffix("/") ? base : base + "/") + S3Signer.encodePath(key))
    }
}

public struct S3Credentials: Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// AWS Signature Version 4 for S3, in headers or as a presigned URL.
public struct S3Signer: Sendable {
    public let credentials: S3Credentials
    public let region: String
    public let service = "s3"

    public init(credentials: S3Credentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    public static let emptyPayloadHash = sha256Hex(Data())
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// Adds `x-amz-date`, `x-amz-content-sha256` and `Authorization`.
    public func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
        let (amzDate, day) = Self.timestamps(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        guard let url = request.url, let host = url.host else { return }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["host"] = Self.hostHeader(url, host: host)
        let (canonicalHeaders, signedHeaders) = Self.canonicalHeaders(headers)
        let canonical = [request.httpMethod ?? "GET", Self.canonicalURI(url), Self.canonicalQuery(url),
                         canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let signature = self.signature(canonicalRequest: canonical, amzDate: amzDate, day: day)
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope(day)), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// A URL anyone can GET until it expires.
    public func presignedURL(for url: URL, method: String = "GET", expires: Int, date: Date = Date()) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = url.host else { return nil }
        let (amzDate, day) = Self.timestamps(date)
        var query = components.percentEncodedQueryItems ?? []
        query += [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: Self.encode("\(credentials.accessKeyID)/\(scope(day))")),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(min(max(expires, 1), 604_800))),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]
        components.percentEncodedQueryItems = query
        guard let unsigned = components.url else { return nil }
        let canonical = [method, Self.canonicalURI(unsigned), Self.canonicalQuery(unsigned),
                         "host:\(Self.hostHeader(url, host: host))\n", "host", Self.unsignedPayload].joined(separator: "\n")
        let signature = self.signature(canonicalRequest: canonical, amzDate: amzDate, day: day)
        components.percentEncodedQueryItems = query + [URLQueryItem(name: "X-Amz-Signature", value: signature)]
        return components.url
    }

    // MARK: Pieces (internal for tests)

    func scope(_ day: String) -> String { "\(day)/\(region)/\(service)/aws4_request" }

    func signature(canonicalRequest: String, amzDate: String, day: String) -> String {
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope(day), Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)).hex
    }

    static func timestamps(_ date: Date) -> (amzDate: String, day: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }

    static func hostHeader(_ url: URL, host: String) -> String {
        guard let port = url.port, !(url.scheme == "https" && port == 443), !(url.scheme == "http" && port == 80) else { return host }
        return "\(host):\(port)"
    }

    static func canonicalHeaders(_ headers: [String: String]) -> (String, String) {
        let normalized = headers.map { (key: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")) }
            .filter { $0.key != "authorization" && $0.key != "content-length" && $0.key != "user-agent" }
            .sorted { $0.key < $1.key }
        let canonical = normalized.map { "\($0.key):\($0.value)\n" }.joined()
        return (canonical, normalized.map(\.key).joined(separator: ";"))
    }

    static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        return path.isEmpty ? "/" : path
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else { return "" }
        // Re-encode to S3's rules: decode whatever URLComponents kept, encode strictly.
        var pairs: [(name: String, value: String)] = []
        for item in items {
            let rawValue = item.value ?? ""
            pairs.append((encode(item.name.removingPercentEncoding ?? item.name), encode(rawValue.removingPercentEncoding ?? rawValue)))
        }
        pairs.sort { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 3986 encoding as SigV4 wants it (everything but unreserved characters).
    public static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// Encodes a key keeping its slashes.
    public static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    public static func sha256Hex(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

public enum S3Error: LocalizedError {
    case notConfigured
    case http(status: Int, code: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "Uploads are not set up: the bucket, the endpoint or the keys are missing.")
        case let .http(status, code, message):
            let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
            return detail.isEmpty ? String(localized: "The server answered \(status).") : String(localized: "The server answered \(status) (\(detail)).")
        }
    }
}

/// Uploads objects and builds the links to share them.
public struct S3Client: Sendable {
    public let configuration: S3Configuration
    public let credentials: S3Credentials
    private let session: URLSession

    public init(configuration: S3Configuration, credentials: S3Credentials, session: URLSession = .shared) {
        self.configuration = configuration
        self.credentials = credentials
        self.session = session
    }

    private var signer: S3Signer { S3Signer(credentials: credentials, region: configuration.region) }

    public func putObject(key: String, data: Data, contentType: String) async throws {
        guard configuration.isComplete, let url = configuration.objectURL(key: key) else { throw S3Error.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if configuration.publicReadACL { request.setValue("public-read", forHTTPHeaderField: "x-amz-acl") }
        signer.sign(&request, payloadHash: S3Signer.sha256Hex(data))
        let (body, response) = try await session.upload(for: request, from: data)
        try Self.check(response, body)
    }

    public func deleteObject(key: String) async throws {
        guard configuration.isComplete, let url = configuration.objectURL(key: key) else { throw S3Error.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash)
        let (body, response) = try await session.data(for: request)
        try Self.check(response, body)
    }

    /// The link to copy after uploading `key`.
    public func link(for key: String, date: Date = Date()) -> URL? {
        switch configuration.linkMode {
        case .publicURL: configuration.publicLink(key: key)
        case .presigned: configuration.objectURL(key: key).flatMap {
            signer.presignedURL(for: $0, expires: configuration.presignExpiry, date: date)
        }
        }
    }

    static func check(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let xml = String(decoding: body, as: UTF8.self)
            func tag(_ name: String) -> String? {
                guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
                return String(xml[start.upperBound..<end.lowerBound])
            }
            throw S3Error.http(status: http.statusCode, code: tag("Code"), message: tag("Message"))
        }
    }
}

/// Names for uploaded files: readable, URL-safe and hard to guess.
public enum UploadNaming {
    public static func objectName(base: String, format: ImageFormat, random: String = randomToken()) -> String {
        let folded = base.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        let slug = folded.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return (slug.isEmpty ? String(localized: "capture") : slug) + "-" + random + "." + format.fileExtension
    }

    public static func randomToken(length: Int = 8) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
