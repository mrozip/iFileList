import SwiftUI

@main
struct iFileListApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("iFileList", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 600, minHeight: 300)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
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

        // Adds iFileList › Settings… (⌘,) to the app menu.
        Settings {
            SettingsView(model: model)
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
