import Foundation

/// The commands, in the order help lists them. Each phase of the CLI adds
/// its own; the app answers every `.app` command.
public enum CommandCatalog {
    public static let all: [CommandSpec] = general

    public static func command(_ name: String) -> CommandSpec? { all.first { $0.name == name } }

    /// The commands that are MCP tools.
    public static var tools: [CommandSpec] { all.filter { $0.mcpName != nil } }

    /// The whole catalog as JSON (`shotdock schema`), for agents and docs.
    public static func schema(_ commands: [CommandSpec] = all) -> JSONValue {
        .array(commands.map { spec in
            var entry: [String: JSONValue] = [
                "name": .string(spec.name),
                "command": .string((["shotdock"] + spec.path).joined(separator: " ")),
                "summary": .string(spec.summary),
                "params": spec.inputSchema,
            ]
            if !spec.details.isEmpty { entry["details"] = .string(spec.details) }
            if let tool = spec.mcpName { entry["mcp_tool"] = .string(tool) }
            if case let .alias(of: target) = spec.exposure { entry["alias_of"] = .string(target) }
            if spec.returnsImage { entry["returns_image"] = true }
            if spec.readOnly { entry["read_only"] = true }
            if spec.destructive { entry["destructive"] = true }
            return .object(entry)
        })
    }

    // MARK: General

    static let general: [CommandSpec] = [
        CommandSpec("status", "ShotDock's version, permissions and displays", readOnly: true),
        CommandSpec("schema", "Print every command and its parameters as JSON", exposure: .local, readOnly: true),
    ]
}
