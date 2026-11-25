import CoreGraphics
import Foundation
import ImageIO

/// One capture in the history.
public struct CaptureItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var scale: CGFloat
    /// Size of the edited (cropped) image in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var annotationCount: Int
    /// Where it was last saved, if it was.
    public var savedPath: String?
}

/// The history of captures ("the dock"): every capture is kept with its
/// original pixels and its editable annotations, so it can be reopened,
/// copied or exported later. Layout on disk:
///
///     <root>/index.json
///     <root>/<id>/original.png    untouched capture
///     <root>/<id>/document.json   annotations and crop
///     <root>/<id>/thumbnail.png   ≤ 480 px preview of the edited image
public final class CaptureLibrary {
    public let root: URL
    public private(set) var items: [CaptureItem] = []
    private let fileManager = FileManager.default

    public static let thumbnailSize = 480

    public init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            items = (try? Self.decoder.decode([CaptureItem].self, from: data)) ?? []
        }
        // Drop entries whose folder disappeared.
        items.removeAll { !fileManager.fileExists(atPath: originalURL($0.id).path) }
        items.sort { $0.createdAt > $1.createdAt }
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotDock/Library", isDirectory: true)
    }

    // MARK: Paths

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    public func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func originalURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("original.png") }
    public func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumbnail.png") }
    private func documentURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("document.json") }

    public func item(_ id: UUID) -> CaptureItem? { items.first { $0.id == id } }

    // MARK: Changes

    @discardableResult
    public func add(_ document: CaptureDocument) throws -> CaptureItem {
        let id = UUID()
        try fileManager.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try ImageEncoding.write(document.image, to: originalURL(id), scale: document.scale)
        var item = CaptureItem(id: id, createdAt: document.createdAt, scale: document.scale,
                               pixelWidth: document.image.width, pixelHeight: document.image.height,
                               annotationCount: 0, savedPath: nil)
        try writeDocumentState(document, item: &item)
        items.insert(item, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        try saveIndex()
        return item
    }

    /// Stores new annotations or crop for an item and refreshes its thumbnail.
    public func update(_ id: UUID, with document: CaptureDocument) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        try writeDocumentState(document, item: &item)
        items[index] = item
        try saveIndex()
    }

    public func markSaved(_ id: UUID, at url: URL) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].savedPath = url.path
        try saveIndex()
    }

    public func delete(_ ids: Set<UUID>) throws {
        for id in ids { try? fileManager.removeItem(at: folder(id)) }
        items.removeAll { ids.contains($0.id) }
        try saveIndex()
    }

    /// Keeps the newest `count` captures; returns the removed ids.
    @discardableResult
    public func prune(keeping count: Int) throws -> Set<UUID> {
        guard count >= 0, items.count > count else { return [] }
        let removed = Set(items[count...].map(\.id))
        try delete(removed)
        return removed
    }

    // MARK: Reading

    public func document(_ id: UUID) throws -> CaptureDocument {
        guard let item = item(id) else { throw CocoaError(.fileNoSuchFile) }
        let image = try ImageEncoding.image(from: Data(contentsOf: originalURL(id)))
        var document = CaptureDocument(image: image, scale: item.scale, createdAt: item.createdAt)
        if let data = try? Data(contentsOf: documentURL(id)), let state = try? Self.decoder.decode(DocumentState.self, from: data) {
            document.annotations = state.annotations
            document.crop = state.crop
            document.backdrop = state.backdrop
        }
        return document
    }

    // MARK: Private

    private struct DocumentState: Codable {
        var annotations: [Annotation]
        var crop: CGRect?
        var backdrop: Backdrop?
    }

    private func writeDocumentState(_ document: CaptureDocument, item: inout CaptureItem) throws {
        let state = DocumentState(annotations: document.annotations, crop: document.crop, backdrop: document.backdrop)
        try Self.encoder.encode(state).write(to: documentURL(item.id), options: .atomic)
        let canvas = document.layout.canvas
        item.pixelWidth = Int(canvas.width)
        item.pixelHeight = Int(canvas.height)
        item.annotationCount = document.annotations.count
        if let flat = document.flattened(), let thumbnail = Self.thumbnail(of: flat) {
            try ImageEncoding.write(thumbnail, to: thumbnailURL(item.id))
        }
    }

    private func saveIndex() throws {
        try Self.encoder.encode(items).write(to: indexURL, options: .atomic)
    }

    static func thumbnail(of image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > thumbnailSize else { return image }
        let factor = CGFloat(thumbnailSize) / CGFloat(longest)
        let w = max(1, Int(CGFloat(image.width) * factor)), h = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
