import AppKit
import ApplicationServices
import ShotDockCore

/// Captures for agents: the same pixels as the menu and the shortcuts, but
/// silent. The capture goes to the history and to a file; copying, saving,
/// uploading, editing or pinning only happen when asked.
@MainActor
enum RemoteCapture {
    static let handlers: [String: RemoteHandler] = [
        "capture.area": { params, _ in try await exclusive { try await area(params) } },
        "capture.window": { params, _ in try await exclusive { try await window(params) } },
        "capture.screen": { params, _ in try await exclusive { try await screen(params) } },
        "capture.repeat": { params, _ in
            try await exclusive {
                try await prepare(params)
                guard let area = AppSettings.shared.lastArea, let document = try await coordinator.repeatAreaDocument() else {
                    throw RPCError.notFound("There is no previous area: capture an area first")
                }
                return try await deliver(Captured(document: document, rect: topLeft(area)), params)
            }
        },
        "capture.scroll": { params, _ in try await exclusive { try await scroll(params) } },
    ]

    struct Captured {
        var document: CaptureDocument
        /// Where it was on screen: points, top-left origin.
        var rect: CGRect?
        var window: JSONValue?
    }

    static var coordinator: CaptureCoordinator {
        guard let app = NSApp.delegate as? AppDelegate else { fatalError("ShotDock's delegate is missing") }
        return app.coordinator
    }

    static let busy = RPCError(code: RPCError.busyCode, message: "ShotDock is busy with another capture")
    static let cancelled = RPCError(code: RPCError.cancelledCode, message: "The user cancelled the capture")

    static func topLeft(_ rect: CGRect) -> CGRect { ScreenGeometry.flipped(rect, primaryHeight: RemoteScreens.primaryHeight) }

    /// One capture at a time: refuses while another one (an agent's, or the
    /// user's from a shortcut) is in progress, and holds the coordinator meanwhile.
    static func exclusive(_ body: () async throws -> JSONValue) async throws -> JSONValue {
        guard !coordinator.isBusy else { throw busy }
        coordinator.reserved = true
        defer { coordinator.reserved = false }
        return try await body()
    }

