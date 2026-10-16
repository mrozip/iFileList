import AppKit
import UniformTypeIdentifiers

/// What the list can do with files without changing them: open, reveal in Finder, show Finder's
/// Get Info window, and put them on the pasteboard. `FileOperations` holds the changes.
@MainActor
enum FileActions {
    /// An app that can open the targets of Open With.
    struct Application: Identifiable {
        let url: URL
        let name: String
        let icon: NSImage
        let isDefault: Bool
        var id: URL { url }
    }

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

    static func open(_ urls: [URL], with application: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Asks for an app to open the files with, starting in /Applications.
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an application to open the document with."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The apps for Open With, the default first: those that open every one of `types`.
    static func applications(for types: [UTType]) -> [Application] {
        guard let first = types.first else { return [] }
        let workspace = NSWorkspace.shared
        var urls = workspace.urlsForApplications(toOpen: first)
        for type in types.dropFirst() {
            let others = Set(workspace.urlsForApplications(toOpen: type))
            urls.removeAll { !others.contains($0) }
        }
        let defaultApp = types.count == 1 ? workspace.urlForApplication(toOpen: first) : nil
        var seen = Set<String>()
        var apps: [Application] = []
        for url in urls {
            // The same app can be installed in several places; list the first.
            let name = FileManager.default.displayName(atPath: url.path)
            guard seen.insert(name).inserted || url == defaultApp else { continue }
            let icon = workspace.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            apps.append(Application(url: url, name: name, icon: icon, isDefault: url == defaultApp))
        }
        apps.sort { $0.isDefault != $1.isDefault ? $0.isDefault : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return apps
    }

    // MARK: Pasteboard

    /// Puts the files on the pasteboard, so pasting in Finder copies them.
    static func copy(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    static func copyPathnames(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// The files on the pasteboard, as Finder's Copy leaves them.
    static func pastedFiles() -> [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    static var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    // MARK: Finder

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
