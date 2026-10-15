import Synchronization

/// Identifies a file system entry. Doubles as the SQLite row id and the in-memory slot.
///
/// IDs are allocated monotonically, so a directory always has a smaller ID than its children.
public typealias EntryID = UInt32

public struct EntryFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let directory = EntryFlags(rawValue: 1 << 0)
    public static let symlink = EntryFlags(rawValue: 1 << 1)
    /// The root of an indexed volume. Its stored name is the volume's mount path.
    public static let volumeRoot = EntryFlags(rawValue: 1 << 2)

    /// Flags written to the database. The remaining bits are in-memory state of `FileIndex`.
    static let persistent: EntryFlags = [.directory, .symlink, .volumeRoot]
}

/// Entries produced by a scan, stored column-wise with names packed into one byte buffer.
public struct EntryBatch: Sendable {
    public private(set) var ids: [EntryID] = []
    public private(set) var parents: [EntryID] = []
    public private(set) var flags: [EntryFlags] = []
    public private(set) var sizes: [Int64] = []
    public private(set) var mtimes: [Int64] = []
    /// Creation (birth) times, in seconds since 1970 like `mtimes`.
    public private(set) var crtimes: [Int64] = []
    private var nameBytes: [UInt8] = []
    private var nameEnds: [Int] = []

    public init() {}

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public mutating func append(
        id: EntryID, parent: EntryID, flags: EntryFlags, size: Int64, mtime: Int64, crtime: Int64,
        name: UnsafeBufferPointer<UInt8>
    ) {
        ids.append(id)
        parents.append(parent)
        self.flags.append(flags)
        sizes.append(size)
        mtimes.append(mtime)
        crtimes.append(crtime)
        nameBytes.append(contentsOf: name)
        nameEnds.append(nameBytes.count)
    }

    public mutating func append(
        id: EntryID, parent: EntryID, flags: EntryFlags, size: Int64, mtime: Int64, crtime: Int64, name: String
    ) {
        var name = name
        name.withUTF8 {
            append(id: id, parent: parent, flags: flags, size: size, mtime: mtime, crtime: crtime, name: $0)
        }
    }

    public func withName<T>(at index: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        let start = index == 0 ? 0 : nameEnds[index - 1]
        return try nameBytes.withUnsafeBufferPointer {
            try body(UnsafeBufferPointer(rebasing: $0[start..<nameEnds[index]]))
        }
    }

    public func name(at index: Int) -> String {
        withName(at: index) { String(decoding: $0, as: UTF8.self) }
    }

    public mutating func removeAll() {
        ids.removeAll(keepingCapacity: true)
        parents.removeAll(keepingCapacity: true)
        flags.removeAll(keepingCapacity: true)
        sizes.removeAll(keepingCapacity: true)
        mtimes.removeAll(keepingCapacity: true)
        crtimes.removeAll(keepingCapacity: true)
        nameBytes.removeAll(keepingCapacity: true)
        nameEnds.removeAll(keepingCapacity: true)
    }
}

/// Hands out entry IDs from any thread.
public final class IDAllocator: Sendable {
    private let nextID: Atomic<EntryID>

    public init(startingAt first: EntryID) {
        nextID = Atomic(max(first, 1))
    }

    public func allocate() -> EntryID {
        nextID.wrappingAdd(1, ordering: .relaxed).oldValue
    }

    public var next: EntryID { nextID.load(ordering: .relaxed) }
}
