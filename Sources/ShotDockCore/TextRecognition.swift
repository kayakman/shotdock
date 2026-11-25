import CoreGraphics
import CoreImage
import Foundation
import Vision

/// One line of text and where it is, in image pixels from the top-left.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect
    public var confidence: Float
}

/// A QR code or barcode and where it is.
public struct RecognizedCode: Equatable, Sendable {
    public var payload: String
    /// "QR", "EAN13", "Code128"…
    public var symbology: String
    public var box: CGRect
}

/// A secret found in the text, masked, and where it is.
public struct RecognizedSecret: Equatable, Sendable {
    public var kind: String
    public var masked: String
    public var box: CGRect
}

/// What Vision finds in a capture: text lines and QR/barcode payloads.
public struct RecognitionResult: Equatable, Sendable {
    public var lines: [String]
    public var codes: [String]
    public var textLines: [RecognizedLine] = []
    public var barcodes: [RecognizedCode] = []
    /// Where the searched text appears (`find`), word-precise.
    public var matches: [CGRect] = []
    /// Secrets in the text (`secrets`), with their boxes.
    public var secrets: [RecognizedSecret] = []

    public init(lines: [String] = [], codes: [String] = []) {
        self.lines = lines
        self.codes = codes
    }

    /// Text with line breaks, or joined into paragraphs when `joinLines`.
    public func text(joinLines: Bool = false) -> String {
        joinLines ? lines.joined(separator: " ") : lines.joined(separator: "\n")
    }

    public var isEmpty: Bool { lines.isEmpty && codes.isEmpty }
}

public enum TextRecognition {
    /// Runs OCR (Spanish and English, with automatic language detection) and
    /// barcode detection on the image.
    /// `find` locates a text; `secrets` looks for secrets of those kinds (empty: all).
    public static func recognize(_ image: CGImage, languages: [String] = ["es-ES", "en-US"], find: String? = nil,
                                 secrets: Set<String>? = nil) async throws -> RecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try recognizeSync(image, languages: languages, find: find, secrets: secrets))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeSync(_ image: CGImage, languages: [String], find: String? = nil, secrets: Set<String>? = nil) throws -> RecognitionResult {
        let text = makeTextRequest(languages: languages)
        let barcodes = VNDetectBarcodesRequest()
        // Small captures read better scaled up.
        let input = image.width < 400 ? upscaled(image, factor: 3) ?? image : image
        try VNImageRequestHandler(cgImage: input).perform([text, barcodes])
        var textObservations = text.results ?? []

        // A large QR code makes Vision skip the text around it; read the text
        // again with the codes painted over.
        let codeBoxes = (barcodes.results ?? []).map(\.boundingBox)
        if !codeBoxes.isEmpty, let masked = masking(codeBoxes, in: input) {
            let retry = makeTextRequest(languages: languages)
            try VNImageRequestHandler(cgImage: masked).perform([retry])
            if (retry.results?.count ?? 0) > textObservations.count { textObservations = retry.results ?? [] }
        }

        let observations = textObservations.sorted { a, b in
            // Top to bottom (Vision's origin is bottom-left), then left to right on the same line.
            let ay = a.boundingBox.midY, by = b.boundingBox.midY
            if abs(ay - by) > min(a.boundingBox.height, b.boundingBox.height) / 2 { return ay > by }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        var codes: [String] = []
        for payload in (barcodes.results ?? []).compactMap(\.payloadStringValue) where !codes.contains(payload) {
            codes.append(payload)
        }
        var result = RecognitionResult(lines: lines, codes: codes)
        // Vision's boxes are normalised with the origin at the bottom-left.
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h).integral
        }
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            result.textLines.append(RecognizedLine(text: candidate.string, box: pixels(observation.boundingBox), confidence: candidate.confidence))
            if let secrets {
                for finding in SecretScanner.scan(candidate.string, kinds: secrets.isEmpty ? nil : secrets) {
                    let box = (try? candidate.boundingBox(for: finding.range))?.boundingBox ?? observation.boundingBox
                    result.secrets.append(RecognizedSecret(kind: finding.kind, masked: finding.masked, box: pixels(box)))
                }
            }
            guard let find, !find.isEmpty else { continue }
            let text = candidate.string
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: find, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                result.matches.append(pixels(box))
                searchRange = range.upperBound..<text.endIndex
            }
        }
        for code in barcodes.results ?? [] {
            guard let payload = code.payloadStringValue else { continue }
            let symbology = code.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
            result.barcodes.append(RecognizedCode(payload: payload, symbology: symbology, box: pixels(code.boundingBox)))
        }
        return result
    }

    static func makeTextRequest(languages: [String]) -> VNRecognizeTextRequest {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.recognitionLanguages = languages
        text.automaticallyDetectsLanguage = true
        // Vision ignores text smaller than 1/32 of the image height by default; screenshots often are.
        text.minimumTextHeight = 0
        return text
    }

    /// The image with white boxes over normalised (bottom-left origin) rectangles.
    static func masking(_ boxes: [CGRect], in image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(gray: 1, alpha: 1)
        for box in boxes {
            let rect = VNImageRectForNormalizedRect(box, w, h)
            context.fill(rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08))
        }
        return context.makeImage()
    }

    static func upscaled(_ image: CGImage, factor: Int) -> CGImage? {
        let w = image.width * factor, h = image.height * factor
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
