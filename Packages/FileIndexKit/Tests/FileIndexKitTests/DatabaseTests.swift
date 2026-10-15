import Foundation
import SQLite3
import Testing
@testable import FileIndexKit

@Suite struct IndexDatabaseTests {
    let directory: TemporaryDirectory
    let url: URL

    init() throws {
        directory = try TemporaryDirectory()
        url = directory.url("cache/FileIndex.sqlite")
    }

    @Test func entriesRoundTripIntoTheIndex() throws {
        let database = try IndexDatabase.open(at: url)
        let volume = try database.insertVolume(key: "boot", mountPath: "/", rootEntry: 1, eventStreamUUID: "U")
        try database.insert(.make([
            (1, 0, "/", [.directory, .volumeRoot], 0),
            (2, 1, "Users", .directory, 0),
            (3, 2, "Ünïcode.txt", [], 42),
        ]), volume: volume.id)
        try database.markVolumeComplete(volume.id)

        let reopened = try IndexDatabase.open(at: url)
        #expect(try reopened.volumes() == [VolumeRecord(
            id: volume.id, key: "boot", mountPath: "/", rootEntry: 1, eventStreamUUID: "U", isComplete: true)])
        let index = FileIndex()
        try index.load(from: reopened, volumeSlots: [volume.id: 1])
        #expect(index.visibleCount == 3)
        #expect(index.path(of: 3) == "/Users/Ünïcode.txt")
        #expect(index.snapshot(3)?.size == 42)
        #expect(index.snapshot(3)?.mtime == 1_700_000_000)
        #expect(index.snapshot(3)?.crtime == 1_600_000_000)
    }

    @Test func childLookupAndSubtreeDeletion() throws {
        let database = try IndexDatabase.open(at: url)
        try database.insert(.make([
            (1, 0, "/", [.directory, .volumeRoot], 0),
            (2, 1, "Dir", .directory, 0),
            (3, 2, "Sub", .directory, 0),
            (4, 3, "file", [], 0),
            (5, 1, "other", [], 0),
        ]), volume: 1)
        #expect(try database.child(of: 1, named: "Dir")?.id == 2)
        #expect(try database.child(of: 1, named: "dir") == nil)
        #expect(try database.child(of: 1, named: "dir", ignoringCase: true)?.id == 2)
        #expect(try database.descendants(of: 2).sorted() == [3, 4])
        try database.deleteEntries([2, 3, 4])
        #expect(try database.entryCount() == 2)
    }

    @Test func deletingAVolumeRemovesItsEntries() throws {
        let database = try IndexDatabase.open(at: url)
        let a = try database.insertVolume(key: "a", mountPath: "/a", rootEntry: 1, eventStreamUUID: nil)
        let b = try database.insertVolume(key: "b", mountPath: "/b", rootEntry: 2, eventStreamUUID: nil)
        try database.insert(.make([(1, 0, "/a", [.directory, .volumeRoot], 0)]), volume: a.id)
        try database.insert(.make([(2, 0, "/b", [.directory, .volumeRoot], 0)]), volume: b.id)
        try database.deleteVolume(a.id)
        #expect(try database.volumes().map(\.key) == ["b"])
        #expect(try database.entryCount() == 1)
    }

    @Test func metadataIsStored() throws {
        let database = try IndexDatabase.open(at: url)
        #expect(try database.value(forKey: "last_event_id") == nil)
        try database.setValue("123", forKey: "last_event_id")
        try database.setValue("456", forKey: "last_event_id")
        #expect(try IndexDatabase.open(at: url).value(forKey: "last_event_id") == "456")
    }

    @Test func otherSchemaVersionsAreDiscarded() throws {
        do {
            let database = try IndexDatabase.open(at: url)
            try database.setValue("x", forKey: "k")
        }
        var handle: OpaquePointer?
        sqlite3_open(url.path, &handle)
        sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil)
        sqlite3_close(handle)

        #expect(try IndexDatabase.open(at: url).value(forKey: "k") == nil)
    }

    @Test func corruptFilesAreReplaced() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4096).write(to: url)
        let database = try IndexDatabase.open(at: url)
        #expect(try database.entryCount() == 0)
    }

    @Test func compactionRenumbersDenselyAndKeepsParents() throws {
        let database = try IndexDatabase.open(at: url)
        let volume = try database.insertVolume(key: "v", mountPath: "/", rootEntry: 1, eventStreamUUID: nil)
        try database.insert(.make([
            (1, 0, "/", [.directory, .volumeRoot], 0),
            (150_000, 1, "Dir", .directory, 0),
            (200_000, 150_000, "file", [], 0),
        ]), volume: volume.id)
        #expect(try database.compactIDsIfNeeded())
        #expect(try database.maxEntryID() == 3)
        let index = FileIndex()
        try index.load(from: database, volumeSlots: [volume.id: 1])
        #expect(index.path(of: 3) == "/Dir/file")
    }
}
