import Foundation

public enum SortKey: Sendable, Hashable {
    case name
    case size
    case dateModified
    case dateCreated
}

public struct SortOrder: Sendable, Hashable {
    public var key: SortKey
    public var ascending: Bool

    public init(key: SortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    public static let byName = SortOrder(key: .name, ascending: true)
}

/// Filters the index by name and returns entry IDs in the requested order.
///
/// Matching is a parallel substring scan over the contiguous name buffer. Each sort order is a
/// cached permutation of all visible IDs, rebuilt in the background when the index changes;
/// filtering it keeps results sorted. Entries added since the last rebuild follow the sorted part.
public final class SearchEngine: @unchecked Sendable {
    private struct SortedIDs {
        let ids: [EntryID]
        /// Slot count of the index when built; higher IDs are not in `ids`.
        let slotCount: Int
        let version: UInt64
        let builtAt: Date
    }

    private let index: FileIndex
    private let lock = NSLock()
    private var sorted: [SortKey: SortedIDs] = [:]
    private var building: Set<SortKey> = []
    private var deferred = false
    private let buildQueue = DispatchQueue(label: "com.mrozip.iFileList.sort", qos: .utility)
    private let onSortUpdated: @Sendable (SortKey) -> Void

    /// `onSortUpdated` is called on a background thread when a sort order has been rebuilt.
    public init(index: FileIndex, onSortUpdated: @escaping @Sendable (SortKey) -> Void = { _ in }) {
        self.index = index
        self.onSortUpdated = onSortUpdated
    }

    /// While true, sort orders are not rebuilt; used during scans, when the index changes constantly.
    public var defersSorting: Bool {
        get { lock.withLock { deferred } }
        set { lock.withLock { deferred = newValue } }
    }

    /// Returns visible IDs whose names contain every term of `query`, or nil if cancelled.
    public func search(
        _ query: String, order: SortOrder, isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> [EntryID]? {
        let terms = NameFolding.terms(of: query)
        // Terms are copied into raw buffers so the hot loop does no reference counting.
        let termBuffers = UnsafeMutableBufferPointer<UnsafeBufferPointer<UInt8>>.allocate(capacity: terms.count)
        for (i, term) in terms.enumerated() {
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(term.count, 1))
            _ = buffer.initialize(from: term)
            termBuffers[i] = UnsafeBufferPointer(rebasing: buffer[0..<term.count])
        }
        defer {
            termBuffers.forEach { UnsafeMutableRawPointer(mutating: $0.baseAddress)?.deallocate() }
            termBuffers.deallocate()
        }

        let cached = lock.withLock { sorted[order.key] }
        let result: [EntryID]? = index.read { reader in
            var head: [EntryID] = []
            var tailStart = 1
            let termBuffers = UnsafeBufferPointer(termBuffers)
            if let cached {
                guard let matches = cached.ids.withUnsafeBufferPointer({
                    Self.filter(reader, termBuffers, candidates: $0, range: 0..<$0.count, isCancelled)
                }) else { return nil }
                head = order.ascending ? matches : matches.reversed()
                tailStart = cached.slotCount
            }
            guard let tail = Self.filter(
                reader, termBuffers, candidates: nil, range: tailStart..<max(tailStart, reader.slotCount),
                isCancelled)
            else { return nil }
            head.append(contentsOf: tail)
            return head
        }
        scheduleSortIfNeeded(order.key)
        return result
    }

