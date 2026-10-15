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

    @Test func containsIgnoresASCIICase() {
        func contains(_ haystack: String, _ needle: String) -> Bool {
            Array(haystack.utf8).withUnsafeBufferPointer { h in
                Array(needle.utf8).withUnsafeBufferPointer { NameFolding.contains(h, $0) }
            }
        }
        #expect(contains("PLAN.md", "plan"))
        #expect(contains("PLAN.md", ".md"))
        #expect(!contains("PLAN.md", "planx"))
        #expect(contains("abc", ""))
        #expect(!contains("ab", "abc"))
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
