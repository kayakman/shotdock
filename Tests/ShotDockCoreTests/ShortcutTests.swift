import Foundation
import Testing
@testable import ShotDockCore

private let shiftCmd = KeyCombo.command | KeyCombo.shift

@Test func defaultsMatchShottr() {
    let settings = ShortcutSettings()
    #expect(settings.combo(for: .captureArea) == KeyCombo(keyCode: 0x13, modifiers: shiftCmd))
    #expect(settings.combo(for: .captureFullscreen)?.modifierSymbols == "⇧⌘")
    #expect(settings.combo(for: .captureWindow) == nil)
}

@Test func assigningMovesComboAndDisablingSticks() {
    var settings = ShortcutSettings()
    let area = KeyCombo(keyCode: 0x13, modifiers: shiftCmd)
    settings.set(area, for: .captureWindow)
    #expect(settings.combo(for: .captureWindow) == area)
    #expect(settings.combo(for: .captureArea) == nil)
    #expect(settings.action(for: area) == .captureWindow)
    settings.set(nil, for: .captureFullscreen)
    #expect(settings.combo(for: .captureFullscreen) == nil)
}

@Test func settingsRoundTripThroughJSONKeepingDisabled() throws {
    var settings = ShortcutSettings()
    settings.set(KeyCombo(keyCode: 0x0D, modifiers: KeyCombo.control | KeyCombo.option), for: .captureWindow)
    settings.set(nil, for: .captureFullscreen)
    let data = try JSONEncoder().encode(settings)
    #expect(String(decoding: data, as: UTF8.self).contains("\"captureWindow\""))
    let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: data)
    #expect(decoded == settings)
    #expect(decoded.combo(for: .captureFullscreen) == nil)
}

@Test func editorShortcutsDefaultsAndRelease() {
    var editor = EditorShortcutSettings()
    #expect(editor.combo(for: .copyAndClose) == KeyCombo(keyCode: 0x08, modifiers: KeyCombo.command | KeyCombo.shift))
    #expect(editor.combo(for: .copyAndClose)?.modifierSymbols == "⇧⌘")
    // A combo taken by a global shortcut is released from the editor set.
    editor.release(KeyCombo(keyCode: 0x01, modifiers: KeyCombo.command))
    #expect(editor.combo(for: .save) == nil)
    #expect(editor.combo(for: .saveAs) != nil)
}

@Test func combosParseFromSymbolsAndWords() {
    let area = KeyCombo(keyCode: 0x13, modifiers: shiftCmd)
    #expect(KeyCombo(parsing: "⇧⌘2") == area)
    #expect(KeyCombo(parsing: "cmd+shift+2") == area)
    #expect(KeyCombo(parsing: "Shift-Cmd-2") == area)
    #expect(KeyCombo(parsing: "⌃⌥O") == KeyCombo(keyCode: 0x1F, modifiers: KeyCombo.control | KeyCombo.option))
    #expect(KeyCombo(parsing: "F5") == KeyCombo(keyCode: 0x60, modifiers: 0))
    #expect(KeyCombo(parsing: "cmd+space") == KeyCombo(keyCode: 0x31, modifiers: KeyCombo.command))
    #expect(KeyCombo(parsing: "cmd+-") == KeyCombo(keyCode: 0x1B, modifiers: KeyCombo.command))
    #expect(KeyCombo(parsing: "hyper+2") == nil && KeyCombo(parsing: "cmd+ñ") == nil)
    #expect(KeyCombo(parsing: "cmd+#70000") == nil && KeyCombo(parsing: "cmd+#5") == KeyCombo(keyCode: 5, modifiers: KeyCombo.command))
    #expect(area.plainDescription == "shift+cmd+2")
    #expect(KeyCombo(parsing: area.plainDescription) == area)
}
