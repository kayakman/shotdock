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
            LabeledContent("After capturing:") {
                Toggle("Upload each capture and copy the link", isOn: $settings.uploadAfterCapture)
                    .disabled(!settings.s3.isComplete)
            }
            Divider()
            Picker("Provider:", selection: provider) {
                ForEach(S3Configuration.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            TextField("Endpoint:", text: $settings.s3.endpoint, prompt: Text(verbatim: "https://s3.eu-west-1.amazonaws.com"))
            TextField("Region:", text: $settings.s3.region)
            TextField("Bucket:", text: $settings.s3.bucket)
            TextField("Folder:", text: $settings.s3.prefix, prompt: Text("captures/"))
            LabeledContent("") {
                Toggle("Bucket in the path (path-style; R2 and MinIO)", isOn: $settings.s3.pathStyle)
            }
            Divider()
            TextField("Access key ID:", text: $accessKey)
            SecureField("Secret access key:", text: $secretKey)
            LabeledContent("") {
                HStack {
                    Button("Save keys in the keychain") { saveKeys() }.disabled(accessKey.isEmpty || secretKey.isEmpty)
                    if keysSaved { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            Divider()
            Picker("Link:", selection: $settings.s3.linkMode) {
                Text("Public").tag(S3Configuration.LinkMode.publicURL)
                Text("Signed (expires)").tag(S3Configuration.LinkMode.presigned)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            if settings.s3.linkMode == .publicURL {
                TextField("Public URL:", text: $settings.s3.publicBaseURL, prompt: Text("https://img.example.com (optional)"))
                LabeledContent("") {
                    Toggle("Mark as public (ACL public-read)", isOn: $settings.s3.publicReadACL)
                }
            } else {
                Picker("Expires in:", selection: $settings.s3.presignExpiry) {
                    Text("1 hour").tag(3600)
                    Text("1 day").tag(86400)
                    Text("7 days").tag(604_800)
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
                    Button("Test connection") { test() }
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
        let key = settings.s3.key(for: UploadNaming.objectName(base: CaptureNaming.defaultName(for: Date()), format: settings.profile(for: .upload).format, random: "k7x2m9qa"))
        let url = settings.s3.linkMode == .publicURL ? settings.s3.publicLink(key: key) : settings.s3.objectURL(key: key)
        return url.map { String(localized: "Example: \($0.absoluteString + (settings.s3.linkMode == .presigned ? "?X-Amz-…" : ""))") }
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
                testState = .ok(String(localized: "Connection works: test file uploaded and deleted"))
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
