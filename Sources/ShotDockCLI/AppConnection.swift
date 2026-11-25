import Foundation
import ShotDockCore

/// Talks to the running app over the control socket, starting it in the
/// background when it is not running: captures always happen in the app,
/// under its own Screen Recording permission.
enum AppConnection {
    static let bundleID = "app.shotdock.ShotDock"

    enum Failure: Error, LocalizedError {
        case notInstalled
        case didNotStart(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "ShotDock.app was not found; install it with `make install`"
            case let .didNotStart(detail): "ShotDock did not start: \(detail)"
            }
        }
    }

    /// A client connected to the app, launching it if needed.
    static func connect(path: String = ControlSocket.defaultPath) throws -> ControlClient {
        if let client = try? ControlClient(path: path) { return client }
        try launchApp()
        let deadline = Date().addingTimeInterval(20)
        var lastError: Error?
        while Date() < deadline {
            do { return try ControlClient(path: path) } catch { lastError = error }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw Failure.didNotStart(lastError?.localizedDescription ?? "no socket at \(path)")
    }

    /// Opens the app without activating it.
    static func launchApp() throws {
        guard let app = appBundle() else { throw Failure.notInstalled }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", app.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw Failure.didNotStart("open exited with \(open.terminationStatus)") }
    }

    /// The app this binary lives in (ShotDock.app/Contents/Helpers/shotdock),
    /// else the one Launch Services knows.
    static func appBundle() -> URL? {
        if let own = enclosingApp() { return own }
        let lsregister = Process()
        let pipe = Pipe()
        lsregister.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        lsregister.arguments = ["kMDItemCFBundleIdentifier == '\(bundleID)'"]
        lsregister.standardOutput = pipe
        lsregister.standardError = FileHandle.nullDevice
        guard (try? lsregister.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsregister.waitUntilExit()
        let candidates = output.split(separator: "\n").map(String.init)
        return (candidates.first { $0.hasPrefix("/Applications/") } ?? candidates.first).map { URL(fileURLWithPath: $0) }
    }

    static func enclosingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let helpers = executable.deletingLastPathComponent()
        let app = helpers.deletingLastPathComponent().deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", app.pathExtension == "app" else { return nil }
        return app
    }

    static var version: String {
        enclosingApp().flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "dev"
    }
}
