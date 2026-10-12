import Foundation

/// The Empty Trash action. Asks Finder to empty the Trash through Apple
/// Events, so the first run shows the system Automation prompt.
enum TrashEmptier {
    /// `errAEEventNotPermitted`: the user denied Automation access to Finder.
    private static let notPermitted = -1743

    /// Turns off Finder's "warn before emptying" dialog for this one call,
    /// so a scheduled run never waits on a dialog. Returns the item count.
    private static let source = """
        tell application "Finder"
            set itemCount to count items of trash
            if itemCount > 0 then
                set shouldWarn to warns before emptying of trash
                set warns before emptying of trash to false
                try
                    empty trash
                on error message number code
                    set warns before emptying of trash to shouldWarn
                    error message number code
                end try
                set warns before emptying of trash to shouldWarn
            end if
            return itemCount
        end tell
        """

    enum Failure: LocalizedError {
        case notPermitted
        case finder(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return String(localized: "MFPete needs permission to control Finder. Turn on Finder for MFPete in System Settings › Privacy & Security › Automation.")
            case .finder(let message):
                return String(localized: "Could not empty the Trash: \(message)")
            }
        }
    }

    /// Empties the Trash and returns how many items it held.
    /// `NSAppleScript` is not thread-safe, so it runs on the main actor.
    @MainActor
    static func empty() throws -> Int {
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if errorInfo[NSAppleScript.errorNumber] as? Int == notPermitted {
                throw Failure.notPermitted
            }
            throw Failure.finder(errorInfo[NSAppleScript.errorMessage] as? String
                ?? String(localized: "Finder returned an unknown error."))
        }
        return Int(result?.int32Value ?? 0)
    }
}
