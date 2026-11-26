import CoreGraphics
import Foundation

/// A WebP lossless (VP8L) encoder, because ImageIO only reads WebP.
/// RFC 9649. Images with up to 256 colours (most screenshots) use a palette,
/// packing several pixels per byte when there are few colours; others use the
/// subtract-green and predictor transforms. Then LZ77 backward references,
/// a colour cache and canonical prefix (Huffman) codes.
public enum WebPLossless {
    public static let maxDimension = 16384

    public enum Failure: Error { case tooLarge, cannotRead }

    public static func encode(_ image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        guard width >= 1, height >= 1, width <= maxDimension, height <= maxDimension else { throw Failure.tooLarge }
        guard var argb = pixels(of: image) else { throw Failure.cannotRead }
        let hasAlpha = argb.contains { $0 >> 24 != 0xFF }

        var writer = BitWriter()
        writer.write(0x2F, 8)                                  // signature
        writer.write(UInt64(width - 1), 14)
        writer.write(UInt64(height - 1), 14)
        writer.write(hasAlpha ? 1 : 0, 1)
        writer.write(0, 3)                                     // version

        var xsize = width
        if let palette = palette(of: argb) {
            // Colour indexing transform (3).
            writer.write(1, 1)
            writer.write(3, 2)
            writer.write(UInt64(palette.count - 1), 8)
            // The palette is stored delta-coded, as a one-row image.
            var deltas = palette
            for i in stride(from: palette.count - 1, to: 0, by: -1) { deltas[i] = subtractPixels(palette[i], palette[i - 1]) }
            writeImage(deltas, width: palette.count, height: 1, main: false, into: &writer)
            let bits = palette.count <= 2 ? 3 : palette.count <= 4 ? 2 : palette.count <= 16 ? 1 : 0
            argb = bundle(argb, width: width, height: height, palette: palette, widthBits: bits)
            xsize = (width + (1 << bits) - 1) >> bits
        } else {
            // Subtract green (2), then predictor (0), applied in that order.
            writer.write(1, 1)
            writer.write(2, 2)
            for i in argb.indices {
                let p = argb[i], green = (p >> 8) & 0xFF
                let red = ((p >> 16) &- green) & 0xFF, blue = (p &- green) & 0xFF
                argb[i] = (p & 0xFF00_FF00) | (red << 16) | blue
            }
            let blockBits = 4
            writer.write(1, 1)
            writer.write(0, 2)
            writer.write(UInt64(blockBits - 2), 3)
            let (modes, residuals) = predict(argb, width: width, height: height, blockBits: blockBits)
            let tilesWide = (width + (1 << blockBits) - 1) >> blockBits, tilesHigh = (height + (1 << blockBits) - 1) >> blockBits
            writeImage(modes, width: tilesWide, height: tilesHigh, main: false, into: &writer)
            argb = residuals
        }
        writer.write(0, 1)                                     // no more transforms
        writeImage(argb, width: xsize, height: height, main: true, into: &writer)

        let payload = writer.finish()
        var data = Data()
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        let padded = payload.count + (payload.count & 1)
        data.append(contentsOf: Array("RIFF".utf8))
        le32(4 + 8 + padded)
        data.append(contentsOf: Array("WEBPVP8L".utf8))
        le32(payload.count)
        data.append(payload)
        if payload.count & 1 == 1 { data.append(0) }
        return data
    }

    // MARK: Pixels

    /// Straight (not premultiplied) ARGB, row by row from the top.
    static func pixels(of image: CGImage) -> [UInt32]? {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var argb = [UInt32](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            var r = UInt32(rgba[i * 4]), g = UInt32(rgba[i * 4 + 1]), b = UInt32(rgba[i * 4 + 2])
            let a = UInt32(rgba[i * 4 + 3])
            if a == 0 {
                r = 0; g = 0; b = 0
            } else if a < 255 {
                r = min(255, (r * 255 + a / 2) / a); g = min(255, (g * 255 + a / 2) / a); b = min(255, (b * 255 + a / 2) / a)
            }
            argb[i] = a << 24 | r << 16 | g << 8 | b
        }
        return argb
    }

