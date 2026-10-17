import AppKit
import FileIndexKit
import UniformTypeIdentifiers

/// A background file operation's line in the status bar.
struct FileOperationProgress {
    var id = UUID()
    var text: String
    /// Cancels the operation's task; nil when it can't be stopped.
    let stop: (() -> Void)?
}

/// Entries to select once results searched at `indexVersion` or later are shown.
struct PendingSelection {
    var ids: [EntryID]
    var indexVersion: UInt64
    var beginsRename: Bool
}

/// One of Finder's color tags.
struct FinderTag: Identifiable {
    let name: String
    let image: NSImage
    var id: String { name }
}

// MARK: - Commands

extension AppModel {
    /// The selection, for the menu bar's commands. They reach the list only while it has focus.
    var selectionTargets: FileTargets {
        FileTargets(selection: selection, index: index)
    }

    func targets(_ ids: [EntryID]) -> FileTargets {
        FileTargets(ids: ids, index: index)
    }

    func urls(_ ids: [EntryID]) -> [URL] {
        ids.compactMap(url(for:))
    }

    func perform(_ command: FileCommand, on targets: FileTargets) {
        guard command.isAvailable(for: targets) else { return }
        let ids = targets.ids
        switch command {
        case .open: open(ids)
        case .showInFinder: revealInFinder(ids)
        case .getInfo: showInfo(ids)
        case .rename: listController?.beginRename(ids[0])
        case .compress: compress(urls(ids))
        case .duplicate: duplicate(urls(ids))
        case .makeAlias: makeAliases(urls(ids))
        case .quickLook: listController?.toggleQuickLook()
        case .showOriginal: showOriginal(of: ids[0])
        case .moveToTrash: moveToTrash(urls(ids))
        case .deleteImmediately: deleteImmediately(urls(ids))
        case .eject: eject(ids[0])
        case .copy: FileActions.copy(urls(ids))
        case .copyPathname: FileActions.copyPathnames(urls(ids))
        case .newFolderWithSelection: newFolder(with: urls(ids))
        case .share: listController?.share(urls(ids))
        }
    }

    /// New Folder and Paste put items in the filtered folder; without a folder
    /// filter there is no current folder, as in Finder's search results.
    var hasTargetFolder: Bool { filters.folder != nil && !showsAccessOnboarding }

    // MARK: The index

    /// Updates the index for `urls` now instead of after FSEvents' latency.
    func refreshIndex(_ urls: [URL]) {
        var seen = Set<String>()
        let paths = urls.flatMap { [$0.path, $0.deletingLastPathComponent().path] }.filter { seen.insert($0).inserted }
        if !paths.isEmpty { coordinator?.refresh(paths: paths) }
    }

    /// Refreshes `urls`, then selects them once they are listed, and can start renaming the first.
    func select(_ urls: [URL], beginRename: Bool = false) {
        refreshIndex(urls)
        guard let coordinator, !urls.isEmpty else { return }
        Task {
            let ids = await coordinator.entryIDs(atPaths: urls.map(\.path)).compactMap { $0 }
            guard !ids.isEmpty else { return }
            pendingSelection = PendingSelection(ids: ids, indexVersion: index.version, beginsRename: beginRename)
            runSearch()
        }
    }

    // MARK: Running operations

