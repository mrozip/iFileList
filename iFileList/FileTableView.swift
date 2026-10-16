import AppKit
import FileIndexKit
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
        tableView.onOpen = { [weak coordinator] in coordinator?.openSelection() }
        let menu = NSMenu()
        menu.delegate = coordinator
        tableView.menu = menu
        coordinator.tableView = tableView

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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var tableView: NSTableView?
        private var shownVersion = -1
        private var rows: [EntryID] = []

        private static let sizeFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        init(model: AppModel) {
            self.model = model
        }

        func reloadIfNeeded(resultsVersion: Int) {
            guard resultsVersion != shownVersion, let tableView else { return }
            shownVersion = resultsVersion
            let selected = selectedIDs()
            rows = model.results
            tableView.reloadData()
            restoreSelection(selected, in: tableView)
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

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let ids = targetIDs(clickedRow: tableView.clickedRow)
            guard !ids.isEmpty else { return }
            menu.addItem(item("Open", #selector(openFromMenu(_:)), ids))
            menu.addItem(item("Open in Finder", #selector(revealFromMenu(_:)), ids))
            menu.addItem(.separator())
            menu.addItem(item("Properties", #selector(showInfoFromMenu(_:)), ids))
        }

        private func item(_ title: String, _ action: Selector, _ ids: [EntryID]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = ids
            return item
        }

        @objc private func openFromMenu(_ sender: NSMenuItem) {
            model.open(sender.representedObject as? [EntryID] ?? [])
        }

        @objc private func revealFromMenu(_ sender: NSMenuItem) {
            model.revealInFinder(sender.representedObject as? [EntryID] ?? [])
        }

        @objc private func showInfoFromMenu(_ sender: NSMenuItem) {
            model.showInfo(sender.representedObject as? [EntryID] ?? [])
        }
    }
}

/// Opens the selection with Return or ⌘O.
final class FileListTableView: NSTableView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isCommandO = event.charactersIgnoringModifiers == "o" && event.modifierFlags.contains(.command)
        if (isReturn || isCommandO), let onOpen {
            onOpen()
        } else {
            super.keyDown(with: event)
        }
    }
}
