import AppKit
import FileIndexKit
import SwiftUI

/// The Settings window (iFileList › Settings…, ⌘,): which volumes are indexed and what is left out.
struct SettingsView: View {
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
        .frame(width: 520)
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
