import AppKit
import ShotDockCore

/// Imagen › Redimensionar…: the export size in pixels, keeping the
/// proportions. Non-destructive, like the crop.
@MainActor
final class ResizePanel: NSObject, NSTextFieldDelegate {
    private let canvas: CGSize
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var keepAlive: ResizePanel?

    init(canvas: CGSize, current: CGSize) {
        self.canvas = canvas
        super.init()
        for (field, value) in [(widthField, current.width), (heightField, current.height)] {
            field.integerValue = Int(value)
            field.alignment = .right
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
    }

    /// `completion` gets the new factor, nil for the original size; not called on cancel.
    func run(on window: NSWindow, completion: @escaping (CGFloat?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Redimensionar"
        alert.informativeText = "Tamaño de la imagen al copiarla, guardarla o subirla. La original (\(Int(canvas.width)) × \(Int(canvas.height)) px) se conserva."
        alert.addButton(withTitle: "Redimensionar")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Tamaño original")
        let row = NSStackView(views: [NSTextField(labelWithString: "Ancho:"), widthField, NSTextField(labelWithString: "Alto:"), heightField,
                                      NSTextField(labelWithString: "px")])
        row.spacing = 6
        row.frame = CGRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = row
        alert.window.initialFirstResponder = widthField
        keepAlive = self
        alert.beginSheetModal(for: window) { [self] response in
            keepAlive = nil
            switch response {
            case .alertFirstButtonReturn:
                let width = CGFloat(widthField.integerValue)
                if width >= 1 { completion(width / canvas.width) }
            case .alertThirdButtonReturn: completion(nil)
            default: break
            }
        }
    }

    /// Typing one side updates the other.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === widthField, widthField.integerValue > 0 {
            heightField.integerValue = Int((CGFloat(widthField.integerValue) * canvas.height / canvas.width).rounded())
        } else if field === heightField, heightField.integerValue > 0 {
            widthField.integerValue = Int((CGFloat(heightField.integerValue) * canvas.width / canvas.height).rounded())
        }
    }
}
