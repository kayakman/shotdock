import AppKit

/// ShotDock has no menu bar of its own (it is a menu bar extra), but its
/// windows still need ⌘Z, ⌘C, ⌘S… which come from the main menu.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "ShotDock")
        app.addItem(item("Acerca de ShotDock", #selector(AppDelegate.showAbout), target: target))
        app.addItem(.separator())
        app.addItem(item("Preferencias…", #selector(AppDelegate.showPreferences), ",", target: target))
        app.addItem(.separator())
        app.addItem(item("Ocultar ShotDock", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Salir de ShotDock", #selector(NSApplication.terminate(_:)), "q"))
        add(app, to: main)

        let file = NSMenu(title: "Archivo")
        file.addItem(item("Capturar área", #selector(AppDelegate.captureArea), target: target))
        file.addItem(item("Capturas recientes", #selector(AppDelegate.showGallery), "y", [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(item("Guardar", #selector(EditorWindowController.saveDocument(_:)), "s"))
        file.addItem(item("Guardar como…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Subir y copiar enlace", #selector(EditorWindowController.uploadImage(_:)), "u"))
        file.addItem(item("Fijar encima de todo", #selector(EditorWindowController.pinImage(_:)), "p"))
        file.addItem(item("Fondo y marco", #selector(EditorWindowController.toggleBackdropPanel(_:)), "b"))
        file.addItem(item("Reconocer texto", #selector(EditorWindowController.recognizeText(_:)), "t", [.command, .shift]))
        file.addItem(item("Cerrar", #selector(NSWindow.performClose(_:)), "w"))
        add(file, to: main)

        let edit = NSMenu(title: "Edición")
        edit.addItem(item("Deshacer", Selector(("undo:")), "z"))
        edit.addItem(item("Rehacer", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cortar", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copiar", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Pegar", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Eliminar", #selector(NSText.delete(_:)), "\u{8}", []))
        edit.addItem(item("Seleccionar todo", #selector(NSText.selectAll(_:)), "a"))
        add(edit, to: main)

        let view = NSMenu(title: "Visualización")
        view.addItem(item("Tamaño real", #selector(EditorWindowController.zoomToActualSize(_:)), "0"))
        view.addItem(item("Ampliar", #selector(EditorWindowController.zoomIn(_:)), "+"))
        view.addItem(item("Reducir", #selector(EditorWindowController.zoomOut(_:)), "-"))
        add(view, to: main)

        let window = NSMenu(title: "Ventana")
        window.addItem(item("Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m"))
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