    static func subtractPixels(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let alphaGreen = UInt32(0x00FF_00FF) &+ (a & 0xFF00_FF00) &- (b & 0xFF00_FF00)
        let redBlue = UInt32(0xFF00_FF00) &+ (a & 0x00FF_00FF) &- (b & 0x00FF_00FF)
        return (alphaGreen & 0xFF00_FF00) | (redBlue & 0x00FF_00FF)
    }

    // MARK: Palette

    static func palette(of argb: [UInt32]) -> [UInt32]? {
        var colors = Set<UInt32>()
        for p in argb {
            colors.insert(p)
            if colors.count > 256 { return nil }
        }
        return colors.sorted()
    }

    /// Palette indices in the green channel, `1 << widthBits` pixels per pixel.
    static func bundle(_ argb: [UInt32], width: Int, height: Int, palette: [UInt32], widthBits: Int) -> [UInt32] {
        var index: [UInt32: UInt32] = [:]
        for (i, color) in palette.enumerated() { index[color] = UInt32(i) }
        let perPixel = 1 << widthBits, bitsPerIndex = 8 >> widthBits
        let packedWidth = (width + perPixel - 1) >> widthBits
        var packed = [UInt32](repeating: 0xFF00_0000, count: packedWidth * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = index[argb[y * width + x]]!
                packed[y * packedWidth + (x >> widthBits)] |= i << (8 + UInt32((x & (perPixel - 1)) * bitsPerIndex))
            }
        }
        return packed
    }

    // MARK: Predictor

    @inline(__always) static func average2(_ a: UInt32, _ b: UInt32) -> UInt32 {
        (((a ^ b) & 0xFEFE_FEFE) >> 1) &+ (a & b)
    }

    @inline(__always) static func channel(_ p: UInt32, _ shift: UInt32) -> Int { Int((p >> shift) & 0xFF) }

    @inline(__always) static func clamp(_ v: Int) -> UInt32 { UInt32(min(max(v, 0), 255)) }

    static func predictor(_ mode: Int, left l: UInt32, top t: UInt32, topRight tr: UInt32, topLeft tl: UInt32) -> UInt32 {
        switch mode {
        case 0: return 0xFF00_0000
        case 1: return l
        case 2: return t
        case 3: return tr
        case 4: return tl
        case 5: return average2(average2(l, tr), t)
        case 6: return average2(l, tl)
        case 7: return average2(l, t)
        case 8: return average2(tl, t)
        case 9: return average2(t, tr)
        case 10: return average2(average2(l, tl), average2(t, tr))
        case 11:
            // Select: whichever of left and top is nearer the gradient estimate.
            var pl = 0, pt = 0
            for shift: UInt32 in [24, 16, 8, 0] {
                let estimate = channel(l, shift) + channel(t, shift) - channel(tl, shift)
                pl += abs(estimate - channel(l, shift))
                pt += abs(estimate - channel(t, shift))
            }
            return pl < pt ? l : t
        case 12:
            var out: UInt32 = 0
            for shift: UInt32 in [24, 16, 8, 0] { out |= clamp(channel(l, shift) + channel(t, shift) - channel(tl, shift)) << shift }
            return out
        default:
            let a = average2(l, t)
            var out: UInt32 = 0
            for shift: UInt32 in [24, 16, 8, 0] {
                let av = channel(a, shift)
                out |= clamp(av + (av - channel(tl, shift)) / 2) << shift
            }
            return out
        }
    }

    /// Chooses a predictor per block and returns the modes image and the residuals.
    static func predict(_ argb: [UInt32], width: Int, height: Int, blockBits: Int) -> ([UInt32], [UInt32]) {
        let size = 1 << blockBits
        let tilesWide = (width + size - 1) >> blockBits, tilesHigh = (height + size - 1) >> blockBits
        var modes = [UInt32](repeating: 0, count: tilesWide * tilesHigh)
        var residuals = [UInt32](repeating: 0, count: argb.count)

        func prediction(_ x: Int, _ y: Int, _ mode: Int) -> UInt32 {
            let i = y * width + x
            if y == 0 { return x == 0 ? 0xFF00_0000 : argb[i - 1] }
            if x == 0 { return argb[i - width] }
            // The top-right of the last column is the first pixel of this row, as in memory order.
            return predictor(mode, left: argb[i - 1], top: argb[i - width], topRight: argb[i - width + 1], topLeft: argb[i - width - 1])
        }
        func cost(_ residual: UInt32) -> Int {
            var total = 0
            for shift: UInt32 in [24, 16, 8, 0] {
                let v = Int((residual >> shift) & 0xFF)
                total += min(v, 256 - v)
            }
            return total
        }

        for ty in 0..<tilesHigh {
            for tx in 0..<tilesWide {
                let x0 = tx * size, y0 = ty * size, x1 = min(x0 + size, width), y1 = min(y0 + size, height)
                var best = 1, bestCost = Int.max
                for mode in 0..<14 {
                    var total = 0
                    var y = y0
                    while y < y1, total < bestCost {
                        for x in x0..<x1 { total += cost(subtractPixels(argb[y * width + x], prediction(x, y, mode))) }
                        y += 1
                    }
                    if total < bestCost { best = mode; bestCost = total }
                }
                modes[ty * tilesWide + tx] = 0xFF00_0000 | UInt32(best) << 8
                for y in y0..<y1 {
                    for x in x0..<x1 { residuals[y * width + x] = subtractPixels(argb[y * width + x], prediction(x, y, best)) }
                }
            }
        }
        return (modes, residuals)
    }

    // MARK: Entropy-coded image

    enum Symbol {
        case literal(UInt32)
        case cache(Int)
        case copy(length: Int, distance: Int)
    }

    static let cacheBits = 10

    /// Prefix code and extra bits of an LZ77 length or distance (1-based).
    @inline(__always) static func prefix(_ value: Int) -> (code: Int, extraBits: Int, extra: Int) {
        let d = value - 1
        if d < 4 { return (d, 0, 0) }
        let highest = Int.bitWidth - 1 - d.leadingZeroBitCount
        let second = (d >> (highest - 1)) & 1
        let extraBits = highest - 1
        return (2 * highest + second, extraBits, d & ((1 << extraBits) - 1))
    }

    /// LZ77 with a hash chain (plus the pixel to the left and the one above,
    /// the best bets in screenshots) and a colour cache.
    static func symbols(_ argb: [UInt32], width: Int, useCache: Bool) -> [Symbol] {
        let count = argb.count
        var out: [Symbol] = []
        out.reserveCapacity(count / 4)
        let hashBits = 16
        var head = [Int32](repeating: -1, count: 1 << hashBits)
        var chain = [Int32](repeating: -1, count: count)
        var cache = [UInt32](repeating: 0, count: 1 << cacheBits)
        var cacheUsed = [Bool](repeating: false, count: 1 << cacheBits)
        let maxLength = 4096, minLength = 3, maxCandidates = 24
        // The largest distance code (40 prefixes) is 2^20, minus the 120 plane codes we never use.
        let maxDistance = (1 << 20) - 120

        @inline(__always) func hash(_ i: Int) -> Int {
            let v = UInt64(argb[i]) << 32 | UInt64(argb[i + 1])
            return Int((v &* 0x9E37_79B9_7F4A_7C15) >> UInt64(64 - hashBits))
        }
        @inline(__always) func cacheIndex(_ p: UInt32) -> Int { Int((0x1E35_A7BD &* p) >> UInt32(32 - cacheBits)) }
        @inline(__always) func insert(_ i: Int) {
            if i + 1 < count {
                let h = hash(i)
                chain[i] = head[h]
                head[h] = Int32(i)
            }
        }
        @inline(__always) func matchLength(_ i: Int, _ j: Int) -> Int {
            var n = 0
            let limit = min(maxLength, count - i)
            while n < limit, argb[i + n] == argb[j + n] { n += 1 }
            return n
        }

        var i = 0
        while i < count {
            var bestLength = 0, bestDistance = 0
            if i + minLength <= count {
                for distance in [1, width] where distance <= i && distance <= maxDistance {
                    let n = matchLength(i, i - distance)
                    if n > bestLength { bestLength = n; bestDistance = distance }
                }
                if bestLength < maxLength, i + 1 < count {
                    var candidate = Int(head[hash(i)]), tries = 0
                    while candidate >= 0, tries < maxCandidates, i - candidate <= maxDistance {
                        let n = matchLength(i, candidate)
                        if n > bestLength { bestLength = n; bestDistance = i - candidate }
                        if bestLength == maxLength { break }
                        candidate = Int(chain[candidate])
                        tries += 1
                    }
                }
            }
            if bestLength >= minLength {
                out.append(.copy(length: bestLength, distance: bestDistance))
                for k in i..<(i + bestLength) {
                    insert(k)
                    if useCache { let c = cacheIndex(argb[k]); cache[c] = argb[k]; cacheUsed[c] = true }
                }
                i += bestLength
            } else {
                let p = argb[i]
                let c = cacheIndex(p)
                if useCache, cacheUsed[c], cache[c] == p {
                    out.append(.cache(c))
                } else {
                    out.append(.literal(p))
                }
                if useCache { cache[c] = p; cacheUsed[c] = true }
                insert(i)
                i += 1
            }
        }
        return out
    }

    /// Writes an image as VP8L entropy-coded data: one set of five prefix
    /// codes (green+length+cache, red, blue, alpha, distance).
    static func writeImage(_ argb: [UInt32], width: Int, height: Int, main: Bool, into writer: inout BitWriter) {
        let useCache = argb.count > 64
        let stream = symbols(argb, width: width, useCache: useCache)
        let cacheSize = useCache ? 1 << cacheBits : 0
        var green = [Int](repeating: 0, count: 256 + 24 + cacheSize)
        var red = [Int](repeating: 0, count: 256), blue = [Int](repeating: 0, count: 256), alpha = [Int](repeating: 0, count: 256)
        var distance = [Int](repeating: 0, count: 40)
        for symbol in stream {
            switch symbol {
            case let .literal(p):
                green[Int((p >> 8) & 0xFF)] += 1
                red[Int((p >> 16) & 0xFF)] += 1
                blue[Int(p & 0xFF)] += 1
                alpha[Int(p >> 24)] += 1
            case let .cache(index):
                green[256 + 24 + index] += 1
            case let .copy(length, dist):
                green[256 + prefix(length).code] += 1
                distance[prefix(dist + 120).code] += 1
            }
        }
        if useCache {
            writer.write(1, 1)
            writer.write(UInt64(cacheBits), 4)
        } else {
            writer.write(0, 1)
        }
        if main { writer.write(0, 1) }                         // one set of prefix codes for the whole image
        let codes = [green, red, blue, alpha, distance].map { PrefixCode(counts: $0) }
        for code in codes { code.write(into: &writer) }
        for symbol in stream {
            switch symbol {
            case let .literal(p):
                codes[0].write(Int((p >> 8) & 0xFF), into: &writer)
                codes[1].write(Int((p >> 16) & 0xFF), into: &writer)
                codes[2].write(Int(p & 0xFF), into: &writer)
                codes[3].write(Int(p >> 24), into: &writer)
            case let .cache(index):
                codes[0].write(256 + 24 + index, into: &writer)
            case let .copy(length, dist):
                let l = prefix(length), d = prefix(dist + 120)
                codes[0].write(256 + l.code, into: &writer)
                writer.write(UInt64(l.extra), l.extraBits)
                codes[4].write(d.code, into: &writer)
                writer.write(UInt64(d.extra), d.extraBits)
            }
        }
    }
}

