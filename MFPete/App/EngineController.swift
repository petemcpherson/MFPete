import Foundation
import MFPeteCore
import OSLog
import SwiftData

/// The UI's view of the engine. Owns the `RuleEngine` actor and the trigger
/// coordinator, pushes rule changes to them, and mirrors engine state for
/// SwiftUI: pause, per-rule status and stats, manual runs in progress,
/// pending prompts, and recent activity.
@MainActor
@Observable
final class EngineController {
    /// Global pause (spec §5.6). Persisted across launches.
    private(set) var isPaused: Bool
    /// Rules the engine reports a problem for. Rules not listed are OK.
    private(set) var statuses: [Rule.ID: RuleStatus] = [:]
    /// Last run and lifetime file count, from the activity log.
    private(set) var stats: [Rule.ID: RuleStats] = [:]
    /// Rules with a Run Now in progress (spinner on the row).
    private(set) var runningRuleIDs: Set<Rule.ID> = []
    /// Newest first, for the menu bar.
    private(set) var recentActivity: [ActivityRecord] = []
    /// Automatic or manual runs held by the bulk guard (spec §5.6).
    private(set) var bulkRequests: [BulkApprovalRequest] = []
    /// "Apply this rule to the N files already in …?" (spec §3.4).
    private(set) var applyRequests: [ApplyExistingRequest] = []
    /// Set on resume: offer "Scan now" for files added while paused.
    var offerScanAfterResume = false
    /// Every scope folder with its health (Settings › Folders).
    private(set) var folderUsages: [FolderUsage] = []
    /// Bumped on every refresh, so the Activity window reloads.
    private(set) var activityRevision = 0
    /// Settings › General › Notifications (spec §8.8).
    private(set) var notificationLevel: NotificationLevel
    /// Settings › Advanced (spec §8.5).
    private(set) var settleDelay: TimeInterval
    private(set) var bulkThreshold: Int

    static let recentActivityLimit = 5

    @ObservationIgnored let engine: RuleEngine
    @ObservationIgnored let triggers: TriggerCoordinator
    /// Called when a prompt needs an open Rules window.
    @ObservationIgnored var onPromptNeeded: (() -> Void)?
    @ObservationIgnored private let activityStore: ActivityStore
    @ObservationIgnored let notifier: any RunNotifier
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var rules: [Rule] = []
    /// Rule pushes run in order, each after the previous one finished.
    @ObservationIgnored private var rulesPush: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.mftpete.MFPete", category: "EngineController")

    init(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard,
        notifier: (any RunNotifier)? = nil
    ) {
        self.defaults = defaults
        self.notifier = notifier ?? SummaryNotifier()
        self.activityStore = ActivityStore(modelContainer: modelContainer)
        self.isPaused = defaults.bool(forKey: SettingsKey.isPaused)
        self.notificationLevel = defaults.string(forKey: SettingsKey.notificationLevel)
            .flatMap(NotificationLevel.init(rawValue:)) ?? .default

        let threshold = defaults.object(forKey: SettingsKey.bulkThreshold) as? Int
            ?? RuleEngine.Configuration.defaultBulkThreshold
        let bulkThreshold = max(threshold, Self.bulkThresholdRange.lowerBound)
        self.bulkThreshold = bulkThreshold
        let storedDelay = defaults.object(forKey: SettingsKey.settleDelay) as? Double ?? Settler.defaultDelay
        let settleDelay = min(max(storedDelay, Settler.delayRange.lowerBound), Settler.delayRange.upperBound)
        self.settleDelay = settleDelay
        engine = RuleEngine(
            activityStore: ActivityStore(modelContainer: modelContainer),
            processedStore: ProcessedStore(modelContainer: modelContainer),
            environment: ActionEnvironment(workspace: AppWorkspaceService(), notifier: ActionNotificationPoster()),
            configuration: RuleEngine.Configuration(bulkThreshold: bulkThreshold)
        )
        triggers = TriggerCoordinator(
            engine: engine,
            state: UserDefaultsEngineState(defaults: defaults),
            configuration: TriggerCoordinator.Configuration(settleDelay: settleDelay)
        )

        let triggers = triggers
        let paused = isPaused
        rulesPush = Task { await triggers.setPaused(paused) }
        listenForEvents()
    }

