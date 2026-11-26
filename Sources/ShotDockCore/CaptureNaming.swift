import Foundation

public enum CaptureNaming {
    /// Default file name in the app's language, e.g. "ShotDock 2026-11-25 at 10.58.40".
    public static func defaultName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: date)
        return String(localized: "ShotDock \(day) at \(time)")
    }
}
