import AppKit
import ShotDockCore

/// ShotDock has no menu bar of its own (it is a menu bar extra), but its
/// windows still need ⌘Z, ⌘C, ⌘S… which come from the main menu.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate, editor shortcuts: EditorShortcutSettings) -> NSMenu {
        let main = NSMenu()
        /// An editor command with the user's shortcut.
        func editorItem(_ action: EditorAction, _ selector: Selector) -> NSMenuItem {
            let menuItem = NSMenuItem(title: action.title, action: selector, keyEquivalent: "")
            if let combo = shortcuts.combo(for: action), let key = KeyComboFormatter.menuKeyEquivalent(combo) {
                menuItem.keyEquivalent = key.character
                menuItem.keyEquivalentModifierMask = key.modifiers
            }
            return menuItem
        }

        let app = NSMenu(title: "ShotDock")
        app.addItem(item(String(localized: "About ShotDock"), #selector(AppDelegate.showAbout), target: target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Preferences…"), #selector(AppDelegate.showPreferences), ",", target: target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Hide ShotDock"), #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item(String(localized: "Quit ShotDock"), #selector(NSApplication.terminate(_:)), "q"))
        add(app, to: main)

        let file = NSMenu(title: String(localized: "File"))
        file.addItem(item(String(localized: "Capture Area"), #selector(AppDelegate.captureArea), target: target))
        file.addItem(item(String(localized: "Recent Captures"), #selector(AppDelegate.showGallery), "y", [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(editorItem(.save, #selector(EditorWindowController.saveDocument(_:))))
        file.addItem(editorItem(.saveAs, #selector(EditorWindowController.saveDocumentAs(_:))))
        file.addItem(.separator())
        file.addItem(editorItem(.upload, #selector(EditorWindowController.uploadImage(_:))))
        file.addItem(editorItem(.pin, #selector(EditorWindowController.pinImage(_:))))
        file.addItem(editorItem(.backdrop, #selector(EditorWindowController.toggleBackdropPanel(_:))))
        file.addItem(editorItem(.recognizeText, #selector(EditorWindowController.recognizeText(_:))))
        file.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"))
        add(file, to: main)

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        edit.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(editorItem(.copyAndClose, #selector(EditorWindowController.copyAndClose(_:))))
        edit.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(String(localized: "Delete"), #selector(NSText.delete(_:)), "\u{8}", []))
        edit.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        add(edit, to: main)

        let image = NSMenu(title: String(localized: "Image"))
        image.addItem(item(String(localized: "Resize…"), #selector(EditorWindowController.resizeImage(_:))))
        image.addItem(item(String(localized: "Hide Secrets"), #selector(EditorWindowController.redactSecrets(_:))))
        add(image, to: main)

        let view = NSMenu(title: String(localized: "View"))
        view.addItem(item(String(localized: "Actual Size"), #selector(EditorWindowController.zoomToActualSize(_:)), "0"))
        view.addItem(item(String(localized: "Zoom In"), #selector(EditorWindowController.zoomIn(_:)), "+"))
        view.addItem(item(String(localized: "Zoom Out"), #selector(EditorWindowController.zoomOut(_:)), "-"))
        add(view, to: main)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        add(window, to: main)
        NSApp.windowsMenu = window
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }
}
