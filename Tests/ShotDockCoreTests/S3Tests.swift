import Foundation
import Testing
@testable import ShotDockCore

/// Examples from the AWS S3 documentation ("Signature Calculations for the
/// Authorization Header" and "Query String Authentication").
private let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
private let signer = S3Signer(credentials: credentials, region: "us-east-1")
private let date = Date(timeIntervalSince1970: 1_369_353_600)  // 2013-05-24T00:00:00Z

private func signature(_ request: URLRequest) -> String? {
    request.value(forHTTPHeaderField: "Authorization")?.components(separatedBy: "Signature=").last
}

@Test func awsGetObjectExample() {
    var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
    request.httpMethod = "GET"
    request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
    signer.sign(&request, payloadHash: S3Signer.emptyPayloadHash, date: date)
    #expect(signature(request) == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date") == true)
}

@Test func awsPutObjectExample() {
    let body = Data("Welcome to Amazon S3.".utf8)
    #expect(S3Signer.sha256Hex(body) == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    var config = S3Configuration()
    config.endpoint = "https://s3.amazonaws.com"
    config.bucket = "examplebucket"
    var request = URLRequest(url: config.objectURL(key: "test$file.text")!)
    #expect(request.url?.absoluteString == "https://examplebucket.s3.amazonaws.com/test%24file.text")
    request.httpMethod = "PUT"
    request.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
    request.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")
    signer.sign(&request, payloadHash: S3Signer.sha256Hex(body), date: date)
    #expect(signature(request) == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
}

@Test func awsPresignedURLExample() throws {
    let url = try #require(signer.presignedURL(for: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, expires: 86400, date: date))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.first { $0.name == "X-Amz-Signature" }?.value == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    #expect(items.first { $0.name == "X-Amz-Credential" }?.value == "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request")
}

@Test func objectURLsAndLinks() {
    var config = S3Configuration()
    config.bucket = "capturas"
    config.region = "eu-west-1"
    config.endpoint = S3Configuration.Provider.aws.defaultEndpoint(region: "eu-west-1")
    config.prefix = "/shots/"
    let key = config.key(for: "mi captura.png")
    #expect(key == "shots/mi captura.png")
    #expect(config.objectURL(key: key)?.absoluteString == "https://capturas.s3.eu-west-1.amazonaws.com/shots/mi%20captura.png")
    config.pathStyle = true
    config.endpoint = "https://abc.r2.cloudflarestorage.com"
    #expect(config.objectURL(key: key)?.absoluteString == "https://abc.r2.cloudflarestorage.com/capturas/shots/mi%20captura.png")
    config.publicBaseURL = "https://img.example.com"
    #expect(config.publicLink(key: key)?.absoluteString == "https://img.example.com/shots/mi%20captura.png")
}

@Test func uploadNames() {
    #expect(UploadNaming.objectName(base: "ShotDock 2026-11-25 a las 10.58.40", format: .png, random: "k7x2m9qa")
            == "shotdock-2026-11-25-a-las-10-58-40-k7x2m9qa.png")
    #expect(UploadNaming.objectName(base: "Diseño ñandú", format: .jpeg, random: "r") == "diseno-nandu-r.jpg")
    #expect(UploadNaming.randomToken().count == 8)
}

@Test func errorParsing() {
    let body = Data("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>".utf8)
    let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
    #expect(throws: S3Error.self) { try S3Client.check(response, body) }
    do { try S3Client.check(response, body) } catch {
        #expect(error.localizedDescription == "The server answered 403 (AccessDenied: Access Denied).")
    }
}
