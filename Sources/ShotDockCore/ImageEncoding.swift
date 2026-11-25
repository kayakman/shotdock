import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Codable, Sendable {
    case png
    case jpeg

    public var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }

    var utType: UTType { self == .png ? .png : .jpeg }
}

public enum ImageEncodingError: Error {
    case cannotCreateDestination
    case cannotFinalize
    case cannotDecode
}

public enum ImageEncoding {
    /// Encodes an image, tagging it with the given scale so viewers show Retina
    /// captures at their point size.
    public static func data(from image: CGImage, format: ImageFormat = .png,
                            scale: CGFloat = 1, jpegQuality: CGFloat = 0.9) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil
        ) else { throw ImageEncodingError.cannotCreateDestination }

        let dpi = 72 * max(scale, 1)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncodingError.cannotFinalize }
        return data as Data
    }

    public static func write(_ image: CGImage, to url: URL, format: ImageFormat = .png,
                             scale: CGFloat = 1) throws {
        try data(from: image, format: format, scale: scale).write(to: url, options: .atomic)
    }

    public static func image(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageEncodingError.cannotDecode }
        return image
    }
}
