import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("shotdock-library-\(UUID().uuidString)")
}

@Test func addReopenAndEdit() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try CaptureLibrary(root: root)
    var document = CaptureDocument(image: makeImage(width: 1200, height: 600, color: (1, 1, 1)), scale: 2)
    let item = try library.add(document)
    #expect(library.items.count == 1 && item.pixelWidth == 1200)

    // Annotations and crop survive a reload from disk.
    document.annotations = [Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 50)), style: AnnotationStyle())]
    document.crop = CGRect(x: 0, y: 0, width: 600, height: 300)
    try library.update(item.id, with: document)
    let reloaded = try CaptureLibrary(root: root)
    let reopened = try reloaded.document(item.id)
    #expect(reopened.annotations == document.annotations)
    #expect(reopened.crop == document.crop)
    #expect(reopened.scale == 2)
    #expect(reloaded.item(item.id)?.pixelWidth == 600)
    #expect(reloaded.item(item.id)?.annotationCount == 1)

    let thumbnail = try ImageEncoding.image(from: Data(contentsOf: reloaded.thumbnailURL(item.id)))
    #expect(max(thumbnail.width, thumbnail.height) == CaptureLibrary.thumbnailSize)
}

@Test func newestFirstPruneAndDelete() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try CaptureLibrary(root: root)
    var ids: [UUID] = []
    for i in 0..<5 {
        let doc = CaptureDocument(image: makeImage(width: 20, height: 20), scale: 1, createdAt: Date(timeIntervalSince1970: Double(i) * 60))
        ids.append(try library.add(doc).id)
    }
    #expect(library.items.map(\.id) == ids.reversed())
    let removed = try library.prune(keeping: 3)
    #expect(removed == Set(ids[0...1]))
    #expect(!FileManager.default.fileExists(atPath: library.folder(ids[0]).path))
    try library.delete([ids[4]])
    #expect(try CaptureLibrary(root: root).items.map(\.id) == [ids[3], ids[2]])
}
