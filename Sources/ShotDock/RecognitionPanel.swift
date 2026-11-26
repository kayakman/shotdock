import AppKit
import ShotDockCore
import SwiftUI

/// Shows what OCR and the barcode reader found, to copy or open.
struct RecognitionView: View {
    let result: RecognitionResult
    @State var text: String
    let onClose: () -> Void

    init(result: RecognitionResult, joinLines: Bool, onClose: @escaping () -> Void) {
        self.result = result
        _text = State(initialValue: result.text(joinLines: joinLines))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.isEmpty ? "No text or codes found" : "Recognized text")
                .font(.headline)
            if !result.lines.isEmpty {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(result.codes, id: \.self) { code in
                HStack {
                    Image(systemName: "qrcode")
                    Text(code).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if let url = URL(string: code), url.scheme?.hasPrefix("http") == true {
                        Button("Open") { NSWorkspace.shared.open(url) }
                    }
                    Button("Copy") { copy(code) }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                if !result.lines.isEmpty {
                    Button("Copy Text") { copy(text); onClose() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

@MainActor
enum RecognitionPanel {
    /// Runs OCR and shows the result as a sheet on `window`.
    static func present(for image: CGImage, on window: NSWindow) {
        Task {
            do {
                let result = try await TextRecognition.recognize(image)
                let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                let view = RecognitionView(result: result, joinLines: AppSettings.shared.ocrJoinLines) { [weak sheet] in
                    if let sheet { window.endSheet(sheet) }
                }
                sheet.contentView = NSHostingView(rootView: view)
                sheet.setContentSize(sheet.contentView!.fittingSize)
                window.beginSheet(sheet, completionHandler: nil)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
