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
