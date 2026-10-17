import AppKit

/// Shows and hides the app's windows (the main window, About and Settings) and its menu bar
/// icon, for the menus, the global shortcut, the icon and Dock clicks. Keeps the Dock icon only
/// while a window is open.
///
/// With no window open the app is an accessory, like other menu bar apps. While one is open it's
/// a regular app, because accessory apps don't show their menu bar and the window relies on it.
@MainActor
final class WindowPresenter {
    weak var model: AppModel?
    private var mainController: MainWindowController?
    private var aboutController: AboutWindowController?
    private var settingsController: SettingsWindowController?
    private var statusItem: StatusItemController?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { self?.windowDidBecomeKey(window) }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // After the window has closed, so it no longer counts as open.
            Task { @MainActor in self?.updateActivationPolicy() }
        })
    }

    private var mainWindow: NSWindow? { mainController?.window }

    /// Brings the main window to the current Space, in front, with the search field focused.
    func showMainWindow() {
        guard let model else { return }
        activate()
        let controller = mainController ?? MainWindowController(model: model)
        mainController = controller
        guard let window = controller.window else { return }
        let wasOpen = window.isVisible || window.isMiniaturized
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        controller.showWindow(nil)
        if !wasOpen { model.windowDidAppear() }
        model.focusSearch()
    }

    /// The global shortcut: hides the app if its window is already in front, else shows it.
    func toggleMainWindow() {
        if NSApp.isActive, let window = mainWindow, window.isKeyWindow {
            NSApp.hide(nil)
        } else {
            showMainWindow()
        }
    }

    func showAbout() {
        activate()
        let controller = aboutController ?? AboutWindowController()
        aboutController = controller
        controller.showWindow(nil)
    }

    /// Opens Settings in front, on the current Space.
    func showSettings() {
        guard let model else { return }
        activate()
        let controller = settingsController ?? SettingsWindowController(model: model)
        settingsController = controller
        controller.window?.collectionBehavior.insert(.moveToActiveSpace)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Shows the menu bar icon while the app keeps running in the menu bar.
    func updateStatusItem() {
        guard let model else { return }
        if model.keepsRunningInMenuBar, statusItem == nil {
            statusItem = StatusItemController(model: model)
        } else if !model.keepsRunningInMenuBar, let statusItem {
            statusItem.remove()
            self.statusItem = nil
        }
    }

    /// Makes the app a regular one and brings it forward, before showing any of its windows.
    func activate() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.unhide(nil)
        NSApp.activate()
    }

    /// Regular while a window is open or the app doesn't stay in the menu bar; otherwise accessory.
    func updateActivationPolicy() {
        let keepsRunning = model?.keepsRunningInMenuBar ?? false
        let policy: NSApplication.ActivationPolicy = !keepsRunning || hasOpenWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Any titled window: the main window, Settings, About, or an open panel. Menus and the menu
    /// bar icon's own window have no title bar.
    private var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    private func windowDidBecomeKey(_ window: NSWindow?) {
        if window === mainWindow {
            window?.collectionBehavior.insert(.moveToActiveSpace)
        }
        updateActivationPolicy()
    }
}
