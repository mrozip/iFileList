import Foundation

/// Where the file list cache lives: `~/Library/Caches/<bundle identifier>/`.
///
/// Caches is Apple's location for data an app can regenerate. It is hidden inside `~/Library`
/// and excluded from Time Machine, which matters for an index that can reach hundreds of MB.
public enum StorageLocation {
    public static let databaseFileName = "FileIndex.sqlite"

    public static func cacheDirectory(bundleIdentifier: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches.appending(path: bundleIdentifier, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func databaseURL(bundleIdentifier: String) throws -> URL {
        try cacheDirectory(bundleIdentifier: bundleIdentifier)
            .appending(path: databaseFileName, directoryHint: .notDirectory)
    }
}
