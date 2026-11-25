import AppKit
import ShotDockCore
import SwiftUI

/// Installs `shotdock` on the PATH as a link to the binary in the bundle.
@MainActor
enum CLIInstaller {
    static var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shotdock") }

    static let candidates = ["/usr/local/bin", NSHomeDirectory() + "/.local/bin"]

    /// The link pointing at this app's helper, if there is one.
    static var installedPath: String? {
        candidates.map { $0 + "/shotdock" }.first { path in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == helperURL.path
        }
    }

    /// Links /usr/local/bin/shotdock, or ~/.local/bin/shotdock when that is not writable.
    @discardableResult
    static func install() throws -> String {
        let fileManager = FileManager.default
        for folder in candidates {
            try? fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard fileManager.isWritableFile(atPath: folder) else { continue }
            let link = folder + "/shotdock"
            if (try? fileManager.attributesOfItem(atPath: link)) != nil { try fileManager.removeItem(atPath: link) }
            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: helperURL.path)
            return link
        }
        throw CocoaError(.fileWriteNoPermission)
    }
}

struct AgentsPreferences: View {
    @Bindable var settings: AppSettings
    @State private var installed = CLIInstaller.installedPath
    @State private var installError: String?

    var body: some View {
        Form {
            LabeledContent("Agentes:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Permitir que la CLI y los agentes de IA controlen ShotDock", isOn: $settings.agentControlEnabled)
                    Text("Con `shotdock` en la terminal, o su servidor MCP en Claude Code, Codex o Cursor, un agente puede capturar, editar y subir imágenes, leer el historial y cambiar las preferencias. La primera vez que un agente lo use, ShotDock te pedirá permiso.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 400, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Con permiso:") {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.approvedAgents.isEmpty {
                        Text("Ninguno todavía").foregroundStyle(.secondary)
                    }
                    ForEach(settings.approvedAgents) { agent in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.title)
                                Text(usage(agent)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Retirar") { settings.approvedAgents.removeAll { $0.id == agent.id } }
                        }
                        .frame(width: 400)
                    }
                }
            }

            Divider()

            LabeledContent("Terminal:") {
                VStack(alignment: .leading, spacing: 6) {
                    if let installed {
                        Text("`shotdock` instalado en \(installed.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    } else {
                        Text("`shotdock` no está en el PATH").foregroundStyle(.secondary)
                    }
                    Button(installed == nil ? "Instalar `shotdock`" : "Volver a instalar") {
                        do {
                            installed = try CLIInstaller.install()
                        } catch {
                            installError = "No se pudo crear el enlace. En la terminal:\nln -sf '\(CLIInstaller.helperURL.path)' /usr/local/bin/shotdock"
                        }
                    }
                    if let installError {
                        Text(installError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: 400, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.columns)
    }

    private func usage(_ agent: AgentClient) -> String {
        var parts: [String] = []
        if let date = agent.approvedAt { parts.append("Permitido el \(date.formatted(date: .abbreviated, time: .omitted))") }
        if let date = agent.lastUsed { parts.append("último uso \(date.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}
