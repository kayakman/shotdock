import AppKit
import ScreenCaptureKit

/// A frozen image of one display, with the geometry needed to map it back to
/// screen coordinates.
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Display frame in AppKit global coordinates (points, bottom-left origin).
    let frame: CGRect
    let scale: CGFloat
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplays

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "ShotDock no tiene permiso de Grabación de pantalla."
        case .noDisplays: "No se encontró ninguna pantalla."
        }
    }
}

enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording access; the first time this shows the
    /// system prompt, later it only returns the current state.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    @MainActor
    static func snapshotAllDisplays() async throws -> [DisplaySnapshot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw hasPermission ? error : ScreenCaptureError.permissionDenied
        }
        guard !content.displays.isEmpty else { throw ScreenCaptureError.noDisplays }

        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var snapshots: [DisplaySnapshot] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int((filter.contentRect.width * scale).rounded())
            config.height = Int((filter.contentRect.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(DisplaySnapshot(displayID: display.displayID, image: image,
                                             frame: screen.frame, scale: scale))
        }
        return snapshots
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
