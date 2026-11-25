import AppKit
import CoreImage
import ScreenCaptureKit
import ShotDockCore

/// Non-interactive checks run with `ShotDock --selftest <name> <output>`, so a
/// build can be verified from the command line. Mouse and keyboard input is
/// simulated by sending NSEvents to the real windows. Results go to
/// `selftest.log` next to the output file; any line starting with FAIL fails.
@MainActor
final class SelfTest {
    let app: AppDelegate
    let output: URL
    private var lines: [String] = []

    private init(app: AppDelegate, output: URL) {
        self.app = app
        self.output = output
    }

    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    static func runIfRequested(app: AppDelegate) -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), args.count > index + 2 else { return false }
        let test = SelfTest(app: app, output: URL(fileURLWithPath: args[index + 2]))
        let name = args[index + 1]
        Task { await test.run(name) }
        return true
    }

    private func run(_ name: String) async {
        do {
            switch name {
            case "capture": try await capture()
            case "area": try await area()
            case "editor": try await editor()
            case "branding": try await branding()
            case "modes": try await modes()
            case "prefs": try await prefs()
            case "measure": try await measure()
            case "history": try await history()
            case "pin-ocr": try await pinAndOCR()
            case "backdrop": try await backdrop()
            case "upload": try await upload()
            case "scroll": try await scroll()
            case "dock": try await dock()
            case "magnifier": try await magnifier()
            case "overlay-fidelity": try await overlayFidelity()
            case "cli": try await cli()
            case "cli-capture": try await cliCapture()
            default: fail("unknown selftest \(name)")
            }
        } catch {
            fail(error.localizedDescription)
        }
        let log = output.deletingLastPathComponent().appendingPathComponent("selftest.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func note(_ line: String) { lines.append(line) }
    func fail(_ line: String) { lines.append("FAIL \(line)") }
    func check(_ condition: Bool, _ what: String) { lines.append("\(condition ? "OK" : "FAIL") \(what)") }

    func sibling(_ suffix: String) -> URL {
        let base = output.deletingPathExtension().lastPathComponent
        return output.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix).png")
    }

    // MARK: Tests

    /// Real ScreenCaptureKit capture of every display (needs the permission).
    private func capture() async throws {
        guard ScreenCapturer.hasPermission else { throw ScreenCaptureError.permissionDenied }
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        for snapshot in snapshots {
            note("display \(snapshot.displayID): \(snapshot.image.width)x\(snapshot.image.height) px, frame \(snapshot.frame), scale \(snapshot.scale)")
            check(CGFloat(snapshot.image.width) == snapshot.frame.width * snapshot.scale, "snapshot matches display size")
        }
        let main = snapshots.first { $0.displayID == CGMainDisplayID() } ?? snapshots[0]
        try ImageEncoding.write(main.image, to: output, scale: main.scale)
        note("wrote \(output.path)")
    }

    /// Drags a selection on the overlay and checks the pixels that come out.
    /// Uses real snapshots when permitted, a synthetic one otherwise.
    private func area() async throws {
        let snapshots: [DisplaySnapshot]
        if ScreenCapturer.hasPermission {
            snapshots = try await ScreenCapturer.snapshotAllDisplays()
            note("using real snapshots")
        } else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let scale = screen.backingScaleFactor
            let image = Self.testPattern(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
            snapshots = [DisplaySnapshot(displayID: screen.displayID, image: image, frame: screen.frame, scale: scale)]
            note("no permission: using a synthetic snapshot")
        }
        app.coordinator.beginSelection(over: snapshots)
        try await Task.sleep(for: .milliseconds(300))
        guard let view = app.coordinator.selection?.selectionViews.first, let window = view.window else {
            return fail("overlay did not appear")
        }
        check(window.isVisible && window.level == .screenSaver, "overlay covers the screen")

        // Drag from (100, 120) to (400, 320) in view coordinates (top-left origin).
        let toWindow = { (p: CGPoint) in view.convert(p, to: nil) }
        send(.leftMouseDown, at: toWindow(CGPoint(x: 100, y: 120)), to: window)
        send(.leftMouseDragged, at: toWindow(CGPoint(x: 250, y: 200)), to: window)
        send(.leftMouseDragged, at: toWindow(CGPoint(x: 400, y: 320)), to: window)
        let selection = view.selection
        check(selection == CGRect(x: 100, y: 120, width: 300, height: 200), "selection follows the drag (\(String(describing: selection)))")
        render(view, to: sibling("overlay"))
        send(.leftMouseUp, at: toWindow(CGPoint(x: 400, y: 320)), to: window)
        try await Task.sleep(for: .milliseconds(300))

        check(app.coordinator.selection == nil && !window.isVisible, "overlay closes after selecting")
        guard let editor = app.coordinator.editors.last else { return fail("editor did not open") }
        let image = editor.model.document.image
        let scale = editor.model.document.scale
        check(CGFloat(image.width) == 300 * scale && CGFloat(image.height) == 200 * scale,
              "captured \(image.width)x\(image.height) px at scale \(scale)")
        let pasted = NSPasteboard.general.data(forType: .png).flatMap { try? ImageEncoding.image(from: $0) }
        check(pasted?.width == image.width && pasted?.height == image.height, "capture copied to the clipboard")
        try ImageEncoding.write(image, to: output, scale: scale)
        editor.close()

        // Esc cancels without opening an editor.
        app.coordinator.beginSelection(over: snapshots)
        try await Task.sleep(for: .milliseconds(200))
        if let view = app.coordinator.selection?.selectionViews.first, let window = view.window {
            window.makeFirstResponder(view)
            sendKey(53, to: window)
        }
        try await Task.sleep(for: .milliseconds(200))
        check(app.coordinator.selection == nil && app.coordinator.editors.isEmpty, "Esc cancels the selection")
    }

    /// Draws, moves, edits text, undoes and crops in a real editor window.
    private func editor() async throws {
        let image = Self.testPattern(width: 1200, height: 800, text: "Contraseña: hunter2")
        let editor = app.coordinator.openEditor(with: CaptureDocument(image: image, scale: 2))
        try await Task.sleep(for: .milliseconds(300))
        guard let window = editor.window else { return fail("no editor window") }
        let canvas = editor.canvas
        let model = editor.model
        // Canvas coordinates are image pixels; convert to window points for events.
        let at = { (x: CGFloat, y: CGFloat) in canvas.convert(CGPoint(x: x, y: y), to: nil) }

        model.tool = .arrow
        drag(from: at(100, 100), to: at(500, 300), in: window)
        check(model.document.annotations.count == 1, "arrow drawn")
        if case let .arrow(from, to)? = model.document.annotations.first?.shape {
            check(abs(from.x - 100) < 1 && abs(to.y - 300) < 1, "arrow follows the mouse (\(from) → \(to))")
        }

        model.tool = .rectangle
        drag(from: at(600, 100), to: at(900, 400), in: window)
        check(model.document.annotations.count == 2, "rectangle drawn")

        // Drag the rectangle by its edge: it moves instead of drawing a new one.
        drag(from: at(600, 250), to: at(650, 300), in: window)
        if case let .rectangle(rect)? = model.document.annotations.last?.shape {
            check(model.document.annotations.count == 2 && abs(rect.minX - 650) < 1 && abs(rect.minY - 150) < 1,
                  "rectangle moved to \(rect)")
        }

        model.tool = .text
        send(.leftMouseDown, at: at(150, 550), to: window)
        send(.leftMouseUp, at: at(150, 550), to: window)
        if let fieldEditor = window.firstResponder as? NSTextView {
            fieldEditor.insertText("Hola ShotDock", replacementRange: fieldEditor.selectedRange())
        } else {
            fail("text field did not take focus")
        }
        model.tool = .arrow
        send(.leftMouseDown, at: at(1100, 750), to: window)  // clicking elsewhere commits the text
        send(.leftMouseUp, at: at(1100, 750), to: window)
        let texts = model.document.annotations.compactMap { a -> String? in
            if case let .text(_, string) = a.shape { return string } else { return nil }
        }
        check(texts == ["Hola ShotDock"], "text annotation committed (\(texts))")

        model.undoManager.undo()
        check(!model.document.annotations.contains { if case .text = $0.shape { true } else { false } }, "undo removes the text")
        model.undoManager.redo()
        check(model.document.annotations.count == 3, "redo restores it")

        model.selectedID = model.document.annotations.first?.id
        sendKey(51, to: window)  // Delete
        check(model.document.annotations.count == 2, "Delete removes the selected annotation")
        model.undoManager.undo()

        // Phase 3 tools.
        let before = model.document.annotations.count
        model.tool = .ellipse
        drag(from: at(700, 500), to: at(900, 650), in: window)
        model.tool = .highlight
        drag(from: at(100, 380), to: at(450, 430), in: window)
        model.tool = .step
        for x in [1000, 1080] {
            send(.leftMouseDown, at: at(CGFloat(x), 120), to: window)
            send(.leftMouseUp, at: at(CGFloat(x), 120), to: window)
        }
        let steps = model.document.annotations.compactMap { a -> Int? in if case let .step(_, n) = a.shape { n } else { nil } }
        check(steps == [1, 2], "steps number themselves (\(steps))")
        model.tool = .blur
        drag(from: at(40, 660), to: at(300, 740), in: window)
        model.tool = .pixelate
        drag(from: at(320, 660), to: at(560, 740), in: window)
        model.tool = .eraser
        drag(from: at(580, 660), to: at(820, 740), in: window)
        check(model.document.annotations.count == before + 7, "ellipse, highlight, 2 steps, blur, pixelate, eraser added")

        // Resize the ellipse by its bottom-right handle.
        if let ellipse = model.document.annotations.first(where: { if case .ellipse = $0.shape { true } else { false } }) {
            model.selectedID = ellipse.id
            canvas.needsDisplay = true
            drag(from: at(900, 650), to: at(950, 700), in: window)
            let box = model.document.annotations.first { $0.id == ellipse.id }?.box
            check(box == CGRect(x: 700, y: 500, width: 250, height: 200), "handle resizes the ellipse (\(String(describing: box)))")
            model.undoManager.undo()
            check(model.document.annotations.first { $0.id == ellipse.id }?.box == CGRect(x: 700, y: 500, width: 200, height: 150), "resize undoes in one step")
            model.undoManager.redo()
        }
        try await Task.sleep(for: .milliseconds(200))
        try await snapshot(window, to: sibling("window"))

        model.tool = .crop
        drag(from: at(50, 50), to: at(1000, 700), in: window)
        check(model.document.visibleRect == CGRect(x: 50, y: 50, width: 950, height: 650), "crop applied (\(model.document.visibleRect))")
        check(canvas.bounds == model.document.visibleRect, "canvas shows the cropped area")

        editor.copy(nil)
        let pasted = NSPasteboard.general.data(forType: .png).flatMap { try? ImageEncoding.image(from: $0) }
        check(pasted?.width == 950 && pasted?.height == 650, "copy puts the edited image on the clipboard")

        guard let flat = model.flattened() else { return fail("could not flatten") }
        try ImageEncoding.write(flat, to: output, scale: 2)
        note("wrote \(output.path)")

        // ⇧⌘C: a main-menu shortcut whose action the editor handles. (A synthetic key press
        // only reaches the editor when ShotDock is the active app, which a selftest cannot force.)
        let menuItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(EditorWindowController.copyAndClose(_:)) }
        check(menuItem?.keyEquivalent == "c" && menuItem?.keyEquivalentModifierMask == [.command, .shift], "⇧⌘C is in the Edit menu")
        check(editor.responds(to: #selector(EditorWindowController.copyAndClose(_:))), "the editor handles it")
        NSPasteboard.general.clearContents()
        editor.copyAndClose(nil)
        try await Task.sleep(for: .milliseconds(300))
        let copied = NSPasteboard.general.data(forType: .png).flatMap { try? ImageEncoding.image(from: $0) }
        check(copied?.width == 950 && copied?.height == 650, "⇧⌘C copies the edited image")
        check(app.coordinator.editors.isEmpty && !window.isVisible, "⇧⌘C closes the editor and releases it")
    }

    /// Asset catalog resources: menu bar template, logo in both appearances,
    /// accent colour and app icon.
    private func branding() async throws {
        let menuBar = NSImage(named: "MenuBarIcon")
        check(menuBar != nil && menuBar!.isTemplate && menuBar!.size == NSSize(width: 18, height: 18),
              "menu bar icon is an 18 pt template (\(String(describing: menuBar?.size)))")
        check(NSImage(named: "Logo") != nil, "logo loads")
        check(NSApp.applicationIconImage != nil, "app icon loads")
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        note("controlAccentColor \(String(describing: accent)) (follows the user's system setting unless it is Multicolour)")
        let named = NSColor(named: "AccentColor")?.usingColorSpace(.sRGB)
        check(named.map { abs($0.redComponent - 1) < 0.01 && abs($0.greenComponent - 0x5A / 255.0) < 0.01 } ?? false,
              "AccentColor is #FF5A1F")

        let about = AboutWindowController.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            about.window?.appearance = NSAppearance(named: appearance)
            about.show()
            try await Task.sleep(for: .milliseconds(400))
            if let view = about.window?.contentView?.superview { render(view, to: sibling("about-\(name)")) }
        }
        about.close()

        // Menu bar icon tinted as the system does for light and dark menu bars.
        if let menuBar {
            let size = NSSize(width: 72, height: 36)
            let image = NSImage(size: size, flipped: false) { _ in
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 36, height: 36).fill()
                NSColor.black.setFill(); NSRect(x: 36, y: 0, width: 36, height: 36).fill()
                for (x, color) in [(CGFloat(9), NSColor.black), (45, NSColor.white)] {
                    let tinted = NSImage(size: menuBar.size, flipped: false) { rect in
                        menuBar.draw(in: rect); color.set(); rect.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: x, y: 9, width: 18, height: 18))
                }
                return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: sibling("menubar"))
            }
        }
    }

    /// Every capture mode against the real screen, plus auto-save.
    private func modes() async throws {
        guard ScreenCapturer.hasPermission else { throw ScreenCaptureError.permissionDenied }
        let coordinator = app.coordinator
        let settings = AppSettings.shared
        let folder = output.deletingLastPathComponent().appendingPathComponent("selftest-saved")
        try? FileManager.default.removeItem(at: folder)
        settings.saveFolder = folder
        settings.saveAfterCapture = true
        settings.filenameTemplate = "prueba {n}"

        // Full screen: the display under the pointer.
        coordinator.captureFullscreen()
        try await Task.sleep(for: .seconds(1))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }!
        if let editor = coordinator.editors.last {
            let image = editor.model.document.image
            check(CGFloat(image.width) == screen.frame.width * screen.backingScaleFactor, "full screen \(image.width)x\(image.height)")
            editor.close()
        } else { fail("full screen did not open an editor") }
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check(saved == ["prueba 1.png"], "auto-saved with the name template (\(saved))")

        // Area, then repeat it without selecting.
        settings.saveAfterCapture = false
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        coordinator.beginSelection(over: snapshots)
        try await Task.sleep(for: .milliseconds(300))
        guard let view = coordinator.selection?.selectionViews.first(where: { $0.snapshot.displayID == CGMainDisplayID() }),
              let window = view.window else { return fail("no overlay") }
        drag(from: view.convert(CGPoint(x: 200, y: 200), to: nil), to: view.convert(CGPoint(x: 450, y: 350), to: nil), in: window)
        try await Task.sleep(for: .milliseconds(300))
        let first = coordinator.editors.last?.model.document.image
        coordinator.editors.last?.close()
        check(settings.lastArea?.size == CGSize(width: 250, height: 150), "last area remembered (\(String(describing: settings.lastArea)))")
        coordinator.repeatArea()
        try await Task.sleep(for: .seconds(1))
        let repeated = coordinator.editors.last?.model.document.image
        check(repeated != nil && repeated?.width == first?.width && repeated?.height == first?.height,
              "repeat area captures the same size (\(repeated?.width ?? 0)x\(repeated?.height ?? 0))")
        coordinator.editors.last?.close()

        // Pick a window by hovering and clicking it.
        let windows = try await ScreenCapturer.pickableWindows()
        note("pickable windows: \(windows.count), front: \(windows.first?.title ?? "-")")
        if let target = windows.first(where: { w in NSScreen.screens.contains { $0.frame.contains(w.frame) } }) {
            coordinator.beginSelection(over: snapshots, windows: windows, mode: .window)
            try await Task.sleep(for: .milliseconds(300))
            let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
            guard let view = coordinator.selection?.selectionViews.first(where: { $0.snapshot.frame.contains(center) }),
                  let overlay = view.window else { return fail("no overlay for window mode") }
            let inWindow = overlay.convertPoint(fromScreen: center)
            send(.mouseMoved, at: inWindow, to: overlay)
            check(coordinator.selection?.hoveredWindow?.window.windowID == windows.first { $0.frame.contains(center) }?.window.windowID,
                  "hover highlights the window under the pointer")
            render(view, to: sibling("window-pick"))
            send(.leftMouseDown, at: inWindow, to: overlay)
            send(.leftMouseUp, at: inWindow, to: overlay)
            try await Task.sleep(for: .seconds(1))
            if let editor = coordinator.editors.last {
                let image = editor.model.document.image
                let picked = windows.first { $0.frame.contains(center) }!
                let expected = picked.frame.width * editor.model.document.scale
                check(CGFloat(image.width) >= expected, "window captured \(image.width)x\(image.height) for a \(Int(picked.frame.width)) pt wide window")
                try ImageEncoding.write(image, to: sibling("window"), scale: editor.model.document.scale)
                editor.close()
            } else { fail("window pick did not open an editor") }
        }

        // Delayed capture: countdown, then the overlay; Esc cancels.
        settings.captureDelay = 1
        coordinator.captureDelayed()
        try await Task.sleep(for: .milliseconds(2200))
        check(coordinator.selection != nil, "delayed capture shows the overlay after the countdown")
        if let view = coordinator.selection?.selectionViews.first, let window = view.window { sendKey(53, to: window) }
        try await Task.sleep(for: .milliseconds(200))
        check(coordinator.selection == nil, "Esc closes it")
    }

    /// The frozen screen must look exactly like the real one: compares a
    /// capture of the screen with a capture of the overlay showing it.
    private func overlayFidelity() async throws {
        guard ScreenCapturer.hasPermission, let screen = NSScreen.main else { throw ScreenCaptureError.permissionDenied }
        note("screen colour space: \(screen.colorSpace?.localizedName ?? "?") / \(String(describing: screen.colorSpace?.cgColorSpace?.name))")
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        let start = Date()
        app.coordinator.beginSelection(over: snapshots)
        guard let view = app.coordinator.selection?.selectionViews.first(where: { $0.snapshot.displayID == screen.displayID }) else {
            return fail("no overlay")
        }
        note("overlay shown in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        try await Task.sleep(for: .milliseconds(400))
        // Capture what is on screen now, overlay included.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays.first { $0.displayID == screen.displayID }!
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = view.snapshot.image.width
        config.height = view.snapshot.image.height
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = view.snapshot.image.colorSpace?.name ?? CGColorSpace.sRGB
        let shown = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if let view = app.coordinator.selection?.selectionViews.first, let window = view.window { sendKey(53, to: window) }

        // Compare a grid of pixels away from the pointer (crosshair and loupe).
        let original = view.snapshot.image
        let mouse = NSEvent.mouseLocation
        let pointer = CGPoint(x: (mouse.x - screen.frame.minX) * view.snapshot.scale, y: (screen.frame.maxY - mouse.y) * view.snapshot.scale)
        var compared = 0, worst = 0, total = 0
        for gx in stride(from: 40, to: original.width - 40, by: original.width / 40) {
            for gy in stride(from: 60, to: original.height - 40, by: original.height / 30) {
                if abs(CGFloat(gx) - pointer.x) < 420 || abs(CGFloat(gy) - pointer.y) < 420 { continue }
                guard let a = Measure.color(in: original, at: CGPoint(x: gx, y: gy)), let b = Measure.color(in: shown, at: CGPoint(x: gx, y: gy)) else { continue }
                let d = Int(max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255)
                worst = max(worst, d); total += d; compared += 1
            }
        }
        note("compared \(compared) pixels: worst difference \(worst), mean \(String(format: "%.2f", Double(total) / Double(max(compared, 1))))")
        check(compared > 50 && worst <= 3, "frozen screen matches the real one")
    }

    /// The magnifier annotation: select a source, the enlargement appears beside it.
    private func magnifier() async throws {
        let image = Self.testPattern(width: 1200, height: 800, text: "Detalle pequeño")
        let editor = app.coordinator.openEditor(with: CaptureDocument(image: image, scale: 2))
        try await Task.sleep(for: .milliseconds(300))
        guard let window = editor.window else { return fail("no editor") }
        let model = editor.model
        let at = { (x: CGFloat, y: CGFloat) in editor.canvas.convert(CGPoint(x: x, y: y), to: nil) }

        model.tool = .magnifier
        drag(from: at(60, 670), to: at(260, 730), in: window)
        guard case let .magnifier(source, target, round)? = model.document.annotations.last?.shape else { return fail("no magnifier added") }
        check(source == CGRect(x: 60, y: 670, width: 200, height: 60), "source is the dragged area (\(source))")
        check(round && abs(target.width / source.width - 2) < 0.01 && model.document.visibleRect.contains(target),
              "enlarged 2× inside the image (\(target))")

        // Drag the enlargement: only it moves.
        model.tool = .arrow
        drag(from: at(target.midX, target.midY), to: at(target.midX, target.midY - 300), in: window)
        guard case let .magnifier(s2, t2, _)? = model.document.annotations.last?.shape else { return fail("lost the magnifier") }
        check(s2 == source && abs(t2.minY - (target.minY - 300)) < 1, "dragging the enlargement leaves the source (\(t2))")

        // Resize the enlargement from its bottom-right handle: aspect ratio kept.
        model.selectedID = model.document.annotations.last?.id
        drag(from: at(t2.maxX, t2.maxY), to: at(t2.maxX + 200, t2.maxY), in: window)
        if case let .magnifier(_, t3, _)? = model.document.annotations.last?.shape {
            check(abs(t3.width - (t2.width + 200)) < 1 && abs(t3.width / t3.height - source.width / source.height) < 0.01,
                  "handle resizes keeping the aspect (\(t3))")
        }
        model.magnifierRound = false
        if case let .magnifier(_, _, r)? = model.document.annotations.last?.shape { check(!r, "shape switches to a rectangle") }
        try await Task.sleep(for: .milliseconds(200))
        try await snapshot(window, to: sibling("magnifier"))
        model.undoManager.undo()
        if case let .magnifier(_, _, r)? = model.document.annotations.last?.shape { check(r, "undo restores the circle") }
        editor.close()
    }

    /// Dock icon while a window is open, menu-bar-only otherwise.
    private func dock() async throws {
        check(NSApp.activationPolicy() == .accessory, "starts as a menu bar app")
        app.showGallery()
        try await Task.sleep(for: .seconds(1.5))
        check(NSApp.activationPolicy() == .regular, "shows in the Dock with the gallery open")
        if ScreenCapturer.hasPermission {
            let snapshot = try await ScreenCapturer.snapshotDisplay(containing: CGPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.midY))
            try ImageEncoding.write(snapshot.image, to: sibling("screen"), scale: snapshot.scale)
        }
        app.gallery?.close()
        try await Task.sleep(for: .milliseconds(500))
        check(NSApp.activationPolicy() == .accessory, "back to the menu bar when it closes")
    }

    /// Scrolling capture: synthetic scrolling frames, then the real path over the screen.
    private func scroll() async throws {
        let coordinator = app.coordinator
        AppSettings.shared.openEditorAfterCapture = true
        AppSettings.shared.copyAfterCapture = false

        // A tall page seen through a 600 × 400 px window that scrolls 90 px per frame.
        let page = Self.testPattern(width: 600, height: 2000, text: nil)
        let pageContext = CGContext(data: nil, width: 600, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pageContext.draw(page, in: CGRect(x: 0, y: 0, width: 600, height: 2000))
        pageContext.flipVertically(height: 2000)
        for y in stride(from: 20, to: 2000, by: 40) {
            TextLayout(string: "Línea \(y / 40) del documento largo", fontSize: 20, color: CGColor(gray: 0.1, alpha: 1))
                .draw(at: CGPoint(x: 30, y: CGFloat(y)), in: pageContext)
        }
        let tall = pageContext.makeImage()!
        var offset = 0
        let source: ScrollCaptureSession.FrameSource = {
            offset = min(offset + 90, 1600)
            return tall.cropping(to: CGRect(x: 0, y: offset, width: 600, height: 400))!
        }
        let first = tall.cropping(to: CGRect(x: 0, y: 0, width: 600, height: 400))!
        let screen = NSScreen.main!
        let area = CGRect(x: screen.frame.midX - 150, y: screen.frame.midY - 100, width: 300, height: 200)
        coordinator.startScrolling(AreaSelectionController.Result(image: first, scale: 2, screenRect: area, displayID: screen.displayID),
                                   frameSource: source)
        guard let session = coordinator.scrollSession else { return fail("no scroll session") }
        while offset < 1600 { await session.captureFrame() }
        check(session.state.height == 2000, "stitched the whole page (\(session.state.height) px, \(session.state.frames) frames)")
        session.finish()
        try await Task.sleep(for: .milliseconds(300))
        guard let editor = coordinator.editors.last else { return fail("no editor after scrolling") }
        let result = editor.model.document.image
        check(result.width == 600 && result.height == 2000, "editor gets the tall image (\(result.width)x\(result.height))")
        try ImageEncoding.write(result, to: sibling("scroll"), scale: 2)
        editor.close()

        // Real path: shortcut → overlay → drag → frames from the screen → Return.
        guard ScreenCapturer.hasPermission else { return note("skipping the real scroll path: no permission") }
        coordinator.captureScrolling()
        try await waitFor(seconds: 5) { coordinator.selection != nil }
        guard let view = coordinator.selection?.selectionViews.first(where: { $0.snapshot.displayID == CGMainDisplayID() }),
              let overlay = view.window else { return fail("no overlay for scrolling") }
        drag(from: view.convert(CGPoint(x: 300, y: 300), to: nil), to: view.convert(CGPoint(x: 600, y: 500), to: nil), in: overlay)
        try await Task.sleep(for: .seconds(1))
        guard let real = coordinator.scrollSession else { return fail("selecting did not start a scroll session") }
        check(real.state.frames >= 1, "real frames captured (\(real.state.frames), \(real.state.height) px)")
        real.finish()
        try await Task.sleep(for: .milliseconds(300))
        let realImage = coordinator.editors.last?.model.document.image
        check(realImage.map { $0.width == 600 && $0.height >= 400 } ?? false, "real scrolling capture opens (\(realImage?.width ?? 0)x\(realImage?.height ?? 0))")
        coordinator.editors.last?.close()
    }

    /// Uploads to scripts/mock-s3.py on port 9555 (start it first).
    private func upload() async throws {
        let settings = AppSettings.shared
        var config = S3Configuration()
        config.provider = .minio
        config.endpoint = "http://127.0.0.1:9555"
        config.region = "eu-west-1"
        config.bucket = "capturas"
        config.prefix = "shotdock"
        config.pathStyle = true
        config.linkMode = .presigned
        config.presignExpiry = 3600
        settings.s3 = config
        defer { Keychain.saveS3Credentials(nil) }
        check(Keychain.saveS3Credentials(S3Credentials(accessKeyID: "test", secretAccessKey: "testsecret")), "keys saved in the keychain")
        check(Keychain.loadS3Credentials()?.secretAccessKey == "testsecret", "keys read back from the keychain")
        check(Uploader.isConfigured, "upload configured")

        let key = try await Uploader.testConnection()
        note("test connection uploaded and deleted \(key)")

        // A capture with "upload after capture" on: the link lands on the clipboard.
        settings.uploadAfterCapture = true
        settings.openEditorAfterCapture = false
        settings.copyAfterCapture = true
        NSPasteboard.general.clearContents()
        let image = Self.testPattern(width: 640, height: 400, text: "Subida")
        app.coordinator.finish(CaptureDocument(image: image, scale: 2))
        let started = Date()
        while NSPasteboard.general.string(forType: .string) == nil, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let linkString = NSPasteboard.general.string(forType: .string), let link = URL(string: linkString) else {
            return fail("no link on the clipboard")
        }
        note("link: \(linkString.prefix(110))…")
        check(linkString.contains("/capturas/shotdock/shotdock-") && linkString.contains("X-Amz-Signature="), "presigned link to the object")
        let (data, response) = try await URLSession.shared.data(from: link)
        let downloaded = try? ImageEncoding.image(from: data)
        check((response as? HTTPURLResponse)?.statusCode == 200 && downloaded?.width == 640, "the link downloads the PNG (\(downloaded?.width ?? 0) px)")
        try await Task.sleep(for: .milliseconds(200))
        check(LibraryStore.shared.items.first?.uploadedURL == linkString, "history remembers the link")

        // Wrong keys: a clear error, nothing copied.
        Keychain.saveS3Credentials(S3Credentials(accessKeyID: "test", secretAccessKey: "wrong"))
        do {
            try await Uploader.upload(image, scale: 2, date: Date(), libraryItem: nil)
            fail("upload with a wrong secret succeeded")
        } catch {
            check(error.localizedDescription.contains("SignatureDoesNotMatch"), "wrong secret: \(error.localizedDescription)")
        }

        app.openPreferences(tab: .upload)
        try await Task.sleep(for: .milliseconds(500))
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
            try await snapshot(window, to: sibling("prefs-upload"))
        }
    }

    /// The backdrop panel: on/off, presets, live sliders with one undo step.
    private func backdrop() async throws {
        let image = Self.testPattern(width: 1000, height: 600, text: "Fondo")
        let editor = app.coordinator.openEditor(with: CaptureDocument(image: image, scale: 2))
        try await Task.sleep(for: .milliseconds(300))
        let model = editor.model
        AppSettings.shared.lastBackdrop = Backdrop()
        editor.toggleBackdropPanel(nil)
        check(editor.isBackdropPanelVisible && model.backdrop != nil, "panel opens and turns the backdrop on")
        check(model.flattened()?.width == 1000 + 2 * 96, "export includes the 48 pt margin")
        check(editor.canvas.bounds == model.document.layout.canvas, "canvas shows the backdrop")

        // A slider drag: many live changes, one undo step.
        for padding in stride(from: 50, through: 90, by: 10) {
            var b = model.backdrop!
            b.padding = CGFloat(padding)
            model.updateBackdrop(b, live: true)
        }
        model.commitBackdropEdit()
        check(model.backdrop?.padding == 90, "live padding applied")
        var b = model.backdrop!
        b.fill = Backdrop.presets[2]
        b.aspect = .wide
        model.updateBackdrop(b)
        check(model.flattened().map { abs(CGFloat($0.width) / CGFloat($0.height) - 16.0 / 9.0) < 0.01 } ?? false, "16:9 export")
        try await Task.sleep(for: .milliseconds(300))
        try await snapshot(editor.window!, to: sibling("backdrop"))
        model.undoManager.undo()
        check(model.backdrop?.aspect == .auto && model.backdrop?.padding == 90, "undo reverts the preset change")
        model.undoManager.undo()
        check(model.backdrop?.padding == 48, "the slider drag undoes in one step (\(model.backdrop?.padding ?? -1))")
        model.setBackdropEnabled(false)
        check(model.flattened()?.width == 1000, "turning it off exports the capture alone")
        if let flat = model.flattened() { try ImageEncoding.write(flat, to: output, scale: 2) }
        editor.close()
    }

    /// Pinned images, OCR from the shortcut and from the editor, QR codes.
    private func pinAndOCR() async throws {
        let coordinator = app.coordinator
        let image = Self.testPattern(width: 800, height: 400, text: "Fijada")
        let pin = coordinator.pin(image, scale: 2)
        try await Task.sleep(for: .milliseconds(300))
        guard let window = pin.window else { return fail("no pin window") }
        check(window.level == .floating && window.isVisible, "pin floats above other windows")
        check(window.frame.size == CGSize(width: 400, height: 200), "pin shows at point size (\(window.frame.size))")
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "5", charactersIgnoringModifiers: "5", isARepeat: false, keyCode: 23) {
            window.contentView?.keyDown(with: event)
        }
        check(abs(window.alphaValue - 0.5) < 0.01, "key 5 sets 50 % opacity")
        pin.setZoom(2)
        check(window.frame.size == CGSize(width: 800, height: 400), "zoom 200 %")
        pin.opacity = 1
        try await snapshot(window, to: sibling("pin"))
        pin.clickThrough = true
        check(window.ignoresMouseEvents, "click-through")
        coordinator.restorePinClicks()
        check(!window.ignoresMouseEvents, "clicks restored")
        sendKey(53, to: window)
        try await Task.sleep(for: .milliseconds(200))
        check(coordinator.pins.isEmpty, "Esc closes the pin")

        // Global OCR over a frozen screen with text and a QR code.
        let screen = NSScreen.main!
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.flipVertically(height: CGFloat(h))
        TextLayout(string: "Hola desde ShotDock", fontSize: 28 * scale, color: CGColor(gray: 0, alpha: 1))
            .draw(at: CGPoint(x: 100 * scale, y: 100 * scale), in: ctx)
        let qrPayload = "https://github.com/kayakman/shotdock"
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(qrPayload.utf8)])!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 6 * scale, y: 6 * scale))
        let qrImage = CIContext().createCGImage(qr, from: qr.extent)!
        ctx.drawImageTopLeft(qrImage, in: CGRect(x: 100 * scale, y: 300 * scale, width: CGFloat(qrImage.width), height: CGFloat(qrImage.height)))
        let snapshotImage = DisplaySnapshot(displayID: screen.displayID, image: ctx.makeImage()!, frame: screen.frame, scale: scale)

        coordinator.onRecognized = { [weak self] image, result in
            guard let self else { return }
            note("recognised \(image.width)x\(image.height): \(result.lines) \(result.codes)")
            try? ImageEncoding.write(image, to: sibling("ocr-input-\(image.width)"))
        }
        for (rect, expected) in [(CGRect(x: 80, y: 80, width: 420, height: 80), "Hola desde ShotDock"),
                                 (CGRect(x: 80, y: 280, width: CGFloat(qrImage.width) / scale + 40, height: CGFloat(qrImage.height) / scale + 40), qrPayload)] {
            NSPasteboard.general.clearContents()
            coordinator.beginSelection(over: [snapshotImage], purpose: .recognize)
            try await Task.sleep(for: .milliseconds(300))
            guard let view = coordinator.selection?.selectionViews.first, let overlay = view.window else { return fail("no overlay") }
            drag(from: view.convert(rect.origin, to: nil), to: view.convert(CGPoint(x: rect.maxX, y: rect.maxY), to: nil), in: overlay)
            let started = Date()
            while NSPasteboard.general.string(forType: .string) == nil, Date().timeIntervalSince(started) < 30 {
                try await Task.sleep(for: .milliseconds(200))
            }
            note("OCR took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            let copied = NSPasteboard.general.string(forType: .string)
            check(copied == expected, "OCR copies \"\(copied ?? "-")\"")
            check(coordinator.editors.isEmpty, "OCR does not open an editor")
        }

        // The real shortcut path keeps the OCR purpose through the selection.
        if ScreenCapturer.hasPermission {
            var recognised = false
            coordinator.onRecognized = { _, _ in recognised = true }
            coordinator.recognizeText()
            try await waitFor(seconds: 5) { coordinator.selection != nil }
            if let view = coordinator.selection?.selectionViews.first(where: { $0.snapshot.displayID == CGMainDisplayID() }), let overlay = view.window {
                drag(from: view.convert(CGPoint(x: 100, y: 100), to: nil), to: view.convert(CGPoint(x: 500, y: 300), to: nil), in: overlay)
                try await Task.sleep(for: .seconds(2))
                check(recognised && coordinator.editors.isEmpty, "OCR shortcut recognises instead of capturing")
            } else { fail("no overlay for the OCR shortcut") }
        }

        // OCR from the editor shows a sheet.
        let editor = coordinator.openEditor(with: CaptureDocument(image: snapshotImage.image.cropping(to: CGRect(x: 0, y: 0, width: 1400, height: 1400))!, scale: scale))
        try await Task.sleep(for: .milliseconds(300))
        editor.recognizeText(nil)
        let started = Date()
        while editor.window?.attachedSheet == nil, Date().timeIntervalSince(started) < 30 { try await Task.sleep(for: .milliseconds(200)) }
        check(editor.window?.attachedSheet != nil, "editor shows the recognised text")
        try ImageEncoding.write(editor.model.flattened()!, to: sibling("ocr-editor"))
        let editorResult = try await TextRecognition.recognize(editor.model.flattened()!)
        check(editorResult.lines == ["Hola desde ShotDock"] && editorResult.codes == [qrPayload],
              "small text and QR found in a large capture (\(editorResult.lines), \(editorResult.codes))")
        if let sheet = editor.window?.attachedSheet { try await snapshot(sheet, to: sibling("ocr-sheet")) }
        editor.window?.attachedSheet.map { editor.window?.endSheet($0) }
        editor.close()
    }

    /// Captures land in the history; editing from it persists; the gallery shows them.
    private func history() async throws {
        let settings = AppSettings.shared
        let store = LibraryStore.shared
        settings.openEditorAfterCapture = false
        settings.copyAfterCapture = false
        for (i, text) in ["Primera", "Segunda", "Tercera"].enumerated() {
            let image = Self.testPattern(width: 900 + i * 200, height: 600, text: text)
            app.coordinator.finish(CaptureDocument(image: image, scale: 2, createdAt: Date(timeIntervalSinceNow: Double(i - 3) * 3600)))
        }
        check(store.items.count == 3, "three captures in the history (\(store.items.count))")
        guard let newest = store.items.first else { return }
        check(newest.pixelWidth == 1300, "newest first")

        // Edit from the history; closing writes the annotations back.
        app.coordinator.openEditor(libraryItem: newest.id)
        try await Task.sleep(for: .milliseconds(300))
        guard let editor = app.coordinator.editors.last, let window = editor.window else { return fail("history item did not open") }
        let at = { (x: CGFloat, y: CGFloat) in editor.canvas.convert(CGPoint(x: x, y: y), to: nil) }
        editor.model.tool = .rectangle
        drag(from: at(100, 100), to: at(600, 400), in: window)
        editor.model.tool = .crop
        drag(from: at(50, 50), to: at(1000, 500), in: window)
        editor.close()
        let updated = store.items.first { $0.id == newest.id }
        check(updated?.annotationCount == 1 && updated?.pixelWidth == 950, "edits saved to the history (\(String(describing: updated)))")
        app.coordinator.openEditor(libraryItem: newest.id)
        try await Task.sleep(for: .milliseconds(200))
        check(app.coordinator.editors.last?.model.document.annotations.count == 1, "reopening restores the annotations")
        app.coordinator.openEditor(libraryItem: newest.id)
        check(app.coordinator.editors.count == 1, "opening it again focuses the same editor")
        app.coordinator.editors.last?.close()

        app.showGallery()
        try await Task.sleep(for: .milliseconds(600))
        if let gallery = app.gallery, let window = gallery.window {
            gallery.selection = [newest.id]
            try await Task.sleep(for: .milliseconds(200))
            try await snapshot(window, to: sibling("gallery"))
            check(store.exportForDrag(newest.id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "drag exports a PNG")
        } else { fail("no gallery window") }

        settings.historyLimit = 2
        store.applyLimit()
        check(store.items.count == 2, "history trimmed to the limit")
        store.delete([newest.id])
        check(store.items.count == 1 && store.items.first?.id != newest.id, "delete removes it")
    }

    /// Ruler, eyedropper and loupe, in the editor and on the frozen screen.
    private func measure() async throws {
        // Test pattern with an orange 300 × 120 px box at (400, 300).
        let base = Self.testPattern(width: 1200, height: 800)
        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(base, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        context.flipVertically(height: 800)
        context.setFillColor(red: 1, green: 90.0 / 255, blue: 31.0 / 255, alpha: 1)
        context.fill(CGRect(x: 420, y: 320, width: 300, height: 120))
        let image = context.makeImage()!

        let editor = app.coordinator.openEditor(with: CaptureDocument(image: image, scale: 2))
        try await Task.sleep(for: .milliseconds(300))
        guard let window = editor.window else { return fail("no editor") }
        let at = { (x: CGFloat, y: CGFloat) in editor.canvas.convert(CGPoint(x: x, y: y), to: nil) }

        editor.model.tool = .ruler
        send(.mouseMoved, at: at(500, 380), to: window)
        editor.canvas.display()
        try await snapshot(window, to: sibling("ruler"))
        send(.leftMouseDown, at: at(500, 380), to: window)
        send(.leftMouseUp, at: at(500, 380), to: window)
        check(NSPasteboard.general.string(forType: .string) == "300 × 120", "ruler click copies the box size (\(NSPasteboard.general.string(forType: .string) ?? "-"))")
        drag(from: at(100, 100), to: at(250, 180), in: window)
        check(NSPasteboard.general.string(forType: .string) == "150 × 80", "ruler drag copies the dragged size")

        editor.model.tool = .colorPicker
        send(.mouseMoved, at: at(430, 330), to: window)
        send(.leftMouseDown, at: at(430, 330), to: window)
        send(.leftMouseUp, at: at(430, 330), to: window)
        check(NSPasteboard.general.string(forType: .string) == "#FF5A1F", "eyedropper copies HEX (\(NSPasteboard.general.string(forType: .string) ?? "-"))")
        AppSettings.shared.colorFormat = .rgb
        send(.leftMouseDown, at: at(430, 330), to: window)
        send(.leftMouseUp, at: at(430, 330), to: window)
        check(NSPasteboard.general.string(forType: .string) == "rgb(255, 90, 31)", "eyedropper copies RGB when chosen")
        AppSettings.shared.colorFormat = .hex
        editor.close()

        // Global eyedropper over a frozen (synthetic) screen.
        let screen = NSScreen.main!
        let scale = screen.backingScaleFactor
        let frozen = CGContext(data: nil, width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale),
                               bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        frozen.draw(image, in: CGRect(x: 0, y: CGFloat(frozen.height) - 800, width: 1200, height: 800))
        let snapshot = DisplaySnapshot(displayID: screen.displayID, image: frozen.makeImage()!, frame: screen.frame, scale: scale)
        app.coordinator.beginSelection(over: [snapshot], mode: .color)
        try await Task.sleep(for: .milliseconds(300))
        guard let view = app.coordinator.selection?.selectionViews.first, let overlay = view.window else { return fail("no overlay") }
        let point = view.convert(CGPoint(x: 430 / scale, y: 330 / scale), to: nil)
        send(.mouseMoved, at: point, to: overlay)
        render(view, to: sibling("loupe"))
        send(.leftMouseDown, at: point, to: overlay)
        try await Task.sleep(for: .milliseconds(200))
        check(app.coordinator.selection == nil, "picking a colour closes the overlay")
        check(NSPasteboard.general.string(forType: .string) == "#FF5A1F", "global eyedropper copies the colour")
    }

    /// Preferences window, shortcut recorder and the Shottr import.
    private func prefs() async throws {
        let settings = AppSettings.shared
        app.showPreferences()
        try await Task.sleep(for: .milliseconds(500))
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) else { return fail("no preferences window") }
        check(window.title == "General" && window.toolbar != nil, "preferences open on General with toolbar tabs")
        for tab in PreferencesTab.allCases {
            app.openPreferences(tab: tab)
            try await Task.sleep(for: .milliseconds(400))
            check(window.title == tab.title, "tab \(tab.title) selected and titled")
            try await snapshot(window, to: sibling("pane-\(tab.rawValue)"))
        }

        // A Shottr file with the values found on the developer's Mac.
        let plist: [String: Any] = [
            "KeyboardShortcuts_area": #"{"carbonModifiers":768,"carbonKeyCode":23}"#,
            "KeyboardShortcuts_repeatArea": #"{"carbonKeyCode":23,"carbonModifiers":2816}"#,
            "KeyboardShortcuts_window": #"{"carbonKeyCode":19,"carbonModifiers":768}"#,
            "KeyboardShortcuts_anyWindow": #"{"carbonModifiers":768,"carbonKeyCode":20}"#,
            "KeyboardShortcuts_fullscreen": #"{"carbonModifiers":768,"carbonKeyCode":21}"#,
            "KeyboardShortcuts_ocr": #"{"carbonModifiers":6400,"carbonKeyCode":31}"#,
        ]
        let file = output.deletingLastPathComponent().appendingPathComponent("selftest-shottr.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file)
        let result = try ShottrImport.parse(plistData: Data(contentsOf: file))
        note("import summary:\n" + ShottrImporter.summary(of: result))
        settings.shortcuts.apply(result)
        try await Task.sleep(for: .milliseconds(100))
        check(KeyComboFormatter.string(for: settings.shortcuts.combo(for: .captureArea)!) == "⇧⌘5", "area is ⇧⌘5")
        check(KeyComboFormatter.string(for: settings.shortcuts.combo(for: .repeatArea)!) == "⌥⇧⌘5", "repeat is ⌥⇧⌘5")
        check(KeyComboFormatter.string(for: settings.shortcuts.combo(for: .recognizeText)!) == "⌃⌥⌘O", "OCR is ⌃⌥⌘O")
        check(app.shortcuts.failed.isEmpty, "all hotkeys registered (failed: \(app.shortcuts.failed.map(\.rawValue)))")

        app.openPreferences(tab: .shortcuts)
        try await Task.sleep(for: .milliseconds(400))
        // Record ⌃⌥D for the delayed capture with the recorder button.
        guard let recorder = Self.find(RecorderButton.self, in: window.contentView!).first(where: { $0.title == "Sin atajo" }) else {
            return fail("no empty recorder found")
        }
        recorder.performClick(nil)
        check(recorder.title == "Pulsa el atajo…", "recorder waits for keys")
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2) {
            recorder.keyDown(with: event)
        }
        try await Task.sleep(for: .milliseconds(200))
        let recorded = ShortcutAction.allCases.first { settings.shortcuts.combo(for: $0) == KeyCombo(keyCode: 2, modifiers: KeyCombo.control | KeyCombo.option) }
        check(recorded != nil, "recorded ⌃⌥D for \(recorded?.title ?? "nothing")")
        check(app.shortcuts.failed.isEmpty, "hotkeys re-registered after the change")

        // Editor shortcuts: ⇧⌘C by default, configurable, reflected in the main menu.
        func menuItem(_ selector: Selector) -> NSMenuItem? {
            NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == selector }
        }
        let copyClose = #selector(EditorWindowController.copyAndClose(_:))
        check(menuItem(copyClose)?.keyEquivalent == "c" && menuItem(copyClose)?.keyEquivalentModifierMask == [.command, .shift],
              "Copiar y cerrar is ⇧⌘C in the menu")
        settings.editorShortcuts.set(KeyCombo(keyCode: 0x08, modifiers: KeyCombo.command | KeyCombo.option), for: .copyAndClose)
        try await Task.sleep(for: .milliseconds(200))
        check(menuItem(copyClose)?.keyEquivalentModifierMask == [.command, .option], "changing it updates the menu (⌥⌘C)")
        // Giving ⌥⌘C to a global shortcut takes it away from the editor.
        settings.editorShortcuts.release(KeyCombo(keyCode: 0x08, modifiers: KeyCombo.command | KeyCombo.option))
        settings.shortcuts.set(KeyCombo(keyCode: 0x08, modifiers: KeyCombo.command | KeyCombo.option), for: .pickColor)
        try await Task.sleep(for: .milliseconds(200))
        check(settings.editorShortcuts.combo(for: .copyAndClose) == nil && menuItem(copyClose)?.keyEquivalent == "",
              "a combo has one use across global and editor shortcuts")
        settings.editorShortcuts = EditorShortcutSettings()
        try await Task.sleep(for: .milliseconds(200))
        check(menuItem(copyClose)?.keyEquivalentModifierMask == [.command, .shift], "reset restores ⇧⌘C")
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }

    // MARK: Helpers

    private func waitFor(seconds: Double, _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < seconds { try await Task.sleep(for: .milliseconds(100)) }
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint, to window: NSWindow, clicks: Int = 1) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clicks, pressure: 1) else { return }
        window.sendEvent(event)
    }

    private func drag(from start: CGPoint, to end: CGPoint, in window: NSWindow) {
        send(.leftMouseDown, at: start, to: window)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            send(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), to: window)
        }
        send(.leftMouseUp, at: end, to: window)
    }

    private func sendKey(_ keyCode: UInt16, to window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else { return }
        window.sendEvent(event)
    }

    /// Real screenshot of one of our windows (needs Screen Recording).
    private func snapshot(_ window: NSWindow, to url: URL) async throws {
        guard ScreenCapturer.hasPermission else { return render(window.contentView!, to: url) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            return fail("window not found for snapshot")
        }
        let (image, scale) = try await ScreenCapturer.capture(window: scWindow, shadow: false)
        try ImageEncoding.write(image, to: url, scale: scale)
        note("captured \(url.lastPathComponent)")
    }

    /// Saves what a view draws, so the UI can be inspected without screen capture.
    private func render(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        note("rendered \(url.lastPathComponent)")
    }

    /// A gradient with a grid, easy to recognise in rendered output.
    static func testPattern(width: Int, height: Int, text: String? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(red: 0.85, green: 0.9, blue: 1, alpha: 1),
                                           CGColor(red: 1, green: 0.95, blue: 0.85, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        for x in stride(from: 0, to: width, by: 100) { context.stroke(CGRect(x: x, y: 0, width: 1, height: height)) }
        for y in stride(from: 0, to: height, by: 100) { context.stroke(CGRect(x: 0, y: y, width: width, height: 1)) }
        if let text {
            context.flipVertically(height: CGFloat(height))
            for (i, x) in [60, 340, 600].enumerated() {
                TextLayout(string: text, fontSize: 22 + CGFloat(i) * 2, color: CGColor(gray: 0.1, alpha: 1))
                    .draw(at: CGPoint(x: CGFloat(x), y: 685), in: context)
            }
        }
        return context.makeImage()!
    }
}
