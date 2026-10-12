import AppKit

/// Menu bar › Empty Trash. Asks Finder to empty the Trash through Apple
/// Events, so the first use shows the system Automation prompt.
enum TrashEmptier {
    /// `errAEEventNotPermitted`: the user denied Automation access to Finder.
    private static let notPermitted = -1743

    @MainActor
    static func confirmAndEmpty() {
        AppActivation.bringToFront()

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = String(localized: "Empty the Trash?")
        confirm.informativeText = String(localized: "All items in the Trash will be deleted permanently. You can’t undo this action.")
        confirm.addButton(withTitle: String(localized: "Empty Trash"))
        confirm.addButton(withTitle: String(localized: "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        script?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }

        let code = errorInfo[NSAppleScript.errorNumber] as? Int
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not empty the Trash")
        if code == notPermitted {
            alert.informativeText = String(localized: "MFPete needs permission to control Finder. Turn on Finder for MFPete in System Settings › Privacy & Security › Automation.")
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                SystemSettingsLink.openAutomation()
            }
        } else {
            alert.informativeText = errorInfo[NSAppleScript.errorMessage] as? String
                ?? String(localized: "Finder returned an unknown error.")
            alert.runModal()
        }
    }
}
