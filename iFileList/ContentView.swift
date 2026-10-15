import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

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
                FileTableView(model: model)
            }
            Divider()
            StatusBar(model: model)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search file names")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onAppear { model.windowAppeared() }
    }
}

private struct StatusBar: View {
    let model: AppModel
    @State private var showsAccessInfo = false

    var body: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(model.statusText)
                .lineLimit(1)
                .truncationMode(.middle)
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
