import AppKit
import MFPeteCore

/// Problems found while loading `rules.json`, shown once at launch
/// (spec §13: corrupt rules file; spec §9: rules with unknown parts).
@MainActor
enum LaunchAlerts {
    static func show(for appState: AppState) {
        let issue = appState.loadIssue
        let unknown = appState.disabledUnknownRules
        guard issue != nil || !unknown.isEmpty else { return }
        // Let the menu bar item appear first.
        DispatchQueue.main.async {
            if let issue {
                showLoadIssue(issue)
                appState.loadIssue = nil
            }
            if !unknown.isEmpty {
                showUnknownRules(unknown)
                appState.disabledUnknownRules = []
            }
        }
    }

    private static func showLoadIssue(_ issue: RulesStore.LoadIssue) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let corruptFile: URL?
        switch issue {
        case .recoveredFromBackup(let file):
            corruptFile = file
            alert.messageText = String(localized: "Rules Restored from Backup")
            alert.informativeText = String(localized: "MFPete could not read its rules file, so it loaded the backup copy. Your most recent rule change may be missing.")
        case .startedEmpty(let file):
            corruptFile = file
            alert.messageText = String(localized: "Rules Could Not Be Loaded")
            alert.informativeText = String(localized: "MFPete could not read its rules file or the backup, so it started with no rules.")
        }
        if let corruptFile {
            alert.informativeText += "\n\n" + String(localized: "The unreadable file was kept as “\(corruptFile.lastPathComponent)” for recovery.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Show File"))
        }
        AppActivation.bringToFront()
        if alert.runModal() == .alertSecondButtonReturn, let corruptFile {
            NSWorkspace.shared.activateFileViewerSelecting([corruptFile])
        }
    }

    private static func showUnknownRules(_ names: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Some Rules Were Turned Off")
        let list = ListFormatter.localizedString(byJoining: names)
        alert.informativeText = String(localized: "These rules use features from a newer version of MFPete, so they cannot run: \(list).")
        AppActivation.bringToFront()
        alert.runModal()
    }
}
