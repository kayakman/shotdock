import Foundation

/// The commands, in the order help lists them. Each phase of the CLI adds
/// its own; the app answers every `.app` command.
public enum CommandCatalog {
    public static let all: [CommandSpec] = general + screens + captures + history + editing + inspection + sharing + settings

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
        ParamSpec("redact", .boolean, "Cover secrets (keys, tokens, passwords, e-mails, cards) with black boxes before returning the image"),
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

    // MARK: Editing

    static let editTarget = ParamSpec("target", .reference, "Capture: history id (or its start), last, last-1…, or an image file (added to the history)",
                                      required: true, positional: true)
    static let space = ParamSpec("space", .choice(["pixels", "preview"]),
                                 "Positions are pixels of the edited image, or of the MCP preview (pixels × preview_scale)", default: "pixels")
    static let style: [ParamSpec] = [
        ParamSpec("color", .color, "Colour: #RRGGBB or red, orange, yellow, green, blue, purple, black, white"),
        ParamSpec("weight", .choice(["thin", "medium", "thick"]), "Line weight, as in the editor"),
        ParamSpec("line_width", .number, "Line width in pixels"),
        ParamSpec("font_size", .number, "Text size in pixels"),
    ]
    static let onText = ParamSpec("on_text", .string, "Put the mark on this text, found by OCR, instead of giving a position")

    static let editResult = """
        Positions are pixels of the image as edited (crop, backdrop and resize applied), from its top-left \
        corner: the image at `path`. Returns that image again.
        """

    /// `shotdock annotate arrow last --from 10,10 --to 200,120`: one mark of `type`.
    static func mark(_ name: String, type: String, _ summary: String, _ params: [ParamSpec]) -> CommandSpec {
        CommandSpec("annotate.\(name)", summary, details: editResult, params: [editTarget] + params + style + [onText, space],
                    exposure: .alias(of: "annotate")) { params in
            var mark = params
            mark["target"] = nil
            mark["space"] = nil
            mark["type"] = .string(type)
            return ["target": params["target"] ?? nil, "space": params["space"] ?? nil, "annotations": [.object(mark)]]
        }
    }

