import AppKit

/// What the list can do with files: open, reveal in Finder, and show Finder's Get Info window.
@MainActor
enum FileActions {
    /// Opens each file in its default application. Returns the URLs that no longer exist.
    static func open(_ urls: [URL]) -> [URL] {
        var missing: [URL] = []
        for url in urls {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                missing.append(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return missing
    }

    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Opens Finder's Get Info window for each file.
    ///
    /// Uses Finder's own "Show Info" service, which needs no Automation permission. If the
    /// service is unavailable, falls back to asking Finder over Apple Events.
    static func showInfo(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mrozip.iFileList.showInfo"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.addTypes([filenames], owner: nil)
        pasteboard.setPropertyList(urls.map(\.path), forType: filenames)

        if NSPerformService("Finder/Show Info", pasteboard) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        } else {
            showInfoWithAppleScript(urls)
        }
    }

    private static func showInfoWithAppleScript(_ urls: [URL]) {
        let files = urls.map { url in
            let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "POSIX file \"\(escaped)\""
        }
        let source = """
            tell application "Finder"
                activate
                repeat with f in {\(files.joined(separator: ", "))}
                    open information window of (f as alias)
                end repeat
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("Get Info via Finder failed: %@", error)
        }
    }
}
