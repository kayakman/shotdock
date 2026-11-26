import AppKit
import ShotDockCore
import SwiftUI

/// The export profile a destination uses.
struct ProfilePicker: View {
    @Bindable var settings: AppSettings
    let destination: ExportDestination

    var body: some View {
        Picker("", selection: Binding(get: { settings.profile(for: destination).id },
                                      set: { settings.destinationProfiles[destination] = $0 })) {
            ForEach(settings.exportProfiles) { profile in
                Text(verbatim: "\(profile.name) — \(profile.summary)").tag(profile.id)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Export profiles (named format, quality and size) and where each is used.
struct ExportPreferences: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Save to folder:") { ProfilePicker(settings: settings, destination: .save) }
            LabeledContent("Upload:") { ProfilePicker(settings: settings, destination: .upload) }
            LabeledContent("Drag to other apps:") { ProfilePicker(settings: settings, destination: .drag) }

            Divider()

            LabeledContent("Profiles:") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($settings.exportProfiles) { $profile in
                        ProfileRow(profile: $profile, canDelete: settings.exportProfiles.count > 1) { remove(profile) }
                    }
                    HStack {
                        Button("Add Profile") {
                            settings.exportProfiles.append(ExportProfile(name: String(localized: "New profile"), format: .png))
                        }
                        Button("Restore Defaults") {
                            settings.exportProfiles = ExportProfile.defaults()
                            settings.destinationProfiles = [:]
                        }
                    }
                    Text("WebP is written without loss. Copying to the clipboard always uses PNG, which every app accepts.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 440, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.columns)
    }

    private func remove(_ profile: ExportProfile) {
        settings.exportProfiles.removeAll { $0.id == profile.id }
        for (destination, id) in settings.destinationProfiles where id == profile.id { settings.destinationProfiles[destination] = nil }
    }
}

private struct ProfileRow: View {
    @Binding var profile: ExportProfile
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $profile.name, prompt: Text("Name")).labelsHidden().frame(width: 120)
            Picker("Format", selection: $profile.format) {
                ForEach(ImageFormat.available, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 80)
            if profile.format.hasQuality {
                Slider(value: $profile.quality, in: 0.1...1).frame(width: 90)
                Text(verbatim: "\(Int((profile.quality * 100).rounded())) %").monospacedDigit().frame(width: 40, alignment: .trailing)
            } else {
                Text(profile.format == .webp ? "lossless" : "no loss").foregroundStyle(.secondary).frame(width: 138, alignment: .leading)
            }
            TextField("", value: $profile.maxWidth, format: .number.grouping(.never), prompt: Text("max. width")).labelsHidden().frame(width: 80)
            Text(verbatim: "px").foregroundStyle(.secondary)
            Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(!canDelete)
                .help("Remove the profile")
        }
    }
}
