import AppKit
import Observation

/// The menu bar icon, shown while the app keeps running in the menu bar, and its menu: indexing
/// status, a way back to the window, and the app's commands.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var menuIsOpen = false

    init(model: AppModel) {
        self.model = model
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "iFileList")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        statusLine.title = model.indexStatusText
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let search = item("Search iFileList", #selector(showMainWindow(_:)))
        if let shortcut = model.globalShortcut, let key = shortcut.menuKeyEquivalent {
            search.keyEquivalent = key
            search.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(search)
        menu.addItem(item("Rescan All Volumes", #selector(AppDelegate.rescanAllVolumes(_:))))
        if !model.hasFullDiskAccess {
            menu.addItem(item("Grant Full Disk Access…", #selector(grantFullDiskAccess(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item("About iFileList", #selector(AppDelegate.showAbout(_:))))
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit iFileList", #selector(NSApplication.terminate(_:)), "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        followStatus()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    /// Keeps the status line current while the menu is open, as indexing goes on.
    private func followStatus() {
        guard menuIsOpen else { return }
        statusLine.title = withObservationTracking {
            model.indexStatusText
        } onChange: { [weak self] in
            Task { @MainActor in self?.followStatus() }
        }
    }

    /// Items for this controller's own actions target it; the rest have no target, so the
    /// responder chain takes them to `AppDelegate` or the app.
    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if responds(to: action) { item.target = self }
        return item
    }

    @objc private func showMainWindow(_ sender: Any?) {
        model.presenter.showMainWindow()
    }

    @objc private func grantFullDiskAccess(_ sender: Any?) {
        FullDiskAccess.openSystemSettings()
    }
}
