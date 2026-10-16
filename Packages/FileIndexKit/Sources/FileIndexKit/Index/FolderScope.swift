/// Limits a search to the entries inside one folder, at any depth, given the folder's path.
///
/// Works like `PathPattern`, but anchored at the start of the path and comparing exact name bytes:
/// `VolumeCatalog.canonicalPath(_:)` returns names as stored on disk, as the index does, and folding
/// could merge sibling folders that differ only in case or accents. One pass over the directories
/// in ID order (parents come first) records how many bytes of the folder's path plus a trailing "/"
/// each directory's path matches. An entry is inside the folder when its parent matched all of them,
/// so the folder itself is not. Volume roots have no parent folder, so those inside the folder (say,
/// every external disk when it is /Volumes) are listed separately.
///
/// Holds raw buffers so the search loop does no reference counting; call `deallocate()` when done.
struct FolderScope {
    /// The state of a directory whose path has left the folder's path.
    private static let dead = UInt16.max

    private let prefix: UnsafeMutablePointer<UInt8>
    private let directoryStates: UnsafeMutablePointer<UInt16>
    private let accept: UInt16
    private var rootsInside: [EntryID] = []

    /// Builds the scope for the folder at `path` (canonical, no trailing slash except for "/") and
    /// runs it over the directories of `reader`. Returns nil if cancelled.
    init?(path: String, reader: FileIndex.Reader, isCancelled: () -> Bool) {
        let slash = UInt8(ascii: "/")
        var bytes = Array(path.utf8)
        if bytes.last != slash { bytes.append(slash) }
        precondition(bytes.count < Int(Self.dead))
        accept = UInt16(bytes.count)
        prefix = .allocate(capacity: bytes.count)
        prefix.initialize(from: bytes, count: bytes.count)

        // Slot 0 stays the start state: it is the parent of volume roots.
        directoryStates = .allocate(capacity: reader.slotCount)
        directoryStates.initialize(repeating: 0, count: reader.slotCount)
        for raw in 1..<reader.slotCount {
            if raw & 0xFFFF == 0 && isCancelled() {
                deallocate()
                return nil
            }
            let id = EntryID(raw)
            guard reader.contains(id), reader.flags(id).contains(.directory) else { continue }
            let name = reader.nameBytes(id)
            var state = run(from: directoryStates[Int(reader.parent(id))], over: name)
            if reader.parent(id) == 0 && state == accept && name.count > Int(accept) { rootsInside.append(id) }
            // Only the "/" root's name already ends with the separator.
            if name.last != slash && state < accept { state = prefix[Int(state)] == slash ? state + 1 : Self.dead }
            directoryStates[raw] = state
        }
    }

    func deallocate() {
        prefix.deallocate()
        directoryStates.deallocate()
    }

    /// Whether `id` is inside the folder.
    @inline(__always)
    func contains(_ reader: FileIndex.Reader, _ id: EntryID) -> Bool {
        let parent = reader.parent(id)
        return directoryStates[Int(parent)] == accept || (parent == 0 && rootsInside.contains(id))
    }

    /// Advances over `bytes`; both `accept` and `dead` absorb, and `dead` is above `accept`.
    @inline(__always)
    private func run(from start: UInt16, over bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        var state = start
        var i = 0
        while i < bytes.count && state < accept {
            state = prefix[Int(state)] == bytes[i] ? state + 1 : Self.dead
            i += 1
        }
        return state
    }
}
