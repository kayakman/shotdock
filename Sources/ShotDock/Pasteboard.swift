import AppKit
import ShotDockCore

enum Pasteboard {
    /// Puts an image on the clipboard as PNG and TIFF, sized in points so a
    /// Retina capture pastes at its on-screen size.
    @discardableResult
    static func copy(_ image: CGImage, scale: CGFloat) -> Bool {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let nsImage = NSImage(cgImage: image, size: size)
        let item = NSPasteboardItem()
        if let png = try? ImageEncoding.data(from: image, scale: scale) { item.setData(png, forType: .png) }
        if let tiff = nsImage.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