/// Bits written least significant first, as VP8L reads them.
struct BitWriter {
    private var bytes: [UInt8] = []
    private var accumulator: UInt64 = 0
    private var used = 0

    mutating func write(_ value: UInt64, _ count: Int) {
        guard count > 0 else { return }
        accumulator |= (value & ((1 << UInt64(count)) - 1)) << UInt64(used)
        used += count
        while used >= 8 {
            bytes.append(UInt8(accumulator & 0xFF))
            accumulator >>= 8
            used -= 8
        }
    }

    mutating func finish() -> Data {
        if used > 0 { bytes.append(UInt8(accumulator & 0xFF)) }
        accumulator = 0
        used = 0
        return Data(bytes)
    }
}

/// A canonical prefix code with lengths of at most `limit` bits.
struct PrefixCode {
    let lengths: [Int]
    let codes: [UInt32]
    /// Symbols for VP8L's "simple" form (one or two symbols under 256), else nil.
    let simple: [Int]?

    init(counts: [Int], limit: Int = 15) {
        let used = counts.indices.filter { counts[$0] > 0 }
        if used.count <= 2, used.allSatisfy({ $0 < 256 }) {
            simple = used.isEmpty ? [0] : used
            var lengths = [Int](repeating: 0, count: counts.count)
            if used.count == 2 { lengths[used[0]] = 1; lengths[used[1]] = 1 }
            self.lengths = lengths
        } else {
            simple = nil
            var counts = counts
            // A lone symbol (≥ 256) still needs a two-symbol code.
            if used.count == 1 { counts[used[0] == 0 ? 1 : 0] = 1 }
            lengths = Self.lengths(counts, limit: limit)
        }
        codes = Self.canonical(lengths)
    }

