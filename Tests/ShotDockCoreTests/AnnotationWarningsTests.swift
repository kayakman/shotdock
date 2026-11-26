import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

private func blankDocument(width: Int = 400, height: Int = 200) -> CaptureDocument {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return CaptureDocument(image: context.makeImage()!, scale: 2)
}

private func warnings(_ marks: [Annotation], on document: CaptureDocument, text: [RecognizedLine] = []) -> [String] {
    var document = document
    document.annotations += marks
    return AnnotationWarnings.check(marks, in: document, capturedText: text)
}

@Test func marksPastTheEdgeAreReported() {
    let document = blankDocument()
    // fontSize 38: radius 26.6, so 4 px above the top.
    let step = Annotation(shape: .step(center: CGPoint(x: 60, y: 23), number: 4), style: AnnotationStyle(fontSize: 38))
    let found = warnings([step], on: document)
    #expect(found.count == 1)
    #expect(found.first?.contains("step 4") == true && found.first?.contains("top by 4 px") == true)

    // An arrow whose tail is near the edge: only its head is wide.
    let arrow = Annotation(shape: .arrow(from: CGPoint(x: 396, y: 100), to: CGPoint(x: 300, y: 100)), style: AnnotationStyle(lineWidth: 6))
    #expect(warnings([arrow], on: document).isEmpty)
    let text = Annotation(shape: .text(origin: CGPoint(x: 300, y: 80), string: "Quitar permiso"), style: AnnotationStyle(fontSize: 22))
    #expect(warnings([text], on: document).first?.contains("right by") == true)
}

@Test func theCropIsTheEdge() {
    var document = blankDocument()
    document.crop = CGRect(x: 0, y: 0, width: 200, height: 200)
    let box = Annotation(shape: .rectangle(CGRect(x: 150, y: 50, width: 100, height: 50)), style: AnnotationStyle(lineWidth: 6))
    #expect(warnings([box], on: document).first?.contains("right by 53 px") == true)
}

@Test func labelsOverOtherMarks() {
    let document = blankDocument()
    let style = AnnotationStyle(lineWidth: 6, fontSize: 22)
    let box = Annotation(shape: .rectangle(CGRect(x: 200, y: 20, width: 120, height: 50)), style: style)
    let shaft = Annotation(shape: .arrow(from: CGPoint(x: 20, y: 150), to: CGPoint(x: 380, y: 150)), style: style)
    let onLine = Annotation(shape: .text(origin: CGPoint(x: 120, y: 62), string: "Agente permitido"), style: style)
    let inside = Annotation(shape: .text(origin: CGPoint(x: 215, y: 28), string: "Dentro"), style: style)
    let crossing = Annotation(shape: .text(origin: CGPoint(x: 100, y: 140), string: "Encima"), style: style)
    let beside = Annotation(shape: .text(origin: CGPoint(x: 30, y: 90), string: "Al lado"), style: style)
    var document2 = document
    document2.annotations = [box, shaft]
    let found = warnings([onLine, inside, crossing, beside], on: document2)
    #expect(found.contains { $0.hasPrefix("text “Agente permitido”") && $0.contains("overlaps rectangle") })
    #expect(found.contains { $0.hasPrefix("text “Encima”") && $0.contains("overlaps arrow") })
    #expect(!found.contains { $0.contains("“Dentro”") || $0.contains("“Al lado”") })
}

@Test func labelsOverTheCapturedText() {
    let document = blankDocument()
    let retirar = RecognizedLine(text: "Retirar", box: CGRect(x: 300, y: 30, width: 70, height: 24), confidence: 1)
    let style = AnnotationStyle(fontSize: 22)
    let over = Annotation(shape: .text(origin: CGPoint(x: 250, y: 32), string: "Permitido"), style: style)
    let clear = Annotation(shape: .text(origin: CGPoint(x: 20, y: 120), string: "Permitido"), style: style)
    // Boxes are not labels: highlighting text is what they are for.
    let highlight = Annotation(shape: .highlight(CGRect(x: 290, y: 25, width: 90, height: 34)), style: style)
    let found = warnings([over, clear, highlight], on: document, text: [retirar])
    #expect(found.count == 1)
    #expect(found.first?.contains("covers text of the capture: “Retirar”") == true)
}