    static let editing: [CommandSpec] = [
        CommandSpec("annotate", "Add annotations to a capture; they stay editable in the history and the editor", details: """
            Each annotation: {"type": "arrow", "from": {"x", "y"}, "to": {…}}, rectangle/oval/highlight/blur/pixelate/erase
            with "rect", text with "at" and "text", step with "at" (numbered automatically), magnifier with "source"
            (and "lens" or "zoom"). Optional: color, weight, line_width, font_size, and on_text to place the mark on a
            text found by OCR. \(editResult)
            """, params: [
                editTarget,
                ParamSpec("annotations", .json(schema: ["type": "array", "items": AnnotationCoding.schema]),
                          "The annotations (JSON array; on the command line also @file or - for stdin)", required: true),
                space,
            ], mcp: "annotate", returnsImage: true),
        mark("arrow", type: "arrow", "Draw an arrow", [ParamSpec("from", .point, "Tail"), ParamSpec("to", .point, "Head")]),
        mark("rect", type: "rectangle", "Draw a rectangle", [ParamSpec("rect", .rect, "Rectangle")]),
        mark("oval", type: "oval", "Draw an oval", [ParamSpec("rect", .rect, "Box of the oval")]),
        mark("highlight", type: "highlight", "Highlight an area like a marker", [ParamSpec("rect", .rect, "Area")]),
        mark("text", type: "text", "Write a text", [ParamSpec("at", .point, "Top-left corner of the text"),
                                                   ParamSpec("text", .string, "The text", required: true)]),
        mark("step", type: "step", "Add a numbered step", [ParamSpec("at", .point, "Centre"), ParamSpec("number", .integer, "Number (default: the next one)")]),
        mark("magnifier", type: "magnifier", "Show an area enlarged beside it", [
            ParamSpec("source", .rect, "Area to enlarge"), ParamSpec("lens", .rect, "Where the enlargement goes (default: beside it)"),
            ParamSpec("zoom", .number, "Enlargement when no lens is given (default 2)"), ParamSpec("round", .boolean, "Round lens (default true)"),
        ]),
        mark("blur", type: "blur", "Blur an area", [ParamSpec("rect", .rect, "Area")]),
        mark("pixelate", type: "pixelate", "Pixelate an area", [ParamSpec("rect", .rect, "Area")]),
        mark("erase", type: "erase", "Smart eraser: paint an area with the background around it", [ParamSpec("rect", .rect, "Area")]),
        CommandSpec("annotations", "List a capture's annotations, with their ids", details: editResult, params: [editTarget],
                    mcp: "list_annotations", readOnly: true),
        CommandSpec("annotation.update", "Change an annotation: position, text, colour or size", details: editResult, params: [
            editTarget,
            ParamSpec("id", .string, "Annotation id (or its start)", required: true, positional: true),
            ParamSpec("from", .point, "Arrow tail"), ParamSpec("to", .point, "Arrow head"), ParamSpec("at", .point, "Text corner or step centre"),
            ParamSpec("rect", .rect, "Box of rectangles, ovals, highlights, blur…"), ParamSpec("source", .rect, "Area a magnifier enlarges"),
            ParamSpec("lens", .rect, "Where a magnifier's enlargement goes"), ParamSpec("text", .string, "Text"),
            ParamSpec("number", .integer, "Step number"), ParamSpec("round", .boolean, "Round magnifier"),
        ] + style + [space], mcp: "update_annotation", returnsImage: true),
        CommandSpec("annotation.remove", "Remove annotations from a capture", params: [
            editTarget,
            ParamSpec("ids", .strings, "Annotation ids (or their start)", positional: true),
            ParamSpec("all", .boolean, "Remove them all"),
        ], mcp: "remove_annotations", returnsImage: true, destructive: true),
        CommandSpec("crop", "Crop a capture; non-destructive (--reset brings the rest back)", details: editResult, params: [
            editTarget,
            ParamSpec("rect", .rect, "Area to keep"),
            ParamSpec("reset", .boolean, "Undo the crop"),
            space,
        ], mcp: "crop", returnsImage: true),
        CommandSpec("resize", "Resize a capture when it is exported; non-destructive (--reset: original size)", params: [
            editTarget,
            ParamSpec("width", .integer, "Width in pixels (the height follows)"),
            ParamSpec("height", .integer, "Height in pixels (the width follows)"),
            ParamSpec("scale", .number, "Fraction of the size: 0.5 halves it"),
            ParamSpec("reset", .boolean, "Back to the original size"),
        ], mcp: "resize", returnsImage: true),
        CommandSpec("redact", "Cover secrets with black boxes: API keys, tokens, passwords, e-mails, cards, IBANs", details: """
            Found by OCR on the image as edited; the boxes stay editable like any annotation. Findings come back
            masked (ghp_…(40)), never the secret itself. \(editResult)
            """, params: [
                editTarget,
                ParamSpec("kinds", .strings, "Only these kinds: \(SecretScanner.kinds.joined(separator: ", "))"),
                ParamSpec("dry_run", .boolean, "Only report what would be covered"),
            ], mcp: "redact", returnsImage: true),
        CommandSpec("backdrop", "Frame a capture on a background for sharing (Shottr's backdrop)", details: """
            Presets 1–8: sunset, violet, ocean, mint, sun, graphite, silver, ShotDock orange. Without a fill, the last
            backdrop used. Padding and radius are in points.
            """, params: [
                editTarget,
                ParamSpec("preset", .integer, "Preset background, 1–8"),
                ParamSpec("gradient", .string, "Gradient: colour,colour[,angle in degrees]"),
                ParamSpec("solid", .color, "Plain background colour"),
                ParamSpec("padding", .number, "Margin around the capture, in points"),
                ParamSpec("radius", .number, "Corner radius, in points"),
                ParamSpec("shadow", .number, "Shadow strength, 0–1"),
                ParamSpec("aspect", .choice(["auto", "1:1", "16:9", "4:3", "4:5"]), "Shape of the canvas"),
                ParamSpec("off", .boolean, "Remove the backdrop"),
            ], mcp: "set_backdrop", returnsImage: true),
    ]

    // MARK: Measure, colour, OCR

    static let optionalTarget = ParamSpec("target", .reference, "Capture (history id, last…) or image file; without it, the screen", positional: true)

    static let inspection: [CommandSpec] = [
        CommandSpec("measure", "Pixel ruler: the size of the area of the same colour around a point (a button, a gap…)", details: """
            On a capture, `at` is in pixels of the edited image; on the screen (no target), in points from the top-left of
            the main display. Returns the box in both pixels and points.
            """, params: [
                optionalTarget,
                ParamSpec("at", .point, "Where to measure", required: true),
                ParamSpec("tolerance", .integer, "How different (0–255) a pixel may be and still count as the same colour", default: 24),
            ], mcp: "measure", readOnly: true),
        CommandSpec("color", "Eyedropper: the colour of a pixel, as HEX and RGB", details: """
            On a capture, `at` is in pixels of the edited image; on the screen (no target), in points.
            """, params: [
                optionalTarget,
                ParamSpec("at", .point, "Pixel to read", required: true),
                ParamSpec("copy", .boolean, "Copy it, in the format set in the preferences"),
            ], mcp: "pick_color", readOnly: true),
        CommandSpec("ocr", "Recognise the text and the QR codes or barcodes of a capture or of the screen", details: """
            Give a capture, a screen area (rect, in points) or let the user select one (interactive). Returns the text,
            each line with its box (pixels from the top-left of the image) and confidence, and the codes with their
            content and box. The text is kept with the capture so the history can be searched by it.
            """, params: [
                optionalTarget,
                ParamSpec("rect", .rect, "Screen area in points, when there is no target"),
                ParamSpec("interactive", .boolean, "Let the user select the area"),
                ParamSpec("languages", .strings, "Languages to read, e.g. es-ES, en-US (default: Spanish and English)"),
                ParamSpec("join", .boolean, "Join the lines into one paragraph (default: as in the preferences)"),
                ParamSpec("copy", .boolean, "Copy the text (or the QR content) to the clipboard"),
            ], mcp: "recognize_text", readOnly: true),
    ]

