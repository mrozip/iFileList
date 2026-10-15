import AppKit

/// Full Disk Access lets the app list protected folders (Mail, Messages, Safari, other apps' data)
/// without per-folder permission prompts.
enum FullDiskAccess {
    /// Probes a file that only processes with Full Disk Access can open.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno == ENOENT
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Starts a fresh instance and quits this one; macOS applies a new grant to new processes.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
