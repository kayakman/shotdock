import CoreGraphics
import Foundation

/// How an image is written where it goes: a named format, quality and
/// maximum size ("Web: WebP 80 %, up to 1600 px"). Each destination (save
/// to folder, upload, drag, Save As) uses one.
public struct ExportProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var format: ImageFormat
    /// 0…1, for formats with a quality (JPEG, HEIC, AVIF).
    public var quality: Double
    /// Largest width and height in pixels; nil keeps the size.
    public var maxWidth: Int?
    public var maxHeight: Int?

    public init(id: UUID = UUID(), name: String, format: ImageFormat, quality: Double = 0.9,
                maxWidth: Int? = nil, maxHeight: Int? = nil) {
        self.id = id
        self.name = name
        self.format = format
        self.quality = quality
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    /// The profiles a new install starts with, named in the app's language.
    public static func defaults() -> [ExportProfile] {
        [
            ExportProfile(name: String(localized: "Original"), format: .png),
            ExportProfile(name: String(localized: "Web"), format: .webp, maxWidth: 1600),
            ExportProfile(name: String(localized: "Document"), format: .png, maxWidth: 2000),
            ExportProfile(name: String(localized: "Light"), format: .jpeg, quality: 0.7, maxWidth: 1280),
        ]
    }

    /// "WebP 80 % · up to 1600 px".
    public var summary: String {
        var parts = [format.title]
        if format.hasQuality {
            parts[0] += " \(Int((quality * 100).rounded())) %"
        }
        switch (maxWidth, maxHeight) {
        case let (w?, h?): parts.append(String(localized: "up to \(w) × \(h) px"))
        case let (w?, nil): parts.append(String(localized: "up to \(w) px wide"))
        case let (nil, h?): parts.append(String(localized: "up to \(h) px high"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// The factor that fits `size` inside the maximum size (never enlarges).
    public func fitting(_ size: CGSize) -> CGFloat {
        var factor: CGFloat = 1
        if let maxWidth, size.width > CGFloat(maxWidth) { factor = min(factor, CGFloat(maxWidth) / size.width) }
        if let maxHeight, size.height > CGFloat(maxHeight) { factor = min(factor, CGFloat(maxHeight) / size.height) }
        return factor
    }

    /// The format actually written: this Mac may not write AVIF (then JPEG,
    /// with the same quality); WebP cannot exceed 16384 px (then PNG).
    public func writtenFormat(for size: CGSize) -> ImageFormat {
        if format == .webp, max(size.width, size.height) > CGFloat(WebPLossless.maxDimension) { return .png }
        return format.isAvailable ? format : .jpeg
    }
}

public struct EncodedImage: Sendable {
    public var data: Data
    public var format: ImageFormat
    public var width: Int
    public var height: Int
    /// Pixels per point after fitting the maximum size.
    public var scale: CGFloat
}

public extension ImageEncoding {
    /// The image as `profile` says: fitted to its maximum size, in its format and quality.
    static func encode(_ image: CGImage, scale: CGFloat, profile: ExportProfile) throws -> EncodedImage {
        let factor = profile.fitting(CGSize(width: image.width, height: image.height))
        let fitted = factor < 1 ? resized(image, by: factor) ?? image : image
        let format = profile.writtenFormat(for: CGSize(width: fitted.width, height: fitted.height))
        let data = try ImageEncoding.data(from: fitted, format: format, scale: scale * factor, jpegQuality: profile.quality)
        return EncodedImage(data: data, format: format, width: fitted.width, height: fitted.height, scale: scale * factor)
    }

    static func resized(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded())), height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

public extension ExportProfile {
    /// This profile with some settings replaced for one export (CLI flags).
    /// `quality` is 0…1.
    func overriding(format: ImageFormat? = nil, quality: Double? = nil, maxWidth: Int? = nil, maxHeight: Int? = nil) -> ExportProfile {
        var copy = self
        if let format { copy.format = format }
        if let quality { copy.quality = min(max(quality, 0), 1) }
        if let maxWidth { copy.maxWidth = maxWidth > 0 ? maxWidth : nil }
        if let maxHeight { copy.maxHeight = maxHeight > 0 ? maxHeight : nil }
        return copy
    }
}

/// Where an image goes; each has its export profile.
public enum ExportDestination: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case save, upload, drag
}