    // MARK: Pins and uploads

    static let pinOptions: [ParamSpec] = [
        ParamSpec("zoom", .number, "Zoom: 1 is the capture's size, 0.5 half"),
        ParamSpec("opacity", .number, "Opacity, 0.15–1"),
        ParamSpec("click_through", .boolean, "Let clicks go through to what is below"),
        ParamSpec("at", .point, "Top-left corner, in screen points"),
    ]

    static let sharing: [CommandSpec] = [
        CommandSpec("pin", "Pin a capture above every window", params: [editTarget] + pinOptions, mcp: "pin"),
        CommandSpec("pins", "List the pinned captures", mcp: "list_pins", readOnly: true),
        CommandSpec("pin.update", "Change a pinned capture: zoom, opacity, clicks, position", params: [
            ParamSpec("id", .string, "Pin id (or its start)", required: true, positional: true),
        ] + pinOptions, mcp: "update_pin"),
        CommandSpec("pin.close", "Close pinned captures", params: [
            ParamSpec("ids", .strings, "Pin ids (or their start)", positional: true),
            ParamSpec("all", .boolean, "Close them all"),
        ], mcp: "close_pins"),
        CommandSpec("upload", "Upload a capture, as edited, to S3 and return the link", details: """
            Uses the bucket set in Preferencias › Subida (or `shotdock prefs set s3.…`). The link is public or
            presigned, as configured.
            """, params: [
                editTarget,
                ParamSpec("copy", .boolean, "Copy the link to the clipboard"),
            ], mcp: "upload"),
        CommandSpec("upload.test", "Check the S3 settings by uploading and deleting a tiny file", mcp: "upload_test"),
        CommandSpec("s3.credentials", "Set the S3 access keys (kept in the keychain)", details: """
            Without --secret-access-key the secret is asked for on the terminal, without echo. Not an MCP tool:
            secrets should not pass through a model.
            """, params: [
                ParamSpec("access_key_id", .string, "Access key id"),
                ParamSpec("secret_access_key", .string, "Secret access key (better typed when asked)"),
                ParamSpec("clear", .boolean, "Remove the keys"),
            ], tool: false),
    ]

    // MARK: Preferences and shortcuts

    static let settings: [CommandSpec] = [
        CommandSpec("prefs.get", "Read the preferences (all, or one)", params: [
            ParamSpec("key", .choice(Preferences.all.map(\.key)), "Preference", positional: true),
        ], mcp: "get_preferences", readOnly: true),
        CommandSpec("prefs.list", "List every preference with its value, type and meaning", exposure: .alias(of: "prefs.get")) { _ in [:] },
        CommandSpec("prefs.set", "Change a preference", details: "`shotdock prefs list` shows the keys and the values they take.", params: [
            ParamSpec("key", .choice(Preferences.all.map(\.key)), "Preference", required: true, positional: true),
            ParamSpec("value", .scalar, "New value", required: true, positional: true),
        ], mcp: "set_preferences"),
        CommandSpec("shortcuts.list", "List the keyboard shortcuts: global ones and the editor's", mcp: "get_shortcuts", readOnly: true),
        CommandSpec("shortcuts.set", "Change a keyboard shortcut", details: """
            Combos as "⇧⌘2" or "shift+cmd+2" (keys by their US-layout position). A combo has one use: giving it to an
            action takes it away from any other, as in the preferences. Global shortcuts need ⌘, ⌥ or ⌃ (or a function key).
            """, params: [
                ParamSpec("action", .choice(ShortcutNames.all), "Action", required: true, positional: true),
                ParamSpec("combo", .string, "New combo", positional: true),
                ParamSpec("off", .boolean, "No shortcut"),
                ParamSpec("default", .boolean, "Back to the default"),
            ], mcp: "set_shortcut"),
        CommandSpec("open", "Show the preferences (optionally a tab) or the About window", params: [
            ParamSpec("window", .choice(["preferences", "about"]), "Window (the history has `history gallery`)", required: true, positional: true),
            ParamSpec("tab", .choice(["general", "capture", "shortcuts", "history", "upload", "agents", "import"]), "Preferences tab"),
        ], mcp: "show_window"),
    ]
}
