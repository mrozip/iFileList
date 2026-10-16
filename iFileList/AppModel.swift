import AppKit
import FileIndexKit
import Observation
import Synchronization
import UniformTypeIdentifiers

/// App state: the index, the current query and its results, and indexing status.
@MainActor
@Observable
final class AppModel {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.mrozip.iFileList"

    var query = "" {
        didSet { if query != oldValue { runSearch() } }
    }
    /// Narrows the list beyond the query. Not saved: each launch starts unfiltered, like the query.
    var filters = SearchFilters() {
        didSet { if filters != oldValue { runSearch() } }
    }
    /// Shows the folder picker for the folder filter.
    var showsFolderPicker = false
    var sortOrder = AppModel.savedSortOrder {
        didSet {
            guard sortOrder != oldValue else { return }
            UserDefaults.standard.set(sortOrder.key.rawValue, forKey: Self.sortKeyKey)
            UserDefaults.standard.set(sortOrder.ascending, forKey: Self.sortAscendingKey)
            runSearch()
        }
    }
    /// What is indexed besides the startup disk; edited in the Settings window.
    var indexSettings = AppModel.savedIndexSettings {
        didSet {
            guard indexSettings != oldValue else { return }
            let defaults = UserDefaults.standard
            defaults.set(indexSettings.indexesExternalVolumes, forKey: Self.externalVolumesKey)
            defaults.set(indexSettings.indexesNetworkVolumes, forKey: Self.networkVolumesKey)
            defaults.set(indexSettings.excludedPaths, forKey: Self.excludedPathsKey)
            coordinator?.update(settings: indexSettings)
        }
    }
    private(set) var results: [EntryID] = []
    /// Increases each time `results` is replaced; the table reloads when it changes.
    private(set) var resultsVersion = 0
    private(set) var status = IndexStatus()
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    /// Full Disk Access was granted while running; a relaunch is needed to use it.
    private(set) var needsRelaunchForAccess = false
    /// First launch without Full Disk Access: the window explains it instead of showing the list.
    private(set) var showsAccessOnboarding = false
    /// Increments to ask the window to focus the search field.
    private(set) var searchFocusRequest = 0
    /// The list's selection and focus; the menu bar's file commands act on it.
    var selection = FileSelection()
    /// The file operation running in the background, shown in the status bar.
    var operation: FileOperationProgress?

    @ObservationIgnored let index: FileIndex
    @ObservationIgnored let coordinator: IndexCoordinator?
    @ObservationIgnored weak var listController: FileListController?
    /// Entries to select once the results include them, after an operation created them.
    @ObservationIgnored var pendingSelection: PendingSelection?
    @ObservationIgnored var applicationsByType: [String: [FileActions.Application]] = [:]
    @ObservationIgnored private let engine: SearchEngine
    @ObservationIgnored private let databaseURL: URL?
    @ObservationIgnored private let searchGeneration = SearchGeneration()
    /// The index version the current results were searched at.
    @ObservationIgnored private(set) var searchedVersion: UInt64 = 0
    @ObservationIgnored private var throttledSearch: Task<Void, Never>?
    @ObservationIgnored private var searchInFlight = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var lastSearchStart = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var folderPaths: [EntryID: String] = [:]
    @ObservationIgnored private var icons = IconCache()

    private static let skippedAccessKey = "skippedFullDiskAccess"
    private static let sortKeyKey = "sortKey"
    private static let sortAscendingKey = "sortAscending"
    private static let externalVolumesKey = "indexExternalVolumes"
    private static let networkVolumesKey = "indexNetworkVolumes"
    private static let excludedPathsKey = "excludedPaths"

