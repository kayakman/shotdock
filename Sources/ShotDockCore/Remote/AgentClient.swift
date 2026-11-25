import Darwin
import Foundation

/// Who is driving ShotDock through `shotdock`: the agent (claude, codex,
/// Cursor…) and the app it runs in (Terminal, iTerm…). The user approves
/// each one once.
public struct AgentClient: Codable, Equatable, Sendable, Identifiable {
    /// "claude|com.apple.Terminal": what an approval is remembered by.
    public var id: String
    public var agent: String
    public var appName: String?
    public var appBundleID: String?
    public var approvedAt: Date?
    public var lastUsed: Date?

    public init(agent: String, appName: String?, appBundleID: String?) {
        self.agent = agent
        self.appName = appName
        self.appBundleID = appBundleID
        id = [agent.lowercased(), appBundleID ?? appName ?? ""].joined(separator: "|")
    }

    /// "claude en Terminal".
    public var title: String {
        guard let appName, appName.caseInsensitiveCompare(agent) != .orderedSame else { return agent }
        return "\(agent) en \(appName)"
    }

    /// One process of the chain that started `shotdock`.
    public struct Process: Equatable, Sendable {
        public var path: String
        public var arguments: [String]

        public init(path: String, arguments: [String] = []) {
            self.path = path
            self.arguments = arguments
        }

        var name: String { (path as NSString).lastPathComponent }
    }

    /// Programs that only pass the call along.
    static let wrappers: Set<String> = [
        "shotdock", "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "login", "env", "sudo", "su",
        "nohup", "timeout", "xargs", "make", "tmux", "screen", "script", "npx", "npm", "uv", "uvx", "pnpm", "yarn",
    ]
    /// Interpreters: the script they run names the agent.
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl"]

    /// Names the client from the process chain, `shotdock` first, parents after.
    /// `bundleID` looks up an app bundle's identifier.
    public static func identify(chain: [Process], bundleID: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }) -> AgentClient {
        func appBundle(_ path: String) -> String? {
            // The outermost .app: helpers live inside their app.
            guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
            let bundle = String(path[..<range.upperBound])
            return bundle.hasSuffix("/") ? String(bundle.dropLast()) : bundle
        }
        func appName(_ bundle: String) -> String { ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension }

        let callers = chain.dropFirst().filter { !wrappers.contains($0.name.lowercased()) && !$0.name.hasPrefix("-") }
        let outerApp = chain.compactMap { appBundle($0.path) }.last
        guard let caller = callers.first else {
            return AgentClient(agent: outerApp.map(appName) ?? "shotdock", appName: outerApp.map(appName), appBundleID: outerApp.flatMap(bundleID))
        }
        var agent = caller.name
        if ["exe", "js", "mjs", "py", "sh"].contains((agent as NSString).pathExtension.lowercased()) {
            agent = (agent as NSString).deletingPathExtension
        }
        if let bundle = appBundle(caller.path) {
            agent = appName(bundle)
        } else if interpreters.contains(agent.lowercased()),
                  let script = caller.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            agent = ((script as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return AgentClient(agent: agent, appName: outerApp.map(appName), appBundleID: outerApp.flatMap(bundleID))
    }
}

/// The processes from `pid` up to (not including) launchd.
public enum ProcessLineage {
    public static func chain(from pid: pid_t, limit: Int = 24) -> [AgentClient.Process] {
        var result: [AgentClient.Process] = []
        var current = pid
        while current > 1, result.count < limit {
            guard let path = executablePath(current) else { break }
            result.append(AgentClient.Process(path: path, arguments: arguments(current)))
            guard let parent = parentPID(current), parent != current else { break }
            current = parent
        }
        return result
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// argv of a process of the same user (KERN_PROCARGS2), or [] if unreadable.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // argc, the executable path, padding NULs, then argv strings.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
