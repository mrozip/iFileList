import AppKit
import FileIndexKit

/// The list's selection as the table reports it. `rows` is the table's copy of the results, which
/// shares storage with `AppModel.results`, so updating this on every click copies nothing.
struct FileSelection {
    var rows: [EntryID] = []
    var indexes = IndexSet()

    var count: Int { indexes.count }
    var ids: [EntryID] { indexes.compactMap { $0 < rows.count ? rows[$0] : nil } }

    /// The first `limit` selected IDs, without resolving the rest.
    func prefix(_ limit: Int) -> [EntryID] {
        var result: [EntryID] = []
        for row in indexes {
            guard result.count < limit else { break }
            if row < rows.count { result.append(rows[row]) }
        }
        return result
    }
}

/// The items a command applies to: the selection for the menu bar, the clicked rows for the context
/// menu. What the commands need to know is worked out once and bounded by `inspectionLimit`, so a
/// selection of millions stays cheap until a command runs.
struct FileTargets {
    static let inspectionLimit = 1_000

    private enum Source {
        case ids([EntryID])
        case selection(FileSelection)
    }

    private let source: Source
    let count: Int
    /// The first item, for titles and for the commands that take one item.
    let first: EntrySnapshot?
    let firstName: String
    /// Every item is in the same folder. False above `inspectionLimit`, where it isn't checked.
    let sharesParent: Bool
    let containsVolumeRoot: Bool
    /// Some item is in the Trash, so it can't be moved there again.
    let containsTrashed: Bool
    /// The one item is a symbolic link or a Finder alias.
    let isLink: Bool

    static let none = FileTargets(source: .ids([]), count: 0, inspected: [], index: nil)

    init(ids: [EntryID], index: FileIndex) {
        self.init(source: .ids(ids), count: ids.count, inspected: Array(ids.prefix(Self.inspectionLimit)), index: index)
    }

    init(selection: FileSelection, index: FileIndex) {
        self.init(
            source: .selection(selection), count: selection.count,
            inspected: selection.prefix(Self.inspectionLimit), index: index)
    }

    private init(source: Source, count: Int, inspected: [EntryID], index: FileIndex?) {
        self.source = source
        self.count = count
        let snapshots = index?.read { reader in inspected.compactMap { reader.snapshot($0) } } ?? []
        first = snapshots.first
        if let first {
            firstName = first.flags.contains(.volumeRoot) && first.name != "/"
                ? (first.name as NSString).lastPathComponent : first.name
        } else {
            firstName = ""
        }
        let inspectedAll = count <= Self.inspectionLimit
        sharesParent = inspectedAll && !snapshots.isEmpty
            && snapshots.allSatisfy { $0.parent == snapshots[0].parent && !$0.flags.contains(.volumeRoot) }
        containsVolumeRoot = snapshots.contains { $0.flags.contains(.volumeRoot) }
        let folders = Set(snapshots.filter { !$0.flags.contains(.volumeRoot) }.map(\.parent))
        containsTrashed = folders.contains { index?.path(of: $0).map(FileOperations.isInTrash) == true }
        if count == 1, let first, let index {
            isLink = first.flags.contains(.symlink)
                || (!first.isDirectory && index.path(of: first.id).map(Self.isAlias) == true)
        } else {
            isLink = false
        }
    }

    /// Resolved only when a command runs.
    var ids: [EntryID] {
        switch source {
        case .ids(let ids): ids
        case .selection(let selection): selection.ids
        }
    }

    /// The first `limit` IDs, for menus that look at a few items.
    func prefix(_ limit: Int) -> [EntryID] {
        switch source {
        case .ids(let ids): Array(ids.prefix(limit))
        case .selection(let selection): selection.prefix(limit)
        }
    }

    var isEmpty: Bool { count == 0 }

    /// A name short enough for a menu title.
    var shortName: String {
        guard firstName.count > 40 else { return firstName }
        return String(firstName.prefix(24)) + "…" + String(firstName.suffix(12))
    }

    private static func isAlias(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    }
}

/// The commands that act on listed files, shared by the menu bar and the context menu so their
/// titles and availability come from one place. Keyboard shortcuts belong to the menu bar.
enum FileCommand: Int, CaseIterable {
    case open, showInFinder, getInfo, rename, compress, duplicate, makeAlias, quickLook, showOriginal, moveToTrash,
         deleteImmediately, eject, copy, copyPathname, newFolderWithSelection, share

