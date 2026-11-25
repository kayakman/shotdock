import Foundation
import Testing
@testable import ShotDockCore

/// Runs against scripts/mock-s3.py (an independent SigV4 implementation):
///   MOCK_S3_URL=http://127.0.0.1:9555 swift test --filter S3Integration
private let mockURL = ProcessInfo.processInfo.environment["MOCK_S3_URL"]

private func client(secret: String = "testsecret", linkMode: S3Configuration.LinkMode = .presigned) -> S3Client {
    var config = S3Configuration()
    config.provider = .minio
    config.endpoint = mockURL ?? ""
    config.region = "eu-west-1"
    config.bucket = "capturas"
    config.prefix = "shotdock/"
    config.pathStyle = true
    config.linkMode = linkMode
    config.presignExpiry = 600
    return S3Client(configuration: config, credentials: S3Credentials(accessKeyID: "test", secretAccessKey: secret))
}

@Test(.enabled(if: mockURL != nil)) func uploadDownloadDelete() async throws {
    let s3 = client()
    let key = s3.configuration.key(for: "prueba ñandú+1.png")
    let data = Data((0..<5000).map { UInt8($0 % 251) })
    try await s3.putObject(key: key, data: data, contentType: "image/png")

    let link = try #require(s3.link(for: key))
    let (downloaded, response) = try await URLSession.shared.data(from: link)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(downloaded == data)

    try await s3.deleteObject(key: key)
    let (_, gone) = try await URLSession.shared.data(from: try #require(s3.link(for: key)))
    #expect((gone as? HTTPURLResponse)?.statusCode == 404)
}

@Test(.enabled(if: mockURL != nil)) func wrongSecretIsRejected() async throws {
    await #expect {
        try await client(secret: "wrong").putObject(key: "x.png", data: Data([1, 2, 3]), contentType: "image/png")
    } throws: { error in
        if case let S3Error.http(status, code, _) = error { return status == 403 && code == "SignatureDoesNotMatch" }
        return false
    }
}
