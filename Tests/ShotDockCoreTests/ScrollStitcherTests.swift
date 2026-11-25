import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

/// A tall "page" with varied rows (text-like stripes and colour bands).
private func page(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.flipVertically(height: CGFloat(height))
    for y in stride(from: 0, to: height, by: 6) {
        let shade = CGFloat((y * 37) % 255) / 255
        context.setFillColor(red: shade, green: CGFloat((y * 13) % 200) / 255, blue: 1 - shade, alpha: 1)
        context.fill(CGRect(x: 0, y: y, width: width, height: 6))
        // A "word" whose length depends on the line, so rows are distinguishable.
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 10, y: y + 2, width: 20 + (y * 7) % (width - 40), height: 2))
    }
    return context.makeImage()!
}

/// The visible window of the page at `offset`, with an optional sticky header and footer.
private func frame(of page: CGImage, offset: Int, height: Int, header: Int = 0, footer: Int = 0) -> CGImage {
    let w = page.width
    let context = CGContext(data: nil, width: w, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.flipVertically(height: CGFloat(height))
    context.drawImageTopLeft(page.cropping(to: CGRect(x: 0, y: offset, width: w, height: height))!, in: CGRect(x: 0, y: 0, width: w, height: height))
    if header > 0 {
        context.setFillColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: header))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 8, y: header / 2 - 2, width: 60, height: 4))
    }
    if footer > 0 {
        context.setFillColor(red: 0.9, green: 0.9, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: height - footer, width: w, height: footer))
    }
    return context.makeImage()!
}

private func rowsEqual(_ a: CGImage, _ ay: Int, _ b: CGImage, _ by: Int) -> Bool {
    (0..<a.width).allSatisfy { x in pixel(a, x, ay) == pixel(b, x, by) } || (0..<a.width).filter { x in pixel(a, x, ay) != pixel(b, x, by) }.count < 2
}

@Test func stitchesPlainScrolling() throws {
    let tall = page(width: 120, height: 900)
    let stitcher = ScrollStitcher(width: 120, height: 200)
    for offset in [0, 70, 150, 260, 380, 500, 640, 700] {
        stitcher.add(frame(of: tall, offset: offset, height: 200))
    }
    let result = try #require(stitcher.image())
    #expect(result.height == 900)
    for y in [0, 199, 333, 640, 899] { #expect(rowsEqual(result, y, tall, y), "row \(y)") }
}

@Test func keepsStickyHeaderAndFooterOnce() throws {
    let tall = page(width: 120, height: 900)
    let stitcher = ScrollStitcher(width: 120, height: 240)
    var results: [ScrollStitcher.AddResult] = []
    for offset in [0, 90, 180, 300, 420, 540, 660] {
        results.append(stitcher.add(frame(of: tall, offset: offset, height: 240, header: 30, footer: 20)))
    }
    #expect(results.dropFirst().allSatisfy { if case .appended = $0 { true } else { false } }, "\(results)")
    let result = try #require(stitcher.image())
    // Header (30) + body rows 30…(660+220) of the page + footer (20).
    #expect(result.height == 30 + (660 + 220 - 30) + 20)
    let header = frame(of: tall, offset: 0, height: 240, header: 30, footer: 20)
    #expect(rowsEqual(result, 10, header, 10))                       // header kept
    #expect(rowsEqual(result, 30 + 500, tall, 30 + 500))             // body is the page
    #expect(rowsEqual(result, result.height - 5, header, 235))       // footer at the end
}

@Test func ignoresUnchangedAndUnrelatedFrames() {
    let tall = page(width: 120, height: 900)
    let stitcher = ScrollStitcher(width: 120, height: 200)
    #expect(stitcher.add(frame(of: tall, offset: 0, height: 200)) == .first)
    #expect(stitcher.add(frame(of: tall, offset: 0, height: 200)) == .unchanged)
    #expect(stitcher.add(makeImage(width: 120, height: 200, color: (0, 1, 0))) == .rejected)
    #expect(stitcher.add(frame(of: tall, offset: 100, height: 200)) == .appended(rows: 100))
    #expect(stitcher.add(makeImage(width: 10, height: 10)) == .rejected)
}

@Test func stopsAtMaxHeight() {
    let tall = page(width: 120, height: 900)
    let stitcher = ScrollStitcher(width: 120, height: 200, maxHeight: 350)
    for offset in [0, 100, 200, 300] { stitcher.add(frame(of: tall, offset: offset, height: 200)) }
    #expect(stitcher.currentHeight == 350 && stitcher.isFull)
}
