import Foundation

/// Everything that can have a global shortcut.
public enum ShortcutAction: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case captureArea
    case repeatArea
    case captureActiveWindow
    case captureWindow
    case captureFullscreen
    case captureDelayed
    case captureScrolling
    case recognizeText
    case pickColor
    case showHistory

    public var title: String {
        switch self {
        case .captureArea: "Capturar área"
        case .repeatArea: "Repetir última área"
        case .captureActiveWindow: "Capturar ventana activa"
        case .captureWindow: "Capturar ventana (elegir)"
        case .captureFullscreen: "Capturar pantalla completa"
        case .captureDelayed: "Capturar con retardo"
        case .captureScrolling: "Captura con scroll"
        case .recognizeText: "Reconocer texto (OCR)"
        case .pickColor: "Cuentagotas de color"
        case .showHistory: "Mostrar capturas recientes"
        }
    }

    /// Shottr's defaults for the same actions, so both feel the same.
    public var defaultCombo: KeyCombo? {
        switch self {
        case .captureFullscreen: KeyCombo(keyCode: 0x12, modifiers: KeyCombo.command | KeyCombo.shift)  // ⇧⌘1
        case .captureArea: KeyCombo(keyCode: 0x13, modifiers: KeyCombo.command | KeyCombo.shift)        // ⇧⌘2
        default: nil
        }
    }
}

/// The user's shortcuts. Actions missing from `custom` use their default;
/// an explicit `nil` means the user turned the shortcut off.
public struct ShortcutSettings: Codable, Equatable, Sendable {
    public var custom: [ShortcutAction: KeyCombo?] = [:]

    public init(custom: [ShortcutAction: KeyCombo?] = [:]) {
        self.custom = custom
    }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        if let value = custom[action] { return value }
        return action.defaultCombo
    }

    public mutating func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        // Assigning a combo takes it away from any other action.
        if let combo {
            for other in ShortcutAction.allCases where other != action && self.combo(for: other) == combo {
                custom[other] = .some(nil)
            }
        }
        custom[action] = .some(combo)
    }

    public func action(for combo: KeyCombo) -> ShortcutAction? {
        ShortcutAction.allCases.first { self.combo(for: $0) == combo }
    }
}
