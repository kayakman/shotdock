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

/// Actions with a default keyboard shortcut.
public protocol ShortcutActionType: RawRepresentable, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable
where RawValue == String {
    var defaultCombo: KeyCombo? { get }
}

extension ShortcutAction: ShortcutActionType {}

/// Shortcuts that only work in the editor window (menu key equivalents).
public enum EditorAction: String, ShortcutActionType {
    case copyAndClose
    case save
    case saveAs
    case upload
    case pin
    case backdrop
    case recognizeText

    public var title: String {
        switch self {
        case .copyAndClose: "Copiar y cerrar"
        case .save: "Guardar"
        case .saveAs: "Guardar como…"
        case .upload: "Subir y copiar enlace"
        case .pin: "Fijar encima de todo"
        case .backdrop: "Fondo y marco"
        case .recognizeText: "Reconocer texto"
        }
    }

    public var defaultCombo: KeyCombo? {
        let cmd = KeyCombo.command, shift = KeyCombo.shift
        return switch self {
        case .copyAndClose: KeyCombo(keyCode: 0x08, modifiers: cmd | shift)   // ⇧⌘C
        case .save: KeyCombo(keyCode: 0x01, modifiers: cmd)                   // ⌘S
        case .saveAs: KeyCombo(keyCode: 0x01, modifiers: cmd | shift)         // ⇧⌘S
        case .upload: KeyCombo(keyCode: 0x20, modifiers: cmd)                 // ⌘U
        case .pin: KeyCombo(keyCode: 0x23, modifiers: cmd)                    // ⌘P
        case .backdrop: KeyCombo(keyCode: 0x0B, modifiers: cmd)               // ⌘B
        case .recognizeText: KeyCombo(keyCode: 0x11, modifiers: cmd | shift)  // ⇧⌘T
        }
    }
}

/// The user's shortcuts for one set of actions. Actions missing from
/// `custom` use their default; an explicit `nil` means the user turned the
/// shortcut off.
public struct ShortcutMap<Action: ShortcutActionType>: Codable, Equatable, Sendable {
    public var custom: [Action: KeyCombo?] = [:]

    public init(custom: [Action: KeyCombo?] = [:]) {
        self.custom = custom
    }

    public func combo(for action: Action) -> KeyCombo? {
        if let value = custom[action] { return value }
        return action.defaultCombo
    }

    public mutating func set(_ combo: KeyCombo?, for action: Action) {
        // Assigning a combo takes it away from any other action.
        if let combo { release(combo, except: action) }
        custom[action] = .some(combo)
    }

    /// Turns off whichever action uses `combo` (used across sets too).
    public mutating func release(_ combo: KeyCombo, except keep: Action? = nil) {
        for other in Action.allCases where other != keep && self.combo(for: other) == combo {
            custom[other] = .some(nil)
        }
    }

    public func action(for combo: KeyCombo) -> Action? {
        Action.allCases.first { self.combo(for: $0) == combo }
    }
}

public typealias ShortcutSettings = ShortcutMap<ShortcutAction>
public typealias EditorShortcutSettings = ShortcutMap<EditorAction>
