import Foundation

/// How agents name a capture of the history: its id (or the start of it,
/// at least 4 characters), `last` for the newest, `last-1` for the one
/// before, and so on.
public enum CaptureReference {
    public static func resolve(_ reference: String, in items: [CaptureItem]) throws -> UUID {
        let text = reference.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "last" || text.hasPrefix("last-") {
            let offset = text == "last" ? 0 : Int(text.dropFirst(5)) ?? -1
            guard offset >= 0 else { throw RPCError.invalidParams("Use last, last-1, last-2…") }
            guard offset < items.count else {
                throw RPCError.notFound(items.isEmpty ? "The history is empty" : "The history has only \(items.count) captures")
            }
            return items[offset].id
        }
        if let id = UUID(uuidString: text), items.contains(where: { $0.id == id }) { return id }
        guard text.count >= 4 else { throw RPCError.notFound("No capture \(reference) in the history") }
        let matches = items.filter { $0.id.uuidString.lowercased().hasPrefix(text) }
        guard matches.count == 1 else {
            throw matches.isEmpty ? RPCError.notFound("No capture \(reference) in the history")
                : RPCError.invalidParams("\(reference) matches \(matches.count) captures; give more of the id")
        }
        return matches[0].id
    }
}

/// `--since`: an ISO 8601 date ("2026-11-25", "2026-11-25T10:00:00Z") or an
/// age: "30m", "2h", "3d", "1w".
public enum RelativeDate {
    public static func parse(_ text: String, now: Date = Date()) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let unit = text.last, let amount = Double(text.dropLast()), amount >= 0 {
            let seconds: Double? = switch unit {
            case "s": 1
            case "m": 60
            case "h": 3600
            case "d": 86400
            case "w": 7 * 86400
            default: nil
            }
            if let seconds { return now.addingTimeInterval(-amount * seconds) }
        }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text.uppercased()) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        return day.date(from: text)
    }
}

public struct HistoryFilter: Sendable {
    public var search: String?
    public var since: Date?
    public var uploaded: Bool?
    public var saved: Bool?

    public init(search: String? = nil, since: Date? = nil, uploaded: Bool? = nil, saved: Bool? = nil) {
        self.search = search
        self.since = since
        self.uploaded = uploaded
        self.saved = saved
    }
}

extension CaptureLibrary {
    /// Captures that pass the filter, newest first. The search looks at text
    /// annotations, the saved file name, the uploaded link and recognised text.
    public func items(matching filter: HistoryFilter) -> [CaptureItem] {
        items.filter { item in
            if let since = filter.since, item.createdAt < since { return false }
            if let uploaded = filter.uploaded, (item.uploadedURL != nil) != uploaded { return false }
            if let saved = filter.saved, (item.savedPath != nil) != saved { return false }
            guard let query = filter.search, !query.isEmpty else { return true }
            return searchableText(item).contains { TextMatch.loosely($0, contains: query) }
        }
    }

    func searchableText(_ item: CaptureItem) -> [String] {
        var texts = [item.savedPath.map { ($0 as NSString).lastPathComponent }, item.uploadedURL, item.recognizedText].compactMap { $0 }
        if let annotations = try? documentState(item.id).annotations {
            texts += annotations.compactMap { if case let .text(_, string) = $0.shape { string } else { nil } }
        }
        return texts
    }
}
