import Foundation
import Testing
@testable import ShotDockCore

/// Values as found in a real Shottr 1.9.3 preferences file.
nonisolated(unsafe) private let shottrPreferences: [String: Any] = [
    "KeyboardShortcuts_anyWindow": #"{"carbonModifiers":768,"carbonKeyCode":20}"#,
    "KeyboardShortcuts_area": #"{"carbonModifiers":768,"carbonKeyCode":23}"#,
    "KeyboardShortcuts_fullscreen": #"{"carbonModifiers":768,"carbonKeyCode":21}"#,
    "KeyboardShortcuts_ocr": #"{"carbonModifiers":6400,"carbonKeyCode":31}"#,
    "KeyboardShortcuts_repeatArea": #"{"carbonKeyCode":23,"carbonModifiers":2816}"#,
    "KeyboardShortcuts_window": #"{"carbonKeyCode":19,"carbonModifiers":768}"#,
    "KeyboardShortcuts_somethingNew": #"{"carbonKeyCode":1,"carbonModifiers":256}"#,
    "afterGrabCopy": true,
]

private let shiftCmd = KeyCombo.command | KeyCombo.shift

@Test func parsesShottrShortcuts() {
    let result = ShottrImport.parse(shottrPreferences)
    #expect(result.shortcuts[.captureArea] == KeyCombo(keyCode: 23, modifiers: shiftCmd))
    #expect(result.shortcuts[.repeatArea] == KeyCombo(keyCode: 23, modifiers: shiftCmd | KeyCombo.option))
    #expect(result.shortcuts[.captureActiveWindow] == KeyCombo(keyCode: 19, modifiers: shiftCmd))
    #expect(result.shortcuts[.captureWindow] == KeyCombo(keyCode: 20, modifiers: shiftCmd))
    #expect(result.shortcuts[.captureFullscreen] == KeyCombo(keyCode: 21, modifiers: shiftCmd))
    #expect(result.shortcuts[.recognizeText]??.modifierSymbols == "⌃⌥⌘")
    #expect(result.unknown == ["somethingNew"])
}

@Test func applyingImportReplacesDefaults() {
    var settings = ShortcutSettings()
    settings.apply(ShottrImport.parse(shottrPreferences))
    // ⇧⌘2 was ShotDock's default for areas; in this Shottr setup it is the active window.
    #expect(settings.action(for: KeyCombo(keyCode: 19, modifiers: shiftCmd)) == .captureActiveWindow)
    #expect(settings.combo(for: .captureArea) == KeyCombo(keyCode: 23, modifiers: shiftCmd))
    #expect(settings.combo(for: .captureFullscreen) == KeyCombo(keyCode: 21, modifiers: shiftCmd))
}

@Test func disabledShortcutImportsAsOff() throws {
    let data = try PropertyListSerialization.data(fromPropertyList: ["KeyboardShortcuts_fullscreen": false], format: .binary, options: 0)
    var settings = ShortcutSettings()
    settings.apply(try ShottrImport.parse(plistData: data))
    #expect(settings.combo(for: .captureFullscreen) == nil)
    #expect(settings.combo(for: .captureArea) != nil)
}
