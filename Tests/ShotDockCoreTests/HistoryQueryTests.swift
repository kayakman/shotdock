import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

private func whiteImage(_ width: Int = 400, _ height: Int = 300) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func item(_ id: String, minutesAgo: Double) -> CaptureItem {
    CaptureItem(id: UUID(uuidString: id)!, createdAt: Date().addingTimeInterval(-minutesAgo * 60), scale: 2, pixelWidth: 10, pixelHeight: 10,
                annotationCount: 0, savedPath: nil, uploadedURL: nil, recognizedText: nil)
}

@Test func referencesResolveByIdPrefixAndPosition() throws {
    let items = [item("AAAA1111-0000-0000-0000-000000000001", minutesAgo: 1),
                 item("AAAA2222-0000-0000-0000-000000000002", minutesAgo: 5),
                 item("BBBB3333-0000-0000-0000-000000000003", minutesAgo: 9)]
    #expect(try CaptureReference.resolve("last", in: items) == items[0].id)
    #expect(try CaptureReference.resolve("last-2", in: items) == items[2].id)
    #expect(try CaptureReference.resolve("bbbb", in: items) == items[2].id)
    #expect(try CaptureReference.resolve(items[1].id.uuidString.lowercased(), in: items) == items[1].id)
    #expect(throws: RPCError.self) { try CaptureReference.resolve("aaaa", in: items) }  // ambiguous
    #expect(throws: RPCError.notFound("The history has only 3 captures")) { try CaptureReference.resolve("last-3", in: items) }
    #expect(throws: RPCError.notFound("The history is empty")) { try CaptureReference.resolve("last", in: []) }
    #expect(throws: RPCError.self) { try CaptureReference.resolve("abc", in: items) }
}

@Test func relativeDatesAndISODates() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(RelativeDate.parse("30m", now: now) == now.addingTimeInterval(-1800))
    #expect(RelativeDate.parse("2h", now: now) == now.addingTimeInterval(-7200))
    #expect(RelativeDate.parse("1w", now: now) == now.addingTimeInterval(-7 * 86400))
    #expect(RelativeDate.parse("2026-11-25T10:00:00Z") == ISO8601DateFormatter().date(from: "2026-11-25T10:00:00Z"))
    #expect(RelativeDate.parse("2026-11-25") != nil)
    #expect(RelativeDate.parse("yesterday") == nil)
}

@Test func libraryFiltersBySearchAndFlags() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try CaptureLibrary(root: root)
    var invoice = CaptureDocument(image: whiteImage(), scale: 2)
    invoice.annotations = [Annotation(shape: .text(origin: .zero, string: "Factura nº 7"), style: AnnotationStyle())]
    let a = try library.add(invoice)
    let b = try library.add(CaptureDocument(image: whiteImage(), scale: 2, createdAt: Date().addingTimeInterval(-7200)))
    try library.markUploaded(b.id, link: URL(string: "https://cdn.example.com/shotdock-abc.png")!)
    try library.setRecognizedText(b.id, "Total a pagar: 120 €")

    #expect(library.items(matching: HistoryFilter(search: "factura")).map(\.id) == [a.id])
    #expect(library.items(matching: HistoryFilter(search: "a pagar")).map(\.id) == [b.id])
    #expect(library.items(matching: HistoryFilter(search: "shotdock-abc")).map(\.id) == [b.id])
    #expect(library.items(matching: HistoryFilter(uploaded: false)).map(\.id) == [a.id])
    #expect(library.items(matching: HistoryFilter(since: Date().addingTimeInterval(-3600))).map(\.id) == [a.id])
    // The recognised text survives reopening the library.
    #expect(try CaptureLibrary(root: root).item(b.id)?.recognizedText == "Total a pagar: 120 €")
}

@Test func annotationsRoundTripThroughAgentJSON() throws {
    let document = CaptureDocument(image: whiteImage(), scale: 2)
    let arrow = try AnnotationCoding.annotation(from: ["type": "arrow", "from": ["x": 10, "y": 20], "to": ["x": 200, "y": 90],
                                                       "color": "blue", "weight": "thick"], for: document)
    #expect(arrow.shape == .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 200, y: 90)))
    #expect(arrow.style == AnnotationStyle.standard(color: .blue, weight: 10, scale: 2))
    let json = AnnotationCoding.json(arrow)
    #expect(json["type"] == "arrow" && json["color"] == .string(RGBAColor.blue.hexString))
    // Colours go through #RRGGBB, so they come back rounded to 8 bits.
    let back = try AnnotationCoding.annotation(from: json, for: document)
    #expect(back.id == arrow.id && back.shape == arrow.shape && back.style.lineWidth == arrow.style.lineWidth)
    #expect(back.style.color.hexString == arrow.style.color.hexString)

    let highlight = try AnnotationCoding.annotation(from: ["type": "highlight", "rect": ["x": 0, "y": 0, "width": 50, "height": 20]], for: document)
    #expect(highlight.style.color == .yellow)
    let step = try AnnotationCoding.annotation(from: ["type": "step", "at": ["x": 30, "y": 30]], for: document, nextStep: 4)
    #expect(step.shape == .step(center: CGPoint(x: 30, y: 30), number: 4))
    // Preview coordinates are scaled to pixels.
    let oval = try AnnotationCoding.annotation(from: ["type": "oval", "rect": ["x": 10, "y": 10, "width": 40, "height": 30]], for: document, scale: 2)
    #expect(oval.box == CGRect(x: 20, y: 20, width: 80, height: 60))
    // A magnifier without a target is placed beside its source, like in the editor.
    let magnifier = try AnnotationCoding.annotation(from: ["type": "magnifier", "source": ["x": 20, "y": 100, "width": 40, "height": 30]], for: document)
    guard case let .magnifier(source, target, round) = magnifier.shape else { Issue.record("not a magnifier"); return }
    #expect(source.width == 40 && target.width == 80 && round && target.minX > source.maxX)
}

@Test func badAnnotationsAreExplained() {
    let document = CaptureDocument(image: whiteImage(), scale: 2)
    #expect(throws: RPCError.invalidParams("arrow needs to ({x, y})")) {
        try AnnotationCoding.annotation(from: ["type": "arrow", "from": ["x": 1, "y": 1]], for: document)
    }
    #expect(throws: RPCError.self) { try AnnotationCoding.annotation(from: ["type": "star"], for: document) }
    #expect(throws: RPCError.self) { try AnnotationCoding.annotation(from: ["type": "text", "at": ["x": 1, "y": 1], "text": "  "], for: document) }
    #expect(throws: RPCError.self) { try AnnotationCoding.annotation(from: ["type": "rectangle", "rect": ["x": 1, "y": 1, "width": 9, "height": 9], "color": "teal"], for: document) }
}

@Test func scaleIsReadFromTheFileResolution() throws {
    let retina = try ImageEncoding.data(from: whiteImage(), scale: 2)
    #expect(ImageEncoding.scale(of: retina) == 2)
    #expect(ImageEncoding.scale(of: try ImageEncoding.data(from: whiteImage())) == 1)
}
