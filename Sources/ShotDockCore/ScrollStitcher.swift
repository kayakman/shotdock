import CoreGraphics
import Foundation

/// Joins frames of a scrolling area into one tall image. Each new frame is
/// matched against the previous one to find how far the content moved; rows
/// that stay put in both (sticky headers and footers) are kept once.
public final class ScrollStitcher {
    public let width: Int
    public let height: Int
    /// Stops growing past this height (pixels).
    public let maxHeight: Int

    /// Rows kept from the first frame (header), body rows, and the last frame's footer.
    private var header = 0
    private var footer = 0
    private var staticRegionsKnown = false
    private var firstFrame: Frame?
    private var lastFrame: Frame?
    /// Body rows in order, as RGBA bytes.
    private var bodyRows: [ArraySlice<UInt8>] = []

    public private(set) var frameCount = 0
    /// Frames that could not be matched (scrolled too far, or not scrolling content).
    public private(set) var rejectedCount = 0

    public init(width: Int, height: Int, maxHeight: Int = 30_000) {
        self.width = width
        self.height = height
        self.maxHeight = maxHeight
    }

    /// Height of the stitched image so far.
    public var currentHeight: Int { firstFrame == nil ? 0 : header + bodyRows.count + footer }

    public var isFull: Bool { currentHeight >= maxHeight }

    public enum AddResult: Equatable { case first, appended(rows: Int), unchanged, rejected, full }

    @discardableResult
    public func add(_ image: CGImage) -> AddResult {
        guard image.width == width, image.height == height, let frame = Frame(image) else { return .rejected }
        guard let previous = lastFrame else {
            firstFrame = frame
            lastFrame = frame
            bodyRows = (0..<height).map { frame.row($0) }
            frameCount = 1
            return .first
        }
        if isFull { return .full }

        let top = previous.matchingRows(with: frame, fromTop: true)
        if top == height { return .unchanged }
        let bottom = previous.matchingRows(with: frame, fromTop: false)

        if !staticRegionsKnown {
            // Leave a little body above and below so headers are not over-detected on short moves.
            header = min(top, height / 3)
            footer = min(bottom, height / 3)
            staticRegionsKnown = true
            bodyRows = Array(bodyRows[header..<(height - footer)])
        }
        let bodyStart = header, bodyEnd = height - footer
        guard let shift = previous.verticalShift(to: frame, rows: bodyStart..<bodyEnd), shift > 0 else {
            rejectedCount += 1
            return .rejected
        }
        let newRows = (bodyEnd - shift..<bodyEnd).map { frame.row($0) }
        let room = maxHeight - currentHeight
        bodyRows.append(contentsOf: newRows.prefix(max(room, 0)))
        lastFrame = frame
        frameCount += 1
        return .appended(rows: min(newRows.count, max(room, 0)))
    }

    /// The tall image: first frame's header, the body, last frame's footer.
    public func image() -> CGImage? {
        guard let firstFrame, let lastFrame else { return nil }
        var rows: [ArraySlice<UInt8>] = (0..<header).map { firstFrame.row($0) }
        rows += bodyRows
        rows += (height - footer..<height).map { lastFrame.row($0) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(rows.count * width * 4)
        for row in rows { bytes.append(contentsOf: row) }
        return PixelBuffer.makeImage(rgba: bytes, width: width, height: rows.count)
    }

    /// One frame's pixels plus a compact per-row signature for matching.
    struct Frame {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        /// Luminance of `columns` evenly spaced samples per row.
        let signature: [Float]
        static let columns = 48

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let ok = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard ok else { return nil }
            bytes = data
            var signature = [Float](repeating: 0, count: height * Self.columns)
            for y in 0..<height {
                for c in 0..<Self.columns {
                    let x = min(width - 1, (c * width + width / 2) / Self.columns)
                    let i = (y * width + x) * 4
                    signature[y * Self.columns + c] = 0.299 * Float(data[i]) + 0.587 * Float(data[i + 1]) + 0.114 * Float(data[i + 2])
                }
            }
            self.signature = signature
        }

        func row(_ y: Int) -> ArraySlice<UInt8> { bytes[(y * width * 4)..<((y + 1) * width * 4)] }

        /// Exact comparison of a whole row in two frames.
        func sameRow(_ y: Int, as other: Frame, row otherY: Int) -> Bool {
            row(y).elementsEqual(other.row(otherY))
        }

        /// How many rows from the top (or bottom) are identical in both frames.
        func matchingRows(with other: Frame, fromTop: Bool) -> Int {
            var count = 0
            while count < height {
                let y = fromTop ? count : height - 1 - count
                if !sameRow(y, as: other, row: y) { break }
                count += 1
            }
            return count
        }

        /// Mean absolute difference between row signatures.
        func rowDistance(_ y: Int, _ other: Frame, _ otherY: Int) -> Float {
            var sum: Float = 0
            let a = y * Self.columns, b = otherY * Self.columns
            for c in 0..<Self.columns { sum += abs(signature[a + c] - other.signature[b + c]) }
            return sum / Float(Self.columns)
        }

        /// How many rows the content in `rows` moved up from self to `next`:
        /// self's row y + shift appears as next's row y.
        func verticalShift(to next: Frame, rows: Range<Int>) -> Int? {
            let span = rows.count
            let minOverlap = max(span / 6, 8)
            guard span > minOverlap else { return nil }
            var best: (shift: Int, cost: Float)?
            func cost(_ shift: Int, step: Int) -> Float {
                var total: Float = 0, n: Float = 0
                var y = rows.lowerBound
                while y + shift < rows.upperBound {
                    total += rowDistance(y + shift, next, y)
                    n += 1
                    y += step
                }
                return n > 0 ? total / n : .infinity
            }
            // Coarse pass on every 4th row, then refine around the best candidates.
            var coarse: [(Int, Float)] = []
            for shift in 1...(span - minOverlap) { coarse.append((shift, cost(shift, step: 4))) }
            coarse.sort { $0.1 < $1.1 }
            for (candidate, _) in coarse.prefix(5) {
                for shift in max(1, candidate - 2)...min(span - minOverlap, candidate + 2) {
                    let c = cost(shift, step: 1)
                    if best == nil || c < best!.cost { best = (shift, c) }
                }
            }
            // Accept only near-exact matches: screen content scrolls without changing.
            guard let best, best.cost < 2.0 else { return nil }
            return best.shift
        }
    }
}
