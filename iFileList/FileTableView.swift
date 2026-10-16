import AppKit
import FileIndexKit
import Quartz
import SwiftUI

/// The file list: an AppKit table, since SwiftUI's `Table` doesn't scale to millions of rows.
/// Cells are built only for visible rows, straight from the index.
struct FileTableView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = FileListTableView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 20
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.sortDescriptorPrototype = column.sortKey.map {
                NSSortDescriptor(key: $0, ascending: column == .name)
            }
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        // Keyed by the column set, so adding or removing a column starts from the default layout
        // instead of a saved one that has no room for it.
        tableView.autosaveName = "FileList." + Column.allCases.map(\.rawValue).joined(separator: ",")
        tableView.autosaveTableColumns = true
        // After the autosave name, which restores AppKit's own saved sort along with the column
        // widths. The model saves the sort itself, so it survives a change to the column set.
        let order = model.sortOrder
        tableView.sortDescriptors = [NSSortDescriptor(key: Column(order.key).sortKey, ascending: order.ascending)]

        let coordinator = context.coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.openClickedRow(_:))
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([], forLocal: true)
        tableView.onOpen = { [weak coordinator] in coordinator?.openSelection() }
        tableView.onQuickLook = { [weak coordinator] in coordinator?.toggleQuickLook() }
        tableView.model = model
        tableView.previewSource = coordinator
        let menu = NSMenu()
        menu.delegate = coordinator
        tableView.menu = menu
        coordinator.tableView = tableView
        model.listController = coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.reloadIfNeeded(resultsVersion: model.resultsVersion)
    }

    enum Column: String, CaseIterable {
        case name, folder, size, modified, created

        /// The column sorted by `key`.
        init(_ key: SortKey) {
            self = switch key {
            case .name: .name
            case .size: .size
            case .dateModified: .modified
            case .dateCreated: .created
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: "Name"
            case .folder: "Folder"
            case .size: "Size"
            case .modified: "Date Modified"
            case .created: "Date Created"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 260
            case .folder: 340
            case .size: 80
            case .modified, .created: 150
            }
        }

        /// The folder column isn't sortable: ordering millions of paths would need another index.
        var sortKey: String? { self == .folder ? nil : rawValue }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
        NSTextFieldDelegate, FileListController
    {
        let model: AppModel
        weak var tableView: NSTableView?
        private var shownVersion = -1
        private var rows: [EntryID] = []
        /// What the context menu's items act on, set when it opens.
        private var menuTargets = FileTargets.none
        private var menuClickedRow = -1
        /// The selected files Quick Look shows, and their rows.
        private var previewURLs: [URL] = []
        private var previewRows: [Int] = []

        private static let sizeFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        init(model: AppModel) {
            self.model = model
        }

        func reloadIfNeeded(resultsVersion: Int) {
            // Reloading would reuse the cell being edited for another row; catch up once editing ends.
            guard resultsVersion != shownVersion, editedField == nil, let tableView else { return }
            shownVersion = resultsVersion
            let selected = selectedIDs()
            rows = model.results
            tableView.reloadData()
            restoreSelection(selected, in: tableView)
            if let pending = model.pendingSelection, model.searchedVersion >= pending.indexVersion {
                model.pendingSelection = nil
                select(pending.ids, in: tableView, beginRename: pending.beginsRename)
            }
            reportSelection()
        }

        private func selectedIDs() -> [EntryID] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        }

        /// Reselects entries after a reload. Bounded, since it scans the whole result list.
        private func restoreSelection(_ ids: [EntryID], in tableView: NSTableView) {
            guard !ids.isEmpty, ids.count <= 100 else { return }
            let wanted = Set(ids)
            var rowsToSelect = IndexSet()
            for (row, id) in rows.enumerated() where wanted.contains(id) {
                rowsToSelect.insert(row)
                if rowsToSelect.count == wanted.count { break }
            }
            tableView.selectRowIndexes(rowsToSelect, byExtendingSelection: false)
        }

        /// Selects the listed ones of `ids`, after an operation created or moved them.
        private func select(_ ids: [EntryID], in tableView: NSTableView, beginRename: Bool) {
            let wanted = Set(ids)
            var rowsToSelect = IndexSet()
            for (row, id) in rows.enumerated() where wanted.contains(id) {
                rowsToSelect.insert(row)
                if rowsToSelect.count == wanted.count { break }
            }
            guard let first = rowsToSelect.first else { return }
            tableView.selectRowIndexes(rowsToSelect, byExtendingSelection: false)
            tableView.scrollRowToVisible(first)
            tableView.window?.makeFirstResponder(tableView)
            if beginRename, ids.count == 1 {
                // After this update pass, so editing starts in the cell as it will be shown.
                Task { @MainActor in self.beginRename(ids[0]) }
            }
        }

        private func reportSelection() {
            guard let tableView else { return }
            var selection = model.selection
            selection.rows = rows
            selection.indexes = tableView.selectedRowIndexes
            model.selection = selection
        }

        /// The rows an action applies to: the selection if the clicked row is part of it,
        /// otherwise just the clicked row.
        private func targetIDs(clickedRow row: Int) -> [EntryID] {
            guard let tableView, row >= 0, row < rows.count else { return [] }
            if tableView.selectedRowIndexes.contains(row) { return selectedIDs() }
            return [rows[row]]
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  row < rows.count
            else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView
                ?? Self.makeCell(for: column)
            guard let entry = model.index.snapshot(rows[row]) else {
                cell.textField?.stringValue = ""
                cell.imageView?.image = nil
                return cell
            }
            switch column {
            case .name:
                cell.textField?.stringValue = model.displayName(entry)
                cell.textField?.isEditable = !entry.flags.contains(.volumeRoot)
                cell.textField?.delegate = self
                cell.imageView?.image = model.icon(for: entry)
            case .folder:
                cell.textField?.stringValue = model.folderPath(of: entry)
            case .size:
                cell.textField?.stringValue = entry.isDirectory ? "--" : Self.sizeFormatter.string(fromByteCount: entry.size)
            case .modified:
                cell.textField?.stringValue = Self.formattedDate(entry.mtime)
            case .created:
                cell.textField?.stringValue = Self.formattedDate(entry.crtime)
            }
            return cell
        }

        /// Dragging rows out hands other apps the files, as dragging from Finder does.
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row < rows.count, tableView.numberOfSelectedRows <= FileTargets.inspectionLimit else { return nil }
            return model.url(for: rows[row]) as NSURL?
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            reportSelection()
            updatePreviewPanel()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first else { return }
            let key: SortKey = switch descriptor.key {
            case Column.size.sortKey: .size
            case Column.modified.sortKey: .dateModified
            case Column.created.sortKey: .dateCreated
            default: .name
            }
            model.sortOrder = SortOrder(key: key, ascending: descriptor.ascending)
        }

        /// Seconds since 1970 as a short date and time; empty when unknown.
        private static func formattedDate(_ seconds: Int64) -> String {
            guard seconds != 0 else { return "" }
            return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
        }

        private static func makeCell(for column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = column == .folder ? .byTruncatingMiddle : .byTruncatingTail
            text.alignment = column == .size ? .right : .natural
            text.textColor = column == .name ? .labelColor : .secondaryLabelColor
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(text)
            cell.textField = text

            var constraints = [
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ]
            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                constraints += [
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ]
            } else {
                constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4))
            }
            NSLayoutConstraint.activate(constraints)
            return cell
        }

        // MARK: Actions

        @objc func openClickedRow(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            model.open(targetIDs(clickedRow: tableView.clickedRow))
        }

        func openSelection() {
            model.open(selectedIDs())
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            menuClickedRow = tableView.clickedRow
            let ids = targetIDs(clickedRow: menuClickedRow)
            guard !ids.isEmpty else { return }
            let targets = model.targets(ids)
            menuTargets = targets

            // Finder's order.
            add([.open], to: menu)
            menu.addItem(openWithItem(for: targets))
            menu.addItem(.separator())
            add([.moveToTrash], to: menu)
            menu.addItem(.separator())
            add([.getInfo, .rename, .compress, .duplicate, .makeAlias, .quickLook, .showOriginal], to: menu)
            menu.addItem(.separator())
            add([.copy, .copyPathname, .share], to: menu)
            menu.addItem(.separator())
            menu.addItem(tagsItem(for: targets))
            menu.addItem(.separator())
            add([.showInFinder], to: menu)
            if ids.count == 1, let entry = model.index.snapshot(ids[0]), let name = folderName(for: entry) {
                let item = NSMenuItem(
                    title: "Show Only Items in “\(name)”", action: #selector(filterToFolderFromMenu(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            add([.eject], to: menu)
        }

        private func add(_ commands: [FileCommand], to menu: NSMenu) {
            for command in commands where command.isAvailable(for: menuTargets) {
                let item = NSMenuItem(
                    title: command.title(for: menuTargets), action: #selector(performFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = command.rawValue
                menu.addItem(item)
            }
        }

        private func openWithItem(for targets: FileTargets) -> NSMenuItem {
            let submenu = NSMenu()
            for app in model.applications(for: targets) {
                let item = NSMenuItem(
                    title: app.isDefault ? "\(app.name) (default)" : app.name,
                    action: #selector(openWithFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.image = app.icon
                item.representedObject = app.url
                submenu.addItem(item)
                if app.isDefault { submenu.addItem(.separator()) }
            }
            if submenu.items.last?.isSeparatorItem == false { submenu.addItem(.separator()) }
            let other = NSMenuItem(title: "Other…", action: #selector(openWithOtherFromMenu(_:)), keyEquivalent: "")
            other.target = self
            submenu.addItem(other)
            let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        private func tagsItem(for targets: FileTargets) -> NSMenuItem {
            let submenu = NSMenu()
            let states = model.tagStates(for: targets)
            for tag in AppModel.finderTags {
                let item = NSMenuItem(title: tag.name, action: #selector(toggleTagFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.image = tag.image
                item.state = states[tag.name] ?? .off
                item.representedObject = tag.name
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        /// The folder a row filters to: the row itself for a folder, else its enclosing folder.
        private func folderName(for entry: EntrySnapshot) -> String? {
            if entry.isDirectory { return model.displayName(entry) }
            let folder = model.folderPath(of: entry)
            return folder.isEmpty ? nil : (folder == "/" ? "/" : (folder as NSString).lastPathComponent)
        }

        @objc private func performFromMenu(_ sender: NSMenuItem) {
            guard let command = FileCommand(rawValue: sender.tag) else { return }
            if command == .share {
                share(model.urls(menuTargets.ids), at: menuClickedRow)
                return
            }
            // Quick Look shows the selection, so a right-clicked row outside it is selected first, as in Finder.
            if command == .quickLook, let tableView, menuClickedRow >= 0,
               !tableView.selectedRowIndexes.contains(menuClickedRow)
            {
                tableView.selectRowIndexes([menuClickedRow], byExtendingSelection: false)
            }
            model.perform(command, on: menuTargets)
        }

        @objc private func openWithFromMenu(_ sender: NSMenuItem) {
            if let application = sender.representedObject as? URL { model.open(menuTargets, with: application) }
        }

        @objc private func openWithOtherFromMenu(_ sender: NSMenuItem) {
            model.openWithOtherApplication(menuTargets)
        }

        @objc private func toggleTagFromMenu(_ sender: NSMenuItem) {
            if let tag = sender.representedObject as? String { model.toggleTag(tag, on: menuTargets) }
        }

        @objc private func filterToFolderFromMenu(_ sender: NSMenuItem) {
            if let id = menuTargets.prefix(1).first { model.filterToFolder(of: id) }
        }

        // MARK: Share

        func share(_ urls: [URL]) {
            share(urls, at: tableView?.selectedRowIndexes.first ?? -1)
        }

        /// Shows the share picker under the row's icon and name, as Finder does under the item.
        private func share(_ urls: [URL], at row: Int) {
            guard let tableView, !urls.isEmpty else { return }
            let column = tableView.column(withIdentifier: Column.name.identifier)
            guard row >= 0, row < rows.count, column >= 0 else { return }
            tableView.scrollRowToVisible(row)
            var anchor = tableView.frameOfCell(atColumn: column, row: row)
            if let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
               let text = cell.textField
            {
                var name = text.frame
                name.size.width = min(name.width, text.fittingSize.width)
                anchor = cell.convert(name.union(cell.imageView?.frame ?? name), to: tableView)
            }
            // The table is flipped, so its maxY edge is the bottom of the row.
            NSSharingServicePicker(items: urls)
                .show(relativeTo: anchor, of: tableView, preferredEdge: tableView.isFlipped ? .maxY : .minY)
        }

        // MARK: Rename

        /// The name field being edited, if any.
        private var editedField: NSTextField? {
            guard let tableView, let editor = tableView.window?.firstResponder as? NSText,
                  let field = editor.delegate as? NSTextField, field.isDescendant(of: tableView)
            else { return nil }
            return field
        }

        func beginRename(_ id: EntryID) {
            guard let tableView, let row = rows.firstIndex(of: id), let entry = model.index.snapshot(id) else { return }
            let column = tableView.column(withIdentifier: Column.name.identifier)
            guard column >= 0 else { return }
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            tableView.editColumn(column, row: row, with: nil, select: true)
            // Like Finder: the name without its extension, or a folder's whole name.
            guard let field = editedField else { return }
            let name = field.stringValue as NSString
            let length = entry.isDirectory && name.pathExtension.isEmpty
                ? name.length : (FileOperations.split(field.stringValue).base as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
        }

        /// Escape puts the name back.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.abortEditing()
            tableView?.window?.makeFirstResponder(tableView)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let tableView, let field = notification.object as? NSTextField else { return }
            let row = tableView.row(for: field)
            guard row >= 0, row < rows.count, let entry = model.index.snapshot(rows[row]) else { return }
            let name = field.stringValue
            // The list shows the new name once the index has it.
            field.stringValue = model.displayName(entry)
            if tableView.window?.firstResponder === tableView.window { tableView.window?.makeFirstResponder(tableView) }
            model.rename(entry.id, to: name)
            reloadIfNeeded(resultsVersion: model.resultsVersion)
        }
    }
}

// MARK: - Quick Look

extension FileTableView.Coordinator: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    /// The panel shows at most this many selected items.
    private static let previewLimit = 500

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            updatePreviewItems()
            guard !previewURLs.isEmpty else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    fileprivate func updatePreviewPanel() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self
        else { return }
        updatePreviewItems()
        panel.reloadData()
    }

    private func updatePreviewItems() {
        guard let tableView else { return }
        previewRows = []
        previewURLs = []
        for row in tableView.selectedRowIndexes {
            guard previewRows.count < Self.previewLimit else { break }
            if row < rows.count, let url = model.url(for: rows[row]) {
                previewRows.append(row)
                previewURLs.append(url)
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        index < previewURLs.count ? previewURLs[index] as NSURL : nil
    }

    /// Arrow keys and Space in the panel move through and close the list, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let tableView, event.type == .keyDown else { return false }
        tableView.keyDown(with: event)
        return true
    }

    /// Zooms from and to the row's icon.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let tableView, let window = tableView.window, let url = item as? URL,
              let index = previewURLs.firstIndex(of: url)
        else { return .zero }
        let column = tableView.column(withIdentifier: FileTableView.Column.name.identifier)
        guard column >= 0 else { return .zero }
        let cell = tableView.frameOfCell(atColumn: column, row: previewRows[index])
        let icon = NSRect(x: cell.minX + 4, y: cell.midY - 8, width: 16, height: 16)
        guard tableView.visibleRect.intersects(icon) else { return .zero }
        return window.convertToScreen(tableView.convert(icon, to: nil))
    }
}

// MARK: - Table view

/// Opens the selection with Return, toggles Quick Look with Space, and handles Copy and Paste for
/// files while it has focus. Reports focus to the model, so the menu bar's file
/// commands are enabled only then.
final class FileListTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?
    weak var model: AppModel?
    weak var previewSource: FileTableView.Coordinator?
    private var keyObservers: [NSObjectProtocol] = []

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, modifiers.isEmpty, let onOpen {
            onOpen()
        } else if event.keyCode == 49, modifiers.isEmpty, let onQuickLook {
            onQuickLook()
        } else if event.keyCode == 53, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        reportFocus(isFirstResponder: became)
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { reportFocus(isFirstResponder: false) }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard window != nil else { return }
        // Any window: Quick Look's panel becoming key leaves the list in charge.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.reportFocus() }
            })
        }
    }

    private func reportFocus(isFirstResponder: Bool? = nil) {
        guard let model, let window else { return }
        let first = isFirstResponder ?? (window.firstResponder === self)
        let key = window.isKeyWindow || NSApp.keyWindow is QLPreviewPanel
        let focused = first && key
        if model.selection.listIsFocused != focused { model.selection.listIsFocused = focused }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) {
        guard let model else { return }
        model.perform(.copy, on: model.selectionTargets)
    }

    @objc func paste(_ sender: Any?) {
        model?.paste(moving: false)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let model else { return super.validateUserInterfaceItem(item) }
        switch item.action {
        case #selector(copy(_:)):
            return numberOfSelectedRows > 0
        case #selector(paste(_:)):
            return model.hasTargetFolder && FileActions.canPaste
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    // The panel calls these on the main thread; Quartz just doesn't declare it.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = previewSource
            panel.delegate = previewSource
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
