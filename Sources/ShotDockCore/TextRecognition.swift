import CoreGraphics
import CoreImage
import Foundation
import Vision

/// What Vision finds in a capture: text lines and QR/barcode payloads.
public struct RecognitionResult: Equatable, Sendable {
    public var lines: [String]
    public var codes: [String]

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
    public static func recognize(_ image: CGImage, languages: [String] = ["es-ES", "en-US"]) async throws -> RecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try recognizeSync(image, languages: languages))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeSync(_ image: CGImage, languages: [String]) throws -> RecognitionResult {
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
        return RecognitionResult(lines: lines, codes: codes)
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
