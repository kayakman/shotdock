import AppKit
import ShotDockCore

/// Non-interactive checks run with `ShotDock --selftest <name> <output>`, so a
/// build can be verified from the command line. Mouse and keyboard input is
/// simulated by sending NSEvents to the real windows. Results go to
/// `selftest.log` next to the output file; any line starting with FAIL fails.
@MainActor
final class SelfTest {
    private let app: AppDelegate
    private let output: URL
    private var lines: [String] = []

    private init(app: AppDelegate, output: URL) {
        self.app = app
        self.output = output
    }

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
            default: fail("unknown selftest \(name)")
            }
        } catch {
            fail(error.localizedDescription)
        }
        let log = output.deletingLastPathComponent().appendingPathComponent("selftest.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func note(_ line: String) { lines.append(line) }
    private func fail(_ line: String) { lines.append("FAIL \(line)") }
    private func check(_ condition: Bool, _ what: String) { lines.append("\(condition ? "OK" : "FAIL") \(what)") }

    private func sibling(_ suffix: String) -> URL {
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
        let image = Self.testPattern(width: 1200, height: 800)
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

        render(window.contentView!, to: sibling("window"))

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
        editor.close()
        check(app.coordinator.editors.isEmpty, "closing releases the editor")
    }

    // MARK: Helpers

    private func send(_ type: NSEvent.EventType, at point: CGPoint, to window: NSWindow, clicks: Int = 1) {
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

    /// Saves what a view draws, so the UI can be inspected without screen capture.
    private func render(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        note("rendered \(url.lastPathComponent)")
    }

    /// A gradient with a grid, easy to recognise in rendered output.
    static func testPattern(width: Int, height: Int) -> CGImage {
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
        return context.makeImage()!
    }
}
