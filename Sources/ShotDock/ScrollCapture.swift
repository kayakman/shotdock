import AppKit
import ApplicationServices
import ShotDockCore
import SwiftUI

/// Scrolling capture: after selecting an area, the user scrolls (or lets
/// ShotDock scroll) and frames are stitched into one tall image.
@MainActor
final class ScrollCaptureSession {
    typealias FrameSource = () async throws -> CGImage

    let area: CGRect
    let scale: CGFloat
    private let frameSource: FrameSource
    private let stitcher: ScrollStitcher
    private let completion: (CGImage?) -> Void
    private var border: NSPanel?
    private var controls: NSPanel?
    private var loop: Task<Void, Never>?
    private var finished = false
    private var keyMonitor: Any?
    let state = ScrollCaptureState()

    init(area: CGRect, scale: CGFloat, firstFrame: CGImage, maxHeight: Int, frameSource: @escaping FrameSource,
         completion: @escaping (CGImage?) -> Void) {
        self.area = area
        self.scale = scale
        self.frameSource = frameSource
        self.completion = completion
        stitcher = ScrollStitcher(width: firstFrame.width, height: firstFrame.height, maxHeight: maxHeight)
        stitcher.add(firstFrame)
        state.height = stitcher.currentHeight
        state.frames = 1
        state.canAutoScroll = AXIsProcessTrusted()
    }

    func start() {
        showBorder()
        showControls()
        // Return finishes, Esc cancels, even while another app has focus.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 36 { self?.finish() } else if event.keyCode == 53 { self?.cancel() }
            }
        }
        loop = Task { [weak self] in
            while let self, !self.finished, !Task.isCancelled {
                await self.captureFrame()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Captures one frame and stitches it. Exposed for selftests.
    @discardableResult
    func captureFrame() async -> ScrollStitcher.AddResult? {
        guard !finished, let image = try? await frameSource() else { return nil }
        let result = stitcher.add(image)
        state.height = stitcher.currentHeight
        state.frames = stitcher.frameCount
        state.lastWasRejected = result == .rejected
        if result == .full { finish() }
        return result
    }

    /// Scrolls the content under the area with synthetic wheel events
    /// (needs Accessibility) until the page stops moving.
    func autoScroll() {
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt
            AXIsProcessTrustedWithOptions(options)
            return
        }
        state.autoScrolling = true
        Task {
            var stillFrames = 0
            let center = CGPoint(x: area.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - area.midY)  // Quartz coordinates
            while !finished, stillFrames < 3 {
                let pixels = Int32(-(area.height * 0.6))
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) {
                    event.location = center
                    event.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(for: .milliseconds(350))
                let result = await captureFrame()
                stillFrames = result == .unchanged ? stillFrames + 1 : 0
            }
            state.autoScrolling = false
            if !finished { finish() }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let image = stitcher.image()
        tearDown()
        completion(image)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        tearDown()
        completion(nil)
    }

    private func tearDown() {
        loop?.cancel()
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
        border?.orderOut(nil)
        controls?.orderOut(nil)
    }

    private func showBorder() {
        let frame = area.insetBy(dx: -3, dy: -3)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 3
        view.layer?.cornerRadius = 4
        panel.contentView = view
        panel.orderFrontRegardless()
        border = panel
    }

    private func showControls() {
        let hosting = NSHostingView(rootView: ScrollControlsView(state: state, onFinish: { [weak self] in self?.finish() },
                                                                 onCancel: { [weak self] in self?.cancel() },
                                                                 onAuto: { [weak self] in self?.autoScroll() }))
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        // Below the area if there is room, else above, else inside at the bottom.
        let screen = NSScreen.screens.first { $0.frame.intersects(area) }?.visibleFrame ?? area
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 12)
        if origin.y < screen.minY { origin.y = area.maxY + 12 }
        if origin.y + size.height > screen.maxY { origin.y = area.minY + 12 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        controls = panel
    }
}

@MainActor
@Observable
final class ScrollCaptureState {
    var frames = 0
    var height = 0
    var lastWasRejected = false
    var canAutoScroll = false
    var autoScrolling = false
}

private struct ScrollControlsView: View {
    @Bindable var state: ScrollCaptureState
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onAuto: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.doc").foregroundStyle(Color.accentColor).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.autoScrolling ? "Scrolling…" : "Scroll down")
                    .font(.headline)
                Text(state.lastWasRejected ? "Slower: the last part could not be joined" : "\(state.height) px · \(state.frames) parts")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(state.lastWasRejected ? .orange : .secondary)
            }
            .frame(minWidth: 190, alignment: .leading)
            Button("Auto", action: onAuto)
                .help(state.canAutoScroll ? "ShotDock scrolls the page for you" : "Needs the Accessibility permission")
                .disabled(state.autoScrolling)
            Button("Cancel", action: onCancel)
            Button("Done", action: onFinish).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
