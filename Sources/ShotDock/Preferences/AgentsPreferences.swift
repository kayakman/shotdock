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
            LabeledContent("Agents:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Allow the CLI and AI agents to control ShotDock", isOn: $settings.agentControlEnabled)
                    Text("With `shotdock` in the terminal, or its MCP server in Claude Code, Codex or Cursor, an agent can capture, edit and upload images, read the history and change the preferences. The first time an agent uses it, ShotDock asks you.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 400, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Allowed:") {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.approvedAgents.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(settings.approvedAgents) { agent in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.title)
                                Text(usage(agent)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { settings.approvedAgents.removeAll { $0.id == agent.id } }
                        }
                        .frame(width: 400)
                    }
                }
            }

            Divider()

            LabeledContent("Terminal:") {
                VStack(alignment: .leading, spacing: 6) {
                    if let installed {
                        Text("`shotdock` installed in \(installed.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    } else {
                        Text("`shotdock` is not in the PATH").foregroundStyle(.secondary)
                    }
                    Button(installed == nil ? "Install `shotdock`" : "Reinstall") {
                        do {
                            installed = try CLIInstaller.install()
                        } catch {
                            installError = String(localized: "Could not create the link. In the terminal:") + "\nln -sf '\(CLIInstaller.helperURL.path)' /usr/local/bin/shotdock"
                        }
                    }
                    Text("For Claude Code: `claude mcp add shotdock -- shotdock mcp`")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Copy the command for Claude Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude mcp add shotdock -- \(installed == nil ? CLIInstaller.helperURL.path : "shotdock") mcp",
                                                       forType: .string)
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
        if let date = agent.approvedAt { parts.append(String(localized: "Allowed on \(date.formatted(date: .abbreviated, time: .omitted))")) }
        if let date = agent.lastUsed { parts.append(String(localized: "last used \(date.formatted(.relative(presentation: .named)))")) }
        return parts.joined(separator: " · ")
    }
}
