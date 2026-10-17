import SwiftUI

@main
struct iFileListApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("iFileList", id: WindowPresenter.mainWindowID) {
            ContentView(model: model)
                .frame(minWidth: 600, minHeight: 300)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.presenter.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                FileMenuItems(model: model)
            }
            // File operations have no Undo, and the search field doesn't need the menu items.
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(after: .pasteboard) {
                EditMenuItems(model: model)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find") { model.focusSearch() }
                    .keyboardShortcut("f")
            }
            CommandMenu("Filter") {
                Button("Filter by Folder…") { model.showsFolderPicker = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.showsAccessOnboarding)
                Divider()
                Button("Clear Filters") { model.clearFilters() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.hasFilters)
            }
        }

        Window("About iFileList", id: AboutView.windowID) {
            AboutView()
                .windowMinimizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra(isInserted: Bindable(model).keepsRunningInMenuBar) {
            MenuBarMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

/// Owns the model, so it exists before any scene and while no window is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only readable while the launch event is being handled.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
        if model.showsAccessOnboarding {
            model.presenter.showMainWindow()
        } else if launchedAtLogin && model.keepsRunningInMenuBar {
            // Started to keep the index current; the window opens with the shortcut or the icon.
            DispatchQueue.main.async { [model] in
                model.presenter.closeMainWindow()
                model.presenter.updateActivationPolicy()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.keepsRunningInMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.presenter.showMainWindow()
        return false
    }
}
