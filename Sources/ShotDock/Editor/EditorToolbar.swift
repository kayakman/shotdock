import ShotDockCore
import SwiftUI

struct EditorToolbar: View {
    @Bindable var model: EditorModel
    var onSave: () -> Void
    var onPin: () -> Void = {}
    var onRecognize: () -> Void = {}
    var onBackdrop: () -> Void = {}
    var onUpload: () -> Void = {}

    private var customColor: Binding<Color> {
        Binding(get: { Color(cgColor: model.color.cgColor) },
                set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    model.color = RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
                })
    }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $model.tool) {
                ForEach(EditorTool.allCases) { tool in
                    Image(systemName: tool.symbol)
                        .help(Text(verbatim: "\(tool.title) (\(tool.key.uppercased()))"))
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 5) {
                ForEach(RGBAColor.palette, id: \.self) { color in
                    ColorSwatch(color: color, selected: color == model.color) { model.color = color }
                }
                ColorPicker("Other color", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Other color")
            }
            .disabled(!model.tool.usesColor)
            .opacity(model.tool.usesColor ? 1 : 0.35)

            if model.showsMagnifierOptions {
                Picker("Shape", selection: $model.magnifierRound) {
                    Image(systemName: "circle").help("Circle").tag(true)
                    Image(systemName: "square").help("Rectangle").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Picker(model.tool.usesColor ? "Weight" : "Strength", selection: $model.weight) {
                ForEach(LineWeight.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(model.tool.usesColor ? "Line weight and text size" : "Strength of the effect")

            Spacer(minLength: 8)

            if let status = model.status {
                Text(status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button(action: onBackdrop) {
                Image(systemName: model.backdrop == nil ? "rectangle.inset.filled" : "rectangle.inset.filled.on.rectangle")
            }
            .help("Backdrop and frame for sharing (⌘B)")

            Button(action: onRecognize) {
                Image(systemName: "text.viewfinder")
            }
            .help("Recognize text and QR codes")

            Button(action: onUpload) {
                Image(systemName: "icloud.and.arrow.up")
            }
            .help("Upload and copy the link (⌘U)")

            Button(action: onPin) {
                Image(systemName: "pin")
            }
            .help("Pin on top (⌘P)")

            Button {
                model.undoManager.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Undo (⌘Z)")

            Button {
                model.copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy to the clipboard (⌘C)")

            Button(action: onSave) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save to the folder set in Preferences (⌘S). Save as… with ⇧⌘S")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.default, value: model.status)
    }
}

private struct ColorSwatch: View {
    let color: RGBAColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                .frame(width: 16, height: 16)
                .padding(2)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
    }
}
