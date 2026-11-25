import AppKit
import ShotDockCore
import SwiftUI

struct UploadPreferences: View {
    @Bindable var settings: AppSettings
    let window: () -> NSWindow?

    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var keysSaved = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    var body: some View {
        Form {
            LabeledContent("Después de capturar:") {
                Toggle("Subir cada captura y copiar el enlace", isOn: $settings.uploadAfterCapture)
                    .disabled(!settings.s3.isComplete)
            }
            Divider()
            Picker("Proveedor:", selection: provider) {
                ForEach(S3Configuration.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            TextField("Endpoint:", text: $settings.s3.endpoint, prompt: Text("https://s3.eu-west-1.amazonaws.com"))
            TextField("Región:", text: $settings.s3.region)
            TextField("Bucket:", text: $settings.s3.bucket)
            TextField("Carpeta:", text: $settings.s3.prefix, prompt: Text("capturas/"))
            LabeledContent("") {
                Toggle("Bucket en la ruta (path-style; R2 y MinIO)", isOn: $settings.s3.pathStyle)
            }
            Divider()
            TextField("Access key ID:", text: $accessKey)
            SecureField("Secret access key:", text: $secretKey)
            LabeledContent("") {
                HStack {
                    Button("Guardar claves en el llavero") { saveKeys() }.disabled(accessKey.isEmpty || secretKey.isEmpty)
                    if keysSaved { Label("Guardadas", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            Divider()
            Picker("Enlace:", selection: $settings.s3.linkMode) {
                Text("Público").tag(S3Configuration.LinkMode.publicURL)
                Text("Firmado (caduca)").tag(S3Configuration.LinkMode.presigned)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            if settings.s3.linkMode == .publicURL {
                TextField("URL pública:", text: $settings.s3.publicBaseURL, prompt: Text("https://img.ejemplo.com (opcional)"))
                LabeledContent("") {
                    Toggle("Marcar como público (ACL public-read)", isOn: $settings.s3.publicReadACL)
                }
            } else {
                Picker("Caduca en:", selection: $settings.s3.presignExpiry) {
                    Text("1 hora").tag(3600)
                    Text("1 día").tag(86400)
                    Text("7 días").tag(604_800)
                }
                .fixedSize()
            }
            if let example = exampleLink {
                LabeledContent("") {
                    Text(example).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                        .frame(maxWidth: 380, alignment: .leading)
                }
            }
            LabeledContent("") {
                HStack {
                    Button("Probar conexión") { test() }
                        .disabled(!settings.s3.isComplete || testState == .running)
                    switch testState {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case let .ok(message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case let .failed(message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                        .frame(maxWidth: 300, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.columns)
        .onAppear(perform: loadKeys)
    }

    private var provider: Binding<S3Configuration.Provider> {
        Binding(get: { settings.s3.provider }, set: { newValue in
            settings.s3.switchProvider(to: newValue)
        })
    }

    private var exampleLink: String? {
        guard settings.s3.isComplete else { return nil }
        let key = settings.s3.key(for: "shotdock-2026-11-25-a-las-10-58-40-k7x2m9qa.png")
        let url = settings.s3.linkMode == .publicURL ? settings.s3.publicLink(key: key) : settings.s3.objectURL(key: key)
        return url.map { "Ejemplo: \($0.absoluteString)" + (settings.s3.linkMode == .presigned ? "?X-Amz-…" : "") }
    }

    private func loadKeys() {
        if let credentials = Keychain.loadS3Credentials() {
            accessKey = credentials.accessKeyID
            secretKey = credentials.secretAccessKey
            keysSaved = true
        }
    }

    private func saveKeys() {
        keysSaved = Keychain.saveS3Credentials(S3Credentials(accessKeyID: accessKey.trimmingCharacters(in: .whitespaces),
                                                             secretAccessKey: secretKey.trimmingCharacters(in: .whitespaces)))
    }

    private func test() {
        if !accessKey.isEmpty, !secretKey.isEmpty { saveKeys() }
        testState = .running
        Task {
            do {
                _ = try await Uploader.testConnection()
                testState = .ok("Conexión correcta: subida y borrado de prueba")
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
