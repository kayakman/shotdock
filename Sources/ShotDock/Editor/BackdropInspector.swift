import ShotDockCore
import SwiftUI

/// Side panel to frame the capture for sharing.
struct BackdropInspector: View {
    @Bindable var model: EditorModel

    private var enabled: Binding<Bool> {
        Binding(get: { model.backdrop != nil }, set: { model.setBackdropEnabled($0) })
    }

    private var current: Backdrop { model.backdrop ?? AppSettings.shared.lastBackdrop }

    var body: some View {
        Form {
            Toggle("Backdrop", isOn: enabled)
                .toggleStyle(.switch)
                .font(.headline)

            Section("Fill") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(Backdrop.presets.enumerated()), id: \.offset) { _, fill in
                        Button { set(\.fill, fill) } label: {
                            FillSwatch(fill: fill, selected: current.fill == fill)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text("Custom")
                    Spacer()
                    ColorPicker("From", selection: colorBinding(0), supportsOpacity: false).labelsHidden()
                    ColorPicker("To", selection: colorBinding(1), supportsOpacity: false).labelsHidden()
                }
            }
            .disabled(model.backdrop == nil)

            Section("Frame") {
                slider("Padding", \.padding, 0...160)
                slider("Corners", \.cornerRadius, 0...40)
                slider("Shadow", \.shadow, 0...1)
                Picker("Aspect Ratio", selection: Binding(get: { current.aspect }, set: { set(\.aspect, $0) })) {
                    ForEach(Backdrop.Aspect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            .disabled(model.backdrop == nil)
        }
        .formStyle(.grouped)
        .frame(width: 270)
    }

    private func set<T>(_ keyPath: WritableKeyPath<Backdrop, T>, _ value: T, live: Bool = false) {
        var backdrop = current
        backdrop[keyPath: keyPath] = value
        model.updateBackdrop(backdrop, live: live)
    }

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<Backdrop, CGFloat>, _ range: ClosedRange<CGFloat>) -> some View {
        LabeledContent(title) {
            Slider(value: Binding(get: { current[keyPath: keyPath] }, set: { set(keyPath, $0, live: true) }), in: range) { editing in
                if !editing { model.commitBackdropEdit() }
            }
        }
    }

    /// The two colours of a custom gradient (a solid fill counts as both).
    private func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                switch current.fill {
                case let .gradient(a, b, _): Color(cgColor: (index == 0 ? a : b).cgColor)
                case let .solid(c): Color(cgColor: c.cgColor)
                }
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                let picked = RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
                var (a, b, angle): (RGBAColor, RGBAColor, Double)
                switch current.fill {
                case let .gradient(x, y, z): (a, b, angle) = (x, y, z)
                case let .solid(x): (a, b, angle) = (x, x, 45)
                }
                if index == 0 { a = picked } else { b = picked }
                set(\.fill, .gradient(a, b, angle: angle))
            })
    }
}

private struct FillSwatch: View {
    let fill: Backdrop.Fill
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(style)
            .frame(width: 44, height: 32)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
    }

    private var style: AnyShapeStyle {
        switch fill {
        case let .gradient(a, b, _):
            AnyShapeStyle(LinearGradient(colors: [Color(cgColor: a.cgColor), Color(cgColor: b.cgColor)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
        case let .solid(c):
            AnyShapeStyle(Color(cgColor: c.cgColor))
        }
    }
}
