import Foundation

/// Reads Shottr's preferences (cc.ffitch.shottr.plist). Shottr stores its
/// shortcuts with the KeyboardShortcuts library: one key per action,
/// "KeyboardShortcuts_<name>", holding a JSON string with Carbon codes, or
/// `false` when the user removed the shortcut.
public enum ShottrImport {
    public static let bundleID = "cc.ffitch.shottr"

    /// Shottr's preferences file inside its sandbox container.
    public static func preferencesURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
    }

    static let actionsByName: [String: ShortcutAction] = [
        "area": .captureArea,
        "repeatArea": .repeatArea,
        "window": .captureActiveWindow,
        "anyWindow": .captureWindow,
        "fullscreen": .captureFullscreen,
        "delayed": .captureDelayed,
        "scrolling": .captureScrolling,
        "ocr": .recognizeText,
        "colorPicker": .pickColor,
    ]

    public struct Result: Equatable, Sendable {
        /// Shortcuts found for actions ShotDock has; `nil` = turned off in Shottr.
        public var shortcuts: [ShortcutAction: KeyCombo?] = [:]
        /// Shottr shortcut names with no ShotDock equivalent.
        public var unknown: [String] = []
    }

    public static func parse(_ preferences: [String: Any]) -> Result {
        var result = Result()
        let prefix = "KeyboardShortcuts_"
        for (key, value) in preferences where key.hasPrefix(prefix) {
            let name = String(key.dropFirst(prefix.count))
            guard let action = actionsByName[name] else {
                result.unknown.append(name)
                continue
            }
            if let json = value as? String, let combo = decode(json) {
                result.shortcuts[action] = .some(combo)
            } else if let enabled = value as? Bool, !enabled {
                result.shortcuts[action] = .some(nil)
            }
        }
        result.unknown.sort()
        return result
    }

    public static func parse(plistData: Data) throws -> Result {
        let object = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        return parse(object as? [String: Any] ?? [:])
    }

    private struct StoredShortcut: Decodable {
        let carbonKeyCode: Int
        let carbonModifiers: Int
    }

    static func decode(_ json: String) -> KeyCombo? {
        guard let stored = try? JSONDecoder().decode(StoredShortcut.self, from: Data(json.utf8)) else { return nil }
        return KeyCombo(keyCode: stored.carbonKeyCode, modifiers: stored.carbonModifiers)
    }
}

public extension ShortcutSettings {
    /// Applies imported shortcuts on top of the current ones.
    mutating func apply(_ result: ShottrImport.Result) {
        // Turn-offs first, so an imported combo is not stolen back by a later action.
        for (action, combo) in result.shortcuts where combo == nil { set(nil, for: action) }
        for (action, combo) in result.shortcuts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let combo { set(combo, for: action) }
        }
    }
}
