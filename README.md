<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/logo-blanco.png">
    <img src="design/logo-transparente.png" alt="ShotDock" width="420">
  </picture>
</p>

# ShotDock

A macOS app for taking and managing screenshots, with everything Shottr does.

## Features

- **Captures**: area (over the frozen screen, with a loupe), window (picked or the active
  one), full screen, repeat the last area, delayed and scrolling captures.
- **Editor**: arrow, rectangle, oval, text, highlighter, numbered steps, magnifier, blur,
  pixelate, smart eraser (fills with the background, gradients too), crop, resize handles,
  undo.
- **Measure**: pixel ruler between edges, loupe and eyedropper (HEX/RGB), also system-wide.
- **OCR and QR codes** with Vision: the shortcut copies the text (or the QR content) of an area.
- **Pin** captures above every window, with zoom, opacity and click-through.
- **Backdrops and frames** for sharing: gradients, padding, corners, shadow and aspect ratio.
- **Upload to S3** (AWS, Cloudflare R2, Backblaze B2, MinIO…) with the link copied; keys in
  the keychain.
- **The dock**: a history of captures with their annotations still editable, and a gallery to
  reopen, copy, save, upload, pin or drag them into another app.
- **Resize** and **hide secrets** (API keys, tokens, passwords, e-mails, cards, IBANs) with
  black boxes, from the editor's Image menu.
- **CLI and MCP server** for AI agents (Claude Code, Codex, Cursor…) covering all of the
  above: see below.
