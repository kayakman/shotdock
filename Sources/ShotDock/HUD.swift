import AppKit
import SwiftUI

/// Small floating messages: the delayed-capture countdown and confirmations
/// such as "Copiado" when no editor opens.
@MainActor
enum HUD {
    private static var panel: NSPanel?

    static func show(_ text: String, symbol: String? = nil, for duration: Duration = .seconds(1.5)) {
        present(HUDView(text: text, symbol: symbol))
        let shown = panel
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            if panel === shown { hide() }
        }
    }

    /// Counts down on screen, then returns. Returns false if cancelled with Esc.
    static func countdown(seconds: Int) async -> Bool {
        var cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { if $0.keyCode == 53 { cancelled = true } }
        defer { monitor.map(NSEvent.removeMonitor) }
        for remaining in stride(from: seconds, to: 0, by: -1) {
            present(HUDView(text: "\(remaining)", symbol: nil, large: true))
            try? await Task.sleep(for: .seconds(1))
            if cancelled { break }
        }
        hide()
        // Let the HUD disappear before the screen is captured.
        try? await Task.sleep(for: .milliseconds(150))
        return !cancelled
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func present(_ view: HUDView) {
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return p
        }()
        panel.contentView = hosting
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.18,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String?
    var large = false

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
            Text(text)
                .font(large ? .system(size: 64, weight: .bold, design: .rounded).monospacedDigit() : .headline)
        }
        .padding(.horizontal, large ? 36 : 18)
        .padding(.vertical, large ? 18 : 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: large ? 24 : 12, style: .continuous))
    }
}