    /// Runs `work` in a detached task with a line in the status bar and a Stop button, which
    /// cancels the task. `work` can update the line through its argument.
    func runInBackground<T: Sendable>(
        _ text: String, _ work: @escaping @Sendable (_ update: @escaping @Sendable (String) -> Void) -> T
    ) async -> T {
        let id = UUID()
        let update: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                if let self, self.operation?.id == id { self.operation?.text = text }
            }
        }
        let task = Task.detached(priority: .userInitiated) { work(update) }
        operation = FileOperationProgress(id: id, text: text, stop: task.cancel)
        let result = await task.value
        operation = nil
        return result
    }

    /// Only one background operation runs at a time.
    private var canStartOperation: Bool {
        if operation == nil { return true }
        NSSound.beep()
        return false
    }

    func present(_ error: any Error) {
        if let error = error as? CocoaError, error.code == .userCancelled { return }
        NSAlert(error: error).runModal()
    }

    private func alert(_ message: String, _ information: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.runModal()
    }

    /// Asks before acting on many items at once, since a stray ⌘A selects millions.
    private func confirmMany(_ count: Int, action: String) -> Bool {
        guard count > FileTargets.inspectionLimit else { return true }
        let alert = NSAlert()
        alert.messageText = "\(action) \(count.formatted()) items?"
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Trash and delete

    /// Moves items to the Trash through Finder, so its Put Back works.
    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty, confirmMany(urls.count, action: String(localized: "Move to Trash")) else { return }
        let showsProgress = urls.count > 20 && operation == nil
        if showsProgress {
            let text = String(localized: "Moving \(urls.count.formatted()) items to the Trash…")
            operation = FileOperationProgress(text: text, stop: nil)
        }
        NSWorkspace.shared.recycle(urls) { [weak self] map, error in
            Task { @MainActor in
                guard let self else { return }
                if showsProgress { self.operation = nil }
                self.refreshIndex(Array(map.keys) + Array(map.values))
                if let error { self.present(error) }
            }
        }
    }

    func deleteImmediately(_ urls: [URL]) {
        guard !urls.isEmpty, canStartOperation else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if urls.count == 1 {
            alert.messageText = "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
            alert.informativeText = "This item will be deleted immediately. You can’t undo this action."
        } else {
            alert.messageText = "Are you sure you want to delete these \(urls.count.formatted()) items?"
            alert.informativeText = "These items will be deleted immediately. You can’t undo this action."
        }
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let total = urls.count
            let (deleted, error) = await runInBackground("Deleting \(total.formatted()) items…") { update in
                FileOperations.delete(urls) { number, url in
                    update("Deleting “\(url.lastPathComponent)” (\((number + 1).formatted()) of \(total.formatted()))…")
                }
            }
            refreshIndex(deleted)
            if let error { present(error) }
        }
    }

    // MARK: Create

    /// Duplicates through Finder's own naming ("name copy").
    func duplicate(_ urls: [URL]) {
        guard !urls.isEmpty, confirmMany(urls.count, action: "Duplicate"), canStartOperation else { return }
        let name = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count.formatted()) items"
        operation = FileOperationProgress(text: "Duplicating \(name)…", stop: nil)
        NSWorkspace.shared.duplicate(urls) { [weak self] map, error in
            Task { @MainActor in
                guard let self else { return }
                self.operation = nil
                self.select(urls.compactMap { map[$0] })
                if let error { self.present(error) }
            }
        }
    }

    func makeAliases(_ urls: [URL]) {
        guard !urls.isEmpty, confirmMany(urls.count, action: "Make Aliases for") else { return }
        let (created, error) = FileOperations.makeAliases(urls)
        select(created)
        if let error { present(error) }
    }

    func compress(_ urls: [URL]) {
        guard let first = urls.first, confirmMany(urls.count, action: "Compress"), canStartOperation else { return }
        let folder = first.deletingLastPathComponent()
        let text = urls.count == 1 ? "Compressing “\(first.lastPathComponent)”…" : "Compressing \(urls.count.formatted()) items…"
        Task {
            let result = await runInBackground(text) { _ in
                Result { try FileOperations.compress(urls, into: folder) }
            }
            switch result {
            case .success(let archive): select([archive])
            case .failure(let error): present(error)
            }
        }
    }

    func newFolder() {
        guard let folder = filters.folder else {
            NSSound.beep()
            return
        }
        let url = FileOperations.available(URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("untitled folder"))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            select([url], beginRename: true)
        } catch {
            present(error)
        }
    }

    /// Finder's New Folder with Selection: a folder next to the items, with the items moved into it.
    func newFolder(with urls: [URL]) {
        guard let parent = urls.first?.deletingLastPathComponent() else { return }
        let folder = FileOperations.available(parent.appendingPathComponent("New Folder With Items"))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for url in urls {
                try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            }
        } catch {
            present(error)
        }
        refreshIndex(urls)
        select([folder], beginRename: true)
    }

    // MARK: Rename

    /// Renames the entry's item, after editing its name in the list.
    func rename(_ id: EntryID, to name: String) {
        guard let url = url(for: id), name != url.lastPathComponent, isUsableName(name, for: url) else { return }
        do {
            let renamed = try FileOperations.rename(url, to: name)
            refreshIndex([url])
            select([renamed])
        } catch {
            present(error)
        }
    }

    private func isUsableName(_ name: String, for url: URL) -> Bool {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") {
            alert("The name “\(name)” can’t be used.", "Try using a name with fewer characters, or with no slash (/).")
            return false
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        if FileOperations.exists(destination) && !FileOperations.isSameItem(url, destination) {
            alert("The name “\(name)” is already taken.", "Please choose a different name.")
            return false
        }
        return true
    }

    // MARK: Links and volumes

    /// Lists the folder holding the original of a symbolic link or alias, with the original selected.
    func showOriginal(of id: EntryID) {
        guard let url = url(for: id) else { return }
        let target: URL?
        if index.snapshot(id)?.flags.contains(.symlink) == true {
            // realpath keeps /private, unlike resolvingSymlinksInPath, so the path matches the index.
            target = realpath(url.path, nil).map { pointer in
                defer { free(pointer) }
                return URL(fileURLWithPath: String(cString: pointer))
            }
        } else {
            target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
        }
        guard let target, FileOperations.exists(target), target.path != url.path else {
            alert("The original item for “\(url.lastPathComponent)” can’t be found.")
            return
        }
        filter(toFolder: target.deletingLastPathComponent())
        query = ""
        select([target])
    }

    func eject(_ id: EntryID) {
        guard let url = url(for: id) else { return }
        Task {
            let error: (any Error)? = await Task.detached {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error { present(error) }
        }
    }

    // MARK: Open With

    /// The apps that open every target (the first 20), cached by their content types.
    func applications(for targets: FileTargets) -> [FileActions.Application] {
        let types: [UTType] = index.read { reader in
            var seen = Set<String>()
            return targets.prefix(20).compactMap { reader.snapshot($0) }.map(Self.contentType).filter {
                seen.insert($0.identifier).inserted
            }
        }
        let key = types.map(\.identifier).sorted().joined(separator: "\n")
        if let cached = applicationsByType[key] { return cached }
        let apps = FileActions.applications(for: types)
        applicationsByType[key] = apps
        return apps
    }

    private static func contentType(of entry: EntrySnapshot) -> UTType {
        let ext = (entry.name as NSString).pathExtension
        if entry.isDirectory {
            return ext.isEmpty ? .folder : UTType(filenameExtension: ext, conformingTo: .directory) ?? .folder
        }
        return ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
    }

    func open(_ targets: FileTargets, with application: URL) {
        FileActions.open(urls(targets.ids), with: application)
    }

    func openWithOtherApplication(_ targets: FileTargets) {
        let urls = urls(targets.ids)
        guard !urls.isEmpty, let application = FileActions.chooseApplication() else { return }
        FileActions.open(urls, with: application)
    }

    // MARK: Tags

    /// Finder's seven color tags, in Finder's order.
    static let finderTags: [FinderTag] = {
        let workspace = NSWorkspace.shared
        let names = workspace.fileLabels
        let colors = workspace.fileLabelColors
        // fileLabels is ordered None, Gray, Green, Purple, Blue, Yellow, Red, Orange.
        return [6, 7, 5, 2, 4, 3, 1].compactMap { label in
            guard label < names.count, label < colors.count else { return nil }
            let color = colors[label]
            let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            return FinderTag(name: names[label], image: image)
        }
    }()

    /// For each tag, whether every target has it (on), some do (mixed) or none (off). Reads the
    /// tags of at most 100 items.
    func tagStates(for targets: FileTargets) -> [String: NSControl.StateValue] {
        guard !targets.isEmpty, targets.count <= 100 else { return [:] }
        let tags = urls(targets.ids).map(FileOperations.tags(of:))
        var states: [String: NSControl.StateValue] = [:]
        for tag in Self.finderTags {
            let having = tags.count { $0.contains(tag.name) }
            states[tag.name] = having == 0 ? .off : having == tags.count ? .on : .mixed
        }
        return states
    }

    /// Finder's toggle: removes the tag if every target has it, otherwise adds it to all of them.
    func toggleTag(_ tag: String, on targets: FileTargets) {
        let urls = urls(targets.ids)
        let tags = urls.map(FileOperations.tags(of:))
        let removing = tags.allSatisfy { $0.contains(tag) }
        for (url, tags) in zip(urls, tags) {
            do {
                try FileOperations.setTags(removing ? tags.filter { $0 != tag } : tags.contains(tag) ? tags : tags + [tag], of: url)
            } catch {
                present(error)
                return
            }
        }
    }

    // MARK: Paste

    /// Copies the files on the pasteboard into the filtered folder.
    func paste() {
        guard let folder = filters.folder, canStartOperation else { return }
        let sources = FileActions.pastedFiles()
        guard !sources.isEmpty else {
            NSSound.beep()
            return
        }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        var transfers: [FileOperations.Transfer] = []
        for source in sources {
            if source.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path {
                // Pasting where the item already is makes a copy, as in Finder.
                transfers.append(.init(source: source, destination: FileOperations.availableCopy(of: source, in: destination)))
                continue
            }
            var transfer = FileOperations.Transfer(source: source, destination: destination.appendingPathComponent(source.lastPathComponent))
            if FileOperations.exists(transfer.destination) {
                switch askAboutConflict(source.lastPathComponent) {
                case .alertFirstButtonReturn: transfer.destination = FileOperations.available(transfer.destination)
                case .alertThirdButtonReturn: transfer.replacing = true
                default: return
                }
            }
            transfers.append(transfer)
        }
        guard !transfers.isEmpty else { return }
        let planned = transfers
        Task {
            let total = planned.count
            let outcome = await runInBackground("Copying \(total.formatted()) items…") { update in
                FileOperations.copy(planned) { number, transfer in
                    update("Copying “\(transfer.source.lastPathComponent)” (\((number + 1).formatted()) of \(total.formatted()))…")
                }
            }
            select(outcome.done.map(\.destination))
            if let error = outcome.error { present(error) }
        }
    }

    /// Finder's question when an item is in the way: Keep Both, Stop or Replace, in that order.
    private func askAboutConflict(_ name: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "An item named “\(name)” already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you’re copying?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Replace")
        return alert.runModal()
    }
}