    /// Finder's title: with the item's name for one item, the count for several, plain for none.
    func title(for targets: FileTargets) -> String {
        let name = targets.shortName
        let count = targets.count.formatted()
        return switch (self, targets.count) {
        case (.open, _): "Open"
        case (.showInFinder, _): "Show in Finder"
        case (.getInfo, _): "Get Info"
        case (.rename, _): "Rename"
        case (.compress, 0): "Compress"
        case (.compress, 1): "Compress “\(name)”"
        case (.compress, _): "Compress \(count) Items"
        case (.duplicate, _): "Duplicate"
        case (.makeAlias, _): "Make Alias"
        case (.quickLook, 0): "Quick Look"
        case (.quickLook, 1): "Quick Look “\(name)”"
        case (.quickLook, _): "Quick Look \(count) Items"
        case (.showOriginal, _): "Show Original"
        case (.share, _): "Share…"
        // "Move to Bin" in UK English, as in Finder.
        case (.moveToTrash, _): String(localized: "Move to Trash")
        case (.deleteImmediately, _): "Delete Immediately…"
        case (.eject, 1): "Eject “\(name)”"
        case (.eject, _): "Eject"
        case (.copy, 0): "Copy"
        case (.copy, 1): "Copy “\(name)”"
        case (.copy, _): "Copy \(count) Items"
        case (.copyPathname, 0): "Copy as Pathname"
        case (.copyPathname, 1): "Copy “\(name)” as Pathname"
        case (.copyPathname, _): "Copy \(count) Items as Pathnames"
        case (.newFolderWithSelection, 0): "New Folder with Selection"
        case (.newFolderWithSelection, 1): "New Folder with Selection (1 Item)"
        case (.newFolderWithSelection, _): "New Folder with Selection (\(count) Items)"
        }
    }

    func isAvailable(for targets: FileTargets) -> Bool {
        guard !targets.isEmpty else { return false }
        return switch self {
        case .open, .showInFinder, .getInfo, .makeAlias, .quickLook, .copy, .copyPathname: true
        case .rename: targets.count == 1 && !targets.containsVolumeRoot
        case .compress, .duplicate, .deleteImmediately: !targets.containsVolumeRoot
        case .moveToTrash: !targets.containsVolumeRoot && !targets.containsTrashed
        case .showOriginal: targets.isLink
        case .eject: targets.count == 1 && targets.containsVolumeRoot && targets.first?.name != "/"
        case .newFolderWithSelection: targets.sharesParent
        // Above the limit, resolving every URL just to show the picker isn't worth it.
        case .share: targets.count <= FileTargets.inspectionLimit
        }
    }
}

/// What the file list view does for commands that need it.
@MainActor
protocol FileListController: AnyObject {
    /// Starts editing the name of the entry's row, if it is listed.
    func beginRename(_ id: EntryID)
    func toggleQuickLook()
    /// Shows the share picker under the selected item.
    func share(_ urls: [URL])
}

/// The Open With and Tags submenus, for the context menu and the File menu. Their items act on
/// `targets`, which the owner sets before building or filling them.
@MainActor
final class FileSubmenus: NSObject {
    private let model: AppModel
    var targets = FileTargets.none

    init(model: AppModel) {
        self.model = model
    }

    func openWithItem() -> NSMenuItem {
        let submenu = NSMenu()
        fillOpenWith(submenu)
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    func tagsItem() -> NSMenuItem {
        let submenu = NSMenu()
        fillTags(submenu)
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    func fillOpenWith(_ menu: NSMenu) {
        menu.removeAllItems()
        for app in model.applications(for: targets) {
            let item = NSMenuItem(
                title: app.isDefault ? "\(app.name) (default)" : app.name,
                action: #selector(openWith(_:)), keyEquivalent: "")
            item.target = self
            item.image = app.icon
            item.representedObject = app.url
            menu.addItem(item)
            if app.isDefault { menu.addItem(.separator()) }
        }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
    }

    func fillTags(_ menu: NSMenu) {
        menu.removeAllItems()
        let states = model.tagStates(for: targets)
        for tag in AppModel.finderTags {
            let item = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            item.target = self
            item.image = tag.image
            item.state = states[tag.name] ?? .off
            item.representedObject = tag.name
            menu.addItem(item)
        }
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        if let application = sender.representedObject as? URL { model.open(targets, with: application) }
    }

    @objc private func openWithOther(_ sender: NSMenuItem) {
        model.openWithOtherApplication(targets)
    }

    @objc private func toggleTag(_ sender: NSMenuItem) {
        if let tag = sender.representedObject as? String { model.toggleTag(tag, on: targets) }
    }
}
