import AppKit
import ShotDockCore

/// Runs a capture from start to finish: freeze the screens, let the user
/// select, then hand the pixels to an editor.
@MainActor
final class CaptureCoordinator {
    private(set) var selection: AreaSelectionController?
    private(set) var editors: [EditorWindowController] = []
    private var isCapturing = false

    func captureArea() {
        guard !isCapturing else { return }
        guard ScreenCapturer.hasPermission else { return showPermissionAlert() }
        isCapturing = true
        Task {
            do {
                let snapshots = try await ScreenCapturer.snapshotAllDisplays()
                beginSelection(over: snapshots)
            } catch {
                isCapturing = false
                showError(error)
            }
        }
    }

    func beginSelection(over snapshots: [DisplaySnapshot]) {
        isCapturing = true
        let controller = AreaSelectionController(snapshots: snapshots) { [weak self] result in
            guard let self else { return }
            selection = nil
            isCapturing = false
            guard let result else { return }
            Pasteboard.copy(result.image, scale: result.scale)
            openEditor(with: CaptureDocument(image: result.image, scale: result.scale))
        }
        selection = controller
        controller.show()
    }

    @discardableResult
    func openEditor(with document: CaptureDocument) -> EditorWindowController {
        let editor = EditorWindowController(document: document)
        editor.onClose = { [weak self] closed in self?.editors.removeAll { $0 === closed } }
        editors.append(editor)
        editor.show()
        return editor
    }

    private func showPermissionAlert() {
        ScreenCapturer.requestPermission()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "ShotDock necesita permiso de Grabación de pantalla"
        alert.informativeText = "Actívalo en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y vuelve a intentarlo."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func showError(_ error: Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }
}
