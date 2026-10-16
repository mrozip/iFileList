/// A search term matched against entries' full paths, without building the paths.
///
/// The term becomes a substring automaton: KMP as a full transition table, with ASCII case folded
/// in and the accepting state absorbing. One pass over the directories in ID order (parents come
/// first) records the state after each directory's path plus a trailing "/". An entry then matches
/// if running on from its parent's state over its own name reaches the end of the term.
///
/// Holds raw buffers so the search loop does no reference counting; call `deallocate()` when done.
struct PathPattern {
    /// Longer terms can't occur in a path, which is at most `PATH_MAX` (1024) bytes.
    static let maxTermLength = 4096

    private let transitions: UnsafeMutablePointer<UInt16>
    private let directoryStates: UnsafeMutablePointer<UInt16>
    private let accept: UInt16

    /// Builds the automaton for `term` (folded and lowercased, as `NameFolding.terms(of:)` returns
    /// it) and runs it over the directories of `reader`. Returns nil if cancelled.
    init?(_ term: [UInt8], reader: FileIndex.Reader, isCancelled: () -> Bool) {
        precondition(!term.isEmpty && term.count <= Self.maxTermLength)
        let length = term.count
        accept = UInt16(length)
        transitions = .allocate(capacity: (length + 1) << 8)
        let t = transitions

        // Row j is the state after matching j bytes; `restart` is the state the automaton would
        // be in had it started one byte later.
        t.initialize(repeating: 0, count: 256)
        t[Int(term[0])] = 1
        var restart = 0
        for j in 1..<length {
            (t + j << 8).initialize(from: t + restart << 8, count: 256)
            t[j << 8 | Int(term[j])] = UInt16(j + 1)
            restart = Int(t[restart << 8 | Int(term[j])])
        }
        (t + length << 8).initialize(repeating: accept, count: 256)
        // Uppercase ASCII behaves like its lowercase letter.
        for row in 0..<length {
            for upper in 65...90 { t[row << 8 | upper] = t[row << 8 | (upper | 0x20)] }
        }

        // Slot 0 stays the start state: it is the parent of volume roots.
        directoryStates = .allocate(capacity: reader.slotCount)
        directoryStates.initialize(repeating: 0, count: reader.slotCount)
        let slash = UInt8(ascii: "/")
        for raw in 1..<reader.slotCount {
            if raw & 0xFFFF == 0 && isCancelled() {
                deallocate()
                return nil
            }
            let id = EntryID(raw)
            guard reader.contains(id), reader.flags(id).contains(.directory) else { continue }
            let key = reader.searchKey(id)
            var state = run(from: directoryStates[Int(reader.parent(id))], over: key)
            // Only the "/" root's name already ends with the separator.
            if key.last != slash { state = transitions[Int(state) << 8 | Int(slash)] }
            directoryStates[raw] = state
        }
    }

    func deallocate() {
        transitions.deallocate()
        directoryStates.deallocate()
    }

    /// Whether the full path of `id` contains the term.
    @inline(__always)
    func matches(_ reader: FileIndex.Reader, _ id: EntryID) -> Bool {
        run(from: directoryStates[Int(reader.parent(id))], over: reader.searchKey(id)) == accept
    }

    @inline(__always)
    private func run(from start: UInt16, over bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        var state = start
        var i = 0
        while i < bytes.count && state != accept {
            state = transitions[Int(state) << 8 | Int(bytes[i])]
            i += 1
        }
        return state
    }
}