    /// Permission and the delay.
    static func prepare(_ params: [String: JSONValue]) async throws {
        guard ScreenCapturer.hasPermission else { throw ScreenCaptureError.permissionDenied }
        guard let delay = params["delay"]?.doubleValue, delay > 0 else { return }
        if params["countdown"]?.boolValue == true {
            guard await HUD.countdown(seconds: Int(delay.rounded(.up))) else { throw cancelled }
        } else {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    /// The `rect` parameter (top-left points, maybe relative to `display`) in AppKit coordinates.
    static func screenRect(_ params: [String: JSONValue]) throws -> CGRect? {
        guard var rect = params["rect"]?.rect else { return nil }
        guard rect.width >= 1, rect.height >= 1 else { throw RPCError.invalidParams("rect must be at least 1×1 point") }
        if let number = params["display"]?.intValue {
            guard let display = RemoteScreens.display(number) else { throw RPCError.notFound("There is no display \(number)") }
            rect = rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        }
        return ScreenGeometry.flipped(rect, primaryHeight: RemoteScreens.primaryHeight)
    }

    // MARK: Modes

    static func area(_ params: [String: JSONValue]) async throws -> JSONValue {
        if params["interactive"]?.boolValue == true {
            try await prepare(params)
            return try await deliver(try await pickArea(), params)
        }
        guard let rect = try screenRect(params) else { throw RPCError.invalidParams("capture.area needs rect, or interactive") }
        try await prepare(params)
        guard let document = try await coordinator.areaDocument(rect) else { throw RPCError.invalidParams("The area is outside every display") }
        return try await deliver(Captured(document: document, rect: topLeft(rect)), params)
    }

    /// The user selects an area (or clicks a window: Space switches modes).
    static func pickArea() async throws -> Captured {
        switch try await coordinator.pick(mode: .area) {
        case let .area(result):
            AppSettings.shared.lastArea = result.screenRect
            return Captured(document: CaptureDocument(image: result.image, scale: result.scale), rect: topLeft(result.screenRect))
        case let .window(info):
            let document = try await coordinator.windowDocument(info.window, shadow: AppSettings.shared.windowShadow)
            return Captured(document: document, rect: topLeft(info.frame))
        case .color, nil:
            throw cancelled
        }
    }

    static func window(_ params: [String: JSONValue]) async throws -> JSONValue {
        let shadow = params["shadow"]?.boolValue ?? AppSettings.shared.windowShadow
        if params["interactive"]?.boolValue == true {
            try await prepare(params)
            switch try await coordinator.pick(mode: .window) {
            case let .window(info):
                let document = try await coordinator.windowDocument(info.window, shadow: shadow)
                let listed = try await RemoteScreens.windows(includeOffscreen: false).first { $0.window.windowID == info.window.windowID }
                return try await deliver(Captured(document: document, rect: topLeft(info.frame), window: listed?.json), params)
            case let .area(result):
                return try await deliver(Captured(document: CaptureDocument(image: result.image, scale: result.scale),
                                                  rect: topLeft(result.screenRect)), params)
            case .color, nil:
                throw cancelled
            }
        }
        try await prepare(params)
        let id = params["id"]?.intValue
        let app = params["app"]?.stringValue, title = params["title"]?.stringValue
        // Off-screen windows too: one in another Space (a full-screen app in
        // front) can still be captured, when nothing on screen matches.
        let windows = try await RemoteScreens.windows(includeOffscreen: true)
        let target: RemoteScreens.Window?
        if let id {
            target = windows.first { Int($0.window.windowID) == id }
        } else if app != nil || title != nil {
            let matching = windows.filter { TextMatch.loosely($0.app, contains: app ?? "") && TextMatch.loosely($0.title, contains: title ?? "") }
            target = matching.first { $0.window.isOnScreen } ?? matching.first
        } else {
            target = windows.first(where: \.active)
        }
        guard let target else {
            let open = windows.filter { $0.window.isOnScreen }.prefix(15).map { "\($0.window.windowID) \($0.app) — \($0.title)" }
            throw RPCError.notFound("No window matches. Open windows:\n" + open.joined(separator: "\n"))
        }
        let document = try await coordinator.windowDocument(target.window, shadow: shadow)
        return try await deliver(Captured(document: document, rect: target.frame, window: target.json), params)
    }

    static func screen(_ params: [String: JSONValue]) async throws -> JSONValue {
        let displays = RemoteScreens.displays()
        let chosen: [RemoteScreens.Display]
        if params["all"]?.boolValue == true {
            chosen = displays
        } else {
            let number = params["display"]?.intValue ?? 1
            guard let display = displays.first(where: { $0.index == number }) else {
                throw RPCError.notFound("There is no display \(number) (there are \(displays.count))")
            }
            chosen = [display]
        }
        try await prepare(params)
        // Grab every display first, then store them.
        var captured: [Captured] = []
        for display in chosen {
            captured.append(Captured(document: try await coordinator.displayDocument(display.screen.displayID), rect: display.frame))
        }
        if params["all"]?.boolValue != true { return try await deliver(captured[0], params) }
        var results: [JSONValue] = []
        for (index, capture) in captured.enumerated() {
            var options = params
            // One file each: number them if a path was given.
            if let out = params["out"]?.stringValue, captured.count > 1 {
                let url = URL(fileURLWithPath: out)
                let numbered = url.deletingPathExtension().path + "-\(index + 1)" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
                options["out"] = .string(numbered)
            }
            results.append(try await deliver(capture, options))
        }
        return ["captures": .array(results)]
    }

    static func scroll(_ params: [String: JSONValue]) async throws -> JSONValue {
        let auto = params["auto"]?.boolValue ?? false
        if auto, !AXIsProcessTrusted() {
            throw RPCError(code: RPCError.permissionDeniedCode,
                           message: "Automatic scrolling needs the Accessibility permission (System Settings › Privacy & Security › Accessibility)")
        }
        let maxHeight = params["max_height"]?.intValue ?? AppSettings.shared.scrollMaxHeight
        let area: CGRect
        if params["interactive"]?.boolValue == true {
            try await prepare(params)
            guard case let .area(result) = try await coordinator.pick(mode: .area) else { throw cancelled }
            area = result.screenRect
        } else {
            guard let rect = try screenRect(params) else { throw RPCError.invalidParams("capture.scroll needs rect, or interactive") }
            try await prepare(params)
            area = rect
        }
        guard let document = try await coordinator.scroll(area: area, auto: auto, maxHeight: maxHeight) else { throw cancelled }
        return try await deliver(Captured(document: document, rect: topLeft(area)), params)
    }

    // MARK: After capturing

    /// Stores the capture and does what was asked with it.
    static func deliver(_ captured: Captured, _ params: [String: JSONValue]) async throws -> JSONValue {
        var document = captured.document
        let flag = { (name: String) in params[name]?.boolValue == true }
        var result: [String: JSONValue] = [
            "width": .number(Double(document.image.width)),
            "height": .number(Double(document.image.height)),
            "scale": .number(document.scale),
        ]
        if flag("redact") {
            // Covered before anything leaves the app; the boxes stay editable in the history.
            let (boxes, findings) = try await Redaction.annotations(for: document)
            document.annotations += boxes
            result["redacted"] = RemoteEditing.findingsJSON(findings)
        }
        let image = document.annotations.isEmpty ? document.image : document.flattened() ?? document.image
        let itemID = params["history"]?.boolValue == false ? nil : LibraryStore.shared.add(document)
        result["id"] = itemID.map { .string($0.uuidString) } ?? .null
        let file = try RemoteFiles.write(image, scale: document.scale, date: document.createdAt,
                                         to: params["out"]?.stringValue, format: params["format"]?.stringValue)
        result["path"] = .string(file.path)
        if let rect = captured.rect {
            result["rect"] = JSONValue(rect)
            result["display"] = RemoteScreens.displayIndex(containing: CGPoint(x: rect.midX, y: rect.midY)).map { .number(Double($0)) } ?? .null
        }
        if let window = captured.window { result["window"] = window }

        if flag("copy") { result["copied"] = .bool(Pasteboard.copy(image, scale: document.scale)) }
        if flag("save") {
            let url = try coordinator.save(image, scale: document.scale, date: document.createdAt)
            if let itemID { LibraryStore.shared.markSaved(itemID, at: url) }
            result["saved_path"] = .string(url.path)
        }
        if flag("upload") {
            do {
                let link = try await Uploader.upload(image, scale: document.scale, date: document.createdAt, libraryItem: itemID,
                                                     copyLink: false, quiet: true)
                result["url"] = .string(link.absoluteString)
            } catch {
                // The capture is kept; say why the upload failed.
                result["upload_error"] = .string(error.localizedDescription)
            }
        }
        if flag("pin") {
            let pin = coordinator.pin(image, scale: document.scale)
            pin.libraryItemID = itemID
            result["pin"] = .string(pin.id.uuidString)
        }
        if flag("edit") {
            coordinator.openEditor(with: document, libraryItem: itemID)
            result["opened"] = true
        }
        return .object(result)
    }
}

/// Image files handed to agents. Without an explicit path they go to the
/// app's caches, where files older than a day are removed.
@MainActor
enum RemoteFiles {
    static var folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.shotdock.ShotDock/Agent", isDirectory: true)

    static func format(for path: String?, explicit: String?) -> ImageFormat {
        if let explicit, let format = ImageFormat(rawValue: explicit) { return format }
        switch (path as NSString?)?.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        default: return .png
        }
    }

    static func write(_ image: CGImage, scale: CGFloat, date: Date, to path: String?, format explicit: String?) throws -> URL {
        let format = format(for: path, explicit: explicit)
        let url: URL
        if let path {
            var target = URL(fileURLWithPath: path)
            if target.pathExtension.isEmpty { target.appendPathExtension(format.fileExtension) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            url = target
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            prune()
            // No spaces: agents paste these paths into shell commands.
            let base = FilenameTemplate("shotdock-{year}{month}{day}-{h}{min}{s}").name(for: date)
            var candidate = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(format.fileExtension)
                counter += 1
            }
            url = candidate
        }
        try ImageEncoding.write(image, to: url, format: format, scale: scale)
        return url
    }

    /// Removes cached files older than a day.
    static func prune() {
        let fileManager = FileManager.default
        let limit = Date().addingTimeInterval(-24 * 3600)
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < limit {
            try? fileManager.removeItem(at: file)
        }
    }
}
