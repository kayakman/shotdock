import AppKit
import ShotDockCore
import SwiftUI

/// Click, then press the new shortcut. Esc cancels, ⌫ clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    /// Called with true while recording, so global hotkeys can be paused.
    var onRecordingChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = { combo = $0 }
        button.onRecordingChange = onRecordingChange
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onChange = { combo = $0 }
        button.combo = combo
    }
}

final class RecorderButton: NSButton {
    var combo: KeyCombo? { didSet { refresh() } }
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var recording = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggleRecording() {
        setRecording(!recording)
    }

    private func setRecording(_ value: Bool) {
        guard value != recording else { return }
        recording = value
        if value { window?.makeFirstResponder(self) }
        onRecordingChange?(value)
    }

    override func resignFirstResponder() -> Bool {
        setRecording(false)
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        let modifiers = KeyComboFormatter.carbonModifiers(event.modifierFlags)
        switch Int(event.keyCode) {
        case 53 where modifiers == 0:  // Esc
            setRecording(false)
        case 51 where modifiers == 0, 117 where modifiers == 0:  // ⌫ / ⌦
            onChange?(nil)
            setRecording(false)
        default:
            let candidate = KeyCombo(keyCode: Int(event.keyCode), modifiers: modifiers)
            guard candidate.isValidGlobalShortcut else { return NSSound.beep() }
            onChange?(candidate)
            setRecording(false)
        }
    }

    private func refresh() {
        if recording {
            title = String(localized: "Press the shortcut…")
        } else {
            title = combo.map(KeyComboFormatter.string) ?? String(localized: "No shortcut")
        }
        contentTintColor = recording ? .controlAccentColor : (combo == nil ? .secondaryLabelColor : nil)
    }
}
