import Foundation

/// A mounted volume that can be indexed.
public struct VolumeInfo: Sendable, Hashable {
    /// Stable identity: "boot" for the startup disk, else the volume UUID (or mount path).
    public var key: String
    public var mountPath: String
    public var name: String
    public var device: Int32
    public var isBoot: Bool
    /// A network share (SMB, NFS, …) rather than a drive connected to this Mac.
    public var isNetwork = false
}

/// Decides which volumes and folders are indexed.
public enum VolumeCatalog {
    public static let bootKey = "boot"

    /// Mounted volumes that can be indexed: the startup disk plus browsable volumes, local or
    /// network. `IndexSettings` decides which of them are.
    ///
    /// "Browsable" excludes system-internal mounts (Preboot, VM, Recovery) and Time Machine
    /// destinations and snapshots, which are all mounted `nobrowse`.
    public static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeUUIDStringKey, .volumeNameKey,
            .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let path = normalizedPath(url.path(percentEncoded: false))
            let isBoot = values.volumeIsRootFileSystem ?? (path == "/")
            guard isBoot || isIndexable(isBrowsable: values.volumeIsBrowsable ?? false, mountPath: path)
            else { return nil }
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return VolumeInfo(
                key: isBoot ? bootKey : (values.volumeUUIDString ?? "path:" + path),
                mountPath: path,
                name: values.volumeName ?? path,
                device: info.st_dev,
                isBoot: isBoot,
                isNetwork: !isBoot && !(values.volumeIsLocal ?? false))
        }
    }

    static func isIndexable(isBrowsable: Bool, mountPath: String) -> Bool {
        isBrowsable && !mountPath.hasPrefix("/Volumes/.") && !mountPath.hasPrefix("/System/Volumes/")
    }

    /// Folders on the startup disk whose contents are not scanned: other volumes' mount areas
    /// (`/System/Volumes/Data` would duplicate everything reached through firmlinks), special
    /// directories, and this app's own cache.
    public static func bootExclusions(cacheDirectory: String?) -> Set<String> {
        var paths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/.vol", "/.nofollow", "/.resolve"]
        if let cacheDirectory { paths.insert(normalizedPath(cacheDirectory)) }
        return paths
    }

    /// File system metadata folders at the root of external volumes.
    public static func externalExclusions(mountPath: String) -> Set<String> {
        Set([".fseventsd", ".Spotlight-V100"].map { TreeScanner.join(mountPath, $0) })
    }

    /// Devices the startup disk's walk may enter: the system volume and, through firmlinks,
    /// the Data volume.
    static func bootDevices() -> Set<Int32> {
        Set(["/", "/System/Volumes/Data"].compactMap { path -> Int32? in
            var info = stat()
            return lstat(path, &info) == 0 ? info.st_dev : nil
        })
    }

    /// Firmlinks as (path on the system volume, path relative to the Data volume root), longest
    /// target first so the first match is the most specific.
    public static func firmlinks() -> [(source: String, target: String)] {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        let links = text.split(separator: "\n").compactMap { line -> (source: String, target: String)? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        return links.sorted { $0.target.count > $1.target.count }
    }

    /// Maps a path on the Data volume (`/System/Volumes/Data/...`) to the path the startup disk's
    /// walk reaches it by, through a firmlink. Other paths are returned unchanged; Data-volume
    /// paths outside every firmlink, which the walk never reaches, return nil.
    static func pathThroughFirmlinks(_ path: String, firmlinks: [(source: String, target: String)]) -> String? {
        let dataRoot = "/System/Volumes/Data"
        guard path.hasPrefix(dataRoot + "/") else { return path }
        let relative = path.dropFirst(dataRoot.count + 1)
        guard let link = firmlinks.first(where: { relative == $0.target || relative.hasPrefix($0.target + "/") })
        else { return nil }
        return link.source + relative.dropFirst(link.target.count)
    }

    /// The path under which the index lists the item at `path`: symlinks resolved, Data-volume
    /// paths mapped through their firmlink, and no trailing slash.
    public static func canonicalPath(_ path: String) -> String {
        var resolved = path
        if let real = realpath(path, nil) {
            resolved = String(cString: real)
            free(real)
        }
        resolved = normalizedPath(resolved)
        return pathThroughFirmlinks(resolved, firmlinks: firmlinks()) ?? resolved
    }

    static func normalizedPath(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
