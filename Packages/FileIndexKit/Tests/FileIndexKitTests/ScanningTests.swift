import Foundation
import Testing
@testable import FileIndexKit

@Suite struct TreeScannerTests {
    /// Scans `root` into a fresh index and returns (index, statistics).
    static func scan(
        _ root: String, configure: (inout TreeScanner.Configuration) -> Void = { _ in }
    ) -> (FileIndex, ScanStatistics) {
        let index = FileIndex()
        let ids = IDAllocator(startingAt: 1)
        let rootID = ids.allocate()
        index.insert(.make([(rootID, 0, root, [.directory, .volumeRoot], 0)]), volume: 1)
        var configuration = TreeScanner.Configuration()
        configuration.batchSize = 3
        configure(&configuration)
        let scanner = TreeScanner(configuration: configuration, ids: ids) { batch in
            index.insert(batch, volume: 1)
        }
        let statistics = scanner.scan(rootPath: root, rootID: rootID)
        return (index, statistics)
    }

    static func paths(in index: FileIndex) -> Set<String> {
        index.read { reader in
            Set((1..<reader.slotCount).compactMap { reader.isVisible(EntryID($0)) ? reader.path(of: EntryID($0)) : nil })
        }
    }

    @Test func findsEveryEntryWithSizes() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeDirectory("a/b/c")
        try tmp.makeFile("a/one.txt", size: 10)
        try tmp.makeFile("a/b/two.bin", size: 2048)
        try tmp.makeFile("a/b/c/.hidden", size: 1)

        let (index, statistics) = Self.scan(tmp.path)
        let root = tmp.path
        #expect(Self.paths(in: index) == [
            root, "\(root)/a", "\(root)/a/one.txt", "\(root)/a/b", "\(root)/a/b/two.bin",
            "\(root)/a/b/c", "\(root)/a/b/c/.hidden",
        ])
        #expect(statistics.entries == 6)
        #expect(statistics.directories == 3)
        let sizes = index.read { reader in
            (1..<reader.slotCount).reduce(into: [String: Int64]()) { result, raw in
                result[reader.name(EntryID(raw))] = reader.size(EntryID(raw))
            }
        }
        #expect(sizes["two.bin"] == 2048)
        #expect(sizes["one.txt"] == 10)

        // Creation dates come from the file system and match what stat reports.
        var info = stat()
        lstat(tmp.path + "/a/one.txt", &info)
        let created = index.read { reader in
            (1..<reader.slotCount).map(EntryID.init).first { reader.name($0) == "one.txt" }.map(reader.crtime)
        }
        #expect(created == Int64(info.st_birthtimespec.tv_sec))
        #expect((created ?? 0) > 0)
    }

    @Test func symlinksAreListedButNotFollowed() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeDirectory("real")
        try tmp.makeFile("real/inside.txt")
        try FileManager.default.createSymbolicLink(atPath: tmp.path + "/link", withDestinationPath: tmp.path + "/real")

        let (index, _) = Self.scan(tmp.path)
        let paths = Self.paths(in: index)
        #expect(paths.contains(tmp.path + "/link"))
        #expect(!paths.contains(tmp.path + "/link/inside.txt"))
        let linkFlags = index.read { reader in
            (1..<reader.slotCount).map(EntryID.init).first { reader.name($0) == "link" }.map(reader.flags)
        }
        #expect(linkFlags == .symlink)
    }

    @Test func excludedFoldersAreListedButNotEntered() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeDirectory("skip/deep")
        try tmp.makeFile("skip/file")
        try tmp.makeFile("keep")

        let (index, _) = Self.scan(tmp.path) { $0.excludedPaths = [tmp.path + "/skip"] }
        #expect(Self.paths(in: index) == [tmp.path, tmp.path + "/skip", tmp.path + "/keep"])
    }

    @Test func omittedItemsAreLeftOutWithTheirContents() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeDirectory("a/skip/deep")
        try tmp.makeFile("a/skip/deep/file")
        try tmp.makeFile("a/secret.txt")
        try tmp.makeFile("a/keep.txt")

        let (index, statistics) = Self.scan(tmp.path) {
            $0.omittedPaths = [tmp.path + "/a/skip", tmp.path + "/a/secret.txt"]
        }
        #expect(Self.paths(in: index) == [tmp.path, tmp.path + "/a", tmp.path + "/a/keep.txt"])
        #expect(statistics.entries == 2)
    }

    @Test func otherDevicesAreNotEntered() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeDirectory("dir")
        try tmp.makeFile("dir/file")

        let (index, _) = Self.scan(tmp.path) { $0.devices = [-1] }
        #expect(Self.paths(in: index) == [tmp.path, tmp.path + "/dir"])
    }

    @Test func unreadableFoldersAreCounted() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeDirectory("locked")
        try tmp.makeFile("locked/secret")
        chmod(tmp.path + "/locked", 0)

        let (index, statistics) = Self.scan(tmp.path)
        #expect(statistics.unreadableDirectories == 1)
        #expect(Self.paths(in: index).contains(tmp.path + "/locked"))
    }

    @Test func singleItemAttributesUseTheOnDiskName() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeFile("MixedCase.TXT", size: 5)
        let reader = DirectoryReader()
        let item = try #require(reader.item(atPath: tmp.path + "/MixedCase.TXT"))
        #expect(String(decoding: item.name, as: UTF8.self) == "MixedCase.TXT")
        #expect(item.size == 5)
        #expect(item.crtime > 0 && item.crtime <= item.mtime)
        #expect(!item.isDirectory)
        #expect(reader.item(atPath: tmp.path + "/missing") == nil)
    }
}

