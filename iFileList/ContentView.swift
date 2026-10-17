import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if model.needsRelaunchForAccess {
                RelaunchBanner()
                Divider()
            }
            // Shown in the window rather than as a sheet: a sheet would block quitting.
            if model.showsAccessOnboarding {
                FullDiskAccessOnboarding(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if model.hasFilters {
                    FilterBar(model: model)
                    Divider()
                }
                FileTableView(model: model)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let folder = urls.first(where: Self.isFolder) else { return false }
                        model.filter(toFolder: folder)
                        return true
                    } isTargeted: { dropTargeted = $0 }
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(.tint, lineWidth: 3).allowsHitTesting(false)
                        }
                    }
            }
            Divider()
            StatusBar(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showsFolderPicker = true
                } label: {
                    Label("Filter by Folder", systemImage: model.filters.folder == nil ? "folder" : "folder.fill")
                }
                .help("Show only the items in a folder")
                .disabled(model.showsAccessOnboarding)
            }
        }
        .fileImporter(isPresented: $model.showsFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.filter(toFolder: url) }
        }
        .fileDialogConfirmationLabel("Filter")
        .fileDialogDefaultDirectory(model.filters.folder.map { URL(fileURLWithPath: $0, isDirectory: true) })
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { focusSearchField() }
        .onAppear {
            model.presenter.openWindow = openWindow
            model.windowDidAppear()
            // After the window has set up its first responder, so the list doesn't take focus back.
            Task { @MainActor in focusSearchField() }
        }
        .onDisappear { model.windowDidDisappear() }
    }

    /// Puts the cursor in the search field with the query selected, so typing replaces it.
    private func focusSearchField() {
        guard !model.showsAccessOnboarding else { return }
        searchFocused = true
        // Once the field editor has taken over.
        Task { @MainActor in
            guard let editor = NSApp.keyWindow?.firstResponder as? NSText, editor.delegate is NSSearchField
            else { return }
            editor.selectAll(nil)
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// The active filters, shown above the list only while there are any. Each filter is one item in
/// the row, followed by a button that clears them all.
private struct FilterBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let folder = model.filters.folder {
                Image(systemName: "folder")
                Text((folder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder)
                Button("Change…") { model.showsFolderPicker = true }
                    .buttonStyle(.link)
            }
            Spacer()
            Button {
                model.clearFilters()
            } label: {
                Label("Clear Filters", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.tint.opacity(0.08))
    }
}

private struct StatusBar: View {
    let model: AppModel
    @State private var showsAccessInfo = false

    var body: some View {
        HStack(spacing: 8) {
            if let operation = model.operation {
                ProgressView().controlSize(.small)
                Text(operation.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cancel = operation.cancel {
                    Button("Stop") { cancel.cancel() }
                        .buttonStyle(.link)
                }
            } else {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.statusText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !model.hasFullDiskAccess && !model.showsAccessOnboarding {
                Button("Grant Full Disk Access…") { showsAccessInfo = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showsAccessInfo, arrowEdge: .top) {
                        FullDiskAccessExplanation()
                            .padding(20)
                            .frame(width: 400)
                    }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

private struct RelaunchBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "checkmark.shield")
            Text("Full Disk Access granted. Relaunch iFileList to include protected folders.")
            Spacer()
            Button("Relaunch") { FullDiskAccess.relaunch() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.green.opacity(0.12))
    }
}

/// Why Full Disk Access is needed and how to grant it.
private struct FullDiskAccessExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Allow iFileList to see every file", systemImage: "lock.shield")
                .font(.title2.bold())
            Text("""
                To list all files, including Mail, Messages, Safari and other apps' data, iFileList needs \
                Full Disk Access. File names and sizes stay on this Mac, in a cache in ~/Library/Caches.
                """)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                In System Settings, turn on iFileList under Privacy & Security › Full Disk Access, \
                then reopen the app when asked.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { FullDiskAccess.openSystemSettings() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The first-launch prompt, shown in place of the list until the user grants access or skips it.
private struct FullDiskAccessOnboarding: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FullDiskAccessExplanation()
            Divider()
            HStack {
                Text("You can also index without it; protected folders will be skipped.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue Without") { model.continueWithoutFullDiskAccess() }
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}
