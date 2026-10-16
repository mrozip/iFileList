/// User choices about what is indexed besides the startup disk, which is always indexed.
public struct IndexSettings: Sendable, Equatable {
    /// Local drives other than the startup disk: USB, Thunderbolt, disk images.
    public var indexesExternalVolumes: Bool
    /// Network shares. FSEvents doesn't report changes other computers make to them, so they are
    /// only current as of their last scan.
    public var indexesNetworkVolumes: Bool
    /// Files and folders left out of the index, with everything inside them, as returned by
    /// `VolumeCatalog.canonicalPath(_:)`.
    public var excludedPaths: [String]

    public init(indexesExternalVolumes: Bool = false, indexesNetworkVolumes: Bool = false, excludedPaths: [String] = []) {
        self.indexesExternalVolumes = indexesExternalVolumes
        self.indexesNetworkVolumes = indexesNetworkVolumes
        self.excludedPaths = excludedPaths
    }

    func includes(_ volume: VolumeInfo) -> Bool {
        if volume.isBoot { return true }
        guard volume.isNetwork ? indexesNetworkVolumes : indexesExternalVolumes else { return false }
        return !isExcluded(volume.mountPath)
    }

    /// Whether `path` is an excluded item or inside one.
    func isExcluded(_ path: String) -> Bool {
        excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
