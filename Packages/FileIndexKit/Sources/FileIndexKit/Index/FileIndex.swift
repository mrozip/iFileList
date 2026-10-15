import Foundation

/// A display snapshot of one entry.
public struct EntrySnapshot: Sendable, Equatable {
    public var id: EntryID
    public var parent: EntryID
    public var name: String
    public var flags: EntryFlags
    public var size: Int64
    public var mtime: Int64
    /// Creation (birth) time in seconds since 1970; 0 when the file system doesn't record it.
    public var crtime: Int64

    public var isDirectory: Bool { flags.contains(.directory) }
}

/// The in-memory file list that search and the table read.
///
/// Struct-of-arrays storage indexed directly by `EntryID` (slot 0 is unused), with all names in
/// one contiguous byte buffer. One writer (the coordinator) and many readers share it through a
/// reader-writer lock. Removed entries leave unused slots until the next launch compacts IDs.
public final class FileIndex: @unchecked Sendable {
    /// In-memory state kept in the flags byte next to the persistent `EntryFlags`.
    static let presentBit: UInt8 = 1 << 6
    static let hiddenBit: UInt8 = 1 << 7

    private let lock = ReadWriteLock()
    private var parents = Column<EntryID>(fill: 0)
    private var nameOffsets = Column<UInt32>(fill: 0)
    private var nameLengths = Column<UInt16>(fill: 0)
    private var keyLengths = Column<UInt16>(fill: 0)
    private var flagBits = Column<UInt8>(fill: 0)
    private var volumes = Column<UInt8>(fill: 0)
    private var sizes = Column<Int64>(fill: 0)
    private var mtimes = Column<Int64>(fill: 0)
    private var crtimes = Column<Int64>(fill: 0)
    private var names = Column<UInt8>(fill: 0)
    private var namesUsed = 0
    private var slotCount = 1
    private var visible = 0
    private var mutations: UInt64 = 0

    public init() {}

    deinit {
        parents.deallocate()
        nameOffsets.deallocate()
        nameLengths.deallocate()
        keyLengths.deallocate()
        flagBits.deallocate()
        volumes.deallocate()
        sizes.deallocate()
        mtimes.deallocate()
        crtimes.deallocate()
        names.deallocate()
    }

    // MARK: Reading

    /// A read-only view of the index, valid only inside `read(_:)`.
    public struct Reader: @unchecked Sendable {
        public let slotCount: Int
        public let visibleCount: Int
        public let version: UInt64
        fileprivate let parents: UnsafeMutablePointer<EntryID>
        fileprivate let nameOffsets: UnsafeMutablePointer<UInt32>
        fileprivate let nameLengths: UnsafeMutablePointer<UInt16>
        fileprivate let keyLengths: UnsafeMutablePointer<UInt16>
        fileprivate let flagBits: UnsafeMutablePointer<UInt8>
        fileprivate let volumes: UnsafeMutablePointer<UInt8>
        fileprivate let sizes: UnsafeMutablePointer<Int64>
        fileprivate let mtimes: UnsafeMutablePointer<Int64>
        fileprivate let crtimes: UnsafeMutablePointer<Int64>
        fileprivate let names: UnsafeMutablePointer<UInt8>

        @inline(__always)
        public func contains(_ id: EntryID) -> Bool {
            Int(id) < slotCount && flagBits[Int(id)] & FileIndex.presentBit != 0
        }

        @inline(__always)
        public func isVisible(_ id: EntryID) -> Bool {
            Int(id) < slotCount
                && flagBits[Int(id)] & (FileIndex.presentBit | FileIndex.hiddenBit) == FileIndex.presentBit
        }

        public func flags(_ id: EntryID) -> EntryFlags {
            EntryFlags(rawValue: flagBits[Int(id)]).intersection(.persistent)
        }

        public func parent(_ id: EntryID) -> EntryID { parents[Int(id)] }
        public func size(_ id: EntryID) -> Int64 { sizes[Int(id)] }
        public func mtime(_ id: EntryID) -> Int64 { mtimes[Int(id)] }
        public func crtime(_ id: EntryID) -> Int64 { crtimes[Int(id)] }
        func volume(_ id: EntryID) -> UInt8 { volumes[Int(id)] }

        @inline(__always)
        public func nameBytes(_ id: EntryID) -> UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(start: names + Int(nameOffsets[Int(id)]), count: Int(nameLengths[Int(id)]))
        }

