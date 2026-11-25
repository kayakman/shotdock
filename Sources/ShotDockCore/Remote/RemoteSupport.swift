import CoreGraphics
import Foundation

/// Loose text matching for `--app` and `--title`: case, accents and spaces
/// do not matter, so "visual studio" finds "Visual Studio Code".
public enum TextMatch {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { !$0.isWhitespace }
    }

    public static func loosely(_ text: String?, contains query: String) -> Bool {
        let needle = normalized(query)
        return needle.isEmpty || normalized(text ?? "").contains(needle)
    }
}

/// Screen coordinates outside the app are global points with the origin at
/// the top-left of the main display (as `screencapture -R` and CGWindowList);
/// AppKit's origin is at the bottom-left. The flip is its own inverse.
public enum ScreenGeometry {
    public static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func flipped(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

/// Plain-text output of a command result for people (without `--json`):
/// lists of records become tables, records become "key: value" lines.
public enum TextRendering {
    public static func render(_ value: JSONValue) -> String {
        switch value {
        case let .array(items) where !items.isEmpty && items.allSatisfy({ $0.objectValue != nil }):
            return table(items.compactMap(\.objectValue))
        case let .object(object):
            // A record holding one list of records (e.g. {"windows": […]}) shows the table,
            // after the other fields.
            let lists = object.filter { $0.value.arrayValue.map { !$0.isEmpty && $0.allSatisfy { $0.objectValue != nil } } ?? false }
            if lists.count == 1, let (key, list) = lists.first {
                if object.count == 1 { return render(list) }
                var rest = object
                rest[key] = nil
                return render(.object(rest)) + "\n\n" + render(list)
            }
            if object.count == 1, let (_, list) = object.first, case .array = list { return render(list) }
            let width = object.keys.map(\.count).max() ?? 0
            return object.keys.sorted().map { key in
                let text = render(object[key]!)
                let label = (key + ":").padding(toLength: width + 1, withPad: " ", startingAt: 0)
                let nested = object[key]!.objectValue != nil && object[key]!.rect == nil && object[key]!.point == nil
                if nested || text.contains("\n") { return label + "\n" + text.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") }
                return label + " " + text
            }.joined(separator: "\n")
        case let .array(items): return items.isEmpty ? "(none)" : items.map(cell).joined(separator: "\n")
        default: return cell(value)
        }
    }

    /// A value on one line: rectangles as "x,y w×h", points as "x,y".
    public static func cell(_ value: JSONValue) -> String {
        switch value {
        case .null: return "-"
        case let .bool(bool): return bool ? "yes" : "no"
        case let .number(number): return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(format: "%.4g", number)
        case let .string(string): return string
        case .array, .object:
            if let rect = value.rect { return "\(cell(.number(rect.minX))),\(cell(.number(rect.minY))) \(cell(.number(rect.width)))×\(cell(.number(rect.height)))" }
            if let point = value.point { return "\(cell(.number(point.x))),\(cell(.number(point.y)))" }
            if let items = value.arrayValue, items.allSatisfy({ $0.objectValue == nil }) { return items.map(cell).joined(separator: ", ") }
            return value.jsonString()
        }
    }

    static func table(_ rows: [[String: JSONValue]]) -> String {
        var columns: [String] = []
        for row in rows {
            for key in row.keys.sorted() where !columns.contains(key) { columns.append(key) }
        }
        // Identifiers first, the rest alphabetically.
        let preferred = ["index", "id", "name"]
        columns = preferred.filter(columns.contains) + columns.filter { !preferred.contains($0) }
        let cells = rows.map { row in columns.map { row[$0].map(cell) ?? "-" } }
        let widths = columns.indices.map { i in min(max(columns[i].count, cells.map { $0[i].count }.max() ?? 0), 60) }
        func line(_ values: [String]) -> String {
            zip(values, widths).map { value, width in
                let clipped = value.count > width ? String(value.prefix(width - 1)) + "…" : value
                return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        return ([line(columns.map { $0.uppercased() })] + cells.map(line)).joined(separator: "\n")
    }
}
