import Foundation
import Testing
@testable import FileIndexKit

/// Scans the real startup disk (minus /Users, to avoid privacy prompts) and reports timings.
/// Run with `IFL_BENCHMARK=1 swift test --filter BootVolumeBenchmark`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IFL_BENCHMARK"] != nil))
struct BootVolumeBenchmark {
    @Test func scanSearchAndReload() throws {
        let cache = try TemporaryDirectory()
        let database = try IndexDatabase.open(at: URL(fileURLWithPath: cache.path + "/FileIndex.sqlite"))
        let index = FileIndex()
        let ids = IDAllocator(startingAt: 1)
        let rootID = ids.allocate()
        let volume = try database.insertVolume(key: "boot", mountPath: "/", rootEntry: rootID, eventStreamUUID: nil)
        let root = EntryBatch.make([(rootID, 0, "/", [.directory, .volumeRoot], 0)])
        try database.insert(root, volume: volume.id)
        index.insert(root, volume: 1)

        var configuration = TreeScanner.Configuration()
        configuration.excludedPaths = VolumeCatalog.bootExclusions(cacheDirectory: cache.path).union(["/Users"])
        configuration.devices = VolumeCatalog.bootDevices()
        let scanner = TreeScanner(configuration: configuration, ids: ids) { batch in
            try! database.insert(batch, volume: volume.id)
            index.insert(batch, volume: 1)
        }
        var start = Date()
        let statistics = scanner.scan(rootPath: "/", rootID: rootID)
        let scanTime = Date().timeIntervalSince(start)
        print("BENCH scan: \(statistics.entries) entries, \(statistics.directories) dirs, \(statistics.unreadableDirectories) unreadable in \(String(format: "%.1f", scanTime)) s")

        let topLevel = index.read { reader in
            Set((1..<reader.slotCount).map(EntryID.init).filter { reader.isVisible($0) && reader.parent($0) == rootID }.map(reader.name))
        }
        #expect(topLevel.isSuperset(of: ["Applications", "Library", "System", "private", "usr"]))
        let firmlinked = index.read { reader in
            (1..<reader.slotCount).map(EntryID.init).contains { reader.isVisible($0) && reader.path(of: $0)?.hasPrefix("/Applications/") == true }
        }
        #expect(firmlinked, "Data volume contents should be reached through firmlinks")
        let duplicated = index.read { reader in
            (1..<reader.slotCount).map(EntryID.init).contains { reader.isVisible($0) && reader.path(of: $0)?.hasPrefix("/System/Volumes/Data/") == true }
        }
        #expect(!duplicated)

        let engine = SearchEngine(index: index)
        for query in ["", "a", "plist", "info plist", "library/caches", "system library plist", "zzzzqq"] {
            start = Date()
            let count = engine.search(query, order: .byName)?.count ?? -1
            print("BENCH search '\(query)': \(count) results in \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000)) ms")
        }

        start = Date()
        let reloaded = FileIndex()
        try reloaded.load(from: database, volumeSlots: [volume.id: 1])
        print("BENCH reload from SQLite: \(reloaded.visibleCount) entries in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path + "/FileIndex.sqlite")
        print("BENCH database size: \((attributes[.size] as? Int ?? 0) / 1_000_000) MB")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("BENCH peak RSS: \(usage.ru_maxrss / 1_000_000) MB")
    }
}