@Suite struct VolumeCatalogTests {
    @Test func onlyBrowsableVolumesAreIndexable() {
        #expect(VolumeCatalog.isIndexable(isBrowsable: true, mountPath: "/Volumes/Claude"))
        // SMB share: whether it is indexed is up to IndexSettings
        #expect(VolumeCatalog.isIndexable(isBrowsable: true, mountPath: "/Volumes/home"))
        // Time Machine destination, Recovery, system volumes
        #expect(!VolumeCatalog.isIndexable(isBrowsable: false, mountPath: "/Volumes/Backups of Mac"))
        #expect(!VolumeCatalog.isIndexable(isBrowsable: true, mountPath: "/Volumes/.timemachine/X/2026-10-15.backup"))
        #expect(!VolumeCatalog.isIndexable(isBrowsable: true, mountPath: "/System/Volumes/Data"))
    }

    @Test func settingsDecideWhichVolumesAreIndexed() {
        let boot = VolumeInfo(key: "boot", mountPath: "/", name: "Mac", device: 1, isBoot: true)
        let disk = VolumeInfo(key: "disk", mountPath: "/Volumes/Disk", name: "Disk", device: 2, isBoot: false)
        let share = VolumeInfo(
            key: "share", mountPath: "/Volumes/share", name: "share", device: 3, isBoot: false, isNetwork: true)
        var settings = IndexSettings()
        #expect(settings.includes(boot) && !settings.includes(disk) && !settings.includes(share))
        settings.indexesExternalVolumes = true
        #expect(settings.includes(disk) && !settings.includes(share))
        settings.indexesNetworkVolumes = true
        settings.excludedPaths = ["/Volumes/Disk"]
        #expect(!settings.includes(disk) && settings.includes(share))
        settings.excludedPaths = ["/Volumes/Dis"]
        #expect(settings.includes(disk))
        settings.excludedPaths = ["/Volumes"]
        #expect(!settings.includes(disk) && !settings.includes(share) && settings.includes(boot))
    }

    @Test func canonicalPathsMatchHowTheIndexListsItems() throws {
        let tmp = try TemporaryDirectory()
        try tmp.makeDirectory("Real")
        try FileManager.default.createSymbolicLink(atPath: tmp.path + "/link", withDestinationPath: tmp.path + "/Real")
        #expect(VolumeCatalog.canonicalPath(tmp.path + "/link/") == tmp.path + "/Real")
        #expect(VolumeCatalog.canonicalPath(tmp.path + "/real") == tmp.path + "/Real")
        #expect(VolumeCatalog.canonicalPath("/System/Volumes/Data/Users") == "/Users")
        #expect(VolumeCatalog.canonicalPath("/no/such/folder/") == "/no/such/folder")
    }

    @Test func mountedVolumesIncludeTheStartupDisk() {
        let volumes = VolumeCatalog.mountedVolumes()
        let boot = volumes.first(where: \.isBoot)
        #expect(boot?.mountPath == "/")
        #expect(boot?.key == VolumeCatalog.bootKey)
        #expect(!volumes.contains { $0.mountPath.hasPrefix("/Volumes/.timemachine") })
    }

    @Test func bootExclusionsCoverSystemVolumesAndTheCache() {
        let exclusions = VolumeCatalog.bootExclusions(cacheDirectory: "/Users/x/Library/Caches/app/")
        #expect(exclusions.isSuperset(of: ["/System/Volumes", "/Volumes", "/dev", "/Users/x/Library/Caches/app"]))
    }
}
