import Foundation
@testable import FileIndexKit

/// A temporary directory with its canonical path (`/private/var/...`), as FSEvents reports it.
final class TemporaryDirectory {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "FileIndexKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        path = String(cString: resolved)
        free(resolved)
    }

    deinit {
        // Restore permissions so unreadable fixtures can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in enumerator {
                chmod(path + "/" + relative, 0o755)
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func url(_ relative: String) -> URL { URL(fileURLWithPath: path + "/" + relative) }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    func makeFile(_ relative: String, size: Int = 0) throws {
        try Data(count: size).write(to: url(relative))
    }
}

extension EntryBatch {
    static func make(_ entries: [(id: EntryID, parent: EntryID, name: String, flags: EntryFlags, size: Int64)]) -> EntryBatch {
        var batch = EntryBatch()
        for entry in entries {
            batch.append(
                id: entry.id, parent: entry.parent, flags: entry.flags, size: entry.size, mtime: 1_700_000_000,
                crtime: 1_600_000_000, name: entry.name)
        }
        return batch
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: TimeInterval = 10, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return try await condition()
}