        /// The bytes search compares against: the folded key for non-ASCII names, else the name.
        @inline(__always)
        func searchKey(_ id: EntryID) -> UnsafeBufferPointer<UInt8> {
            let keyLength = Int(keyLengths[Int(id)])
            guard keyLength > 0 else { return nameBytes(id) }
            let start = names + Int(nameOffsets[Int(id)]) + Int(nameLengths[Int(id)])
            return UnsafeBufferPointer(start: start, count: keyLength)
        }

        @inline(__always)
        func matches(_ id: EntryID, _ terms: UnsafeBufferPointer<UnsafeBufferPointer<UInt8>>) -> Bool {
            let key = searchKey(id)
            var i = 0
            while i < terms.count {
                if !NameFolding.contains(key, terms[i]) { return false }
                i += 1
            }
            return true
        }

        public func name(_ id: EntryID) -> String {
            String(decoding: nameBytes(id), as: UTF8.self)
        }

        public func snapshot(_ id: EntryID) -> EntrySnapshot? {
            guard contains(id) else { return nil }
            return EntrySnapshot(
                id: id, parent: parent(id), name: name(id), flags: flags(id), size: size(id), mtime: mtime(id),
                crtime: crtime(id))
        }

        /// The absolute path of an entry, built by walking up to its volume root.
        public func path(of id: EntryID) -> String? {
            guard contains(id) else { return nil }
            var chain: [EntryID] = []
            var current = id
            while current != 0, contains(current), chain.count < 4096 {
                chain.append(current)
                if flags(current).contains(.volumeRoot) { break }
                current = parent(current)
            }
            var bytes: [UInt8] = []
            for entry in chain.reversed() {
                if !bytes.isEmpty && bytes.last != UInt8(ascii: "/") { bytes.append(UInt8(ascii: "/")) }
                bytes.append(contentsOf: nameBytes(entry))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    public func read<T>(_ body: (Reader) throws -> T) rethrows -> T {
        try lock.withReadLock {
            try body(Reader(
                slotCount: slotCount, visibleCount: visible, version: mutations,
                parents: parents.base, nameOffsets: nameOffsets.base, nameLengths: nameLengths.base,
                keyLengths: keyLengths.base, flagBits: flagBits.base, volumes: volumes.base,
                sizes: sizes.base, mtimes: mtimes.base, crtimes: crtimes.base, names: names.base))
        }
    }

    /// Increases whenever the index changes.
    public var version: UInt64 { lock.withReadLock { mutations } }
    public var visibleCount: Int { lock.withReadLock { visible } }

    public func snapshot(_ id: EntryID) -> EntrySnapshot? { read { $0.snapshot(id) } }
    public func path(of id: EntryID) -> String? { read { $0.path(of: id) } }

    // MARK: Writing

    private func ensureSlots(_ count: Int) {
        guard count > parents.capacity else { return }
        parents.grow(to: count, fill: 0)
        nameOffsets.grow(to: count, fill: 0)
        nameLengths.grow(to: count, fill: 0)
        keyLengths.grow(to: count, fill: 0)
        flagBits.grow(to: count, fill: 0)
        volumes.grow(to: count, fill: 0)
        sizes.grow(to: count, fill: 0)
        mtimes.grow(to: count, fill: 0)
        crtimes.grow(to: count, fill: 0)
    }

    @inline(__always)
    private func isVisibleLocked(_ i: Int) -> Bool {
        i < slotCount && flagBits.base[i] & (Self.presentBit | Self.hiddenBit) == Self.presentBit
    }

    private func insertLocked(
        id: EntryID, parent: EntryID, volume: UInt8, flags: EntryFlags, size: Int64, mtime: Int64, crtime: Int64,
        name: UnsafeBufferPointer<UInt8>, hidden: Bool
    ) {
        let i = Int(id)
        ensureSlots(i + 1)
        let wasVisible = isVisibleLocked(i)
        slotCount = max(slotCount, i + 1)

        let nameLength = min(name.count, Int(UInt16.max))
        let key = NameFolding.foldedKey(name)
        let keyLength = min(key?.count ?? 0, Int(UInt16.max))
        names.grow(to: namesUsed + nameLength + keyLength, fill: 0)
        if let source = name.baseAddress {
            (names.base + namesUsed).update(from: source, count: nameLength)
        }
        if let key {
            key.withUnsafeBufferPointer {
                (names.base + namesUsed + nameLength).update(from: $0.baseAddress!, count: keyLength)
            }
        }

        parents.base[i] = parent
        nameOffsets.base[i] = UInt32(namesUsed)
        nameLengths.base[i] = UInt16(nameLength)
        keyLengths.base[i] = UInt16(keyLength)
        flagBits.base[i] = flags.intersection(.persistent).rawValue | Self.presentBit | (hidden ? Self.hiddenBit : 0)
        volumes.base[i] = volume
        sizes.base[i] = size
        mtimes.base[i] = mtime
        crtimes.base[i] = crtime
        namesUsed += nameLength + keyLength

        let isVisible = !hidden
        if isVisible && !wasVisible { visible += 1 }
        if !isVisible && wasVisible { visible -= 1 }
    }

    /// Adds entries. `hidden` entries are excluded from search until `reveal(volume:)`.
    public func insert(_ batch: EntryBatch, volume: UInt8, hidden: Bool = false) {
        guard !batch.isEmpty else { return }
        lock.withWriteLock {
            for i in 0..<batch.count {
                batch.withName(at: i) { name in
                    insertLocked(
                        id: batch.ids[i], parent: batch.parents[i], volume: volume, flags: batch.flags[i],
                        size: batch.sizes[i], mtime: batch.mtimes[i], crtime: batch.crtimes[i], name: name,
                        hidden: hidden)
                }
            }
            mutations &+= 1
        }
    }

    /// Adds every entry of `database`. `volumeSlots` maps volume record IDs to in-memory volume
    /// numbers; entries of other volumes are skipped.
    public func load(
        from database: IndexDatabase, volumeSlots: [Int64: UInt8], progress: ((Int) -> Void)? = nil
    ) throws {
        let maxID = try database.maxEntryID()
        try lock.withWriteLock {
            ensureSlots(Int(maxID) + 1)
            var loaded = 0
            try database.forEachEntry { row in
                guard let volume = volumeSlots[row.volume] else { return }
                insertLocked(
                    id: row.id, parent: row.parent, volume: volume, flags: row.flags, size: row.size,
                    mtime: row.mtime, crtime: row.crtime, name: row.name, hidden: false)
                loaded += 1
                if loaded % 250_000 == 0 { progress?(loaded) }
            }
            mutations &+= 1
        }
    }

    public func remove(_ ids: [EntryID]) {
        guard !ids.isEmpty else { return }
        lock.withWriteLock {
            for id in ids where Int(id) < slotCount {
                let i = Int(id)
                if isVisibleLocked(i) { visible -= 1 }
                flagBits.base[i] &= ~(Self.presentBit | Self.hiddenBit)
            }
            mutations &+= 1
        }
    }

    public func update(_ id: EntryID, flags: EntryFlags, size: Int64, mtime: Int64, crtime: Int64) {
        lock.withWriteLock {
            let i = Int(id)
            guard i < slotCount, flagBits.base[i] & Self.presentBit != 0 else { return }
            let state = flagBits.base[i] & (Self.presentBit | Self.hiddenBit)
            flagBits.base[i] = flags.intersection(.persistent).rawValue | state
            sizes.base[i] = size
            mtimes.base[i] = mtime
            crtimes.base[i] = crtime
            mutations &+= 1
        }
    }

    /// Makes the hidden entries of a volume visible (used when a rescan commits).
    public func reveal(volume: UInt8) {
        lock.withWriteLock {
            for i in 1..<slotCount where volumes.base[i] == volume {
                let bits = flagBits.base[i]
                if bits & Self.presentBit != 0 && bits & Self.hiddenBit != 0 {
                    flagBits.base[i] = bits & ~Self.hiddenBit
                    visible += 1
                }
            }
            mutations &+= 1
        }
    }

    /// Removes every entry of a volume.
    public func removeVolume(_ volume: UInt8) {
        lock.withWriteLock {
            for i in 1..<slotCount where volumes.base[i] == volume && flagBits.base[i] & Self.presentBit != 0 {
                if isVisibleLocked(i) { visible -= 1 }
                flagBits.base[i] &= ~(Self.presentBit | Self.hiddenBit)
            }
            mutations &+= 1
        }
    }
}
