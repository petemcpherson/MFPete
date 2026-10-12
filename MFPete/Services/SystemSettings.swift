import AppKit
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (spec §11). The status
/// is read from the system each time, because the user can change it in
/// System Settings › General › Login Items.
enum LoginItem {
    enum Status: Equatable {
        case enabled
        /// Registered, but the user must allow it in Login Items.
        case requiresApproval
        case disabled
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    /// Returns an error message, or nil on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Links into System Settings (spec §10).
enum SystemSettingsLink {
    static func openFilesAndFolders() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    static func openAutomation() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openNotifications() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Project links for Settings › About.
enum AppInfo {
    static let repositoryURL = URL(string: "https://github.com/petemcpherson/MFPete")!
    static let licenseURL = URL(string: "https://github.com/petemcpherson/MFPete/blob/main/LICENSE")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(localized: "Version \(short) (\(build))")
    }
}
