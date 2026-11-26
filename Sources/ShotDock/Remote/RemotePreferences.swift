import AppKit
import ShotDockCore

/// Preferences and shortcuts for agents: the same settings the windows change.
@MainActor
enum RemotePreferences {
    static var settings: AppSettings { AppSettings.shared }

    static let handlers: [String: RemoteHandler] = [
        "prefs.get": { params, _ in
            if let key = params["key"]?.stringValue {
                guard let spec = Preferences.spec(key) else { throw RPCError.notFound("No preference \(key)") }
                return ["key": .string(key), "value": value(key), "type": .string(spec.typeDescription)]
            }
            return ["preferences": .array(Preferences.all.map { spec in
                ["key": .string(spec.key), "value": value(spec.key), "type": .string(spec.typeDescription), "summary": .string(spec.summary)]
            })]
        },
        "prefs.set": { params, _ in
            let key = params["key"]?.stringValue ?? ""
            guard let spec = Preferences.spec(key) else { throw RPCError.notFound("No preference \(key)") }
            let raw = params["value"] ?? .null
            if key == "history_limit", raw.stringValue?.lowercased() == "all" {
                settings.historyLimit = Int.max
            } else {
                try set(key, try spec.coerce(raw))
            }
            return ["key": .string(key), "value": value(key)]
        },
        "profiles.list": { _, _ in
            ["profiles": .array(settings.exportProfiles.map(json))]
        },
        "profiles.set": { params, _ in
            let name = params["name"]?.stringValue ?? ""
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw RPCError.invalidParams("A profile needs a name") }
            var profile = settings.profile(named: name) ?? ExportProfile(name: name, format: .png)
            if let text = params["format"]?.stringValue {
                guard let format = ImageFormat(rawValue: text), format.isAvailable else { throw RPCError.invalidParams("This Mac cannot write \(text)") }
                profile.format = format
            }
            if let quality = params["quality"]?.doubleValue {
                guard (0...100).contains(quality) else { throw RPCError.invalidParams("quality must be 0–100") }
                profile.quality = quality / 100
            }
            profile = profile.overriding(maxWidth: params["max_width"]?.intValue, maxHeight: params["max_height"]?.intValue)
            if let rename = params["rename"]?.stringValue, rename != profile.name {
                if let other = settings.profile(named: rename), other.id != profile.id { throw RPCError.invalidParams("There is already a profile \(rename)") }
                profile.name = rename
            }
            if let index = settings.exportProfiles.firstIndex(where: { $0.id == profile.id }) {
                settings.exportProfiles[index] = profile
            } else {
                settings.exportProfiles.append(profile)
            }
            return json(profile)
        },
        "profiles.remove": { params, _ in
            let name = params["name"]?.stringValue ?? ""
            guard let profile = settings.profile(named: name) else { throw RPCError.notFound("No profile \(name)") }
            guard settings.exportProfiles.count > 1 else { throw RPCError.invalidParams("The last profile cannot be removed") }
            settings.exportProfiles.removeAll { $0.id == profile.id }
            for (destination, id) in settings.destinationProfiles where id == profile.id { settings.destinationProfiles[destination] = nil }
            return ["removed": .string(profile.name)]
        },
        "shortcuts.list": { _, _ in
            var rows: [JSONValue] = []
            for action in ShortcutAction.allCases {
                rows.append(row(ShortcutNames.name(action), title: action.title, scope: "global",
                                combo: settings.shortcuts.combo(for: action), defaultCombo: action.defaultCombo))
            }
            for action in EditorAction.allCases {
                rows.append(row(ShortcutNames.name(action), title: action.title, scope: "editor",
                                combo: settings.editorShortcuts.combo(for: action), defaultCombo: action.defaultCombo))
            }
            return ["shortcuts": .array(rows)]
        },
        "shortcuts.set": { params, _ in try setShortcut(params) },
        "open": { params, _ in
            guard let app = NSApp.delegate as? AppDelegate else { throw RPCError.internalError("No app") }
            switch params["window"]?.stringValue {
            case "about": app.showAbout()
            default:
                let tabs: [String: PreferencesTab] = ["general": .general, "capture": .capture, "export": .export, "shortcuts": .shortcuts, "history": .history,
                                                      "upload": .upload, "agents": .agents, "import": .importing]
                app.openPreferences(tab: params["tab"]?.stringValue.flatMap { tabs[$0] })
            }
            return ["opened": true]
        },
    ]

    // MARK: Preferences

    static func value(_ key: String) -> JSONValue {
        let s3 = settings.s3
        switch key {
        case "language": return .string(settings.language.rawValue)
        case "copy_after_capture": return .bool(settings.copyAfterCapture)
        case "open_editor_after_capture": return .bool(settings.openEditorAfterCapture)
        case "save_after_capture": return .bool(settings.saveAfterCapture)
        case "upload_after_capture": return .bool(settings.uploadAfterCapture)
        case "save_folder": return .string(settings.saveFolder.path)
        case "filename_template": return .string(settings.filenameTemplate)
        case "save_profile": return .string(settings.profile(for: .save).name)
        case "upload_profile": return .string(settings.profile(for: .upload).name)
        case "drag_profile": return .string(settings.profile(for: .drag).name)
        case "capture_delay": return .number(Double(settings.captureDelay))
        case "window_shadow": return .bool(settings.windowShadow)
        case "scroll_max_height": return .number(Double(settings.scrollMaxHeight))
        case "color_format": return .string(settings.colorFormat.rawValue)
        case "ocr_join_lines": return .bool(settings.ocrJoinLines)
        case "history_limit": return settings.historyLimit == Int.max ? "all" : .number(Double(settings.historyLimit))
        case "show_in_dock": return .bool(settings.showInDock)
        case "launch_at_login": return .bool(LaunchAtLogin.isEnabled)
        case "agent_control": return .bool(settings.agentControlEnabled)
        case "s3.provider": return .string(s3.provider.rawValue)
        case "s3.endpoint": return .string(s3.endpoint)
        case "s3.region": return .string(s3.region)
        case "s3.bucket": return .string(s3.bucket)
        case "s3.prefix": return .string(s3.prefix)
        case "s3.path_style": return .bool(s3.pathStyle)
        case "s3.link_mode": return s3.linkMode == .presigned ? "presigned" : "public"
        case "s3.public_base_url": return .string(s3.publicBaseURL)
        case "s3.presign_expiry": return .number(Double(s3.presignExpiry))
        case "s3.public_read_acl": return .bool(s3.publicReadACL)
        case "s3.credentials": return .bool(Keychain.loadS3Credentials() != nil)
        default: return .null
        }
    }

    /// `value` is already coerced to the preference's type.
    static func set(_ key: String, _ value: JSONValue) throws {
        let bool = value.boolValue ?? false, int = value.intValue ?? 0, text = value.stringValue ?? ""
        switch key {
        case "language": settings.language = AppLanguage(rawValue: text) ?? .system
        case "copy_after_capture": settings.copyAfterCapture = bool
        case "open_editor_after_capture": settings.openEditorAfterCapture = bool
        case "save_after_capture": settings.saveAfterCapture = bool
        case "upload_after_capture": settings.uploadAfterCapture = bool
        case "save_folder":
            let path = (text as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                throw RPCError.invalidParams("save_folder must be an existing folder (absolute path)")
            }
            settings.saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        case "filename_template": settings.filenameTemplate = text
        case "save_profile", "upload_profile", "drag_profile":
            guard let profile = settings.profile(named: text) else {
                throw RPCError.notFound("No profile \(text); profiles: \(settings.exportProfiles.map(\.name).joined(separator: ", "))")
            }
            let destination: ExportDestination = key == "save_profile" ? .save : key == "upload_profile" ? .upload : .drag
            settings.destinationProfiles[destination] = profile.id
        case "capture_delay": settings.captureDelay = int
        case "window_shadow": settings.windowShadow = bool
        case "scroll_max_height": settings.scrollMaxHeight = int
        case "color_format": settings.colorFormat = ColorFormat(rawValue: text) ?? .hex
        case "ocr_join_lines": settings.ocrJoinLines = bool
        case "history_limit":
            settings.historyLimit = int
            LibraryStore.shared.applyLimit()
        case "show_in_dock":
            settings.showInDock = bool
            DockPresence.shared.update()
        case "launch_at_login":
            do { try LaunchAtLogin.set(bool) } catch { throw RPCError.internalError("macOS refused: \(error.localizedDescription)") }
        case "s3.provider":
            settings.s3.switchProvider(to: S3Configuration.Provider(rawValue: text) ?? .aws)
        case "s3.endpoint": settings.s3.endpoint = text
        case "s3.region": settings.s3.region = text
        case "s3.bucket": settings.s3.bucket = text
        case "s3.prefix": settings.s3.prefix = text
        case "s3.path_style": settings.s3.pathStyle = bool
        case "s3.link_mode": settings.s3.linkMode = text == "presigned" ? .presigned : .publicURL
        case "s3.public_base_url": settings.s3.publicBaseURL = text
        case "s3.presign_expiry": settings.s3.presignExpiry = int
        case "s3.public_read_acl": settings.s3.publicReadACL = bool
        default: throw RPCError.invalidParams("\(key) cannot be changed from outside ShotDock")
        }
    }

    static func json(_ profile: ExportProfile) -> JSONValue {
        let usedFor = ExportDestination.allCases.filter { settings.profile(for: $0).id == profile.id }.map { JSONValue.string($0.rawValue) }
        return [
            "name": .string(profile.name),
            "format": .string(profile.format.rawValue),
            "quality": profile.format.hasQuality ? .number((profile.quality * 100).rounded()) : .null,
            "max_width": profile.maxWidth.map { .number(Double($0)) } ?? .null,
            "max_height": profile.maxHeight.map { .number(Double($0)) } ?? .null,
            "summary": .string(profile.summary),
            "used_for": .array(usedFor),
        ]
    }

    // MARK: Shortcuts

    static func row(_ name: String, title: String, scope: String, combo: KeyCombo?, defaultCombo: KeyCombo?) -> JSONValue {
        [
            "action": .string(name),
            "title": .string(title),
            "scope": .string(scope),
            "combo": combo.map { .string(KeyComboFormatter.string(for: $0)) } ?? .null,
            "keys": combo.map { .string($0.plainDescription) } ?? .null,
            "default": defaultCombo.map { .string(KeyComboFormatter.string(for: $0)) } ?? .null,
        ]
    }

    static func setShortcut(_ params: [String: JSONValue]) throws -> JSONValue {
        let name = params["action"]?.stringValue ?? ""
        var combo: KeyCombo?
        let off = params["off"]?.boolValue == true, reset = params["default"]?.boolValue == true
        if let text = params["combo"]?.stringValue {
            guard !off, !reset else { throw RPCError.invalidParams("Give a combo, off or default, only one") }
            guard let parsed = KeyCombo(parsing: text) else { throw RPCError.invalidParams("Cannot read the combo \"\(text)\"; e.g. ⇧⌘2 or shift+cmd+2") }
            combo = parsed
        } else if !off, !reset {
            throw RPCError.invalidParams("Give a combo, off or default")
        }
        let before = (settings.shortcuts, settings.editorShortcuts)
        if let action = ShortcutAction.allCases.first(where: { ShortcutNames.name($0) == name }) {
            if reset { combo = action.defaultCombo }
            if let combo, !combo.isValidGlobalShortcut { throw RPCError.invalidParams("A global shortcut needs ⌘, ⌥ or ⌃ (or a function key)") }
            settings.setShortcut(combo, for: action)
        } else if let action = EditorAction.allCases.first(where: { ShortcutNames.name($0) == name }) {
            if reset { combo = action.defaultCombo }
            settings.setShortcut(combo, for: action)
        } else {
            throw RPCError.notFound("No action \(name)")
        }
        // Which actions lost the combo.
        var released: [JSONValue] = []
        for action in ShortcutAction.allCases where ShortcutNames.name(action) != name
            && before.0.combo(for: action) != nil && settings.shortcuts.combo(for: action) == nil {
            released.append(.string(ShortcutNames.name(action)))
        }
        for action in EditorAction.allCases where ShortcutNames.name(action) != name
            && before.1.combo(for: action) != nil && settings.editorShortcuts.combo(for: action) == nil {
            released.append(.string(ShortcutNames.name(action)))
        }
        return ["action": .string(name), "combo": combo.map { .string(KeyComboFormatter.string(for: $0)) } ?? .null,
                "keys": combo.map { .string($0.plainDescription) } ?? .null, "released": .array(released)]
    }
}
