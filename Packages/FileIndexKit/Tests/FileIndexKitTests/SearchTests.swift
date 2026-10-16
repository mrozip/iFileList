import Foundation
import Testing
@testable import FileIndexKit

@Suite struct NameFoldingTests {
    @Test func queryTermsAreLowercasedAndFolded() {
        #expect(NameFolding.terms(of: "  Foo  BAR ") == [Array("foo".utf8), Array("bar".utf8)])
        #expect(NameFolding.terms(of: "Résumé") == [Array("resume".utf8)])
        #expect(NameFolding.terms(of: "").isEmpty)
    }

    @Test func asciiNamesHaveNoFoldedKey() {
        let ascii = Array("Read Me.TXT".utf8)
        ascii.withUnsafeBufferPointer { #expect(NameFolding.foldedKey($0) == nil) }
        let accented = Array("Café Crème.pdf".utf8)
        accented.withUnsafeBufferPointer { #expect(NameFolding.foldedKey($0) == Array("cafe creme.pdf".utf8)) }
    }
}

@Suite struct FileIndexTests {
    /// / (1) → Users (2) → me (3) → PLAN.md (4), Résumé.pdf (5), big.bin (6)
    static func makeIndex() -> FileIndex {
        let index = FileIndex()
        index.insert(.make([
            (1, 0, "/", [.directory, .volumeRoot], 0),
            (2, 1, "Users", .directory, 0),
            (3, 2, "me", .directory, 0),
            (4, 3, "PLAN.md", [], 465),
            (5, 3, "Résumé.pdf", [], 20_000),
            (6, 3, "big.bin", [], 9_000_000),
        ]), volume: 1)
        return index
    }

    @Test func pathsAreBuiltFromTheVolumeRoot() {
        let index = Self.makeIndex()
        #expect(index.path(of: 4) == "/Users/me/PLAN.md")
        #expect(index.path(of: 1) == "/")
        #expect(index.path(of: 99) == nil)
    }

    @Test func externalVolumeRootsKeepTheirMountPath() {
        let index = FileIndex()
        index.insert(.make([
            (1, 0, "/Volumes/Disk", [.directory, .volumeRoot], 0),
            (2, 1, "photo.jpg", [], 10),
        ]), volume: 2)
        #expect(index.path(of: 2) == "/Volumes/Disk/photo.jpg")
    }

    @Test func outOfOrderInsertsAndRemovals() {
        let index = FileIndex()
        index.insert(.make([(5, 1, "late", [], 0)]), volume: 1)
        index.insert(.make([(1, 0, "/", [.directory, .volumeRoot], 0)]), volume: 1)
        #expect(index.visibleCount == 2)
        #expect(index.path(of: 5) == "/late")
        index.remove([5])
        #expect(index.visibleCount == 1)
        #expect(index.snapshot(5) == nil)
    }

    @Test func hiddenEntriesAppearOnlyAfterReveal() {
        let index = Self.makeIndex()
        index.insert(.make([(10, 0, "/Volumes/New", [.directory, .volumeRoot], 0)]), volume: 2, hidden: true)
        #expect(index.visibleCount == 6)
        index.reveal(volume: 2)
        #expect(index.visibleCount == 7)
        index.removeVolume(1)
        #expect(index.visibleCount == 1)
    }

    @Test func updateKeepsVisibility() {
        let index = Self.makeIndex()
        index.update(4, flags: [], size: 1, mtime: 2, crtime: 3)
        #expect(index.snapshot(4)?.size == 1)
        #expect(index.snapshot(4)?.crtime == 3)
        #expect(index.visibleCount == 6)
    }
}

@Suite struct SearchEngineTests {
    @Test func matchesAllTermsIgnoringCaseAndDiacritics() {
        let engine = SearchEngine(index: FileIndexTests.makeIndex())
        #expect(engine.search("plan", order: .byName)?.sorted() == [4])
        #expect(engine.search("RESUME", order: .byName) == [5])
        #expect(engine.search("me pdf", order: .byName) == [5])
        #expect(engine.search("nothing-here", order: .byName) == [])
        #expect(engine.search("", order: .byName)?.count == 6)
    }

    @Test func cancelledSearchReturnsNil() {
        let engine = SearchEngine(index: FileIndexTests.makeIndex())
        #expect(engine.search("", order: .byName, isCancelled: { true }) == nil)
        #expect(engine.search("users", order: .byName, isCancelled: { true }) == nil)
    }

    @Test func termsMatchNamesAndFoldersAnywhereInThePath() {
        let engine = SearchEngine(index: FileIndexTests.makeIndex())
        func search(_ query: String) -> [EntryID]? { engine.search(query, order: .byName)?.sorted() }
        // A folder's name matches the folder and everything inside it.
        #expect(search("users") == [2, 3, 4, 5, 6])
        #expect(search("users me") == [3, 4, 5, 6])
        #expect(search("users/ pdf") == [5])
        #expect(search("me/pl") == [4])
        #expect(search("/USERS/") == [3, 4, 5, 6])
        #expect(search("resume") == [5])
        #expect(search("/") == [1, 2, 3, 4, 5, 6])
        #expect(search("//") == [])
        #expect(search("plan.md/") == [])
        #expect(search("") == [1, 2, 3, 4, 5, 6])
    }

    @Test func pathsStartAtTheVolumeMountPathAndUseFoldedNames() {
        let index = FileIndex()
        index.insert(.make([
            (1, 0, "/Volumes/Disk", [.directory, .volumeRoot], 0),
            (2, 1, "Café", .directory, 0),
            (3, 2, "Menu.txt", [], 10),
        ]), volume: 2)
        let engine = SearchEngine(index: index)
        #expect(engine.search("disk/cafe/menu", order: .byName)?.sorted() == [3])
        #expect(engine.search("volumes/disk", order: .byName)?.sorted() == [1, 2, 3])
        #expect(engine.search("café/", order: .byName) == [3])
    }

    /// Compares search with a substring search over paths built by `FileIndex.path(of:)`, on a
    /// random tree whose names and terms share a tiny alphabet so partial matches abound.
    @Test func searchAgreesWithSearchingBuiltPaths() {
        var random = SplitMix64(seed: 42)
        var batch = EntryBatch()
        batch.append(id: 1, parent: 0, flags: [.directory, .volumeRoot], size: 0, mtime: 0, crtime: 0, name: "/")
        var directories: [EntryID] = [1]
        for id in EntryID(2)...400 {
            let name = String((0..<Int.random(in: 1...4, using: &random)).map { _ in "aAb".randomElement(using: &random)! })
            let isDirectory = Bool.random(using: &random)
            batch.append(
                id: id, parent: directories.randomElement(using: &random)!, flags: isDirectory ? .directory : [],
                size: 0, mtime: 0, crtime: 0, name: name)
            if isDirectory { directories.append(id) }
        }
        let index = FileIndex()
        index.insert(batch, volume: 1)
        let engine = SearchEngine(index: index)
        let paths = index.read { reader in (1...400).map { reader.path(of: EntryID($0))!.lowercased() } }

        for _ in 0..<300 {
            let term = String((0..<Int.random(in: 1...6, using: &random)).map { _ in "ab/".randomElement(using: &random)! })
            let expected = (1...400).filter { paths[$0 - 1].contains(term) }.map(EntryID.init)
            #expect(engine.search(term, order: .byName)?.sorted() == expected, "term \(term)")
        }
    }

    @Test func resultsFollowTheSortOrderOnceBuilt() async {
        let index = FileIndexTests.makeIndex()
        let built = AsyncStream<SortKey>.makeStream()
        let engine = SearchEngine(index: index) { built.continuation.yield($0) }
        var iterator = built.stream.makeAsyncIterator()

        // The first search triggers a background build and returns ID order meanwhile.
        _ = engine.search("", order: SortOrder(key: .size, ascending: false))
        #expect(await iterator.next() == .size)
        let bySize = engine.search("", order: SortOrder(key: .size, ascending: false))
        #expect(bySize?.prefix(3) == [6, 5, 4])

        _ = engine.search("", order: .byName)
        #expect(await iterator.next() == .name)
        let names = index.read { reader in engine.search("", order: .byName)!.map { reader.name($0) } }
        #expect(names == ["/", "big.bin", "me", "PLAN.md", "Résumé.pdf", "Users"])
    }

    @Test func sortsByCreationDate() async {
        let index = FileIndex()
        var batch = EntryBatch()
        batch.append(id: 1, parent: 0, flags: [.directory, .volumeRoot], size: 0, mtime: 0, crtime: 500, name: "/")
        batch.append(id: 2, parent: 1, flags: [], size: 0, mtime: 0, crtime: 300, name: "older")
        batch.append(id: 3, parent: 1, flags: [], size: 0, mtime: 0, crtime: 900, name: "newer")
        index.insert(batch, volume: 1)
        let built = AsyncStream<SortKey>.makeStream()
        let engine = SearchEngine(index: index) { built.continuation.yield($0) }
        var iterator = built.stream.makeAsyncIterator()

        let order = SortOrder(key: .dateCreated, ascending: false)
        _ = engine.search("", order: order)
        #expect(await iterator.next() == .dateCreated)
        #expect(engine.search("", order: order) == [3, 1, 2])
    }

    @Test func entriesAddedAfterSortingFollowTheSortedPart() async {
        let index = FileIndexTests.makeIndex()
        let built = AsyncStream<SortKey>.makeStream()
        let engine = SearchEngine(index: index) { built.continuation.yield($0) }
        var iterator = built.stream.makeAsyncIterator()
        _ = engine.search("", order: .byName)
        _ = await iterator.next()

        index.insert(.make([(7, 3, "aaa.txt", [], 1)]), volume: 1)
        let results = engine.search("", order: .byName)
        #expect(results?.last == 7)
        #expect(results?.count == 7)
    }
}
