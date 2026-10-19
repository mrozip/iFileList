import AppKit

/// The menu bar, laid out like Finder's and built in AppKit rather than with SwiftUI commands.
/// Items have no target, so the responder chain decides what's enabled: the list for file
/// commands (`FileListTableView`), the search field for text, the main window for New Folder,
/// Find and the filters (`MainWindowController`), and the app for the rest (`AppDelegate`).
///
/// SwiftUI rebuilds a commands menu whenever its state changes, even while it's open, and the
/// rebuilt standard items show enabled until AppKit validates them again.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let fileMenu = NSMenu(title: "File")
    private let editMenu = NSMenu(title: "Edit")
    private let openWithMenu = NSMenu(title: "Open With")
    private let tagsMenu = NSMenu(title: "Tags")
    private lazy var submenus = FileSubmenus(model: model)

    init(model: AppModel) {
        self.model = model
    }

    func makeMenuBar() -> NSMenu {
        let bar = NSMenu()
        for menu in [appMenu(), makeFileMenu(), makeEditMenu(), viewMenu(), filterMenu(), windowMenu(), helpMenu()] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            bar.addItem(item)
        }
        return bar
    }

    // MARK: Menus

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "iFileList")
        menu.addItem(item("About iFileList", #selector(AppDelegate.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(submenuItem("Services", services))
        menu.addItem(.separator())
        menu.addItem(item("Hide iFileList", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit iFileList", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func makeFileMenu() -> NSMenu {
        let menu = fileMenu
        menu.delegate = self
        menu.addItem(item("New Folder", #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item(.newFolderWithSelection, "n", [.command, .control]))
        menu.addItem(item(.open, "o"))
        openWithMenu.delegate = self
        menu.addItem(submenuItem("Open With", openWithMenu, action: #selector(FileListTableView.showOpenWith(_:))))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item(.getInfo, "i"))
        menu.addItem(item(.rename))
        menu.addItem(item(.compress))
        menu.addItem(item(.duplicate, "d"))
        menu.addItem(item(.makeAlias, "a", [.command, .control]))
        menu.addItem(item(.quickLook, "y"))
        menu.addItem(item(.showOriginal))
        menu.addItem(item(.showInFinder))
        menu.addItem(item(.share))
        menu.addItem(.separator())
        menu.addItem(item(.moveToTrash, "\u{8}"))
        // Shown in place of Move to Bin while ⌥ is held, as in Finder.
        let deleteImmediately = item(.deleteImmediately, "\u{8}", [.command, .option])
        deleteImmediately.isAlternate = true
        menu.addItem(deleteImmediately)
        menu.addItem(item(.eject, "e"))
        menu.addItem(.separator())
        tagsMenu.delegate = self
        menu.addItem(submenuItem("Tags", tagsMenu, action: #selector(FileListTableView.showTags(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Find", #selector(MainWindowController.findFiles(_:)), "f"))
        menu.addItem(.separator())
        menu.addItem(item("Rescan All Volumes", #selector(AppDelegate.rescanAllVolumes(_:)), "r"))
        return menu
    }

    /// Finder's Edit menu: no Undo, since file operations can't be undone, and no Delete, which is
    /// File › Move to Bin. AppKit adds Writing Tools, AutoFill, Dictation and Emoji & Symbols.
    private func makeEditMenu() -> NSMenu {
        let menu = editMenu
        menu.delegate = self
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private func filterMenu() -> NSMenu {
        let menu = NSMenu(title: "Filter")
        menu.addItem(item("Filter by Folder…", #selector(MainWindowController.filterByFolder(_:)), "f", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Clear Filters", #selector(MainWindowController.clearFilters(_:)), "f", [.command, .option]))
        return menu
    }

    /// AppKit adds the window list and the tiling items.
    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        // "Minimise" in UK English, matching the items AppKit adds.
        menu.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    /// AppKit adds the search field.
    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("iFileList Help", #selector(AppDelegate.openHelp(_:)), "?"))
        NSApp.helpMenu = menu
        return menu
    }

    // MARK: Items

    private func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// One of the commands the list performs, titled for no selection until it validates them.
    private func item(_ command: FileCommand, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = item(command.title(for: .none), #selector(FileListTableView.performFileCommand(_:)), key, modifiers)
        item.tag = command.rawValue
        return item
    }

    /// `action`, if given, lets the responder chain disable the item along with its submenu.
    private func submenuItem(_ title: String, _ submenu: NSMenu, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // MARK: Updates

    /// Puts back the plain titles, which the list replaces with Finder's titles for the selection
    /// when it validates the items. Without the list in charge they would keep the last ones.
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case fileMenu:
            for item in menu.items where item.action == #selector(FileListTableView.performFileCommand(_:)) {
                if let command = FileCommand(rawValue: item.tag) { item.title = command.title(for: .none) }
            }
        case editMenu:
            for item in menu.items {
                if item.action == #selector(NSText.copy(_:)) { item.title = "Copy" }
                if item.action == #selector(NSText.paste(_:)) { item.title = "Paste" }
            }
        case openWithMenu:
            submenus.targets = listTargets
            submenus.fillOpenWith(menu)
        case tagsMenu:
            submenus.targets = listTargets
            submenus.fillTags(menu)
        default:
            break
        }
    }

    /// The selection of the list the File menu's commands would reach, if any.
    private var listTargets: FileTargets {
        let list = NSApp.target(forAction: #selector(FileListTableView.showOpenWith(_:)), to: nil, from: nil)
        return (list as? FileListTableView)?.selectionTargets ?? .none
    }
}
