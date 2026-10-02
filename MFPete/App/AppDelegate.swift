import AppKit
import MFPeteCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = UITestingFixture.isActive ? UITestingFixture.makeAppState() : AppState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if SingleInstance.handOffToRunningInstance() {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstance.observeOpenRequests { [weak self] in
            self?.appState.openWindow(WindowID.rules)
        }
        AppActivation.applyActivationPolicy(showDockIcon: appState.showsDockIcon)
        setUpNotifications()
        appState.startActivityPruning()
        appState.engineController.start()
        appState.updater.start()
        observeWorkspace()
        LaunchAlerts.show(for: appState)
        if !appState.hasCompletedOnboarding && OnboardingWindow.shouldShowAtLaunch {
            appState.openWindow(WindowID.onboarding)
        }
    }

    private var notificationHandler: NotificationClickHandler?

    /// Clicking a notification opens the Activity log for its rule (spec §8.8).
    private func setUpNotifications() {
        let appState = appState
        let handler = NotificationClickHandler { ruleID in
            appState.showActivity(ruleID: ruleID)
        }
        notificationHandler = handler
        UNUserNotificationCenter.current().delegate = handler
    }

    /// Lets the engine finish pending events and save its watcher position.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let appState = appState
        Task {
            await appState.engineController.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Wake runs missed schedules; mounts and unmounts pause or resume rules
    /// on external volumes (spec §11).
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let triggers = appState.engineController.triggers
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await triggers.handleWake() }
        }
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { await triggers.handleVolumeMounted(url) }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { await triggers.handleVolumeUnmounted(url) }
        }
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
        // Unit tests launch the app as a test host, and UI tests use their own
        // isolated state; never quit those.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || UITestingFixture.isActive {
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
