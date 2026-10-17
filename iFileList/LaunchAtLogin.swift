import ServiceManagement

/// Opening the app at login, so the index stays current from the start. The system keeps the
/// state, and the user can change it in System Settings › General › Login Items, so it's read
/// from there each time rather than saved.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// On, or waiting for the user to approve it in System Settings.
    static var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