- Menu bar app, configurable global shortcuts (Shottr's can be imported), preferences,
  configurable file name and save folder, launch at login.

The interface is in English and Spanish: it follows the system language, or the one chosen in
Preferences › General › Language.

## Requirements

- macOS 15 or later, Xcode 16+ (tested with Xcode 27.2 on macOS 27).

## Build and run

```sh
make signing-cert     # once per Mac: local "ShotDock Local Signing" identity
make test             # ShotDockCore tests
make run              # assembles build/ShotDock.app, signs it and opens it
make install          # release build in /Applications
make selftest TEST=…  # checks in the real app: capture, area, editor, modes, prefs, measure,
                      # history, pin-ocr, backdrop, scroll, dock, branding
make selftest-upload  # upload against a local S3 (scripts/mock-s3.py)
make selftest-cli     # the CLI and MCP with the real binary: cli, mcp, cli-history, cli-edit,
                      # cli-inspect, cli-share, cli-prefs, cli-redact, cli-capture
make selftest-l10n    # the interface in English and in Spanish
make strings          # adds new UI strings to Resources/Localizable.xcstrings
```

UI strings are written in English in the code (SwiftUI literals and `String(localized:)`).
`make strings` extracts them with the compiler into `Resources/Localizable.xcstrings`, where
the Spanish translation lives; `make test` fails if a string has no Spanish value.

The stable local signature makes macOS keep the Screen Recording permission across builds.
The first time, grant it in System Settings › Privacy & Security › Screen Recording.
Automatic scrolling captures also need the Accessibility permission.

The `selftest` checks drive the app with simulated events and use their own preferences,
history and keychain item, so the user's are never touched.

## CLI and MCP for agents

`shotdock` is ShotDock's command-line tool, and `shotdock mcp` its MCP server. Everything the
interface does can be done from there: capture, annotate, crop, resize, add a backdrop,
measure, read text and QR codes, hide secrets, pin, upload, manage the history and change the
preferences and shortcuts.

**How it works.** The binary lives inside the app (`ShotDock.app/Contents/Helpers/shotdock`)
and talks to it over a local socket (`~/Library/Application Support/ShotDock/control.sock`,
for your user only). The app does the capturing, under its own Screen Recording permission,
so neither the terminal nor the agent needs it. If the app is not running, `shotdock` opens it
in the background. The app is also the only writer of the history, so whatever an agent does
shows up in the gallery and, when the capture is open in the editor, appears at once and can
be undone.

**Turning it on.** It is off by default. Turn it on in Preferences › Agents (Preferencias ›
Agentes). The first time an agent uses it, ShotDock asks whether to allow it (for example
"claude en Terminal"). Allowed agents are listed in that tab, where their permission can be
withdrawn. `make install` (or the button in that tab) links `shotdock` into `/usr/local/bin`
or `~/.local/bin`.

**Registering the MCP server.**

```sh
claude mcp add shotdock -- shotdock mcp          # Claude Code
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.shotdock]
command = "shotdock"
args = ["mcp"]
```

Cursor (`~/.cursor/mcp.json`): `{"mcpServers": {"shotdock": {"command": "shotdock", "args": ["mcp"]}}}`

Every CLI command is an MCP tool (`capture_area`, `annotate`, `recognize_text`,
`history_list`…). Captures come back as an image for the model (at most 1568 px) and as the
path of the full-resolution PNG, with `preview_scale` to turn preview coordinates into pixels.
The S3 keys are the only thing left out of MCP, so a secret never passes through a model.

**Examples.**

```sh
shotdock windows --app safari                       # windows, front to back
shotdock open preferences --tab agents && shotdock capture window --app shotdock   # ShotDock's own too
shotdock capture window --app safari --json         # id, path, width, height, scale…
shotdock capture area --rect 0,0,800,600 --redact   # in points; covers secrets
shotdock capture screen --display 2 --out ~/Desktop/screen.png
shotdock annotate arrow last --from 100,80 --to 320,200 --color blue
shotdock annotate highlight last --on-text "Save"   # on that text, found by OCR
shotdock annotate last --annotations @marks.json    # several at once
shotdock history duplicate last                     # a copy to annotate another way
shotdock crop last --rect 0,0,1200,800 && shotdock resize last --scale 0.5
shotdock backdrop last --preset 3 --padding 32
shotdock ocr last --json                            # text, lines and QR codes with boxes
shotdock measure last --at 210,140                  # ruler between edges
shotdock upload last --copy                         # S3 link
shotdock history list --search invoice --since 2d
shotdock prefs set image_format jpeg
shotdock shortcuts set capture_window "shift+cmd+4"
shotdock help capture area                          # a command's options
shotdock schema                                     # every command, as JSON
```

- **Coordinates.** Screen rectangles are in points, global, with the origin at the top-left of
  the main display (as with `screencapture -R` and `shotdock windows`). Positions on an image
  are pixels of the image as edited (crop, backdrop and resize applied), which is the image
  `path` and the preview show.
- **Silent captures.** What an agent captures goes to the history and to a file, without
  touching the clipboard, opening the editor or taking the focus, unless it asks for it with
  `--copy`, `--save`, `--upload`, `--edit` or `--pin`.
- **Warnings.** `annotate` and `annotation update` add `warnings` when a mark is cut off at the
  edge of the image, or a text or step is drawn over another mark or over the capture's text.
- **Captures** are named by id (or its first characters), `last`, `last-1`…, or by the path
  of an image file, which is added to the history.
- **`--json`** on every command. Exit codes: 0 success, 1 the command failed (`error.kind`:
  `not_found`, `not_authorized`, `permission_denied`, `cancelled`…), 2 wrong usage,
  3 ShotDock is not available.

## Layout

- `Sources/ShotDockCore`: logic without UI (annotations and their drawing, effects, smart
  eraser, ruler, OCR, scrolling-capture stitching, backdrops, history, S3 signing, Shottr
  import, secrets), with tests. In `Remote/`, the command catalog the CLI, the MCP server
  and the app's dispatch all come from, JSON-RPC, the socket and the MCP server.
- `Sources/ShotDockCLI`: the `shotdock` binary (CLI and `shotdock mcp`).
- `Sources/ShotDock`: the menu bar app (AppKit + SwiftUI, ScreenCaptureKit, Vision); in
  `Remote/`, what answers the CLI.
- `Resources/Info.plist`: the bundle's plist (`app.shotdock.ShotDock`).
- `Resources/Localizable.xcstrings`: the Spanish translation; `Resources/*.lproj`: localized
  Info.plist strings.
- `Resources/Assets.xcassets`: AppIcon, menu bar icon, logo and accent colour (#FF5A1F).
- `design/`: approved design (`icono.png`, `logo.png`) and its vector sources. `make icons`
  regenerates the icons from `design/make-icons.swift`; `swift design/make-logo.swift` makes
  the logo with a transparent background and in white.

## License

[MIT](LICENSE) © 2026 The ShotDock authors
