import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if SingleInstance.handOffToRunningInstance() {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstance.observeOpenRequests { [weak self] in
            self?.appState.openWindow(WindowID.rules)
        }
        appState.pruneActivityLog()
    }

    /// Menu bar app: closing the last window keeps it running (spec §11).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening the app again from Finder or Spotlight shows the Rules window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState.openWindow(WindowID.rules)
        }
        return true
    }
}

/// Keeps one copy of the app running. A second launch asks the first one to
/// open its Rules window, then quits (spec §11).
enum SingleInstance {
    private static let openRulesNotification = Notification.Name("com.mftpete.MFPete.openRules")

    /// Returns true if another instance is running and was asked to come forward.
    static func handOffToRunningInstance() -> Bool {
        // Unit tests launch the app as a test host; never quit those.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != current })
        else { return false }

        DistributedNotificationCenter.default().postNotificationName(
            openRulesNotification,
            object: bundleID,
            userInfo: nil,
            deliverImmediately: true
        )
        other.activate()
        return true
    }

    static func observeOpenRequests(_ handler: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: openRulesNotification,
            object: Bundle.main.bundleIdentifier,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
