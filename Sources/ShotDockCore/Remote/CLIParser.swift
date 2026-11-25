import Foundation

/// A command ready to send: the target command and its checked parameters.
public struct CLIInvocation: Sendable {
    public var command: CommandSpec
    public var params: [String: JSONValue]
    /// Print the result as JSON instead of text.
    public var json: Bool
    /// Seconds to wait for the app; nil uses the client's default.
    public var timeout: Double?
}

public enum CLIRequest: Sendable {
    case run(CLIInvocation)
    /// Text to print (help or usage); not an error.
    case help(String)
    case version
}

public struct CLIError: Error, LocalizedError, Equatable {
    public var message: String
    /// Help for the command that failed, shown below the message.
    public var usage: String?

    public var errorDescription: String? { message }
}

/// Turns `shotdock capture area --rect 0,0,800,600 --json` into a command
/// and JSON parameters, using the catalog. Help comes from the same specs.
public struct CLIParser: Sendable {
    public let commands: [CommandSpec]
    public var readStdin: @Sendable () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
    public var readFile: @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    /// Relative paths are resolved from here: the app runs elsewhere.
    public var workingDirectory = FileManager.default.currentDirectoryPath

    public init(commands: [CommandSpec] = CommandCatalog.all) {
        self.commands = commands
    }

    public func parse(_ arguments: [String]) throws -> CLIRequest {
        var args = arguments
        var json = false, help = false
        var timeout: Double?
        // Global flags go anywhere before "--".
        var index = 0
        while index < args.count, args[index] != "--" {
            switch args[index] {
            case "--json": json = true; args.remove(at: index)
            case "-h", "--help": help = true; args.remove(at: index)
            case "--version" where args.count == 1: return .version
            case "--timeout":
                guard index + 1 < args.count, let seconds = Double(args[index + 1]), seconds > 0 else {
                    throw CLIError(message: "--timeout needs a number of seconds")
                }
                timeout = seconds
                args.removeSubrange(index...index + 1)
            case let arg where arg.hasPrefix("--timeout="):
                guard let seconds = Double(arg.dropFirst("--timeout=".count)), seconds > 0 else {
                    throw CLIError(message: "--timeout needs a number of seconds")
                }
                timeout = seconds
                args.remove(at: index)
            default: index += 1
            }
        }
        if args.first == "help" { args.removeFirst(); help = true }
        if args.first == "version" { return .version }

        let words = Array(args.prefix { !$0.hasPrefix("-") || $0 == "-" })
        guard let (spec, depth) = resolve(words) else {
            if words.isEmpty { return .help(generalHelp()) }
            if let group = groupHelp(words) { return .help(group) }
            let known = (1..<max(words.count, 1)).reversed().lazy.compactMap { groupHelp(Array(words.prefix($0))) }.first
            throw CLIError(message: "Unknown command: \(words.joined(separator: " "))", usage: known ?? generalHelp())
        }
        if help { return .help(self.help(for: spec)) }

        var params = spec.resolvingPaths(try parseParams(Array(args.dropFirst(depth)), for: spec), from: workingDirectory)
        params = try check(spec.validate(.object(params)), spec)
        var target = spec
        if case let .alias(of: name) = spec.exposure {
            guard let real = command(name), let transform = spec.transform else {
                throw CLIError(message: "\(spec.name) points to a missing command \(name)")
            }
            target = real
            params = try check(real.validate(transform(params)), spec)
        }
        return .run(CLIInvocation(command: target, params: params, json: json, timeout: timeout))
    }

    public func command(_ name: String) -> CommandSpec? { commands.first { $0.name == name } }

    /// The command named by the longest run of leading words.
    private func resolve(_ words: [String]) -> (CommandSpec, Int)? {
        for depth in stride(from: min(words.count, 4), through: 1, by: -1) {
            let path = Array(words.prefix(depth))
            if let spec = commands.first(where: { $0.path == path }) { return (spec, depth) }
        }
        return nil
    }

    private func check(_ body: @autoclosure () throws -> [String: JSONValue], _ spec: CommandSpec) throws -> [String: JSONValue] {
        do {
            return try body()
        } catch let error as RPCError {
            // "capture.area: missing rect" → "missing --rect"
            var message = error.message
            if message.hasPrefix(spec.name + ": ") { message.removeFirst(spec.name.count + 2) }
            throw CLIError(message: message, usage: help(for: spec))
        }
    }

    // MARK: Parameters

    private func parseParams(_ tokens: [String], for spec: CommandSpec) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        var positionals = spec.params.filter(\.positional)
        var onlyPositionals = false
        var i = 0
        func usage(_ message: String) -> CLIError { CLIError(message: message, usage: help(for: spec)) }

        func assign(_ param: ParamSpec, _ text: String) throws {
            let value = try parseValue(text, as: param)
            if case .strings = param.kind {
                params[param.name] = .array((params[param.name]?.arrayValue ?? []) + (value.arrayValue ?? []))
            } else if params[param.name] != nil {
                throw usage("\(param.positional ? param.name : param.flag) given twice")
            } else {
                params[param.name] = value
            }
        }

