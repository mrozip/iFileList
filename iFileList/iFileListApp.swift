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
                Button("Rescan All Volumes") { model.rescan() }
                    .keyboardShortcut("r")
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find") { model.focusSearch() }
                    .keyboardShortcut("f")
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