    /// Huffman code lengths, flattening the counts until they fit `limit`.
    static func lengths(_ counts: [Int], limit: Int) -> [Int] {
        var weights = counts
        while true {
            let lengths = huffman(weights)
            if (lengths.max() ?? 0) <= limit { return lengths }
            weights = weights.map { $0 == 0 ? 0 : ($0 >> 1) | 1 }
        }
    }

    static func huffman(_ counts: [Int]) -> [Int] {
        struct Node { var weight: Int; var symbol: Int; var left = -1, right = -1 }
        var nodes: [Node] = counts.indices.filter { counts[$0] > 0 }.map { Node(weight: counts[$0], symbol: $0) }
        var lengths = [Int](repeating: 0, count: counts.count)
        if nodes.count == 1 { lengths[nodes[0].symbol] = 1; return lengths }
        var queue = Array(nodes.indices).sorted { nodes[$0].weight < nodes[$1].weight }
        var merged: [Int] = []
        // Two sorted queues: leaves and merged nodes.
        func popSmallest() -> Int {
            if merged.isEmpty || (!queue.isEmpty && nodes[queue[0]].weight <= nodes[merged[0]].weight) { return queue.removeFirst() }
            return merged.removeFirst()
        }
        while queue.count + merged.count > 1 {
            let a = popSmallest(), b = popSmallest()
            nodes.append(Node(weight: nodes[a].weight + nodes[b].weight, symbol: -1, left: a, right: b))
            merged.append(nodes.count - 1)
        }
        var stack = [(nodes.count - 1, 0)]
        while let (index, depth) = stack.popLast() {
            let node = nodes[index]
            if node.symbol >= 0 { lengths[node.symbol] = max(depth, 1); continue }
            stack.append((node.left, depth + 1))
            stack.append((node.right, depth + 1))
        }
        return lengths
    }