    var hasUnresolvedErrors: Bool {
        statuses.values.contains(where: \.isError)
    }

    func status(of id: Rule.ID) -> RuleStatus {
        statuses[id] ?? .ok
    }

    func isRunning(_ id: Rule.ID) -> Bool {
        runningRuleIDs.contains(id)
    }

    // MARK: - Rules and lifecycle

    func setRules(_ rules: [Rule]) {
        self.rules = rules
        enqueue { triggers in await triggers.setRules(rules) }
    }

    /// Starts watching and scheduling. Called once at launch.
    func start() {
        enqueue { triggers in await triggers.start() }
        Task { await refresh() }
    }

    /// Delivers pending events and saves the watcher position. Call before quitting.
    func stop() async {
        await rulesPush?.value
        await triggers.stop()
    }

    /// Waits until every rule change so far reached the engine.
    func settle() async {
        await rulesPush?.value
    }

    private func enqueue(_ work: @escaping @Sendable (TriggerCoordinator) async -> Void) {
        let triggers = triggers
        let previous = rulesPush
        rulesPush = Task {
            await previous?.value
            await work(triggers)
        }
    }

    // MARK: - Pause

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        defaults.set(paused, forKey: SettingsKey.isPaused)
        // Events that arrived while paused were dropped; offer a catch-up scan.
        offerScanAfterResume = !paused && rules.contains { $0.isEnabled && $0.trigger == .fileAdded }
        enqueue { triggers in await triggers.setPaused(paused) }
    }

    /// "Scan now" after resuming: full scan of enabled "File added" rules.
    func scanAfterResume() {
        offerScanAfterResume = false
        let triggers = triggers
        Task {
            await settle()
            let summaries = await triggers.scanFileEventRules()
            handle(summaries)
            await refresh()
        }
    }

    // MARK: - Settings

    static let bulkThresholdRange = 5...10_000

    func setNotificationLevel(_ level: NotificationLevel) {
        notificationLevel = level
        defaults.set(level.rawValue, forKey: SettingsKey.notificationLevel)
    }

    func setSettleDelay(_ seconds: TimeInterval) {
        let seconds = min(max(seconds, Settler.delayRange.lowerBound), Settler.delayRange.upperBound)
        guard seconds != settleDelay else { return }
        settleDelay = seconds
        defaults.set(seconds, forKey: SettingsKey.settleDelay)
        enqueue { triggers in await triggers.setSettleDelay(seconds) }
    }

    func setBulkThreshold(_ threshold: Int) {
        let threshold = min(max(threshold, Self.bulkThresholdRange.lowerBound), Self.bulkThresholdRange.upperBound)
        guard threshold != bulkThreshold else { return }
        bulkThreshold = threshold
        defaults.set(threshold, forKey: SettingsKey.bulkThreshold)
        let engine = engine
        Task { await engine.setBulkThreshold(threshold) }
    }

    /// Settings › Advanced: every rule re-evaluates existing files on its next run.
    func resetAllProcessed() async {
        await settle()
        await engine.resetAllProcessed()
    }

    // MARK: - Activity log

    /// Entries for the Activity window, newest first.
    func activityEntries(ruleID: Rule.ID?, errorsOnly: Bool) async -> [ActivityRecord] {
        (try? await activityStore.entries(ruleID: ruleID, errorsOnly: errorsOnly)) ?? []
    }

    func clearActivityLog() async {
        try? await activityStore.deleteAll()
        await refresh()
    }

    // MARK: - Run Now (D14)

    /// Every Run Now entry point ends here: row button, row menu, menu bar
    /// submenu, editor Save & Run. A rule already running is ignored (no queue).
    func runNow(_ id: Rule.ID) async {
        guard !runningRuleIDs.contains(id) else { return }
        runningRuleIDs.insert(id)
        await settle()
        let result = await engine.runNow(ruleID: id)
        runningRuleIDs.remove(id)
        switch result {
        case .completed(let summary):
            notify(summary)
        case .needsApproval(let request):
            addBulkRequest(request)
        case .alreadyRunning, .ruleNotFound, .notAvailableForFileRemoved, .unsupportedElements:
            logger.notice("Run Now did not start: \(String(describing: result), privacy: .public)")
        }
        await refresh()
    }

    func startRun(_ id: Rule.ID) {
        Task { await runNow(id) }
    }

    /// "Run Again on All Files": forget what the rule processed (D6), then run it.
    func runAgainOnAllFiles(_ id: Rule.ID) {
        Task {
            await settle()
            await engine.resetProcessed(ruleID: id)
            await runNow(id)
        }
    }

    // MARK: - Prompts

    func resolveBulk(_ request: BulkApprovalRequest, approve: Bool) {
        bulkRequests.removeAll { $0.id == request.id }
        Task {
            if let summary = await engine.resolveBulkApproval(request.id, approve: approve) {
                notify(summary)
            }
            await refresh()
        }
    }

    func resolveApplyExisting(_ request: ApplyExistingRequest, apply: Bool) {
        applyRequests.removeAll { $0.ruleID == request.ruleID }
        let triggers = triggers
        Task {
            if let summary = await triggers.resolveApplyExisting(ruleID: request.ruleID, apply: apply) {
                handle([summary])
            }
            await refresh()
        }
    }

    private func addBulkRequest(_ request: BulkApprovalRequest) {
        bulkRequests.removeAll { $0.ruleID == request.ruleID }
        bulkRequests.append(request)
        onPromptNeeded?()
    }

    // MARK: - Errors and preview

    /// The user opened the rule: clear its error badge (spec §13).
    func clearError(_ id: Rule.ID) {
        guard statuses[id]?.isError == true else { return }
        statuses[id] = nil
        Task { await engine.clearStatus(of: id) }
    }

    /// Dry run for Preview. Makes no changes.
    func plan(_ rule: Rule) async -> [PlannedFileResult] {
        await engine.plan(rule: rule)
    }

    // MARK: - Refresh

    /// Re-reads statuses from the engine, checks every scope folder, and
    /// reads stats from the activity log. The engine's status wins; a rule
    /// it has not flagged still shows a missing or unreadable folder, so
    /// disabled and imported rules get badges too (spec §10).
    func refresh() async {
        let rules = rules
        let usages = await Task.detached(priority: .utility) {
            FolderStatusChecker.usages(for: rules)
        }.value
        let folderStatuses = FolderStatusChecker.ruleStatuses(from: usages, rules: rules)
        var newStatuses: [Rule.ID: RuleStatus] = [:]
        var newStats: [Rule.ID: RuleStats] = [:]
        for rule in rules {
            let status = await engine.status(of: rule.id)
            if status != .ok {
                newStatuses[rule.id] = status
            } else if let folderStatus = folderStatuses[rule.id] {
                newStatuses[rule.id] = folderStatus
            }
            newStats[rule.id] = (try? await activityStore.stats(ruleID: rule.id)) ?? RuleStats()
        }
        statuses = newStatuses
        stats = newStats
        folderUsages = usages
        recentActivity = (try? await activityStore.recent(limit: Self.recentActivityLimit)) ?? []
        activityRevision += 1
    }

    // MARK: - Engine events

    private func listenForEvents() {
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: EngineEvent) async {
        switch event {
        case .runFinished(let summary):
            handle([summary])
        case .bulkApprovalRequested(let request):
            addBulkRequest(request)
        case .applyExistingRequested(let request):
            applyRequests.removeAll { $0.ruleID == request.ruleID }
            applyRequests.append(request)
            onPromptNeeded?()
        case .loopDetected(let alert):
            notifier.loopDetected(alert, level: notificationLevel)
        }
        await refresh()
    }

    private func handle(_ summaries: [RunSummary]) {
        for summary in summaries {
            if let request = summary.pendingApproval {
                addBulkRequest(request)
            } else {
                notify(summary)
            }
        }
    }

    private func notify(_ summary: RunSummary) {
        let notifyEachRun = rules.first { $0.id == summary.ruleID }?.options.notifyEachRun ?? false
        notifier.runFinished(summary, level: notificationLevel, notifyEachRun: notifyEachRun)
    }
}
