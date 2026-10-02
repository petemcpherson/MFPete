import AppKit
import MFPeteCore
import OSLog
import SwiftData
import SwiftUI

/// App-wide UI state. Owns the loaded rules and persists every change
/// through `RulesStore`.
@MainActor
@Observable
final class AppState {
    private(set) var rules: [Rule] = []
    /// Set when `rules.json` could not be read. Shown as an alert (Phase 6).
    var loadIssue: RulesStore.LoadIssue?
    /// Rules loaded disabled because they contain unknown parts.
    var disabledUnknownRules: [String] = []
    var lastSaveError: String?

    @ObservationIgnored let modelContainer: ModelContainer
    @ObservationIgnored private let rulesStore: RulesStore
    /// Runs rules. Phase 4 wraps this in an engine controller for the UI.
    @ObservationIgnored let engine: RuleEngine
    /// Routes file events, schedules, and lifecycle events to the engine.
    @ObservationIgnored let triggers: TriggerCoordinator
    /// Rule pushes run in order, each after the previous one finished.
    @ObservationIgnored private var rulesPush: Task<Void, Never>?
    @ObservationIgnored private var eventLog: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.mftpete.MFPete", category: "AppState")
    /// Set by a scene view, so code outside SwiftUI (the app delegate) can open windows.
    @ObservationIgnored var windowOpener: ((String) -> Void)?

    init(rulesStore: RulesStore = RulesStore()) {
        self.rulesStore = rulesStore
        self.modelContainer = AppState.makeModelContainer()

        let defaults = UserDefaults.standard
        let threshold = defaults.object(forKey: SettingsKey.bulkThreshold) as? Int
            ?? RuleEngine.Configuration.defaultBulkThreshold
        let settleDelay = defaults.object(forKey: SettingsKey.settleDelay) as? Double ?? Settler.defaultDelay
        engine = RuleEngine(
            activityStore: ActivityStore(modelContainer: modelContainer),
            processedStore: ProcessedStore(modelContainer: modelContainer),
            environment: ActionEnvironment(workspace: AppWorkspaceService()),
            configuration: RuleEngine.Configuration(bulkThreshold: threshold)
        )
        triggers = TriggerCoordinator(
            engine: engine,
            state: UserDefaultsEngineState(),
            configuration: TriggerCoordinator.Configuration(
                settleDelay: min(max(settleDelay, Settler.delayRange.lowerBound), Settler.delayRange.upperBound)
            )
        )

        let result = rulesStore.load()
        rules = result.rules
        loadIssue = result.issue
        disabledUnknownRules = result.disabledUnknownRules
        if let issue = result.issue {
            logger.error("Rules file problem on load: \(String(describing: issue))")
        }
        pushRulesToEngine()
    }

    var activeRuleCount: Int {
        rules.filter(\.isEnabled).count
    }

    // MARK: - Rule changes

    func add(_ rule: Rule) {
        var rule = rule
        rule.order = rules.count
        rules.append(rule)
        persist()
    }

    func update(_ rule: Rule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var rule = rule
        rule.modifiedAt = Date()
        rules[index] = rule
        persist()
    }

    func setEnabled(_ isEnabled: Bool, for id: Rule.ID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = isEnabled
        rules[index].modifiedAt = Date()
        persist()
    }

    func delete(_ ids: Set<Rule.ID>) {
        rules.removeAll { ids.contains($0.id) }
        renumber()
        persist()
    }

    /// Drag reorder. Order sets run order (D5).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        renumber()
        persist()
    }

    private func renumber() {
        for index in rules.indices {
            rules[index].order = index
        }
    }

    private func persist() {
        pushRulesToEngine()
        do {
            try rulesStore.save(rules)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
            logger.error("Could not save rules: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine

    /// Starts watching and scheduling. Called once at launch.
    func startEngine() {
        let triggers = triggers
        let previous = rulesPush
        rulesPush = Task {
            await previous?.value
            await triggers.start()
        }
        logEngineEvents()
    }

    /// Delivers pending events and saves the watcher position. Call before quitting.
    func stopEngine() async {
        await rulesPush?.value
        await triggers.stop()
    }

    private func pushRulesToEngine() {
        let triggers = triggers
        let snapshot = rules
        let previous = rulesPush
        rulesPush = Task {
            await previous?.value
            await triggers.setRules(snapshot)
        }
    }

    /// Until the dashboard and notifications exist (Phases 4 and 6), engine
    /// events are only logged. Unanswered prompts keep their safe default:
    /// apply-to-existing stays "Only new files", bulk runs stay held.
    private func logEngineEvents() {
        guard eventLog == nil else { return }
        let events = engine.events
        let logger = logger
        eventLog = Task.detached(priority: .utility) {
            for await event in events {
                switch event {
                case .runFinished(let summary):
                    logger.info("Run finished: \(summary.ruleName, privacy: .public) acted on \(summary.actedOn) files, \(summary.failed) failed")
                case .bulkApprovalRequested(let request):
                    logger.notice("Bulk run held: \(request.ruleName, privacy: .public) wants to act on \(request.fileCount) files")
                case .applyExistingRequested(let request):
                    logger.notice("Apply to existing: \(request.ruleName, privacy: .public) matches \(request.fileCount) files")
                case .loopDetected(let alert):
                    logger.error("\(alert.message, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Windows

    /// Opens a window and brings the app to front (needed in accessory mode).
    func openWindow(_ id: String) {
        windowOpener?(id)
        AppActivation.bringToFront()
    }

    // MARK: - Activity log

    func pruneActivityLog() {
        let store = ActivityStore(modelContainer: modelContainer)
        Task.detached(priority: .utility) {
            try? await store.prune()
        }
    }

    private static func makeModelContainer() -> ModelContainer {
        do {
            return try DataStore.makeContainer()
        } catch {
            Logger(subsystem: "com.mftpete.MFPete", category: "AppState")
                .error("Could not open data store, using memory only: \(error.localizedDescription)")
            do {
                return try DataStore.makeInMemoryContainer()
            } catch {
                fatalError("Could not create in-memory data store: \(error)")
            }
        }
    }
}

/// `UserDefaults` keys for engine settings (Settings › Advanced, Phase 6).
enum SettingsKey {
    static let settleDelay = "settleDelay"
    static let bulkThreshold = "bulkGuardThreshold"
}

enum AppActivation {
    /// In accessory mode a newly opened window stays behind other apps unless
    /// the app activates itself.
    static func bringToFront() {
        NSApp.activate()
    }
}
