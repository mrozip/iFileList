import SwiftUI

/// The File menu's items for the listed files. They act on the selection while the list is
/// focused; the context menu builds the same commands in `FileTableView`.
struct FileMenuItems: View {
    let model: AppModel

    var body: some View {
        let targets = model.selectionTargets
        Button("New Folder") { model.newFolder() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!model.hasTargetFolder)
        command(.newFolderWithSelection, targets)
            .keyboardShortcut("n", modifiers: [.command, .control])
        Divider()
        command(.open, targets)
            .keyboardShortcut("o")
        OpenWithMenu(model: model, targets: targets)
        command(.showInFinder, targets)
        Divider()
        command(.getInfo, targets)
            .keyboardShortcut("i")
        command(.rename, targets)
        command(.compress, targets)
        command(.duplicate, targets)
            .keyboardShortcut("d")
        command(.makeAlias, targets)
            .keyboardShortcut("a", modifiers: [.command, .control])
        command(.quickLook, targets)
            .keyboardShortcut("y")
        command(.showOriginal, targets)
        command(.share, targets)
        Divider()
        command(.moveToTrash, targets)
            .keyboardShortcut(.delete, modifiers: .command)
        command(.deleteImmediately, targets)
            .keyboardShortcut(.delete, modifiers: [.command, .option])
        command(.eject, targets)
            .keyboardShortcut("e")
        Divider()
        TagsMenu(model: model, targets: targets)
        Divider()
        Button("Rescan All Volumes") { model.rescan() }
            .keyboardShortcut("r")
    }

    private func command(_ command: FileCommand, _ targets: FileTargets) -> some View {
        Button(command.title(for: targets)) { model.perform(command, on: targets) }
            .disabled(!command.isAvailable(for: targets))
    }
}

/// The Edit menu's items for files, after Cut, Copy, Paste and Select All, which the list handles
/// through the responder chain.
struct EditMenuItems: View {
    let model: AppModel

    var body: some View {
        let targets = model.selectionTargets
        Button(FileCommand.copyPathname.title(for: targets)) { model.perform(.copyPathname, on: targets) }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!FileCommand.copyPathname.isAvailable(for: targets))
        Button("Move Item Here") { model.paste(moving: true) }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(!model.hasTargetFolder || !model.selection.listIsFocused)
    }
}

private struct OpenWithMenu: View {
    let model: AppModel
    let targets: FileTargets

    var body: some View {
        Menu("Open With") {
            ForEach(model.applications(for: targets)) { app in
                Button {
                    model.open(targets, with: app.url)
                } label: {
                    Label { Text(app.isDefault ? "\(app.name) (default)" : app.name) } icon: { Image(nsImage: app.icon) }
                }
                if app.isDefault { Divider() }
            }
            Divider()
            Button("Other…") { model.openWithOtherApplication(targets) }
        }
        .disabled(!FileCommand.open.isAvailable(for: targets))
    }
}

private struct TagsMenu: View {
    let model: AppModel
    let targets: FileTargets

    var body: some View {
        Menu("Tags") {
            let states = model.tagStates(for: targets)
            ForEach(AppModel.finderTags) { tag in
                Toggle(isOn: Binding(get: { states[tag.name] == .on }, set: { _ in model.toggleTag(tag.name, on: targets) })) {
                    Label { Text(tag.name) } icon: { Image(nsImage: tag.image) }
                }
            }
        }
        .disabled(targets.isEmpty)
    }
}
