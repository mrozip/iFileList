import AppKit
import FileIndexKit
import ServiceManagement
import SwiftUI

/// The Settings window (iFileList › Settings…, ⌘,). Like Finder's, it's an AppKit tab view
/// controller with one toolbar item per pane, which SwiftUI's `Settings` scene doesn't match:
/// its tabs highlight on hover.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // The window takes its title from the controller; keep it rather than the pane's.
        tabs.title = "iFileList Settings"
        tabs.canPropagateSelectedChildViewControllerTitle = false
        tabs.addTabViewItem(Self.pane("General", symbol: "gearshape", GeneralSettingsView(model: model)))
        tabs.addTabViewItem(Self.pane("Index", symbol: "internaldrive", IndexSettingsView(model: model)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A pane that sizes the window to its content, so each tab gets the height it needs.
    private static func pane(_ title: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view.frame(width: 520))
        controller.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// Running in the background and the global search shortcut.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Background") {
                Toggle(isOn: $model.keepsRunningInMenuBar) {
                    Text("Keep running in the menu bar")
                    Text("Closing the window leaves iFileList keeping the index up to date. Quit from the menu bar icon.")
                }
                Toggle(isOn: launchesAtLogin) {
                    Text("Launch at login")
                    if let loginError {
                        Text(loginError).foregroundStyle(.red)
                    } else if loginStatus == .requiresApproval {
                        Text("Allow iFileList in System Settings › General › Login Items.")
                    }
                }
                if loginStatus == .requiresApproval {
                    Button("Open Login Items Settings") { LaunchAtLogin.openSystemSettings() }
                }
            }
            Section("Global Search") {
                LabeledContent {
                    ShortcutRecorder(model: model)
                } label: {
                    Text("Search shortcut")
                    if model.globalShortcutIsTaken {
                        Text("Another app uses this shortcut. Choose a different one.").foregroundStyle(.red)
                    } else {
                        Text("Shows the iFileList window from any app.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = LaunchAtLogin.status  // may have changed in System Settings
        }
    }

    private var launchesAtLogin: Binding<Bool> {
        Binding {
            loginStatus == .enabled || loginStatus == .requiresApproval
        } set: { enabled in
            do {
                try LaunchAtLogin.setEnabled(enabled)
                loginError = nil
            } catch {
                loginError = error.localizedDescription
            }
            loginStatus = LaunchAtLogin.status
        }
    }
}

/// Which volumes are indexed and what is left out.
struct IndexSettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<String> = []

    var body: some View {
        Form {
            Section("Volumes") {
                Toggle(isOn: $model.indexSettings.indexesExternalVolumes) {
                    Text("Index external drives")
                    Text("USB, Thunderbolt and other drives connected to this Mac, and mounted disk images.")
                }
                Toggle(isOn: $model.indexSettings.indexesNetworkVolumes) {
                    Text("Index network drives")
                    Text("Changes made on other computers appear after a rescan (⌘R).")
                }
            }
            Section("Excluded from Index") {
                List(selection: $selection) {
                    ForEach(model.indexSettings.excludedPaths, id: \.self) { path in
                        ExclusionRow(path: path)
                    }
                }
                .frame(height: 140)
                .overlay {
                    if model.indexSettings.excludedPaths.isEmpty {
                        Text("Drag files or folders here, or click +.")
                            .foregroundStyle(.secondary)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    model.addExclusions(urls)
                    return !urls.isEmpty
                }
                .onDeleteCommand(perform: removeSelection)

                HStack(spacing: 2) {
                    Button(action: chooseExclusions) {
                        Image(systemName: "plus").frame(width: 20, height: 16)
                    }
                    .help("Exclude files or folders")
                    Button(action: removeSelection) {
                        Image(systemName: "minus").frame(width: 20, height: 16)
                    }
                    .help("Stop excluding the selected items")
                    .disabled(selection.isEmpty)
                    Spacer()
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseExclusions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Choose files or folders to leave out of the index."
        let model = model
        let completion = { (response: NSApplication.ModalResponse) in
            if response == .OK { model.addExclusions(panel.urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func removeSelection() {
        model.removeExclusions(selection)
        selection = []
    }
}

/// One excluded item: its Finder icon and path, dimmed when nothing is there now (for example
/// on a drive that isn't connected).
private struct ExclusionRow: View {
    let path: String

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: path)
        Label {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 16, height: 16)
        }
        .opacity(exists ? 1 : 0.5)
        .help(exists ? path : "\(path) (not found)")
    }
}
