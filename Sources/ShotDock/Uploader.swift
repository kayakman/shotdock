import AppKit
import ShotDockCore

/// Uploads a capture with the S3 settings and copies its link.
@MainActor
enum Uploader {
    static var isConfigured: Bool {
        AppSettings.shared.s3.isComplete && Keychain.loadS3Credentials() != nil
    }

    static func client() throws -> S3Client {
        let config = AppSettings.shared.s3
        guard config.isComplete, let credentials = Keychain.loadS3Credentials() else { throw S3Error.notConfigured }
        return S3Client(configuration: config, credentials: credentials)
    }

    /// Uploads, copies the link and records it in the history. Returns the link.
    /// Agents upload `quiet`ly: no HUD, and the link is copied only if they ask.
    @discardableResult
    static func upload(_ image: CGImage, scale: CGFloat, date: Date, libraryItem: UUID?,
                       copyLink: Bool = true, quiet: Bool = false) async throws -> URL {
        let settings = AppSettings.shared
        let s3 = try client()
        let format = settings.imageFormat
        let data = try ImageEncoding.data(from: image, format: format, scale: scale)
        let base = FilenameTemplate(settings.filenameTemplate).name(for: date)
        let key = s3.configuration.key(for: UploadNaming.objectName(base: base, format: format))
        if !quiet { HUD.show(String(localized: "Uploading…"), symbol: "icloud.and.arrow.up", for: .seconds(120)) }
        do {
            try await s3.putObject(key: key, data: data, contentType: format == .png ? "image/png" : "image/jpeg")
        } catch {
            if !quiet { HUD.hide() }
            throw error
        }
        guard let link = s3.link(for: key) else {
            if !quiet { HUD.hide() }
            throw S3Error.notConfigured
        }
        if copyLink {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
        }
        if let libraryItem { LibraryStore.shared.markUploaded(libraryItem, link: link) }
        if !quiet { HUD.show(copyLink ? String(localized: "Link copied") : String(localized: "Uploaded"), symbol: "link", for: .seconds(2)) }
        return link
    }

    /// Uploads a tiny file and deletes it, to check the settings.
    static func testConnection() async throws -> String {
        let s3 = try client()
        let key = s3.configuration.key(for: "shotdock-test-\(UploadNaming.randomToken()).txt")
        try await s3.putObject(key: key, data: Data("ShotDock".utf8), contentType: "text/plain")
        try await s3.deleteObject(key: key)
        return key
    }
}
