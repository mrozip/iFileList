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

    /// The test folder is mounted as an external volume, so it is indexed only when they are.
    static let indexingExternalVolumes = IndexSettings(indexesExternalVolumes: true)

    func makeCoordinator(
        settings: IndexSettings = indexingExternalVolumes, isNetwork: Bool = false, volumes: [VolumeInfo]? = nil
    ) -> IndexCoordinator {
        let volumes = volumes ?? [Self.volume(at: root, key: "test", isNetwork: isNetwork)]
        var options = IndexCoordinator.Options(
            databaseURL: URL(fileURLWithPath: cache.path + "/FileIndex.sqlite"), hasFullDiskAccess: true,
            settings: settings)
        options.eventLatency = 0.1
        options.ignoresOwnEvents = false
        options.volumeProvider = { volumes }
        return IndexCoordinator(options: options)
    }

    /// A temporary folder mounted as a volume.
    static func volume(
        at directory: TemporaryDirectory, key: String, isBoot: Bool = false, isNetwork: Bool = false
    ) -> VolumeInfo {
        var info = stat()
        lstat(directory.path, &info)
        return VolumeInfo(
            key: key, mountPath: directory.path, name: key, device: info.st_dev, isBoot: isBoot, isNetwork: isNetwork)
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

    @Test func excludedItemsLeaveTheIndexAndComeBack() async throws {
        try root.makeDirectory("docs/sub")
        try root.makeFile("docs/sub/deep.txt")
        try root.makeFile("notes.txt")
        try root.makeFile("keep.txt")
        let coordinator = makeCoordinator()
        await coordinator.start()
        await coordinator.waitForPendingWork()
        #expect(await contains(coordinator, "docs/sub/deep.txt"))

        var settings = Self.indexingExternalVolumes
        settings.excludedPaths = [root.path + "/docs", root.path + "/notes.txt"]
        coordinator.update(settings: settings)
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [root.path, root.path + "/keep.txt"])

        // Changes inside an excluded folder are ignored.
        try root.makeFile("docs/new.txt")
        try root.makeFile("later.txt")
        #expect(await eventually { await contains(coordinator, "later.txt") })
        #expect(!paths(coordinator).contains { $0.hasPrefix(root.path + "/docs") })

        settings.excludedPaths = []
        coordinator.update(settings: settings)
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [
            root.path, root.path + "/keep.txt", root.path + "/later.txt", root.path + "/notes.txt",
            root.path + "/docs", root.path + "/docs/new.txt", root.path + "/docs/sub", root.path + "/docs/sub/deep.txt",
        ])
        await coordinator.stop()
    }

    @Test func exclusionsChangedWhileClosedApplyOnRestart() async throws {
        try root.makeDirectory("docs")
        try root.makeFile("docs/a.txt")
        var settings = Self.indexingExternalVolumes
        settings.excludedPaths = [root.path + "/docs"]
        do {
            let coordinator = makeCoordinator(settings: settings)
            await coordinator.start()
            await coordinator.waitForPendingWork()
            #expect(paths(coordinator) == [root.path])
            await coordinator.stop()
        }

        let coordinator = makeCoordinator()
        await coordinator.start()
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [root.path, root.path + "/docs", root.path + "/docs/a.txt"])
        await coordinator.stop()
    }

    @Test func volumeTogglesAddAndRemoveVolumes() async throws {
        try root.makeFile("a.txt")
        let coordinator = makeCoordinator(settings: IndexSettings())
        await coordinator.start()
        await coordinator.waitForPendingWork()
        #expect(coordinator.index.visibleCount == 0)

        coordinator.update(settings: Self.indexingExternalVolumes)
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [root.path, root.path + "/a.txt"])

        coordinator.update(settings: IndexSettings())
        await coordinator.waitForPendingWork()
        #expect(coordinator.index.visibleCount == 0)
        await coordinator.stop()
    }

    @Test func networkVolumesHaveTheirOwnToggle() async throws {
        try root.makeFile("a.txt")
        let coordinator = makeCoordinator(isNetwork: true)
        await coordinator.start()
        await coordinator.waitForPendingWork()
        #expect(coordinator.index.visibleCount == 0)

        coordinator.update(settings: IndexSettings(indexesNetworkVolumes: true))
        await coordinator.waitForPendingWork()
        #expect(paths(coordinator) == [root.path, root.path + "/a.txt"])
        await coordinator.stop()
    }

    @Test func volumesAreScannedStartupDiskFirstThenExternalThenNetwork() async throws {
        let share = try TemporaryDirectory()
        let disk = try TemporaryDirectory()
        try share.makeFile("on-server.txt")
        try disk.makeFile("on-disk.txt")
        try root.makeFile("on-mac.txt")
        // Listed slowest first, as the system might.
        let coordinator = makeCoordinator(
            settings: IndexSettings(indexesExternalVolumes: true, indexesNetworkVolumes: true),
            volumes: [
                Self.volume(at: share, key: "share", isNetwork: true),
                Self.volume(at: disk, key: "disk"),
                Self.volume(at: root, key: "mac", isBoot: true),
            ])

        // IDs are allocated in order, so the volume scanned first has the lowest root ID.
        func scanOrder() -> [String] {
            coordinator.index.read { reader in
                (1..<reader.slotCount).map(EntryID.init)
                    .filter { reader.isVisible($0) && reader.flags($0).contains(.volumeRoot) }
                    .map(reader.name)
            }
        }
        await coordinator.start()
        await coordinator.waitForPendingWork()
        #expect(scanOrder() == [root.path, disk.path, share.path])

        coordinator.rescanAll()
        await coordinator.waitForPendingWork()
        #expect(scanOrder() == [root.path, disk.path, share.path])
        await coordinator.stop()
    }

    @Test func startupDiskCatchesUpBeforeOtherVolumesAreRescanned() async throws {
        let disk = try TemporaryDirectory()
        try disk.makeFile("on-disk.txt")
        try root.makeFile("on-mac.txt")
        let volumes = [Self.volume(at: disk, key: "disk"), Self.volume(at: root, key: "mac", isBoot: true)]
        func id(_ coordinator: IndexCoordinator, of path: String) -> EntryID? {
            coordinator.index.read { reader in
                (1..<reader.slotCount).map(EntryID.init).first { reader.isVisible($0) && reader.path(of: $0) == path }
            }
        }

        let cachedDiskRoot: EntryID?
        do {
            let coordinator = makeCoordinator(volumes: volumes)
            await coordinator.start()
            await coordinator.waitForPendingWork()
            cachedDiskRoot = id(coordinator, of: disk.path)
            await coordinator.stop()
        }
        // Wait until FSEvents has recorded the change, as it long has by the time the app reopens.
        let recorded = LockedValue(false)
        let probe = FSEventsWatcher(ignoresOwnEvents: false) { events in
            if events.contains(where: { $0.path.hasSuffix("/while-closed.txt") }) { recorded.update { $0 = true } }
        }
        probe.start(paths: [root.path], sinceEventID: FSEventsWatcher.currentEventID, latency: 0.05)
        try root.makeFile("while-closed.txt")
        #expect(await eventually { recorded.value })
        probe.stop()

        // The startup disk replays FSEvents history; the other disk is rescanned, which gives its
        // root a new ID. IDs are allocated in order, so the replayed file's ID shows what came first.
        let coordinator = makeCoordinator(volumes: volumes)
        await coordinator.start()
        #expect(await eventually {
            await coordinator.waitForPendingWork()
            return id(coordinator, of: root.path + "/while-closed.txt") != nil
                && id(coordinator, of: disk.path) != cachedDiskRoot
        })
        let replayed = try #require(id(coordinator, of: root.path + "/while-closed.txt"))
        let rescannedDiskRoot = try #require(id(coordinator, of: disk.path))
        #expect(replayed < rescannedDiskRoot)
        await coordinator.stop()
    }
}
