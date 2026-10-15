import Foundation
import os

public struct IndexStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case starting
        case loading(entries: Int)
        case scanning(volume: String, entries: Int)
        case idle
        case failed(String)
    }

    public var phase: Phase = .starting
    public var visibleEntries = 0
    /// Folders that couldn't be read in this session's scans (usually missing Full Disk Access).
    public var unreadableDirectories = 0
    public var indexVersion: UInt64 = 0

    public init() {}
}

/// Owns the cache and the in-memory index and keeps both current.
///
/// All work runs as jobs processed one at a time: the startup load and scans, FSEvents batches,
/// volume changes, and rescans. Events that arrive during a scan therefore queue up and are
/// applied after it, so nothing is lost and there is only ever one writer.
public actor IndexCoordinator {
    public struct Options: Sendable {
        public var databaseURL: URL
        public var hasFullDiskAccess: Bool
        public var eventLatency: TimeInterval = 1.0
        var ignoresOwnEvents = true
        var volumeProvider: @Sendable () -> [VolumeInfo] = VolumeCatalog.mountedVolumes

        public init(databaseURL: URL, hasFullDiskAccess: Bool) {
            self.databaseURL = databaseURL
            self.hasFullDiskAccess = hasFullDiskAccess
        }
    }

    private enum Job: Sendable {
        case startup
        case events([FSEvent])
        case refreshVolumes
        case rescanAll
        case barrier(CheckedContinuation<Void, Never>)
    }

    private struct IndexedVolume {
        var info: VolumeInfo
        var record: VolumeRecord
        var slot: UInt8
        var configuration: TreeScanner.Configuration
    }

    private static let lastEventKey = "last_event_id"
    private static let fullDiskAccessKey = "full_disk_access"

    public nonisolated let index = FileIndex()
    public nonisolated let statusUpdates: AsyncStream<IndexStatus>
    private nonisolated let statusContinuation: AsyncStream<IndexStatus>.Continuation
    private nonisolated let jobs: AsyncStream<Job>
    private nonisolated let jobContinuation: AsyncStream<Job>.Continuation
    private let logger = Logger(subsystem: "com.mrozip.iFileList", category: "index")

    private let options: Options
    private let cacheDirectory: String
    private let firmlinks: [(source: String, target: String)]
    private let itemReader = DirectoryReader()
    private var database: IndexDatabase?
    private var ids = IDAllocator(startingAt: 1)
    private var volumes: [String: IndexedVolume] = [:]
    private var freeSlots: [UInt8] = Array(UInt8(1)...UInt8(255)).reversed()
    private var watcher: FSEventsWatcher?
    private var status = IndexStatus()
    private var unreadable: [String: Int] = [:]
    private var started = false

    public init(options: Options) {
        self.options = options
        cacheDirectory = VolumeCatalog.normalizedPath(options.databaseURL.deletingLastPathComponent().path)
        firmlinks = VolumeCatalog.firmlinks().sorted { $0.target.count > $1.target.count }
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (jobs, jobContinuation) = AsyncStream.makeStream()
    }

    /// Loads the cache, then scans what needs scanning and starts watching for changes.
    public func start() {
        guard !started else { return }
        started = true
        jobContinuation.yield(.startup)
        Task { await processJobs() }
    }

    /// Rebuilds the index of every mounted volume. The current list stays visible meanwhile.
    public nonisolated func rescanAll() {
        jobContinuation.yield(.rescanAll)
    }

    /// Re-checks mounted volumes, indexing new ones and dropping unmounted ones.
    public nonisolated func volumesDidChange() {
        jobContinuation.yield(.refreshVolumes)
    }

    /// Re-reads specific paths, e.g. after opening one failed because it no longer exists.
    public nonisolated func refresh(paths: [String]) {
        jobContinuation.yield(.events(paths.map { FSEvent(path: $0, flags: [], id: 0) }))
    }

    /// Waits until every job queued so far has finished.
    public nonisolated func waitForPendingWork() async {
        await withCheckedContinuation { jobContinuation.yield(.barrier($0)) }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        jobContinuation.finish()
    }

    private func processJobs() async {
        for await job in jobs {
            switch job {
            case .startup: await startup()
            case .events(let events): await applyEvents(events)
            case .refreshVolumes: await refreshVolumes()
            case .rescanAll: await rescanAllVolumes()
            case .barrier(let continuation): continuation.resume()
            }
        }
    }

    // MARK: Status

    private func publish(_ phase: IndexStatus.Phase) {
        status.phase = phase
        status.visibleEntries = index.visibleCount
        status.indexVersion = index.version
        status.unreadableDirectories = unreadable.values.reduce(0, +)
        statusContinuation.yield(status)
    }

    // MARK: Startup

    private func startup() async {
        publish(.loading(entries: 0))
        let database: IndexDatabase
        do {
            database = try IndexDatabase.open(at: options.databaseURL)
        } catch {
            logger.error("Cannot open cache: \(error)")
            publish(.failed("Cannot open the file list cache: \(error)"))
            return
        }
        self.database = database

        do {
            for record in try database.volumes() where !record.isComplete {
                try database.deleteVolume(record.id)
            }
            try database.compactIDsIfNeeded()
            ids = IDAllocator(startingAt: try database.maxEntryID() + 1)

            let mounted = options.volumeProvider()
            let lastEventID = try database.value(forKey: Self.lastEventKey).flatMap(UInt64.init)
            let scannedWithFullDiskAccess = try database.value(forKey: Self.fullDiskAccessKey) == "1"

            // Keep records of volumes that are still mounted; decide which can catch up from
            // FSEvents history and which must be rescanned.
            var slots: [Int64: UInt8] = [:]
            var toScan: [VolumeInfo] = []
            var replaysHistory = false
            for record in try database.volumes() {
                guard let info = mounted.first(where: { $0.key == record.key && $0.mountPath == record.mountPath }),
                      let slot = freeSlots.popLast()
                else {
                    try database.deleteVolume(record.id)
                    continue
                }
                slots[record.id] = slot
                volumes[info.key] = IndexedVolume(
                    info: info, record: record, slot: slot, configuration: scanConfiguration(for: info))
                let historyIsUsable = info.isBoot
                    && lastEventID.map { $0 <= FSEventsWatcher.currentEventID } == true
                    && record.eventStreamUUID != nil
                    && record.eventStreamUUID == FSEventsWatcher.eventDatabaseUUID(forDevice: info.device)
                    && (scannedWithFullDiskAccess || !options.hasFullDiskAccess)
                if historyIsUsable {
                    replaysHistory = true
                } else {
                    toScan.append(info)
                }
            }
            toScan += mounted.filter { volumes[$0.key] == nil }

            let statusContinuation = statusContinuation
            let base = status
            try index.load(from: database, volumeSlots: slots) { loaded in
                var loading = base
                loading.phase = .loading(entries: loaded)
                statusContinuation.yield(loading)
            }
            publish(.idle)

            // Watch before scanning so changes made during the scans are queued, not missed.
            let since = replaysHistory ? lastEventID! : FSEventsWatcher.currentEventID
            startWatching(since: since, volumes: mounted)
            if !replaysHistory {
                try database.setValue(String(since), forKey: Self.lastEventKey)
            }

            for info in toScan.sorted(by: { $0.isBoot && !$1.isBoot }) {
                await scanVolume(info, replacing: volumes[info.key])
            }
            publish(.idle)
        } catch {
            logger.error("Startup failed: \(error)")
            publish(.failed("Loading the file list failed: \(error)"))
        }
    }

    private func startWatching(since: UInt64, volumes: [VolumeInfo]) {
        let jobContinuation = jobContinuation
        let watcher = FSEventsWatcher(ignoresOwnEvents: options.ignoresOwnEvents) { events in
            jobContinuation.yield(.events(events))
        }
        let paths = volumes.contains(where: \.isBoot) ? ["/"] : volumes.map(\.mountPath)
        if !watcher.start(
            paths: paths, sinceEventID: since, latency: options.eventLatency, excluding: [cacheDirectory])
        {
            logger.error("Could not start FSEvents stream")
        }
        self.watcher = watcher
    }

    // MARK: Scanning

    private func scanConfiguration(for info: VolumeInfo) -> TreeScanner.Configuration {
        var configuration = TreeScanner.Configuration()
        if info.isBoot {
            configuration.excludedPaths = VolumeCatalog.bootExclusions(cacheDirectory: cacheDirectory)
            configuration.devices = VolumeCatalog.bootDevices()
        } else {
            configuration.excludedPaths = VolumeCatalog.externalExclusions(mountPath: info.mountPath)
            configuration.excludedPaths.insert(cacheDirectory)
            configuration.devices = [info.device]
        }
        return configuration
    }

    /// Scans a volume into a new, hidden generation, then swaps it in for `old` in one step,
    /// so the list is never empty or doubled while a rescan runs.
    private func scanVolume(_ info: VolumeInfo, replacing old: IndexedVolume?) async {
        guard let database, let slot = freeSlots.popLast() else { return }
        let hidden = old != nil
        let configuration = scanConfiguration(for: info)
        do {
            let rootID = ids.allocate()
            var record = try database.insertVolume(
                key: info.key, mountPath: info.mountPath, rootEntry: rootID,
                eventStreamUUID: FSEventsWatcher.eventDatabaseUUID(forDevice: info.device))
            var root = EntryBatch()
            let times = Self.times(of: info.mountPath)
            root.append(
                id: rootID, parent: 0, flags: [.directory, .volumeRoot], size: 0,
                mtime: times.modified, crtime: times.created, name: info.mountPath)
            try database.insert(root, volume: record.id)
            index.insert(root, volume: slot, hidden: hidden)

            publish(.scanning(volume: info.name, entries: 0))
            let statistics = try await runScanner(
                configuration, rootPath: info.mountPath, rootID: rootID, volume: record.id, slot: slot,
                hidden: hidden, progressName: info.name)

            try database.beginTransaction()
            do {
                if let old { try database.deleteVolume(old.record.id) }
                try database.markVolumeComplete(record.id)
                if info.isBoot {
                    try database.setValue(options.hasFullDiskAccess ? "1" : "0", forKey: Self.fullDiskAccessKey)
                }
                try database.commit()
            } catch {
                database.rollback()
                throw error
            }
            record.isComplete = true
            if let old {
                index.removeVolume(old.slot)
                freeSlots.append(old.slot)
            }
            if hidden { index.reveal(volume: slot) }
            volumes[info.key] = IndexedVolume(info: info, record: record, slot: slot, configuration: configuration)
            unreadable[info.key] = statistics.unreadableDirectories
            logger.info("Scanned \(info.mountPath): \(statistics.entries) entries, \(statistics.unreadableDirectories) unreadable folders")
        } catch {
            logger.error("Scanning \(info.mountPath) failed: \(error)")
            index.removeVolume(slot)
            freeSlots.append(slot)
        }
        publish(.idle)
    }

    /// Runs a tree scan on its own threads, writing batches to the cache and the index.
    private func runScanner(
        _ configuration: TreeScanner.Configuration, rootPath: String, rootID: EntryID, volume: Int64,
        slot: UInt8, hidden: Bool, progressName: String?
    ) async throws -> ScanStatistics {
        guard let database else { return ScanStatistics() }
        let index = index
        let failure = LockedValue<(any Error)?>(nil)
        let progress = progressName.map { name in
            let base = status
            let statusContinuation = statusContinuation
            return ProgressReporter { count in
                var current = base
                current.phase = .scanning(volume: name, entries: count)
                current.visibleEntries = index.visibleCount
                current.indexVersion = index.version
                statusContinuation.yield(current)
            }
        }
        let scanner = TreeScanner(
            configuration: configuration, ids: ids, isCancelled: { failure.value != nil }
        ) { batch in
            do {
                try database.insert(batch, volume: volume)
            } catch {
                failure.update { $0 = $0 ?? error }
                return
            }
            index.insert(batch, volume: slot, hidden: hidden)
            progress?.add(batch.count)
        }
        let statistics = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: scanner.scan(rootPath: rootPath, rootID: rootID))
            }
        }
        if let error = failure.value { throw error }
        return statistics
    }

    // MARK: Volumes

    private func refreshVolumes() async {
        let mounted = options.volumeProvider()
        for volume in volumes.values where !volume.info.isBoot {
            if !mounted.contains(where: { $0.key == volume.info.key && $0.mountPath == volume.info.mountPath }) {
                removeVolume(volume)
            }
        }
        for info in mounted where volumes[info.key] == nil {
            await scanVolume(info, replacing: nil)
        }
        publish(.idle)
    }

    private func removeVolume(_ volume: IndexedVolume) {
        do {
            try database?.deleteVolume(volume.record.id)
        } catch {
            logger.error("Removing \(volume.info.mountPath) from the cache failed: \(error)")
        }
        index.removeVolume(volume.slot)
        freeSlots.append(volume.slot)
        volumes[volume.info.key] = nil
        unreadable[volume.info.key] = nil
    }

    private func rescanAllVolumes() async {
        let mounted = options.volumeProvider()
        for volume in volumes.values where !mounted.contains(where: { $0.key == volume.info.key }) {
            removeVolume(volume)
        }
        for info in mounted.sorted(by: { $0.isBoot && !$1.isBoot }) {
            await scanVolume(info, replacing: volumes[info.key])
        }
    }

    // MARK: Live updates

    private func applyEvents(_ events: [FSEvent]) async {
        guard let database else { return }
        var latestID: UInt64 = 0
        var paths: [String] = []
        var seen: Set<String> = []
        var subtreeRescans: [String] = []
        var volumesChanged = false
        var historyLost = false

        for event in events {
            latestID = max(latestID, event.id)
            if event.flags.contains(.historyDone) { continue }
            if event.flags.contains(.eventIDsWrapped) {
                historyLost = true
                continue
            }
            if !event.flags.isDisjoint(with: [.mount, .unmount, .rootChanged]) {
                volumesChanged = true
                continue
            }
            guard let path = normalize(event.path) else { continue }
            if !event.flags.isDisjoint(with: FSEvent.Flags.needsRescan) {
                subtreeRescans.append(path)
            } else if seen.insert(path).inserted {
                paths.append(path)
            }
        }

        if volumesChanged { await refreshVolumes() }
        if historyLost {
            let since = FSEventsWatcher.currentEventID
            await rescanAllVolumes()
            try? database.setValue(String(since), forKey: Self.lastEventKey)
            return
        }

        // Whole-volume rescans run outside the transaction; they commit on their own.
        var rescansInside: [String] = []
        for path in subtreeRescans {
            if let located = locate(path), located.components.isEmpty {
                await scanVolume(located.volume.info, replacing: located.volume)
            } else {
                rescansInside.append(path)
            }
        }

        do {
            try database.beginTransaction()
            do {
                for path in rescansInside { try await rescanSubtree(at: path) }
                // Parents first, so a new folder is scanned once and its children's events
                // then find their entries already in place.
                for path in paths.sorted(by: { $0.utf8.count < $1.utf8.count }) { try await apply(path: path) }
                if latestID > 0 { try database.setValue(String(latestID), forKey: Self.lastEventKey) }
                try database.commit()
            } catch {
                database.rollback()
                throw error
            }
        } catch {
            // The index may now disagree with the cache; rebuilding is the safe way back.
            logger.error("Applying file system changes failed: \(error); rescanning")
            jobContinuation.yield(.rescanAll)
        }
        publish(.idle)
    }

    /// Maps FSEvents paths onto indexed paths: Data-volume paths go through their firmlink, and
    /// changes in this app's own cache are ignored.
    private func normalize(_ raw: String) -> String? {
        var path = VolumeCatalog.normalizedPath(raw)
        let dataRoot = "/System/Volumes/Data"
        if path.hasPrefix(dataRoot + "/") {
            let relative = String(path.dropFirst(dataRoot.count + 1))
            guard let link = firmlinks.first(where: { relative == $0.target || relative.hasPrefix($0.target + "/") })
            else { return nil }
            path = link.source + relative.dropFirst(link.target.count)
        }
        if path == cacheDirectory || path.hasPrefix(cacheDirectory + "/") { return nil }
        return path
    }

    /// The indexed volume containing `path` and the path components below its root, or nil if
    /// the path is outside every indexed volume or inside an excluded folder.
    private func locate(_ path: String) -> (volume: IndexedVolume, components: [String])? {
        var best: IndexedVolume?
        for volume in volumes.values {
            let mount = volume.info.mountPath
            let inside = mount == "/" || path == mount || path.hasPrefix(mount + "/")
            if inside && mount.count > (best?.info.mountPath.count ?? -1) { best = volume }
        }
        guard let volume = best else { return nil }
        for excluded in volume.configuration.excludedPaths where path.hasPrefix(excluded + "/") {
            return nil
        }
        let relative = volume.info.mountPath == "/" ? path.dropFirst() : path.dropFirst(volume.info.mountPath.count)
        return (volume, relative.split(separator: "/").map(String.init))
    }

    /// Re-reads one path and makes the index match it: update, insert (scanning a new folder's
    /// contents, since moving a folder in emits only one event), or delete with its subtree.
    private func apply(path: String) async throws {
        guard let database, let located = locate(path), let name = located.components.last else { return }
        let (volume, components) = located

        var parentID = volume.record.rootEntry
        for depth in 0..<(components.count - 1) {
            guard let child = try database.child(of: parentID, named: components[depth]) else {
                // An ancestor isn't indexed yet: index it instead, which scans this path too.
                let ancestor = components[0...depth].reduce(volume.info.mountPath) { TreeScanner.join($0, $1) }
                try await apply(path: ancestor)
                return
            }
            guard child.flags.contains(.directory) else { return }
            parentID = child.id
        }

        guard let item = itemReader.item(atPath: path) else {
            if let existing = try existingEntry(in: parentID, named: name, parentPath: path) {
                try deleteSubtree(existing, includingRoot: true)
            }
            return
        }

        let realName = String(decoding: item.name, as: UTF8.self)
        let size = item.isDirectory ? 0 : item.size
        if let existing = try database.child(of: parentID, named: realName) {
            if existing.flags.contains(.directory) == item.isDirectory {
                try database.updateEntry(
                    existing.id, flags: item.flags, size: size, mtime: item.mtime, crtime: item.crtime)
                index.update(existing.id, flags: item.flags, size: size, mtime: item.mtime, crtime: item.crtime)
                return
            }
            try deleteSubtree(existing.id, includingRoot: true)
        }

        let id = ids.allocate()
        var batch = EntryBatch()
        batch.append(
            id: id, parent: parentID, flags: item.flags, size: size, mtime: item.mtime, crtime: item.crtime,
            name: realName)
        try database.insert(batch, volume: volume.record.id)
        index.insert(batch, volume: volume.slot)

        let configuration = volume.configuration
        if item.isDirectory,
           configuration.devices?.contains(item.device) ?? true,
           !configuration.excludedPaths.contains(path)
        {
            _ = try await runScanner(
                configuration, rootPath: path, rootID: id, volume: volume.record.id, slot: volume.slot,
                hidden: false, progressName: nil)
        }
    }

    /// The entry for a path that no longer exists. Tries an exact name match first, then a
    /// case-insensitive one whose stored path is confirmed gone too.
    private func existingEntry(in parent: EntryID, named name: String, parentPath path: String) throws -> EntryID? {
        guard let database else { return nil }
        if let exact = try database.child(of: parent, named: name) { return exact.id }
        guard let loose = try database.child(of: parent, named: name, ignoringCase: true),
              let storedPath = index.path(of: loose.id),
              itemReader.item(atPath: storedPath) == nil
        else { return nil }
        return loose.id
    }

    private func rescanSubtree(at path: String) async throws {
        guard let database, let located = locate(path) else { return }
        let volume = located.volume
        var id = volume.record.rootEntry
        for component in located.components {
            guard let child = try database.child(of: id, named: component) else {
                try await apply(path: path)
                return
            }
            id = child.id
        }
        try deleteSubtree(id, includingRoot: false)
        _ = try await runScanner(
            volume.configuration, rootPath: path, rootID: id, volume: volume.record.id, slot: volume.slot,
            hidden: false, progressName: nil)
    }

    private func deleteSubtree(_ id: EntryID, includingRoot: Bool) throws {
        guard let database else { return }
        var doomed = try database.descendants(of: id)
        if includingRoot { doomed.append(id) }
        try database.deleteEntries(doomed)
        index.remove(doomed)
    }

    private static func times(of path: String) -> (modified: Int64, created: Int64) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return (0, 0) }
        return (Int64(info.st_mtimespec.tv_sec), Int64(info.st_birthtimespec.tv_sec))
    }
}

/// A value shared across threads behind a lock.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func update(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}

/// Counts scanned entries from many threads and reports at most four times a second.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastReport = Date.distantPast
    private let report: (Int) -> Void

    init(report: @escaping (Int) -> Void) {
        self.report = report
    }

    func add(_ entries: Int) {
        lock.lock()
        count += entries
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.25 else {
            lock.unlock()
            return
        }
        lastReport = now
        let total = count
        report(total)
        lock.unlock()
    }
}
