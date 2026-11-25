import Foundation

/// File names from a template with tokens:
/// {fecha} 2026-11-25 · {hora} 10.58.40 · {año} {mes} {día} {h} {min} {s} · {n} counter.
public struct FilenameTemplate: Sendable {
    public static let defaultTemplate = "ShotDock {fecha} a las {hora}"
    public static let tokens = ["{fecha}", "{hora}", "{año}", "{mes}", "{día}", "{h}", "{min}", "{s}", "{n}"]

    public var template: String

    public init(_ template: String = Self.defaultTemplate) {
        self.template = template
    }

    public func name(for date: Date, counter: Int = 1, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let two = { (v: Int?) in String(format: "%02d", v ?? 0) }
        let values: [String: String] = [
            "{año}": String(c.year ?? 0), "{mes}": two(c.month), "{día}": two(c.day),
            "{h}": two(c.hour), "{min}": two(c.minute), "{s}": two(c.second),
            "{fecha}": "\(c.year ?? 0)-\(two(c.month))-\(two(c.day))",
            "{hora}": "\(two(c.hour)).\(two(c.minute)).\(two(c.second))",
            "{n}": String(counter),
        ]
        var name = template
        for (token, value) in values { name = name.replacingOccurrences(of: token, with: value) }
        name = Self.sanitized(name)
        return name.isEmpty ? CaptureNaming.defaultName(for: date, timeZone: timeZone) : name
    }

    /// A URL in `folder` that does not overwrite an existing file: adds " 2", " 3"…
    public func uniqueURL(in folder: URL, for date: Date, format: ImageFormat,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = name(for: date)
        var url = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var suffix = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(format.fileExtension)
            suffix += 1
        }
        return url
    }

    /// Removes characters Finder does not allow in names (":" and "/") and trims.
    static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
}