    /// The sort the user last chose, or by name on first launch.
    private static var savedSortOrder: FileIndexKit.SortOrder {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: sortKeyKey), let key = SortKey(rawValue: raw) else { return .byName }
        return SortOrder(key: key, ascending: defaults.bool(forKey: sortAscendingKey))
    }

    /// The settings the user last chose; on first launch only the startup disk is indexed.
    private static var savedIndexSettings: IndexSettings {
        let defaults = UserDefaults.standard
        return IndexSettings(
            indexesExternalVolumes: defaults.bool(forKey: externalVolumesKey),
            indexesNetworkVolumes: defaults.bool(forKey: networkVolumesKey),
            excludedPaths: defaults.stringArray(forKey: excludedPathsKey) ?? [])
    }

    init() {
        let relay = SortRelay()
        var failure: String?
        do {
            let url = try StorageLocation.databaseURL(bundleIdentifier: Self.bundleIdentifier)
            let coordinator = IndexCoordinator(options: .init(
                databaseURL: url, hasFullDiskAccess: FullDiskAccess.isGranted, settings: Self.savedIndexSettings))
            self.coordinator = coordinator
            self.databaseURL = url
            index = coordinator.index
        } catch {
            coordinator = nil
            databaseURL = nil
            index = FileIndex()
            failure = "Cannot create the cache folder: \(error.localizedDescription)"
        }
        engine = SearchEngine(index: index) { key in
            Task { @MainActor in relay.model?.sortOrderDidUpdate(key) }
        }
        relay.model = self
        if let failure { status.phase = .failed(failure) }
        observeWorkspace()
    }

    // MARK: Lifecycle

    func windowAppeared() {
        guard !started else { return }
        let hasCache = databaseURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if !hasFullDiskAccess && !hasCache && !UserDefaults.standard.bool(forKey: Self.skippedAccessKey) {
            showsAccessOnboarding = true  // indexing starts once the user answers it
        } else {
            startIndexing()
        }
    }

    func continueWithoutFullDiskAccess() {
        UserDefaults.standard.set(true, forKey: Self.skippedAccessKey)
        showsAccessOnboarding = false
        startIndexing()
    }

    private func startIndexing() {
        guard !started, let coordinator else { return }
        started = true
        Task { await coordinator.start() }
        Task {
            for await status in coordinator.statusUpdates {
                apply(status)
            }
        }
    }

    func rescan() {
        coordinator?.rescanAll()
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    // MARK: Filters

    var hasFilters: Bool { !filters.isEmpty }

    /// Limits the list to the items inside `url`, under the path the index lists it by.
    func filter(toFolder url: URL) {
        guard url.isFileURL else { return }
        filters.folder = VolumeCatalog.canonicalPath(url.path(percentEncoded: false))
    }

    /// Limits the list to a folder entry's contents, or for a file, to its enclosing folder's.
    func filterToFolder(of id: EntryID) {
        guard let entry = index.snapshot(id) else { return }
        let folder = entry.isDirectory ? index.path(of: id) : folderPath(of: entry)
        if let folder, !folder.isEmpty { filters.folder = folder }
    }

    func clearFilters() {
        filters = SearchFilters()
    }

    // MARK: Settings

    /// Adds files and folders to the excluded list, under the paths the index lists them by.
    /// The startup disk as a whole can't be excluded.
    func addExclusions(_ urls: [URL]) {
        var paths = Set(indexSettings.excludedPaths)
        for url in urls where url.isFileURL {
            let path = VolumeCatalog.canonicalPath(url.path(percentEncoded: false))
            if path != "/" { paths.insert(path) }
        }
        indexSettings.excludedPaths = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func removeExclusions(_ paths: Set<String>) {
        indexSettings.excludedPaths.removeAll(where: paths.contains)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let coordinator = coordinator
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                coordinator?.volumesDidChange()
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckFullDiskAccess()
                self?.applicationsByType.removeAll()  // apps may have been installed meanwhile
            }
        })
    }

    private func recheckFullDiskAccess() {
        guard !hasFullDiskAccess, FullDiskAccess.isGranted else { return }
        hasFullDiskAccess = true
        needsRelaunchForAccess = true
    }

    // MARK: Status and search

    private func apply(_ newStatus: IndexStatus) {
        status = newStatus
        switch newStatus.phase {
        case .loading, .scanning, .starting:
            engine.defersSorting = true
        case .idle, .failed:
            engine.defersSorting = false
        }
        if newStatus.indexVersion != searchedVersion { refreshResults() }
    }

    private func sortOrderDidUpdate(_ key: SortKey) {
        if key == sortOrder.key { refreshResults() }
    }

    /// Re-runs the current search because the index changed. Unlike typing, this never cancels
    /// a search in progress and runs at most once a second, so a steady stream of file system
    /// changes can't keep the user's own search from finishing.
    private func refreshResults() {
        if searchInFlight {
            refreshPending = true
            return
        }
        let wait = 1 - Date().timeIntervalSince(lastSearchStart)
        if wait <= 0 {
            runSearch()
        } else if throttledSearch == nil {
            throttledSearch = Task {
                try? await Task.sleep(for: .seconds(wait))
                throttledSearch = nil
                refreshResults()
            }
        }
    }

    /// Starts a search for the current query and order, cancelling any search in progress.
    func runSearch() {
        lastSearchStart = Date()
        searchInFlight = true
        let generation = searchGeneration.next()
        let token = searchGeneration
        let (engine, query, filters, order, version) = (engine, query, filters, sortOrder, index.version)
        Task.detached(priority: .userInitiated) { [weak self] in
            let ids = engine.search(
                query, filters: filters, order: order, isCancelled: { token.current != generation })
            await self?.finishSearch(ids, generation: generation, version: version)
        }
    }

    private func finishSearch(_ ids: [EntryID]?, generation: Int, version: UInt64) {
        // A newer search superseded this one and will report instead.
        guard searchGeneration.current == generation else { return }
        searchInFlight = false
        if let ids {
            results = ids
            resultsVersion += 1
            searchedVersion = version
        }
        if refreshPending {
            refreshPending = false
            refreshResults()
        }
    }

    var isBusy: Bool {
        switch status.phase {
        case .starting: started
        case .loading, .scanning: true
        case .idle, .failed: false
        }
    }

    var statusText: String {
        var text: String
        switch status.phase {
        case .starting:
            text = started ? "Starting…" : "Waiting to start"
        case .loading(let entries):
            text = "Loading file list… \(entries.formatted()) items"
        case .scanning(let volume, let entries):
            text = "Indexing “\(volume)”… \(entries.formatted()) items found"
        case .idle:
            text = query.isEmpty && !hasFilters
                ? "\(status.visibleEntries.formatted()) items"
                : "\(results.count.formatted()) of \(status.visibleEntries.formatted()) items"
        case .failed(let message):
            return message
        }
        if status.unreadableDirectories > 0 {
            text += " · \(status.unreadableDirectories.formatted()) folders unreadable"
        }
        return text
    }

    // MARK: Rows

    func entry(at row: Int) -> EntrySnapshot? {
        guard row >= 0, row < results.count else { return nil }
        return index.snapshot(results[row])
    }

    func url(for id: EntryID) -> URL? {
        index.path(of: id).map { URL(fileURLWithPath: $0) }
    }

    /// The name to show: volume roots are stored under their mount path.
    func displayName(_ entry: EntrySnapshot) -> String {
        guard entry.flags.contains(.volumeRoot) else { return entry.name }
        return entry.name == "/" ? "/" : (entry.name as NSString).lastPathComponent
    }

    /// The containing folder's path, cached by folder ID (a folder's path never changes; renaming
    /// it creates a new entry).
    func folderPath(of entry: EntrySnapshot) -> String {
        if entry.flags.contains(.volumeRoot) {
            return entry.name == "/" ? "" : (entry.name as NSString).deletingLastPathComponent
        }
        if let cached = folderPaths[entry.parent] { return cached }
        let path = index.path(of: entry.parent) ?? ""
        if folderPaths.count > 50_000 { folderPaths.removeAll(keepingCapacity: true) }
        folderPaths[entry.parent] = path
        return path
    }

    func icon(for entry: EntrySnapshot) -> NSImage {
        icons.icon(for: entry) { [index] in index.path(of: entry.id) }
    }

    // MARK: Actions

    func open(_ ids: [EntryID]) {
        guard !ids.isEmpty else { return }
        if ids.count > 10 {
            let alert = NSAlert()
            alert.messageText = "Open \(ids.count) items?"
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let missing = FileActions.open(ids.compactMap(url(for:)))
        guard !missing.isEmpty else { return }
        coordinator?.refresh(paths: missing.map(\.path))
        let alert = NSAlert()
        alert.messageText = missing.count == 1
            ? "“\(missing[0].lastPathComponent)” no longer exists."
            : "\(missing.count) items no longer exist."
        alert.informativeText = "The list will be updated."
        alert.runModal()
    }

    func revealInFinder(_ ids: [EntryID]) {
        FileActions.revealInFinder(ids.compactMap(url(for:)))
    }

    func showInfo(_ ids: [EntryID]) {
        guard !ids.isEmpty else { return }
        if ids.count > 10 {
            let alert = NSAlert()
            alert.messageText = "Show info for \(ids.count.formatted()) items?"
            alert.informativeText = "A separate Info window opens for each item."
            alert.addButton(withTitle: "Show Info")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        FileActions.showInfo(ids.compactMap(url(for:)))
    }
}

/// Lets the search engine's background callback reach the model created after it.
@MainActor
private final class SortRelay {
    weak var model: AppModel?
}

/// The current search generation; older searches see it change and stop.
final class SearchGeneration: Sendable {
    private let value = Atomic<Int>(0)

    func next() -> Int { value.wrappingAdd(1, ordering: .relaxed).newValue }
    var current: Int { value.load(ordering: .relaxed) }
}

/// File icons: one per extension for ordinary files, per entry for apps and other packages.
@MainActor
struct IconCache {
    private var byType: [String: NSImage] = [:]
    private var byEntry: [EntryID: NSImage] = [:]
    private let folder = NSWorkspace.shared.icon(for: .folder)
    private let symlink = NSWorkspace.shared.icon(for: .symbolicLink)
    private let document = NSWorkspace.shared.icon(for: .data)

    mutating func icon(for entry: EntrySnapshot, path: () -> String?) -> NSImage {
        if entry.flags.contains(.symlink) { return symlink }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let isPackage = entry.isDirectory && !ext.isEmpty
            && (UTType(filenameExtension: ext)?.conforms(to: .package) ?? false)
        if entry.flags.contains(.volumeRoot) || isPackage {
            if let cached = byEntry[entry.id] { return cached }
            guard let path = path() else { return folder }
            let icon = NSWorkspace.shared.icon(forFile: path)
            if byEntry.count > 5_000 { byEntry.removeAll(keepingCapacity: true) }
            byEntry[entry.id] = icon
            return icon
        }
        if entry.isDirectory { return folder }
        guard !ext.isEmpty else { return document }
        if let cached = byType[ext] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        byType[ext] = icon
        return icon
    }
}
