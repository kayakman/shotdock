import Foundation

/// A preference agents can read and change (`shotdock prefs`).
public struct PreferenceSpec: Sendable {
    public enum Kind: Sendable, Equatable {
        case boolean
        case integer(ClosedRange<Int>)
        case text
        case path
        case choice([String])
        /// Shown, not changed from outside (agent control, S3 keys).
        case readOnly
    }

    public let key: String
    public let summary: String
    public let kind: Kind

    public init(_ key: String, _ kind: Kind, _ summary: String) {
        self.key = key
        self.kind = kind
        self.summary = summary
    }

    public var typeDescription: String {
        switch kind {
        case .boolean: "true|false"
        case let .integer(range): "\(range.lowerBound)…\(range.upperBound)"
        case .text: "text"
        case .path: "folder"
        case let .choice(values): values.joined(separator: "|")
        case .readOnly: "read-only"
        }
    }

    /// The value in the preference's type, from JSON or command-line text.
    public func coerce(_ value: JSONValue) throws -> JSONValue {
        func bad() -> RPCError { RPCError.invalidParams("\(key) takes \(typeDescription)") }
        switch kind {
        case .readOnly:
            throw RPCError.invalidParams("\(key) cannot be changed from outside ShotDock")
        case .boolean:
            if let bool = value.boolValue { return .bool(bool) }
            switch value.stringValue?.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: throw bad()
            }
        case let .integer(range):
            let number = value.intValue ?? value.stringValue.flatMap { Int($0) }
            guard let number else { throw bad() }
            guard range.contains(number) else { throw RPCError.invalidParams("\(key) must be between \(range.lowerBound) and \(range.upperBound)") }
            return .number(Double(number))
        case .text, .path:
            if let text = value.stringValue { return .string(text) }
            if let number = value.doubleValue { return .string(JSONValue.number(number).jsonString()) }
            throw bad()
        case let .choice(values):
            guard let text = value.stringValue, values.contains(text) else { throw bad() }
            return .string(text)
        }
    }
}

public enum Preferences {
    public static let all: [PreferenceSpec] = [
        PreferenceSpec("language", .choice(["system", "en", "es"]), "Language of the interface; applies when ShotDock restarts"),
        PreferenceSpec("copy_after_capture", .boolean, "Copy each capture to the clipboard (captures from the menu and shortcuts)"),
        PreferenceSpec("open_editor_after_capture", .boolean, "Open the editor after each capture"),
        PreferenceSpec("save_after_capture", .boolean, "Save each capture in the folder"),
        PreferenceSpec("upload_after_capture", .boolean, "Upload each capture and copy the link"),
        PreferenceSpec("save_folder", .path, "Folder where captures are saved"),
        PreferenceSpec("filename_template", .text, "File name: {date} {time} {year} {month} {day} {h} {min} {s} {n} (or {fecha} {hora} {año} {mes} {día})"),
        PreferenceSpec("image_format", .choice(["png", "jpeg"]), "Format of saved and uploaded files"),
        PreferenceSpec("capture_delay", .integer(1...30), "Seconds of the delayed capture"),
        PreferenceSpec("window_shadow", .boolean, "Window captures include the shadow"),
        PreferenceSpec("scroll_max_height", .integer(1000...100_000), "Tallest scrolling capture, in pixels"),
        PreferenceSpec("color_format", .choice(["hex", "rgb"]), "Format the eyedropper copies"),
        PreferenceSpec("ocr_join_lines", .boolean, "OCR joins the lines into one paragraph"),
        PreferenceSpec("history_limit", .integer(0...1_000_000), "Captures the history keeps; 0 turns it off, \"all\" keeps every one"),
        PreferenceSpec("show_in_dock", .boolean, "Show ShotDock in the Dock while its windows are open"),
        PreferenceSpec("launch_at_login", .boolean, "Open ShotDock when logging in"),
        PreferenceSpec("agent_control", .readOnly, "The CLI and agents may control ShotDock (only from the preferences)"),
        PreferenceSpec("s3.provider", .choice(["aws", "r2", "b2", "minio", "custom"]), "S3 service; fills in the usual endpoint and region"),
        PreferenceSpec("s3.endpoint", .text, "S3 endpoint URL"),
        PreferenceSpec("s3.region", .text, "S3 region"),
        PreferenceSpec("s3.bucket", .text, "Bucket"),
        PreferenceSpec("s3.prefix", .text, "Folder inside the bucket"),
        PreferenceSpec("s3.path_style", .boolean, "Bucket in the path instead of the host name"),
        PreferenceSpec("s3.link_mode", .choice(["public", "presigned"]), "Public links (base URL + key) or presigned, expiring ones"),
        PreferenceSpec("s3.public_base_url", .text, "Base of public links (CDN or custom domain); empty: the bucket's URL"),
        PreferenceSpec("s3.presign_expiry", .integer(60...604_800), "Lifetime of presigned links, in seconds"),
        PreferenceSpec("s3.public_read_acl", .boolean, "Send x-amz-acl: public-read"),
        PreferenceSpec("s3.credentials", .readOnly, "Whether the keys are in the keychain (set them with `shotdock s3 credentials`)"),
    ]

    public static func spec(_ key: String) -> PreferenceSpec? { all.first { $0.key == key } }
}

/// Names of shortcut actions outside the app: capture_area…, and
/// editor.copy_and_close… for the editor's own.
public enum ShortcutNames {
    public static func name(_ action: ShortcutAction) -> String { snake(action.rawValue) }
    public static func name(_ action: EditorAction) -> String { "editor." + snake(action.rawValue) }

    public static var all: [String] { ShortcutAction.allCases.map(name) + EditorAction.allCases.map(name) }

    static func snake(_ camel: String) -> String {
        camel.reduce(into: "") { result, character in
            if character.isUppercase { result += "_" + character.lowercased() } else { result.append(character) }
        }
    }
}
