import ShotDockCore
import SwiftUI

struct EditorToolbar: View {
    @Bindable var model: EditorModel
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Herramienta", selection: $model.tool) {
                ForEach(EditorTool.allCases) { tool in
                    Image(systemName: tool.symbol)
                        .help("\(tool.title) (\(tool.key.uppercased()))")
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
            }

            Picker("Grosor", selection: $model.weight) {
                ForEach(LineWeight.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            if let status = model.status {
                Text(status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button {
                model.undoManager.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Deshacer (⌘Z)")

            Button {
                model.copyToClipboard()
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
            .help("Copiar al portapapeles (⌘C)")

            Button(action: onSave) {
                Label("Guardar", systemImage: "square.and.arrow.down")
            }
            .help("Guardar en la carpeta de Preferencias (⌘S). Guardar como… con ⇧⌘S")
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
