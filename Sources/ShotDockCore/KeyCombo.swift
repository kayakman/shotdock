import Foundation

/// A keyboard shortcut as Carbon understands it: a virtual key code (kVK_*)
/// and Carbon modifier flags.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: Int
    public var modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon modifier flags (Events.h), so Core needs no Carbon import.
    public static let command = 1 << 8
    public static let shift = 1 << 9
    public static let option = 1 << 11
    public static let control = 1 << 12

    /// "⌃⌥⇧⌘" in the order macOS menus use.
    public var modifierSymbols: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s
    }

    /// A global shortcut needs a modifier, except for function keys.
    public var isValidGlobalShortcut: Bool {
        modifiers & (Self.command | Self.option | Self.control) != 0 || KeyNames.isFunctionKey(keyCode)
    }
}

/// Names for keys whose label does not depend on the keyboard layout.
public enum KeyNames {
    static let fixed: [Int: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Espacio", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]

    public static func isFunctionKey(_ keyCode: Int) -> Bool { fixed[keyCode]?.hasPrefix("F") ?? false }

    public static func fixedName(_ keyCode: Int) -> String? { fixed[keyCode] }

    /// US-layout fallback for character keys when the current layout is unavailable.
    static let ansi: [Int: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I",
        0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/",
        0x2A: "\\", 0x32: "`",
    ]

    public static func ansiName(_ keyCode: Int) -> String? { ansi[keyCode] }
}

public extension KeyCombo {
    /// Reads "⇧⌘2", "cmd+shift+2", "ctrl-opt-o", "F5"… Character keys use the
    /// US layout's key positions.
    init?(parsing text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var modifiers = 0
        let symbols: [Character: Int] = ["⌘": Self.command, "⇧": Self.shift, "⌥": Self.option, "⌃": Self.control]
        while let first = rest.first, let flag = symbols[first], rest.count > 1 {
            modifiers |= flag
            rest.removeFirst()
        }
        let names: [String: Int] = ["cmd": Self.command, "command": Self.command, "shift": Self.shift, "opt": Self.option,
                                    "option": Self.option, "alt": Self.option, "ctrl": Self.control, "control": Self.control]
        var parts = rest.split(whereSeparator: { $0 == "+" || $0 == "-" }).map { String($0).trimmingCharacters(in: .whitespaces) }
        // "cmd+-" or "⌘-": the key itself is a dash.
        if rest.hasSuffix("-") || rest.hasSuffix("+") { parts.append(rest.hasSuffix("-") ? "-" : "+") }
        guard let key = parts.popLast() else { return nil }
        for part in parts {
            guard let flag = names[part.lowercased()] else { return nil }
            modifiers |= flag
        }
        guard let code = KeyNames.keyCode(for: key) else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    /// "ctrl+opt+shift+cmd+2", readable anywhere.
    var plainDescription: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("ctrl") }
        if modifiers & Self.option != 0 { parts.append("opt") }
        if modifiers & Self.shift != 0 { parts.append("shift") }
        if modifiers & Self.command != 0 { parts.append("cmd") }
        parts.append(KeyNames.plainName(keyCode))
        return parts.joined(separator: "+")
    }
}

public extension KeyNames {
    static let plain: [Int: String] = [
        0x24: "return", 0x30: "tab", 0x31: "space", 0x33: "delete", 0x35: "esc", 0x75: "forwarddelete",
        0x7B: "left", 0x7C: "right", 0x7D: "down", 0x7E: "up", 0x73: "home", 0x77: "end", 0x74: "pageup", 0x79: "pagedown",
    ]

    static func plainName(_ keyCode: Int) -> String {
        plain[keyCode] ?? fixed[keyCode] ?? ansi[keyCode]?.lowercased() ?? "#\(keyCode)"
    }

    static func keyCode(for name: String) -> Int? {
        let lower = name.lowercased()
        let aliases = ["enter": 0x24, "backspace": 0x33, "escape": 0x35, "del": 0x75, "spacebar": 0x31]
        if let code = aliases[lower] { return code }
        if let code = plain.first(where: { $0.value == lower })?.key { return code }
        if let code = fixed.first(where: { $0.value.lowercased() == lower })?.key { return code }
        if let code = ansi.first(where: { $0.value.lowercased() == lower })?.key { return code }
        // Virtual key codes go up to 0x7F; anything else would not be a key.
        if lower.hasPrefix("#"), let code = Int(lower.dropFirst()), (0...0x7F).contains(code) { return code }
        return nil
    }
}
