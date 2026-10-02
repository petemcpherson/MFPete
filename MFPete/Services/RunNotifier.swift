import Foundation
import MFPeteCore
import OSLog
import UserNotifications

/// Receives run results from `EngineController` and decides, with the
/// current notification level, whether to post a summary (spec §8.8).
protocol RunNotifier {
    func runFinished(_ summary: RunSummary, level: NotificationLevel, notifyEachRun: Bool)
    func loopDetected(_ alert: LoopAlert, level: NotificationLevel)
}

/// Keys in a notification's `userInfo`.
nonisolated enum NotificationUserInfo {
    /// The rule's UUID string. Clicking opens the Activity log filtered to it.
    static let ruleID = "ruleID"
}

/// Posts one summary notification per run (never one per file). File-event
/// runs of the same rule within 5 seconds merge into one notification.
/// Without notification permission, posting fails quietly; the activity
/// log is the record.
@MainActor
final class SummaryNotifier: RunNotifier {
    private var coalescer: NotificationCoalescer
    private var flushTask: Task<Void, Never>?
    private let poster: NotificationPoster
    private let logger = Logger(subsystem: "com.mftpete.MFPete", category: "Notifications")

    init(
        poster: NotificationPoster = UserNotificationPoster(),
        window: TimeInterval = NotificationCoalescer.defaultWindow
    ) {
        self.poster = poster
        self.coalescer = NotificationCoalescer(window: window)
    }

    func runFinished(_ summary: RunSummary, level: NotificationLevel, notifyEachRun: Bool) {
        guard NotificationPolicy.shouldNotify(level: level, notifyEachRun: notifyEachRun, summary: summary) else { return }
        if let now = coalescer.add(summary, now: Date()) {
            post(now)
        } else {
            scheduleFlush()
        }
    }

    func loopDetected(_ alert: LoopAlert, level: NotificationLevel) {
        logger.error("\(alert.message, privacy: .public)")
        guard NotificationPolicy.shouldNotifyLoop(level: level) else { return }
        let text = RunNotificationText(loop: alert)
        poster.post(title: text.title, body: text.body, ruleID: alert.ruleIDs.first)
    }

    private func post(_ summary: RunSummary) {
        let text = RunNotificationText(summary: summary)
        poster.post(title: text.title, body: text.body, ruleID: summary.ruleID)
    }

    /// Wakes at the next merge deadline and posts what is due.
    private func scheduleFlush() {
        guard flushTask == nil, let deadline = coalescer.nextDeadline else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
            guard let self else { return }
            self.flushTask = nil
            for summary in self.coalescer.due(at: Date()) {
                self.post(summary)
            }
            self.scheduleFlush()
        }
    }
}

/// Sends a local notification. Tests swap in a recorder.
nonisolated protocol NotificationPoster: Sendable {
    func post(title: String, body: String, ruleID: UUID?)
}

/// `UNUserNotificationCenter`, no sound (spec §8.8).
nonisolated struct UserNotificationPoster: NotificationPoster {
    func post(title: String, body: String, ruleID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let ruleID {
            content.userInfo = [NotificationUserInfo.ruleID: ruleID.uuidString]
            content.threadIdentifier = ruleID.uuidString
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger(subsystem: "com.mftpete.MFPete", category: "Notifications")
                    .notice("Notification not posted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The "Show notification" action. An explicit user choice, so it posts at
/// every level, including Off.
nonisolated struct ActionNotificationPoster: NotificationService {
    var poster: any NotificationPoster = UserNotificationPoster()

    func showActionNotification(title: String, body: String, ruleID: UUID) async {
        poster.post(title: title, body: body, ruleID: ruleID)
    }
}

/// Shows notifications while the app is frontmost, and opens the Activity
/// log filtered to the rule when one is clicked (spec §8.8).
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    private let onOpen: @MainActor (UUID?) -> Void

    init(onOpen: @escaping @MainActor (UUID?) -> Void) {
        self.onOpen = onOpen
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[NotificationUserInfo.ruleID] as? String
        let ruleID = raw.flatMap(UUID.init(uuidString:))
        await onOpen(ruleID)
    }
}

/// Notification permission, asked during onboarding. The app works fully
/// without it.
enum NotificationPermission {
    static func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])) ?? false
    }

    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}
