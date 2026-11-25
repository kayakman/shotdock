import AppKit
import ApplicationServices
import ScreenCaptureKit
import ShotDockCore

/// The app's side of every `.app` command in CommandCatalog.
@MainActor
enum RemoteHandlers {
    static var all: [String: RemoteHandler] {
        [general, screens, RemoteCapture.handlers, RemoteHistory.handlers, RemoteEditing.handlers, RemoteInspection.handlers, RemoteSharing.handlers].reduce(into: [:]) { all, part in all.merge(part) { a, _ in a } }
    }

    // MARK: General

    static let general: [String: RemoteHandler] = [
        "status": { _, context in
            let settings = AppSettings.shared
            return [
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
                "app": .string(Bundle.main.bundlePath),
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "permissions": ["screen_recording": .bool(ScreenCapturer.hasPermission), "accessibility": .bool(AXIsProcessTrusted())],
                "agent_control": [
                    "enabled": .bool(settings.agentControlEnabled),
                    "client": .string(context.client.title),
                    "approved": .bool(ControlService.shared.isApproved(context.client)),
                ],
                "displays": .number(Double(NSScreen.screens.count)),
                "history": ["enabled": .bool(LibraryStore.shared.isEnabled), "count": .number(Double(LibraryStore.shared.items.count))],
            ]
        },
    ]

    // MARK: Displays and windows

    static let screens: [String: RemoteHandler] = [
        "displays": { _, _ in
            .object(["displays": .array(RemoteScreens.displays().map(\.json))])
        },
        "windows": { params, _ in
            let app = params["app"]?.stringValue ?? "", title = params["title"]?.stringValue ?? ""
            let windows = try await RemoteScreens.windows(includeOffscreen: params["all"]?.boolValue ?? false)
                .filter { TextMatch.loosely($0.app, contains: app) && TextMatch.loosely($0.title, contains: title) }
            return .object(["windows": .array(windows.map(\.json))])
        },
    ]
}

/// Displays and windows in the coordinates agents see: global points, top-left origin.
@MainActor
enum RemoteScreens {
    @MainActor struct Display {
        let index: Int
        let screen: NSScreen
        /// Top-left origin.
        let frame: CGRect

        var json: JSONValue {
            let scale = screen.backingScaleFactor
            return [
                "index": .number(Double(index)),
                "id": .number(Double(screen.displayID)),
                "name": .string(screen.localizedName),
                "frame": JSONValue(frame),
                "scale": .number(scale),
                "pixel_width": .number((frame.width * scale).rounded()),
                "pixel_height": .number((frame.height * scale).rounded()),
                "main": .bool(index == 1),
            ]
        }
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Numbered from 1, the main display (with the menu bar) first.
    static func displays() -> [Display] {
        NSScreen.screens.enumerated().map { offset, screen in
            Display(index: offset + 1, screen: screen, frame: ScreenGeometry.flipped(screen.frame, primaryHeight: primaryHeight))
        }
    }

    static func display(_ index: Int) -> Display? { displays().first { $0.index == index } }

    /// The display number containing a top-left-origin point.
    static func displayIndex(containing point: CGPoint) -> Int? {
        displays().first { $0.frame.contains(point) }?.index
    }

    @MainActor struct Window {
        let window: SCWindow
        let app: String
        let title: String
        /// Top-left origin, as ScreenCaptureKit gives it.
        let frame: CGRect
        let active: Bool

        var json: JSONValue {
            [
                "id": .number(Double(window.windowID)),
                "app": .string(app),
                "bundle_id": window.owningApplication.map { .string($0.bundleIdentifier) } ?? .null,
                "pid": window.owningApplication.map { .number(Double($0.processID)) } ?? .null,
                "title": .string(title),
                "frame": JSONValue(frame),
                "display": RemoteScreens.displayIndex(containing: CGPoint(x: frame.midX, y: frame.midY)).map { .number(Double($0)) } ?? .null,
                "on_screen": .bool(window.isOnScreen),
                "active": .bool(active),
            ]
        }
    }

    /// Normal app windows, front to back, without ShotDock's own.
    static func windows(includeOffscreen: Bool) async throws -> [Window] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: !includeOffscreen)
        } catch {
            throw ScreenCapturer.hasPermission ? error : ScreenCaptureError.permissionDenied
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // CGWindowList knows the stacking order.
        let options: CGWindowListOption = includeOffscreen ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
        let order = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var sawFront = false
        return content.windows
            .filter { window in
                guard let app = window.owningApplication, app.processID != ownPID else { return false }
                return window.windowLayer == 0 && window.frame.width > 40 && window.frame.height > 40
            }
            .sorted { (rank[$0.windowID] ?? .max, $0.windowID) < (rank[$1.windowID] ?? .max, $1.windowID) }
            .map { window in
                let app = window.owningApplication?.applicationName ?? ""
                let isFront = !sawFront && window.isOnScreen && window.owningApplication?.processID == frontPID
                if isFront { sawFront = true }
                return Window(window: window, app: app, title: window.title ?? "", frame: window.frame, active: isFront)
            }
    }
}
