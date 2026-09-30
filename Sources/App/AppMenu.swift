import Cocoa

/// mdeck runs as an accessory app, so it normally owns no menu bar. It only becomes a regular
/// app — Dock icon and menu bar — while the settings window is open, and an empty menu bar
/// would look broken, so the few items that window needs live here. Installed once at launch;
/// harmless while the menu bar is hidden.
enum AppMenu {

    static func install() {
        let appMenu = NSMenu(title: "mdeck")
        appMenu.addItem(withTitle: "About mdeck",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit mdeck",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Text fields (none yet, but a module will have one) need the standard edit actions.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let main = NSMenu()
        for menu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
