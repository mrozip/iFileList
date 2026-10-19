import AppKit

/// Starts the app with an AppKit lifecycle, so the menu bar is AppKit's (`MainMenu`) rather than
/// SwiftUI's. The windows still show SwiftUI views.
@main
@MainActor
enum iFileListApp {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

/// Owns the model, so it exists before any window and while none is open, and handles the menu
/// bar's commands that need no window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let projectURL = URL(string: "https://github.com/mrozip/iFileList")!
    static let helpURL = URL(string: "https://github.com/mrozip/iFileList#readme")!

    let model = AppModel()
    private lazy var mainMenu = MainMenu(model: model)
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only readable while the launch event is being handled.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // One window, so no tabs and no tab commands in the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = mainMenu.makeMenuBar()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
        model.presenter.updateStatusItem()
        if launchedAtLogin && model.keepsRunningInMenuBar && !model.showsAccessOnboarding {
            // Started to keep the index current; the window opens with the shortcut or the icon.
            model.presenter.updateActivationPolicy()
        } else {
            model.presenter.showMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.keepsRunningInMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.presenter.showMainWindow()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Menu bar

    @objc func showAbout(_ sender: Any?) {
        model.presenter.showAbout()
    }

    @objc func showSettings(_ sender: Any?) {
        model.presenter.showSettings()
    }

    @objc func rescanAllVolumes(_ sender: Any?) {
        model.rescan()
    }

    /// The README, since the app has no help book for NSApplication's Help.
    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }
}
