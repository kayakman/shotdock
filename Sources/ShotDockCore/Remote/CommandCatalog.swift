import Foundation

/// The commands, in the order help lists them. Each phase of the CLI adds
/// its own; the app answers every `.app` command.
public enum CommandCatalog {
    public static let all: [CommandSpec] = general + screens + captures + history

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
        CommandSpec("mcp", "Run the MCP server on stdin/stdout, for Claude Code, Codex, Cursor…", details: """
            Register it with `claude mcp add shotdock -- shotdock mcp`. Every command that is not local is a tool.
            """, exposure: .local),
    ]

    // MARK: Displays and windows

    static let screens: [CommandSpec] = [
        CommandSpec("displays", "List the displays: number, id, frame in points, scale, size in pixels", mcp: "list_displays", readOnly: true),
        CommandSpec("windows", "List the windows that can be captured, front to back", details: """
            Frames are global points with the origin at the top-left of the main display. The id is what
            `capture window --id` takes.
            """, params: [
                ParamSpec("app", .string, "Only apps whose name contains this (case, accents and spaces ignored)"),
                ParamSpec("title", .string, "Only windows whose title contains this"),
                ParamSpec("all", .boolean, "Include minimised and off-screen windows"),
            ], mcp: "list_windows", readOnly: true),
    ]

    // MARK: Captures

    /// What to do with a new capture; agents' captures are silent unless asked.
    static let delivery: [ParamSpec] = [
        ParamSpec("delay", .number, "Seconds to wait before capturing"),
        ParamSpec("countdown", .boolean, "Show the countdown on screen during the delay"),
        ParamSpec("out", .path, "Also write the image to this file (.png or .jpg)"),
        ParamSpec("format", .choice(["png", "jpeg"]), "Format of the file (default: from the extension of out, else png)"),
        ParamSpec("copy", .boolean, "Copy the image to the clipboard"),
        ParamSpec("save", .boolean, "Save it in the folder set in the preferences"),
        ParamSpec("upload", .boolean, "Upload it to S3 and return the link"),
        ParamSpec("edit", .boolean, "Open it in the editor"),
        ParamSpec("pin", .boolean, "Pin it above every window"),
        ParamSpec("history", .boolean, "Keep it in the history (needed to edit it later)", default: true),
    ]

    static let captureResult = """
        Returns the history id, the path of a PNG at full resolution, its size in pixels and the scale
        (pixels per point). Nothing is copied, saved or opened unless asked.
        """

    static let captures: [CommandSpec] = [
        CommandSpec("capture.area", "Capture an area of the screen", details: """
            The area is in points, global, with the origin at the top-left of the main display (as in
            `shotdock displays` and `shotdock windows`); with --display it is relative to that display.
            --interactive lets the user select it instead. \(captureResult)
            """, params: [
                ParamSpec("rect", .rect, "Area in points"),
                ParamSpec("display", .integer, "Display number: rect is relative to its top-left corner"),
                ParamSpec("interactive", .boolean, "Let the user select the area"),
            ] + delivery, mcp: "capture_area", returnsImage: true),
        CommandSpec("capture.window", "Capture a window, without its background", details: """
            Pick it by --id (from `shotdock windows`), by --app and/or --title (loose match, the frontmost
            matching window wins), the --active one, or let the user click it (--interactive). With no
            choice, the active window. \(captureResult)
            """, params: [
                ParamSpec("id", .integer, "Window id"),
                ParamSpec("app", .string, "App name, or part of it"),
                ParamSpec("title", .string, "Window title, or part of it"),
                ParamSpec("active", .boolean, "The frontmost window of the active app"),
                ParamSpec("interactive", .boolean, "Let the user click the window"),
                ParamSpec("shadow", .boolean, "Include the window shadow (default: as in the preferences)"),
            ] + delivery, mcp: "capture_window", returnsImage: true),
        CommandSpec("capture.screen", "Capture a whole display", details: "Display 1 is the main one. \(captureResult)", params: [
            ParamSpec("display", .integer, "Display number", default: 1),
            ParamSpec("all", .boolean, "Every display, one capture each"),
        ] + delivery, mcp: "capture_screen", returnsImage: true),
        CommandSpec("capture.repeat", "Capture the last selected area again", details: captureResult, params: delivery,
                    mcp: "capture_repeat", returnsImage: true),
        CommandSpec("capture.scroll", "Scrolling capture: one tall image of an area as it scrolls", details: """
            Give the area (as in capture area) or let the user select it. With --auto ShotDock scrolls the
            content by itself until it stops moving (needs the Accessibility permission); otherwise the user
            scrolls and presses Return. \(captureResult)
            """, params: [
                ParamSpec("rect", .rect, "Area in points"),
                ParamSpec("display", .integer, "Display number: rect is relative to its top-left corner"),
                ParamSpec("interactive", .boolean, "Let the user select the area"),
                ParamSpec("auto", .boolean, "Scroll automatically"),
                ParamSpec("max_height", .integer, "Tallest image in pixels (default: as in the preferences)"),
            ] + delivery, mcp: "capture_scrolling", returnsImage: true, waitsForUser: true),
    ]

    // MARK: History

    static let target = ParamSpec("target", .string, "Capture: its history id (or the first characters), last, last-1…",
                                  required: true, positional: true)

    static let history: [CommandSpec] = [
        CommandSpec("history.list", "List the captures in the history, newest first", params: [
            ParamSpec("limit", .integer, "How many", default: 20),
            ParamSpec("search", .string, "Text in annotations, recognised text (OCR), file name or link"),
            ParamSpec("since", .string, "Newer than a date (2026-11-25) or an age (30m, 2h, 3d, 1w)"),
            ParamSpec("uploaded", .boolean, "Only uploaded captures (false: never uploaded)"),
            ParamSpec("saved", .boolean, "Only saved captures (false: never saved)"),
        ], mcp: "history_list", readOnly: true),
        CommandSpec("history.show", "A capture with its annotations, crop and backdrop, and the image as edited", details: """
            The image is written to a file (path); annotations come with their ids, in the format annotate takes.
            """, params: [target], mcp: "history_get", returnsImage: true, readOnly: true),
        CommandSpec("history.open", "Open a capture in the editor", params: [target], mcp: "history_open"),
        CommandSpec("history.copy", "Copy a capture, as edited, to the clipboard", params: [target], mcp: "history_copy"),
        CommandSpec("history.save", "Save a capture, as edited, in the folder set in the preferences", params: [target], mcp: "history_save"),
        CommandSpec("history.export", "Write a capture, as edited, to a file", params: [
            target,
            ParamSpec("out", .path, "File to write (.png or .jpg)", required: true),
            ParamSpec("format", .choice(["png", "jpeg"]), "Format (default: from the extension)"),
        ], mcp: "history_export", returnsImage: true),
        CommandSpec("history.reveal", "Show the saved file of a capture in the Finder", params: [target], mcp: "history_reveal"),
        CommandSpec("history.delete", "Delete captures from the history (saved files are not touched)", params: [
            ParamSpec("targets", .strings, "Captures to delete", positional: true),
            ParamSpec("all", .boolean, "Empty the whole history"),
        ], mcp: "history_delete", destructive: true),
        CommandSpec("history.import", "Add an image file to the history, to annotate, recognise or upload it", params: [
            ParamSpec("file", .path, "Image file (PNG, JPEG, HEIC, TIFF…)", required: true, positional: true),
            ParamSpec("scale", .number, "Pixels per point (default: from the file's resolution)"),
        ], mcp: "history_import", returnsImage: true),
        CommandSpec("history.gallery", "Show the history window (Capturas recientes)", mcp: "show_gallery"),
    ]
}
