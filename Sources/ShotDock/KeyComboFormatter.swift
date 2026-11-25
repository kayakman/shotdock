import AppKit
import Carbon.HIToolbox
import ShotDockCore

enum KeyComboFormatter {
    /// "⇧⌘5", using the current keyboard layout for character keys.
    static func string(for combo: KeyCombo) -> String {
        combo.modifierSymbols + keyName(combo.keyCode)
    }

    static func keyName(_ keyCode: Int) -> String {
        if let name = KeyNames.fixedName(keyCode) { return name }
        return layoutCharacter(keyCode)?.uppercased() ?? KeyNames.ansiName(keyCode) ?? "#\(keyCode)"
    }

    /// The character the key types with no modifiers in the current layout.
    static func layoutCharacter(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: chars, count: length)
            return string.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : string
        }
    }

    /// Carbon modifiers from an AppKit event.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= KeyCombo.command }
        if flags.contains(.shift) { modifiers |= KeyCombo.shift }
        if flags.contains(.option) { modifiers |= KeyCombo.option }
        if flags.contains(.control) { modifiers |= KeyCombo.control }
        return modifiers
    }

    static func appKitModifiers(_ modifiers: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & KeyCombo.command != 0 { flags.insert(.command) }
        if modifiers & KeyCombo.shift != 0 { flags.insert(.shift) }
        if modifiers & KeyCombo.option != 0 { flags.insert(.option) }
        if modifiers & KeyCombo.control != 0 { flags.insert(.control) }
        return flags
    }
}