    /// Filters candidates in parallel chunks, preserving their order. With `candidates` nil the
    /// candidates are the IDs in `range`; otherwise `range` indexes into `candidates`.
    private static func filter(
        _ reader: FileIndex.Reader, _ terms: UnsafeBufferPointer<UnsafeBufferPointer<UInt8>>,
        candidates: UnsafeBufferPointer<EntryID>?, range: Range<Int>,
        _ isCancelled: @escaping @Sendable () -> Bool
    ) -> [EntryID]? {
        let total = range.count
        guard total > 0 else { return isCancelled() ? nil : [] }
        let chunkSize = 32_768
        let chunkCount = (total + chunkSize - 1) / chunkSize
        var partials = [[EntryID]](repeating: [], count: chunkCount)
        nonisolated(unsafe) let terms = terms
        nonisolated(unsafe) let candidates = candidates
        partials.withUnsafeMutableBufferPointer { output in
            nonisolated(unsafe) let output = output
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                guard !isCancelled() else { return }
                let lower = range.lowerBound + chunk * chunkSize
                let upper = min(lower + chunkSize, range.upperBound)
                var local: [EntryID] = []
                if let candidates {
                    for k in lower..<upper {
                        let id = candidates[k]
                        if reader.isVisible(id) && reader.matches(id, terms) { local.append(id) }
                    }
                } else {
                    for k in lower..<upper {
                        let id = EntryID(k)
                        if reader.isVisible(id) && reader.matches(id, terms) { local.append(id) }
                    }
                }
                output[chunk] = local
            }
        }
        guard !isCancelled() else { return nil }
        var result: [EntryID] = []
        result.reserveCapacity(partials.reduce(0) { $0 + $1.count })
        for partial in partials { result.append(contentsOf: partial) }
        return result
    }

    // MARK: Sort orders

    private func scheduleSortIfNeeded(_ key: SortKey) {
        let (slotCount, version) = index.read { ($0.slotCount, $0.version) }
        let shouldBuild: Bool = lock.withLock {
            guard !deferred, !building.contains(key) else { return false }
            if let existing = sorted[key] {
                guard existing.version != version else { return false }
                let unsorted = slotCount - existing.slotCount
                let stale = Date().timeIntervalSince(existing.builtAt) > 120
                guard unsorted > max(1_000, existing.ids.count / 100) || stale else { return false }
            }
            building.insert(key)
            return true
        }
        guard shouldBuild else { return }
        buildQueue.async { [self] in
            let order = buildSortedIDs(key)
            lock.withLock {
                sorted[key] = order
                building.remove(key)
            }
            onSortUpdated(key)
        }
    }

    /// Builds the permutation for `key`. Keys are copied out under the read lock and sorted
    /// without it; for names, only runs with equal 8-byte prefixes need a second locked pass.
    private func buildSortedIDs(_ key: SortKey) -> SortedIDs {
        struct Item { var key: UInt64; var id: EntryID }
        var items: [Item] = []
        let (slotCount, version) = index.read { reader -> (Int, UInt64) in
            items.reserveCapacity(reader.visibleCount)
            for raw in 1..<reader.slotCount {
                let id = EntryID(raw)
                guard reader.isVisible(id) else { continue }
                let sortKey: UInt64 = switch key {
                case .name: NameFolding.sortPrefix(reader.searchKey(id))
                case .size: UInt64(bitPattern: reader.size(id)) ^ (1 << 63)
                case .dateModified: UInt64(bitPattern: reader.mtime(id)) ^ (1 << 63)
                case .dateCreated: UInt64(bitPattern: reader.crtime(id)) ^ (1 << 63)
                }
                items.append(Item(key: sortKey, id: id))
            }
            return (reader.slotCount, reader.version)
        }
        items.sort { $0.key != $1.key ? $0.key < $1.key : $0.id < $1.id }

        if key == .name {
            index.read { reader in
                var start = 0
                while start < items.count {
                    var end = start + 1
                    while end < items.count && items[end].key == items[start].key { end += 1 }
                    if end - start > 1 {
                        items[start..<end].sort { a, b in
                            guard reader.contains(a.id), reader.contains(b.id) else { return a.id < b.id }
                            let order = NameFolding.compare(reader.searchKey(a.id), reader.searchKey(b.id))
                            return order != 0 ? order < 0 : a.id < b.id
                        }
                    }
                    start = end
                }
            }
        }
        return SortedIDs(ids: items.map(\.id), slotCount: slotCount, version: version, builtAt: Date())
    }
}
