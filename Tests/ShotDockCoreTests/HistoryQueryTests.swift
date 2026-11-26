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
    let oval = try AnnotationCoding.annotation(from: ["type": "oval", "rect": ["x": 10, "y": 10, "width": 40, "height": 30]], for: document,
                                               view: DocumentView(origin: .zero, factor: 0.5))
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

@Test func viewCoordinatesFollowCropBackdropAndResize() throws {
    var document = CaptureDocument(image: whiteImage(1000, 800), scale: 2)
    document.crop = CGRect(x: 100, y: 50, width: 600, height: 400)
    document.resize = 0.5
    let view = DocumentView(document)
    #expect(view.origin == CGPoint(x: 100, y: 50) && view.factor == 0.5)
    #expect(view.toView(CGPoint(x: 300, y: 250)) == CGPoint(x: 100, y: 100))
    #expect(view.toDocument(CGRect(x: 10, y: 10, width: 50, height: 20)) == CGRect(x: 120, y: 70, width: 100, height: 40))
    #expect(document.outputSize == CGSize(width: 300, height: 200) && document.exportScale == 1)
    #expect(document.flattened()?.width == 300)
    // With a backdrop the view starts at the margin.
    document.resize = nil
    document.backdrop = Backdrop(padding: 20)
    #expect(DocumentView(document).origin == CGPoint(x: 60, y: 10))
    #expect(document.resizeFactor(width: 340, height: nil) == 0.5)

    let arrow = Annotation(shape: .arrow(from: CGPoint(x: 200, y: 100), to: CGPoint(x: 300, y: 300)), style: AnnotationStyle(lineWidth: 6))
    let json = AnnotationCoding.json(arrow, view: DocumentView(origin: CGPoint(x: 100, y: 50), factor: 0.5))
    #expect(json["from"]?.point == CGPoint(x: 50, y: 25) && json["line_width"] == 3)
}

@Test func marksArePlacedOnFoundText() {
    let box = CGRect(x: 300, y: 200, width: 100, height: 20)
    let size = CGSize(width: 1000, height: 800)
    let rect = AnnotationCoding.placing(["type": "rectangle", "on_text": "OK"], on: box, imageSize: size, scale: 2)
    #expect(rect["rect"]?.rect == CGRect(x: 292, y: 192, width: 116, height: 36) && rect["on_text"] == nil)
    let arrow = AnnotationCoding.placing(["type": "arrow"], on: box, imageSize: size, scale: 2)
    #expect(arrow["to"]?.point == CGPoint(x: 284, y: 210) && arrow["from"]?.point == CGPoint(x: 164, y: 130))
    // No room on the left: from the right.
    let edge = AnnotationCoding.placing(["type": "arrow"], on: CGRect(x: 20, y: 200, width: 50, height: 20), imageSize: size, scale: 2)
    #expect((edge["to"]?.point?.x ?? 0) > 70)
    // Given positions are kept.
    let kept = AnnotationCoding.placing(["type": "arrow", "from": ["x": 1, "y": 2]], on: box, imageSize: size, scale: 2)
    #expect(kept["from"]?.point == CGPoint(x: 1, y: 2))
    let text = AnnotationCoding.placing(["type": "text", "text": "aquí"], on: box, imageSize: size, scale: 2)
    #expect(text["at"]?.point == CGPoint(x: 300, y: 236))
    let scaled = AnnotationCoding.scaled(["type": "rectangle", "rect": ["x": 10, "y": 10, "width": 20, "height": 20], "line_width": 2], by: 2)
    #expect(scaled["rect"]?.rect == CGRect(x: 20, y: 20, width: 40, height: 40) && scaled["line_width"] == 4)
}

@Test func exportProfilesFitAndEncode() throws {
    let web = ExportProfile(name: "Web", format: .webp, maxWidth: 1600)
    #expect(web.fitting(CGSize(width: 3200, height: 1000)) == 0.5)
    #expect(web.fitting(CGSize(width: 800, height: 1000)) == 1)
    #expect(ExportProfile(name: "x", format: .png, maxWidth: 1000, maxHeight: 200).fitting(CGSize(width: 2000, height: 800)) == 0.25)
    let encoded = try ImageEncoding.encode(whiteImage(3200, 400), scale: 2, profile: web)
    #expect(encoded.format == .webp && encoded.width == 1600 && encoded.height == 200 && encoded.scale == 1)
    #expect(encoded.data.prefix(4) == Data("RIFF".utf8))
    let jpeg = try ImageEncoding.encode(whiteImage(), scale: 2, profile: web.overriding(format: .jpeg, quality: 0.5, maxWidth: 0))
    #expect(jpeg.format == .jpeg && jpeg.width == 400 && jpeg.data.prefix(2) == Data([0xFF, 0xD8]))
    #expect(ExportProfile(name: "L", format: .jpeg, quality: 0.7, maxWidth: 1280).summary == "JPEG 70 % · up to 1280 px wide")
    #expect(ImageFormat(fileExtension: "JPG") == .jpeg && ImageFormat(fileExtension: "webp") == .webp && ImageFormat(fileExtension: "gif") == nil)
    #expect(ImageFormat.available.contains(.webp) && ImageFormat.available.contains(.heic))
    let profiles = ExportProfile.defaults()
    let coded = try JSONDecoder().decode([ExportProfile].self, from: JSONEncoder().encode(profiles))
    #expect(coded == profiles && profiles.map(\.format) == [.png, .webp, .png, .jpeg])
}