        while i < tokens.count {
            let token = tokens[i]
            i += 1
            if token == "--" && !onlyPositionals { onlyPositionals = true; continue }
            if !onlyPositionals, token.hasPrefix("--") {
                var flag = token, inline: String?
                if let eq = token.firstIndex(of: "=") {
                    flag = String(token[..<eq])
                    inline = String(token[token.index(after: eq)...])
                }
                if let param = spec.params.first(where: { $0.flag == flag && !$0.positional }) {
                    if case .boolean = param.kind {
                        guard let inline else { params[param.name] = true; continue }
                        guard let bool = Self.bool(inline) else { throw usage("\(flag) takes true or false") }
                        params[param.name] = .bool(bool)
                        continue
                    }
                    guard let text = inline ?? (i < tokens.count ? tokens[i] : nil) else {
                        throw usage("\(flag) needs a value (\(metavar(param)))")
                    }
                    if inline == nil { i += 1 }
                    try assign(param, text)
                } else if flag.hasPrefix("--no-"), inline == nil,
                          let param = spec.params.first(where: { "--no-" + $0.flag.dropFirst(2) == flag }), case .boolean = param.kind {
                    params[param.name] = false
                } else {
                    throw usage("Unknown option \(flag) for \(spec.path.joined(separator: " "))")
                }
            } else {
                guard let param = positionals.first else { throw usage("Unexpected argument \"\(token)\"") }
                try assign(param, token)
                if case .strings = param.kind {} else { positionals.removeFirst() }
            }
        }
        return params
    }

    private func parseValue(_ text: String, as param: ParamSpec) throws -> JSONValue {
        let label = param.positional ? param.name : param.flag
        func bad() -> CLIError { CLIError(message: "\(label): \"\(text)\" is not \(param.kindDescription) (\(metavar(param)))", usage: nil) }
        func numbers(_ count: Int) throws -> [Double] {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == count, parts.allSatisfy({ $0 != nil }) else { throw bad() }
            return parts.map { $0! }
        }
        switch param.kind {
        case .string, .color, .choice, .reference: return .string(text)
        case .path: return .string(CommandSpec.absolute(text, from: workingDirectory))
        case .integer:
            guard let value = Int(text) else { throw bad() }
            return .number(Double(value))
        case .number:
            guard let value = Double(text) else { throw bad() }
            return .number(value)
        case .boolean:
            guard let value = Self.bool(text) else { throw bad() }
            return .bool(value)
        case .point:
            let v = try numbers(2)
            return ["x": .number(v[0]), "y": .number(v[1])]
        case .rect:
            let v = try numbers(4)
            return ["x": .number(v[0]), "y": .number(v[1]), "width": .number(v[2]), "height": .number(v[3])]
        case .strings: return [.string(text)]
        case .json:
            let data: Data
            if text == "-" {
                data = readStdin()
            } else if text.hasPrefix("@") {
                do { data = try readFile(String(text.dropFirst())) } catch { throw CLIError(message: "\(label): cannot read \(text.dropFirst())") }
            } else {
                data = Data(text.utf8)
            }
            do {
                return try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw CLIError(message: "\(label): not valid JSON", usage: nil)
            }
        }
    }

    private static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: nil
        }
    }

    // MARK: Help

    private func metavar(_ param: ParamSpec) -> String {
        switch param.kind {
        case .string: "text"
        case .path: "path"
        case .reference: "capture"
        case .integer, .number: "n"
        case .boolean: "true|false"
        case .point: "x,y"
        case .rect: "x,y,w,h"
        case .color: "colour"
        case let .choice(values): values.joined(separator: "|")
        case .strings: "text"
        case .json: "json|@file|-"
        }
    }

    private func usageLine(_ spec: CommandSpec) -> String {
        var parts = ["shotdock"] + spec.path
        for param in spec.params where param.positional {
            var word = "<\(param.name)>"
            if case .strings = param.kind { word = "<\(param.name)…>" }
            parts.append(param.required ? word : "[\(word)]")
        }
        if spec.params.contains(where: { !$0.positional }) { parts.append("[options]") }
        return parts.joined(separator: " ")
    }

    public func help(for spec: CommandSpec) -> String {
        var lines = ["Usage: " + usageLine(spec), "", spec.summary]
        if !spec.details.isEmpty { lines += ["", spec.details] }
        let rows: [(String, String)] = spec.params.map { param in
            var left = param.positional ? "<\(param.name)>" : param.flag
            if !param.positional {
                if case .boolean = param.kind {
                    left = param.defaultValue == true ? "--[no-]" + param.flag.dropFirst(2) : param.flag
                } else {
                    left += " " + metavar(param)
                }
            }
            var right = param.summary
            if param.required { right += " (required)" }
            if let value = param.defaultValue, value != false { right += " [default: \(value.stringValue ?? value.jsonString())]" }
            return (left, right)
        } + [("--json", "Print the result as JSON"), ("--timeout s", "Seconds to wait for ShotDock")]
        let width = min(rows.map(\.0.count).max() ?? 0, 28)
        lines += ["", "Options:"] + rows.map { left, right in
            left.count > width ? "  \(left)\n  \(String(repeating: " ", count: width))  \(right)"
                : "  \(left.padding(toLength: width, withPad: " ", startingAt: 0))  \(right)"
        }
        return lines.joined(separator: "\n")
    }

    private func groupHelp(_ prefix: [String]) -> String? {
        let members = commands.filter { $0.path.starts(with: prefix) && $0.path.count > prefix.count }
        guard !members.isEmpty else { return nil }
        return "Usage: shotdock \(prefix.joined(separator: " ")) <command>\n\n" + table(members)
    }

    public func generalHelp() -> String {
        """
        ShotDock from the command line and for AI agents.

        Usage: shotdock <command> [options] [--json]

        \(table(commands))

        Screen rectangles are in points, global, with the origin at the top-left of the
        main display. Positions on an image are in pixels from its top-left corner.
        `shotdock help <command>` shows a command's options.
        """
    }

    private func table(_ specs: [CommandSpec]) -> String {
        let names = specs.map { $0.path.joined(separator: " ") }
        let width = names.map(\.count).max() ?? 0
        return zip(names, specs).map { "  \($0.padding(toLength: width, withPad: " ", startingAt: 0))  \($1.summary)" }
            .joined(separator: "\n")
    }
}
