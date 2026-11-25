import Foundation

public enum CaptureNaming {
    /// Default file name, e.g. "ShotDock 2026-11-25 a las 10.58.40".
    public static func defaultName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        return "ShotDock \(formatter.string(from: date))"
    }
}
