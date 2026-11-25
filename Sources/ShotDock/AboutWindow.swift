import AppKit
import SwiftUI

/// "Acerca de ShotDock": the logo (graphite or white wordmark depending on
/// the appearance, from the asset catalog), version and copyright.
@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.setContentSize(window.contentView!.fittingSize)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var version: String {
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Versión \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 300)
                .accessibilityLabel("ShotDock")
            Text("Capturas de pantalla, anotaciones y tu dock de capturas recientes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(version)
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
            Text(info["NSHumanReadableCopyright"] as? String ?? "")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 400)
    }
}
