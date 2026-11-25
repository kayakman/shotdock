import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ShotDockCore

private func textImage(_ lines: [String]) -> CGImage {
    let w = 900, h = 70 * lines.count + 40
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    context.flipVertically(height: CGFloat(h))
    for (i, line) in lines.enumerated() {
        TextLayout(string: line, fontSize: 40, color: CGColor(gray: 0, alpha: 1)).draw(at: CGPoint(x: 30, y: 20 + i * 70), in: context)
    }
    return context.makeImage()!
}

@Test func recognizesLinesInOrder() async throws {
    let result = try await TextRecognition.recognize(textImage(["Capturas de pantalla", "con ShotDock 2026"]))
    #expect(result.lines.count == 2)
    #expect(result.lines.first?.contains("Capturas") == true)
    #expect(result.text().contains("ShotDock 2026"))
    #expect(result.text(joinLines: true) == result.lines.joined(separator: " "))
}

@Test func readsQRCode() async throws {
    let payload = "https://github.com/kayakman/shotdock"
    let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(payload.utf8), "inputCorrectionLevel": "M"])!
    let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    // A white margin around the code, as on a real screen.
    let framed = qr.composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -40, dy: -40)))
    let image = CIContext().createCGImage(framed, from: framed.extent)!
    let result = try await TextRecognition.recognize(image)
    #expect(result.codes == [payload])
}

/// Vision skips text next to a large QR code unless the code is masked out.
@Test func readsTextBesideALargeQRCode() async throws {
    let size = 1400
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.flipVertically(height: CGFloat(size))
    TextLayout(string: "Hola desde ShotDock", fontSize: 56, color: CGColor(gray: 0, alpha: 1)).draw(at: CGPoint(x: 200, y: 200), in: context)
    let payload = "https://github.com/kayakman/shotdock"
    let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(payload.utf8)])!.outputImage!
        .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let qrImage = CIContext().createCGImage(qr, from: qr.extent)!
    context.drawImageTopLeft(qrImage, in: CGRect(x: 200, y: 600, width: CGFloat(qrImage.width), height: CGFloat(qrImage.height)))
    let result = try await TextRecognition.recognize(context.makeImage()!)
    #expect(result.lines == ["Hola desde ShotDock"])
    #expect(result.codes == [payload])
}
