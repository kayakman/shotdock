import AppKit
import ShotDockCore

/// Non-interactive checks run with `ShotDock --selftest <name> <output>`, so a
/// build can be verified from the command line. Results go to `selftest.log`
/// next to the output file.
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), args.count > index + 2 else { return false }
        let name = args[index + 1]
        let output = URL(fileURLWithPath: args[index + 2])
        Task {
            let log = output.deletingLastPathComponent().appendingPathComponent("selftest.log")
            var lines: [String] = []
            do {
                switch name {
                case "capture": lines += try await capture(to: output)
                default: lines.append("FAIL unknown selftest \(name)")
                }
            } catch {
                lines.append("FAIL \(error.localizedDescription)")
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func capture(to output: URL) async throws -> [String] {
        guard ScreenCapturer.hasPermission else { throw ScreenCaptureError.permissionDenied }
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        var lines = snapshots.map {
            "display \($0.displayID): \($0.image.width)x\($0.image.height) px, frame \($0.frame), scale \($0.scale)"
        }
        let main = snapshots.first { $0.displayID == CGMainDisplayID() } ?? snapshots[0]
        try ImageEncoding.write(main.image, to: output, scale: main.scale)
        lines.append("OK wrote \(output.path)")
        return lines
    }
}
