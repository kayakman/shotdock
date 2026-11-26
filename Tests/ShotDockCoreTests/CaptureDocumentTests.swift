import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

private let white = makeImage(width: 200, height: 100, color: (1, 1, 1))

@Test func flattenWithoutChangesKeepsImage() throws {
    let document = CaptureDocument(image: white, scale: 2)
    let output = try #require(document.flattened())
    #expect(output.width == 200 && output.height == 100)
    #expect(isWhite(pixel(output, 10, 10)))
}

@Test func rectangleIsDrawnTopLeftOrigin() throws {
    var document = CaptureDocument(image: white, scale: 1)
    document.annotations = [Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 20)),
                                       style: AnnotationStyle(color: .red, lineWidth: 4))]
    let output = try #require(document.flattened())
    #expect(isReddish(pixel(output, 35, 10)))   // top edge
    #expect(isReddish(pixel(output, 35, 30)))   // bottom edge
    #expect(isWhite(pixel(output, 35, 20)))     // inside stays clear
    #expect(isWhite(pixel(output, 35, 80)))     // far below
}

@Test func arrowPaintsShaftAndHead() throws {
    var document = CaptureDocument(image: white, scale: 1)
    document.annotations = [Annotation(shape: .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 190, y: 50)),
                                       style: AnnotationStyle(color: .red, lineWidth: 6))]
    let output = try #require(document.flattened())
    #expect(isReddish(pixel(output, 60, 50)))
    #expect(isReddish(pixel(output, 182, 50)))
    #expect(isReddish(pixel(output, 172, 56)))   // wider than the shaft: the head
    #expect(isWhite(pixel(output, 60, 60)))
}

@Test func cropAppliesAfterAnnotations() throws {
    var document = CaptureDocument(image: white, scale: 1)
    document.annotations = [Annotation(shape: .rectangle(CGRect(x: 100, y: 40, width: 40, height: 40)),
                                       style: AnnotationStyle(color: .red, lineWidth: 4))]
    document.crop = CGRect(x: 90, y: 30, width: 60.4, height: 60)
    let output = try #require(document.flattened())
    #expect(output.width == 61 && output.height == 60)
    #expect(isReddish(pixel(output, 10, 30)))   // left edge of the rectangle at x = 100
}

@Test func textHasBoundsAndInk() throws {
    var document = CaptureDocument(image: white, scale: 1)
    let text = Annotation(shape: .text(origin: CGPoint(x: 10, y: 10), string: "Hola"),
                          style: AnnotationStyle(color: .black, fontSize: 40))
    document.annotations = [text]
    #expect(text.bounds.width > 60 && text.bounds.height >= 40)
    let output = try #require(document.flattened())
    var dark = 0
    for x in stride(from: 10, to: Int(text.bounds.maxX), by: 2) {
        for y in stride(from: 10, to: Int(text.bounds.maxY), by: 2) where pixel(output, x, y).r < 80 { dark += 1 }
    }
    #expect(dark > 20)
    #expect(isWhite(pixel(output, 150, 90)))
}

@Test func hitTesting() {
    let rect = Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)), style: AnnotationStyle())
    #expect(rect.hitTest(CGPoint(x: 50, y: 1)))
    #expect(!rect.hitTest(CGPoint(x: 50, y: 50)))
    let arrow = Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 100, y: 100)), style: AnnotationStyle())
    #expect(arrow.hitTest(CGPoint(x: 52, y: 48)))
    #expect(!arrow.hitTest(CGPoint(x: 90, y: 10)))
    let moved = arrow.offsetBy(dx: 10, dy: 5)
    #expect(moved.shape == .arrow(from: CGPoint(x: 10, y: 5), to: CGPoint(x: 110, y: 105)))
}

@Test func defaultNameFormat() {
    let date = Date(timeIntervalSince1970: 1_764_064_720)  // 2025-11-25 09:58:40 UTC
    #expect(CaptureNaming.defaultName(for: date, timeZone: TimeZone(identifier: "UTC")!)
            == "ShotDock 2025-11-25 at 09.58.40")
}
