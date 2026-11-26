import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Codable, Sendable {
    case png
    case jpeg
    case webp
    case heic
    case avif

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    public var mimeType: String { "image/\(rawValue)" }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .heic: "HEIC"
        case .avif: "AVIF"
        }
    }

    /// PNG and WebP (ShotDock writes lossless WebP) keep every pixel; the rest take a quality.
    public var hasQuality: Bool { self != .png && self != .webp }

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .webp: .webP
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .heic
        }
    }

    /// The format of a file name's extension.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "webp": self = .webp
        case "heic": self = .heic
        case "avif": self = .avif
        default: return nil
        }
    }

    /// Whether this Mac can write it (WebP has its own encoder).
    public var isAvailable: Bool {
        self == .webp || (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(utType.identifier)
    }

    public static var available: [ImageFormat] { allCases.filter(\.isAvailable) }
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
        if format == .webp { return try WebPLossless.encode(image) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil
        ) else { throw ImageEncodingError.cannotCreateDestination }

        let dpi = 72 * max(scale, 1)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format.hasQuality {
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

    /// Pixels per point recorded in the file (its DPI ÷ 72), 1 if none.
    public static func scale(of data: Data) -> CGFloat {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 72 else { return 1 }
        return CGFloat((dpi / 72 * 4).rounded() / 4)
    }
}
