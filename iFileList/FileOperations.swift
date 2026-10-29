import AppKit
import FileIndexKit

/// File system changes behind the File and Edit menus. Everything here is synchronous and safe
/// to run off the main actor; `AppModel` decides where each one runs. The long ones stop between
/// items when their task is cancelled.
enum FileOperations {
    /// One item to copy. `replacing` means an existing item at `destination` goes to the
    /// Trash first.
    struct Transfer: Sendable {
        var source: URL
        var destination: URL
        var replacing = false
    }

    struct Outcome: Sendable {
        /// The transfers that finished, in order.
        var done: [Transfer] = []
        var error: (any Error)?
    }

    // MARK: Names

    /// `url` if nothing exists there, else the first free "name 2.ext", "name 3.ext", …
    static func available(_ url: URL) -> URL {
        guard exists(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let (base, ext) = split(url.lastPathComponent)
        var number = 2
        while true {
            let candidate = folder.appendingPathComponent(join(base + " \(number)", ext))
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    /// Finder's name for a copy in the same folder: "name copy.ext", then "name copy 2.ext", …
    static func availableCopy(of url: URL, in folder: URL) -> URL {
        let (base, ext) = split(url.lastPathComponent)
        return available(folder.appendingPathComponent(join(base + " copy", ext)))
    }

    /// Splits off the extension, keeping a leading dot as part of the name (".zshrc").
    static func split(_ name: String) -> (base: String, ext: String) {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard !ext.isEmpty, !base.isEmpty else { return (name, "") }
        return (base, ext)
    }

    private static func join(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : base + "." + ext
    }

    /// True for anything at `url`, including a symbolic link whose target is gone.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Whether `a` and `b` are the same item, such as two spellings on a case-insensitive volume.
    static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        var first = stat(), second = stat()
        guard lstat(a.path, &first) == 0, lstat(b.path, &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    // MARK: Changes

    /// Renames within the same folder. Returns the new URL.
    static func rename(_ url: URL, to name: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Copies each item, stopping at the first error or when cancelled.
    static func copy(_ transfers: [Transfer], progress: (Int, Transfer) -> Void) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default
        for (number, transfer) in transfers.enumerated() {
            guard !Task.isCancelled else { break }
            progress(number, transfer)
            do {
                if transfer.replacing, exists(transfer.destination) {
                    try manager.trashItem(at: transfer.destination, resultingItemURL: nil)
                }
                try manager.copyItem(at: transfer.source, to: transfer.destination)
                outcome.done.append(transfer)
            } catch {
                outcome.error = error
                break
            }
        }
        return outcome
    }

    /// Deletes each item for good. Returns the items deleted and the first error.
    static func delete(_ urls: [URL], progress: (Int, URL) -> Void) -> (deleted: [URL], error: (any Error)?) {
        var deleted: [URL] = []
        for (number, url) in urls.enumerated() {
            guard !Task.isCancelled else { break }
            progress(number, url)
            do {
                try FileManager.default.removeItem(at: url)
                deleted.append(url)
            } catch {
                return (deleted, error)
            }
        }
        return (deleted, nil)
    }

    /// A Finder alias to each item, next to it, named like Finder's: "name alias", "name alias 2".
    static func makeAliases(_ urls: [URL]) -> (created: [URL], error: (any Error)?) {
        var created: [URL] = []
        for url in urls {
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile)
                let alias = available(url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + " alias"))
                try URL.writeBookmarkData(data, to: alias)
                created.append(alias)
            } catch {
                return (created, error)
            }
        }
        return (created, nil)
    }

    /// Zips items the way Finder's Compress does: one item into "name.zip" next to it, several into
    /// "Archive.zip" in `folder`. Returns the archive.
    static func compress(_ urls: [URL], into folder: URL) throws -> URL {
        let manager = FileManager.default
        if urls.count == 1 {
            let archive = available(folder.appendingPathComponent(urls[0].lastPathComponent + ".zip"))
            try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, archive.path], output: archive)
            return archive
        }
        // ditto archives one folder, so gather the items in a temporary one on the same volume,
        // where copying clones instead of duplicating data.
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? manager.removeItem(at: staging) }
        for url in urls {
            guard !Task.isCancelled else { throw CocoaError(.userCancelled) }
            try manager.copyItem(at: url, to: available(staging.appendingPathComponent(url.lastPathComponent)))
        }
        let archive = available(folder.appendingPathComponent("Archive.zip"))
        try runDitto(["-c", "-k", "--sequesterRsrc", staging.path, archive.path], output: archive)
        return archive
    }

    private static func runDitto(_ arguments: [String], output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        while process.isRunning {
            if Task.isCancelled { process.terminate() }
            usleep(50_000)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw CocoaError(.userCancelled)
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "The archive could not be created.",
                NSLocalizedFailureReasonErrorKey: message.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
    }

    // MARK: Trash

    /// The user's Trash on the startup disk, under the path the index lists it by.
    private static let homeTrash = VolumeCatalog.canonicalPath(
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path)

    /// Whether items in `folder` are in a Trash: the user's own, or the `.Trashes` folder of
    /// another volume. Items are put back from Finder's Trash, since there's no API for it.
    static func isInTrash(folder: String) -> Bool {
        folder == homeTrash || folder.hasPrefix(homeTrash + "/") || folder.contains("/.Trashes/")
    }

    // MARK: Tags

    static func tags(of url: URL) -> [String] {
        // A fresh URL, so no cached resource values hide a change made since.
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func setTags(_ tags: [String], of url: URL) throws {
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
