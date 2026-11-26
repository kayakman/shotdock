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
        case .permissionDenied: String(localized: "ShotDock has no Screen Recording permission.")
        case .noDisplays: String(localized: "No display was found.")
        }
    }
}

enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording access; the first time this shows the
    /// system prompt, later it only returns the current state.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// A window that can be picked: its id and frame in AppKit global coordinates.
    struct WindowInfo {
        let window: SCWindow
        let frame: CGRect
        let title: String
    }

    @MainActor
    static func snapshotDisplay(containing point: CGPoint) async throws -> DisplaySnapshot {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let snapshots = try await snapshotAllDisplays(only: screen.displayID)
        guard let snapshot = snapshots.first else { throw ScreenCaptureError.noDisplays }
        return snapshot
    }

    /// On-screen normal windows, front to back. ShotDock's own count too
    /// (editor, preferences, history); its overlays, HUD and pins float above
    /// the normal level and are left out.
    @MainActor
    static func pickableWindows() async throws -> [WindowInfo] {
        let content = try await shareableContent()
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // CGWindowList gives the z-order; ScreenCaptureKit gives capturable windows.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let window = byID[number],
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  window.frame.width > 40, window.frame.height > 40 else { return nil }
            // Quartz window frames have a top-left origin on the primary display.
            let f = window.frame
            let frame = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            return WindowInfo(window: window, frame: frame, title: window.title ?? window.owningApplication?.applicationName ?? "")
        }
    }

    /// The frontmost window of the active app.
    @MainActor
    static func activeWindow() async throws -> WindowInfo? {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return try await pickableWindows().first { $0.window.owningApplication?.processID == pid }
    }

    /// Captures one window by itself, with transparent corners (and its shadow if asked).
    @MainActor
    static func capture(window: SCWindow, shadow: Bool) async throws -> (image: CGImage, scale: CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.shouldBeOpaque = false
        config.ignoreShadowsSingleWindow = !shadow
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Captures part of one display, `rect` in AppKit global coordinates.
    /// ShotDock's floating windows (border, controls) are left out.
    @MainActor
    static func capture(rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { throw ScreenCaptureError.noDisplays }
        let filter = SCContentFilter(display: display, excludingWindows: ownFloatingWindows(content))
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        // sourceRect is in display points with a top-left origin.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// ShotDock's windows above the normal level: the selection overlay, the
    /// HUD, pins and the scrolling capture's border. They never show in a
    /// capture; its normal windows (editor, preferences) do, like any app's.
    static func ownFloatingWindows(_ content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer != 0 }
    }

    @MainActor
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw hasPermission ? error : ScreenCaptureError.permissionDenied
        }
    }

    @MainActor
    static func snapshotAllDisplays(only displayID: CGDirectDisplayID? = nil) async throws -> [DisplaySnapshot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw hasPermission ? error : ScreenCaptureError.permissionDenied
        }
        guard !content.displays.isEmpty else { throw ScreenCaptureError.noDisplays }

        let hidden = ownFloatingWindows(content)
        var snapshots: [DisplaySnapshot] = []
        for display in content.displays where displayID == nil || display.displayID == displayID {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: hidden)
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
