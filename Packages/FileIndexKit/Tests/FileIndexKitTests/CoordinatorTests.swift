import Foundation
import Testing
@testable import FileIndexKit

/// End-to-end tests: a temporary folder stands in for a volume, with real scanning, SQLite and FSEvents.
@Suite(.serialized) struct IndexCoordinatorTests {
    let root: TemporaryDirectory
    let cache: TemporaryDirectory

    init() throws {
        root = try TemporaryDirectory()
        cache = try TemporaryDirectory()
    }

    func makeCoordinator() -> IndexCoordinator {
        var info = stat()
        lstat(root.path, &info)
        let volume = VolumeInfo(key: "test", mountPath: root.path, name: "Test", device: info.st_dev, isBoot: false)
        var options = IndexCoordinator.Options(
            databaseURL: URL(fileURLWithPath: cache.path + "/FileIndex.sqlite"), hasFullDiskAccess: true)
        options.eventLatency = 0.1
        options.ignoresOwnEvents = false
        options.volumeProvider = { [volume] }
        return IndexCoordinator(options: options)
    }

    func paths(_ coordinator: IndexCoordinator) -> Set<String> {
        TreeScannerTests.paths(in: coordinator.index)
    }

    func contains(_ coordinator: IndexCoordinator, _ relative: String) async -> Bool {
        await coordinator.waitForPendingWork()
        return paths(coordinator).contains(root.path + "/" + relative)
    }

    @Test func scansThenTracksChanges() async throws {
        try root.makeDirectory("docs")
        try root.makeFile("docs/PLAN.md", size: 465)
        let coordinator = makeCoordinator()
        await coordinator.start()
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [root.path, root.path + "/docs", root.path + "/docs/PLAN.md"])

        // New file
        try root.makeFile("docs/new.txt", size: 3)
        #expect(await eventually { await contains(coordinator, "docs/new.txt") })

        // Folder with contents moved in: only one event arrives for it, so its contents are scanned.
        let outside = try TemporaryDirectory()
        try FileManager.default.createDirectory(atPath: outside.path + "/bundle/inner", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: outside.path + "/bundle/inner/deep.txt"))
        try FileManager.default.moveItem(atPath: outside.path + "/bundle", toPath: root.path + "/bundle")
        #expect(await eventually { await contains(coordinator, "bundle/inner/deep.txt") })

        // Rename
        try FileManager.default.moveItem(atPath: root.path + "/docs/new.txt", toPath: root.path + "/docs/renamed.txt")
        #expect(await eventually {
            let renamed = await contains(coordinator, "docs/renamed.txt")
            let original = await contains(coordinator, "docs/new.txt")
            return renamed && !original
        })

        // Folder deletion removes the subtree
        try FileManager.default.removeItem(atPath: root.path + "/bundle")
        #expect(await eventually {
            await coordinator.waitForPendingWork()
            return !paths(coordinator).contains { $0.hasPrefix(root.path + "/bundle") }
        })

        // Size change
        try Data(count: 99).write(to: root.url("docs/PLAN.md"))
        #expect(await eventually {
            await coordinator.waitForPendingWork()
            return coordinator.index.read { reader in
                (1..<reader.slotCount).contains { reader.isVisible(EntryID($0)) && reader.name(EntryID($0)) == "PLAN.md" && reader.size(EntryID($0)) == 99 }
            }
        })
        await coordinator.stop()
    }

    @Test func restartLoadsTheCacheAndRescansExternalVolumes() async throws {
        try root.makeFile("first.txt")
        do {
            let coordinator = makeCoordinator()
            await coordinator.start()
            await coordinator.waitForPendingWork()
            await coordinator.stop()
        }
        try root.makeFile("while-closed.txt")

        let coordinator = makeCoordinator()
        await coordinator.start()
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [root.path, root.path + "/first.txt", root.path + "/while-closed.txt"])
        #expect(coordinator.index.visibleCount == 3)
        await coordinator.stop()
    }

    @Test func rescanReplacesTheVolumeInOneStep() async throws {
        try root.makeFile("a.txt")
        let coordinator = makeCoordinator()
        await coordinator.start()
        await coordinator.waitForPendingWork()
        coordinator.rescanAll()
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [root.path, root.path + "/a.txt"])
        #expect(coordinator.index.visibleCount == 2)
        await coordinator.stop()
    }
}
