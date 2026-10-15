import Foundation

public struct ScanStatistics: Sendable, Equatable {
    public var entries = 0
    public var directories = 0
    public var unreadableDirectories = 0

    public init() {}

    mutating func add(_ other: ScanStatistics) {
        entries += other.entries
        directories += other.directories
        unreadableDirectories += other.unreadableDirectories
    }
}

/// Walks a directory tree on a pool of worker threads and reports entries in batches.
///
/// Workers pull directories from a shared stack, so the walk is roughly depth-first and the
/// queue stays small. Batches can arrive out of ID order; consumers must not rely on a parent's
/// batch arriving before its children's.
final class TreeScanner: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Directories whose contents are skipped. The directories themselves are still listed.
        var excludedPaths: Set<String> = []
        /// When set, directories on other devices (mount points) are listed but not entered.
        var devices: Set<Int32>?
        var batchSize = 8_192
        var workerCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
    }

    private let configuration: Configuration
    private let ids: IDAllocator
    private let handler: @Sendable (EntryBatch) -> Void
    private let isCancelled: @Sendable () -> Bool

    private let condition = NSCondition()
    private var pending: [(path: String, id: EntryID)] = []
    private var activeWorkers = 0
    private var totals = ScanStatistics()

    init(
        configuration: Configuration, ids: IDAllocator,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        handler: @escaping @Sendable (EntryBatch) -> Void
    ) {
        self.configuration = configuration
        self.ids = ids
        self.isCancelled = isCancelled
        self.handler = handler
    }

    /// Scans everything below `rootPath`, whose own entry (`rootID`) the caller has recorded.
    /// Blocks until the walk finishes.
    func scan(rootPath: String, rootID: EntryID) -> ScanStatistics {
        pending = [(rootPath, rootID)]
        let group = DispatchGroup()
        for _ in 0..<configuration.workerCount {
            group.enter()
            let thread = Thread { [self] in
                work()
                group.leave()
            }
            thread.qualityOfService = .utility
            thread.stackSize = 1 << 20
            thread.start()
        }
        group.wait()
        return totals
    }

    private func work() {
        let reader = DirectoryReader()
        var batch = EntryBatch()
        var stats = ScanStatistics()
        var children: [(path: String, id: EntryID)] = []
        while let directory = nextDirectory() {
            children.removeAll(keepingCapacity: true)
            if !isCancelled() {
                read(directory, with: reader, into: &batch, stats: &stats, children: &children)
            }
            if batch.count >= configuration.batchSize {
                handler(batch)
                batch.removeAll()
            }
            finish(children)
        }
        if !batch.isEmpty { handler(batch) }
        condition.withLock { totals.add(stats) }
    }

    private func read(
        _ directory: (path: String, id: EntryID), with reader: DirectoryReader,
        into batch: inout EntryBatch, stats: inout ScanStatistics, children: inout [(path: String, id: EntryID)]
    ) {
        let error = reader.forEachItem(inDirectory: directory.path) { item in
            let id = ids.allocate()
            batch.append(
                id: id, parent: directory.id, flags: item.flags, size: item.isDirectory ? 0 : item.size,
                mtime: item.mtime, crtime: item.crtime, name: item.name)
            stats.entries += 1
            guard item.isDirectory else { return }
            stats.directories += 1
            let path = Self.join(directory.path, item.name)
            if shouldEnter(path, device: item.device) { children.append((path, id)) }
        }
        if error != 0 { stats.unreadableDirectories += 1 }
    }

    private func shouldEnter(_ path: String, device: Int32) -> Bool {
        if let devices = configuration.devices, !devices.contains(device) { return false }
        return !configuration.excludedPaths.contains(path)
    }

    private func nextDirectory() -> (path: String, id: EntryID)? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && activeWorkers > 0 { condition.wait() }
        guard let next = pending.popLast() else { return nil }
        activeWorkers += 1
        return next
    }

    private func finish(_ children: [(path: String, id: EntryID)]) {
        condition.lock()
        if !isCancelled() { pending.append(contentsOf: children) }
        activeWorkers -= 1
        condition.broadcast()
        condition.unlock()
    }

    static func join(_ parent: String, _ name: UnsafeBufferPointer<UInt8>) -> String {
        join(parent, String(decoding: name, as: UTF8.self))
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }
}