    /// Canonical codes, bit-reversed for an LSB-first writer.
    static func canonical(_ lengths: [Int]) -> [UInt32] {
        let maxLength = lengths.max() ?? 0
        var countPerLength = [Int](repeating: 0, count: maxLength + 1)
        for length in lengths where length > 0 { countPerLength[length] += 1 }
        var next = [UInt32](repeating: 0, count: maxLength + 2)
        var code: UInt32 = 0
        if maxLength > 0 {
            for length in 1...maxLength {
                code = (code + UInt32(countPerLength[length - 1])) << 1
                next[length] = code
            }
        }
        return lengths.map { length in
            guard length > 0 else { return 0 }
            let c = next[length]
            next[length] += 1
            var reversed: UInt32 = 0
            for bit in 0..<length where c & (1 << UInt32(bit)) != 0 { reversed |= 1 << UInt32(length - 1 - bit) }
            return reversed
        }
    }

    func write(_ symbol: Int, into writer: inout BitWriter) {
        writer.write(UInt64(codes[symbol]), lengths[symbol])
    }

    static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Writes the code itself (VP8L "simple" or "normal" form).
    func write(into writer: inout BitWriter) {
        if let simple {
            writer.write(1, 1)
            writer.write(UInt64(simple.count - 1), 1)
            if simple[0] < 2 {
                writer.write(0, 1)
                writer.write(UInt64(simple[0]), 1)
            } else {
                writer.write(1, 1)
                writer.write(UInt64(simple[0]), 8)
            }
            if simple.count == 2 { writer.write(UInt64(simple[1]), 8) }
            return
        }
        writer.write(0, 1)
        // The lengths, run-length coded with 16 (repeat previous), 17 and 18 (zeros).
        var tokens: [(symbol: Int, extra: Int)] = []
        var i = 0
        var previous = 8
        while i < lengths.count {
            let length = lengths[i]
            var run = 1
            while i + run < lengths.count, lengths[i + run] == length { run += 1 }
            if length == 0 {
                var left = run
                while left >= 11 { let n = min(left, 138); tokens.append((18, n - 11)); left -= n }
                if left >= 3 { tokens.append((17, left - 3)); left = 0 }
                while left > 0 { tokens.append((0, 0)); left -= 1 }
            } else {
                var left = run
                if length != previous { tokens.append((length, 0)); left -= 1; previous = length }
                while left >= 3 { let n = min(left, 6); tokens.append((16, n - 3)); left -= n }
                while left > 0 { tokens.append((length, 0)); left -= 1 }
            }
            i += run
        }
        var counts = [Int](repeating: 0, count: 19)
        for token in tokens { counts[token.symbol] += 1 }
        let lengthCode = PrefixCode(lengthCodeCounts: counts)
        var last = 18
        while last > 3, lengthCode.lengths[Self.codeLengthOrder[last]] == 0 { last -= 1 }
        writer.write(UInt64(last + 1 - 4), 4)
        for k in 0...last { writer.write(UInt64(lengthCode.lengths[Self.codeLengthOrder[k]]), 3) }
        writer.write(0, 1)                                     // every symbol has a length
        for token in tokens {
            lengthCode.write(token.symbol, into: &writer)
            switch token.symbol {
            case 16: writer.write(UInt64(token.extra), 2)
            case 17: writer.write(UInt64(token.extra), 3)
            case 18: writer.write(UInt64(token.extra), 7)
            default: break
            }
        }
    }

    /// The code that codes code lengths: at most 7 bits, always a normal code.
    init(lengthCodeCounts counts: [Int]) {
        var counts = counts
        let used = counts.indices.filter { counts[$0] > 0 }
        if used.count == 1 { counts[used[0] == 0 ? 1 : 0] = 1 }
        simple = nil
        lengths = Self.lengths(counts, limit: 7)
        codes = Self.canonical(lengths)
    }
}
