import SwiftUI

/// The menu bar icon, shown while the app keeps running in the menu bar.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "doc.text.magnifyingglass")
            // The label exists for as long as the icon does, even with every window closed.
            .onAppear { model.presenter.openWindow = openWindow }
    }
}

/// The menu bar icon's menu: indexing status, a way back to the window, and the app's commands.
struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.indexStatusText)
        Divider()
        Button("Search iFileList") {
            model.presenter.openWindow = openWindow
            model.presenter.showMainWindow()
        }
        .keyboardShortcut(model.globalShortcut?.menuShortcut)
        Button("Rescan All Volumes") { model.rescan() }
        if !model.hasFullDiskAccess {
            Button("Grant Full Disk Access…") { FullDiskAccess.openSystemSettings() }
        }
        Divider()
        Button("About iFileList") {
            model.presenter.activate()
            openWindow(id: AboutView.windowID)
        }
        Button("Settings…") { model.presenter.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit iFileList") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
