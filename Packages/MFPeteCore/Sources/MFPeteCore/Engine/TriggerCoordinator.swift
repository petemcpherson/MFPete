import Foundation

/// Turns triggers into engine runs: FSEvents → settling → file-event rules,
/// the schedule timer → scheduled runs, and app lifecycle (launch, wake,
/// volume mount, quit) → catch-up work (spec §3, §5, §11).
///
/// The app owns one coordinator, pushes rule changes with `setRules`, and
/// forwards `NSWorkspace` notifications. UI-facing results arrive on
/// `engine.events`.
public actor TriggerCoordinator {
    public struct Configuration: Sendable {
        /// Seconds a file must stay unchanged before rules see it (spec §5.3).
        public var settleDelay: TimeInterval
        /// FSEvents coalescing latency.
        public var streamLatency: TimeInterval
        /// Settled files arriving within this window run as one batch, so
        /// the bulk guard sees a large drop as one run.
        public var batchWindow: TimeInterval
        /// How often the last event ID is written to disk (spec §5.1).
        public var eventIDSaveInterval: TimeInterval
        /// Longest the schedule timer sleeps before checking again. Guards
        /// against clock changes the timer cannot see.
        public var maxTimerSleep: TimeInterval
        /// Tests turn these off to drive events or schedules by hand.
        public var watchFiles: Bool
        public var runScheduleTimer: Bool

        public init(
            settleDelay: TimeInterval = Settler.defaultDelay,
            streamLatency: TimeInterval = 0.3,
            batchWindow: TimeInterval = 0.25,
            eventIDSaveInterval: TimeInterval = 5,
            maxTimerSleep: TimeInterval = 300,
            watchFiles: Bool = true,
            runScheduleTimer: Bool = true
        ) {
            self.settleDelay = settleDelay
            self.streamLatency = streamLatency
            self.batchWindow = batchWindow
            self.eventIDSaveInterval = eventIDSaveInterval
            self.maxTimerSleep = maxTimerSleep
            self.watchFiles = watchFiles
            self.runScheduleTimer = runScheduleTimer
        }
    }

    public let engine: RuleEngine
    private let state: EngineStateStore
    private let watcher = FSEventsWatcher()
    private let settler: Settler
    private let scheduler: Scheduler
    private let configuration: Configuration

    private var rules: [Rule] = []
    /// Enabled state from the previous `setRules`. Nil until the first call,
    /// so rules loaded at launch never prompt.
    private var knownEnabled: [UUID: Bool]?
    private var paused = false
    private var started = false
    private var consuming = false

    private var resumeEventID: UInt64 = 0
    private var lastEventIDSave: Date = .distantPast
    private var readyItems: [Settler.Item] = []
    private var flushTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    /// File keys marked processed by "Only new files", per rule, until the
    /// user answers the apply-to-existing prompt.
    private var applyKeys: [UUID: Set<String>] = [:]

    public init(engine: RuleEngine, state: EngineStateStore, configuration: Configuration = Configuration()) {
        self.engine = engine
        self.state = state
        self.configuration = configuration
        self.settler = Settler(delay: configuration.settleDelay)
        self.scheduler = Scheduler(calendar: engine.environment.calendar)
    }

    private var now: Date { engine.environment.now() }

    // MARK: - Lifecycle

    /// Launch: starts watching from the stored event ID so files added while
    /// the app was closed are caught (spec §5.1), runs missed schedules
    /// once (spec §3.2), and starts the schedule timer.
    public func start() async {
        guard !started else { return }
        started = true
        startConsumers()

        let current = FSEventsWatcher.currentEventID
        var rescanAll = false
        if let stored = state.lastEventID() {
            if stored > current {
                // Event IDs were reset (new FSEvents database). History is
                // unusable, so scan instead.
                rescanAll = true
                resumeEventID = current
            } else {
                resumeEventID = stored
            }
        } else {
            resumeEventID = current
        }
        rebuildWatcher(force: true)
        if rescanAll { await fallbackScan(nil) }
        await checkSchedules()
        restartTimer()
    }

    /// Quit: delivers pending events, saves the event ID, stops the stream.
    public func stop() async {
        guard started else { return }
        started = false
        watcher.stop()
        saveEventID(force: true)
        timerTask?.cancel()
        timerTask = nil
        flushTask?.cancel()
        flushTask = nil
        readyItems = []
        await settler.cancelAll()
    }

    /// After sleep: run missed schedules, then restart the stream in case
    /// it went stale (spec §11).
    public func handleWake() async {
        guard started else { return }
        await checkSchedules()
        rebuildWatcher(force: true)
        restartTimer()
    }

    /// A volume came back: its rules resume, the stream includes its
    /// folders again, and "File added" rules there catch up.
    public func handleVolumeMounted(_ volumeURL: URL) async {
        await engine.setVolume(volumeURL.path, mounted: true)
        guard started else { return }
        rebuildWatcher(force: true)
        await fallbackScan([volumeURL])
    }

    /// A volume went away: its rules show "Folder unavailable" without
    /// error entries, and the stream drops its folders.
    public func handleVolumeUnmounted(_ volumeURL: URL) async {
        await engine.setVolume(volumeURL.path, mounted: false)
        guard started else { return }
        rebuildWatcher(force: true)
    }

    // MARK: - Settings

    /// Pushes the current rules (dashboard order). Newly created or enabled
    /// file-event rules get the apply-to-existing treatment (spec §3.4);
    /// newly enabled schedule rules start their clock now, so they do not
    /// "catch up" on time spent disabled.
    public func setRules(_ newRules: [Rule]) async {
        rules = newRules.sorted { $0.order < $1.order }
        await engine.setRules(rules)
        state.keepScheduledRuns(for: Set(rules.map(\.id)))
        applyKeys = applyKeys.filter { id, _ in rules.contains { $0.id == id && $0.isEnabled } }

        let previous = knownEnabled
        knownEnabled = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.isEnabled) })

        if let previous {
            for rule in rules where rule.isEnabled && previous[rule.id] != true && !rule.containsUnknownElements {
                switch rule.trigger {
                case .fileAdded, .fileModified:
                    await offerApplyExisting(rule)
                case .interval, .daily, .weekly:
                    state.setLastScheduledRun(now, ruleID: rule.id)
                case .fileRemoved:
                    break
                }
            }
        }
        if started {
            rebuildWatcher(force: false)
            restartTimer()
        }
    }

    /// Global pause (spec §5.6). Events received while paused are dropped.
    /// Run Now still works (D14).
    public func setPaused(_ isPaused: Bool) async {
        paused = isPaused
        await engine.setPaused(isPaused)
        if isPaused {
            await settler.cancelAll()
            readyItems = []
            flushTask?.cancel()
            flushTask = nil
        }
    }

    public func setSettleDelay(_ seconds: TimeInterval) async {
        await settler.setDelay(seconds)
    }

    // MARK: - User answers

    /// "Scan now" after resuming: full scan for every enabled "File added"
    /// rule, compared against processed records.
    @discardableResult
    public func scanFileEventRules() async -> [RunSummary] {
        await fallbackScan(nil)
    }

    /// Answers the apply-to-existing prompt. "Only new files" (apply =
    /// false) keeps the records already written; "Apply" forgets them and
    /// runs the rule. Returns the run summary for "Apply".
    @discardableResult
    public func resolveApplyExisting(ruleID: UUID, apply: Bool) async -> RunSummary? {
        guard let keys = applyKeys.removeValue(forKey: ruleID), apply,
              let rule = rules.first(where: { $0.id == ruleID })
        else { return nil }
        return await engine.applyToExisting(rule, forgetting: keys)
    }

    private func offerApplyExisting(_ rule: Rule) async {
        let keys = await engine.markExistingProcessed(for: rule)
        guard !keys.isEmpty else { return }
        applyKeys[rule.id] = keys
        engine.emit(.applyExistingRequested(ApplyExistingRequest(
            ruleID: rule.id,
            ruleName: rule.name,
            fileCount: keys.count,
            folderNames: rule.scope.map(\.displayName)
        )))
    }

    // MARK: - File events

    private func startConsumers() {
        guard !consuming else { return }
        consuming = true
        let batches = watcher.batches
        let ready = settler.ready
        Task { [weak self] in
            for await batch in batches {
                await self?.handle(batch)
            }
        }
        Task { [weak self] in
            for await item in ready {
                await self?.enqueue(item)
            }
        }
    }

    /// Union of enabled file-event rules' scope folders that exist now.
    private func watchedPaths() -> [String] {
        let paths = rules
            .filter { $0.isEnabled && $0.trigger.isFileEvent && !$0.containsUnknownElements }
            .flatMap(\.scope)
            .filter { FolderHealth.check($0) == .ok }
            .map { TriggerCoordinator.realPath($0.path) }
        return Array(Set(paths)).sorted()
    }

    /// The path FSEvents reports for a folder (`/private/var/...`, not
    /// `/var/...`). Event paths are compared after canonicalizing anyway.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Restarts the stream when the folder set changed (or always, with
    /// `force`), resuming from the last seen event so nothing is missed.
    private func rebuildWatcher(force: Bool) {
        guard started, configuration.watchFiles else { return }
        let paths = watchedPaths()
        if !force && paths == watcher.paths { return }
        resumeEventID = max(resumeEventID, watcher.latestEventID ?? 0)
        if paths.isEmpty {
            watcher.stop()
            return
        }
        watcher.start(paths: paths, since: resumeEventID, latency: configuration.streamLatency)
    }

    /// Handles one FSEvents batch. Removed files go straight to "File
    /// removed" rules; added and modified files wait to settle.
    func handle(_ batch: FileEventBatch) async {
        if let id = batch.lastEventID {
            resumeEventID = max(resumeEventID, id)
            saveEventID(force: false)
        }
        guard !paused else { return }

        if batch.rescanAll {
            await fallbackScan(nil)
        } else if !batch.rescanFolders.isEmpty {
            await fallbackScan(batch.rescanFolders)
        }

        let removed = batch.events.filter { $0.kind == .removed }.map(\.url)
        if !removed.isEmpty {
            report(await engine.handleRemoved(removed))
        }

        for event in batch.events where event.kind != .removed {
            if IgnoreFilter.systemNames.contains(event.url.lastPathComponent) { continue }
            let trigger: Trigger = event.kind == .added ? .fileAdded : .fileModified
            let covering = rules.filter {
                $0.isEnabled && $0.trigger == trigger && FolderScanner.rule($0, covers: event.url)
            }
            guard !covering.isEmpty else { continue }
            let needsContents = covering.contains { $0.actions.contains(where: \.needsContents) }
            await settler.submit(Settler.Item(url: event.url, kind: event.kind, needsContents: needsContents))
        }
    }

    private func enqueue(_ item: Settler.Item) {
        guard !paused else { return }
        readyItems.append(item)
        guard flushTask == nil else { return }
        let window = configuration.batchWindow
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushReady()
        }
    }

    private func flushReady() async {
        flushTask = nil
        let items = readyItems
        readyItems = []
        guard !paused, !items.isEmpty else { return }
        var seen: Set<String> = []
        let unique = items.filter { seen.insert("\($0.kind.rawValue):\($0.url.path)").inserted }
        let added = unique.filter { $0.kind == .added }.map(\.url)
        let modified = unique.filter { $0.kind == .modified }.map(\.url)
        report(await engine.handleFileEvents(added: added, modified: modified))
    }

    /// Full scan for "File added" rules when events were lost (spec §5.1):
    /// all of them, or those whose folders overlap `folders`. Processed
    /// records keep files from running twice.
    @discardableResult
    private func fallbackScan(_ folders: [URL]?) async -> [RunSummary] {
        let roots = folders?.map { FolderScanner.canonicalPath($0) }
        var summaries: [RunSummary] = []
        for rule in rules where rule.isEnabled && rule.trigger == .fileAdded {
            if let roots {
                let scope = rule.scope.map { FolderScanner.canonicalPath($0.url) }
                let overlaps = scope.contains { path in
                    roots.contains { root in
                        path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
                    }
                }
                guard overlaps else { continue }
            }
            summaries.append(await engine.scanAndRun(rule, reason: .fileEvent))
        }
        report(summaries)
        return summaries
    }

    private func saveEventID(force: Bool) {
        resumeEventID = max(resumeEventID, watcher.latestEventID ?? 0)
        let current = now
        guard force || current.timeIntervalSince(lastEventIDSave) >= configuration.eventIDSaveInterval else { return }
        guard resumeEventID > 0 else { return }
        state.setLastEventID(resumeEventID)
        lastEventIDSave = current
    }

    /// Emits summaries of automatic runs that did something worth telling.
    /// Held-back bulk runs already emitted their own request.
    private func report(_ summaries: [RunSummary]) {
        for summary in summaries where summary.pendingApproval == nil && (summary.matched > 0 || summary.hasErrors) {
            engine.emit(.runFinished(summary))
        }
    }

    // MARK: - Schedules

    /// Runs every schedule rule that is due. A time that passed while the
    /// Mac slept or the app was closed runs once, logged "Ran late". Manual
    /// runs never touch these records (D14).
    public func checkSchedules() async {
        let current = now
        for rule in rules where rule.isEnabled && rule.trigger.isSchedule && !rule.containsUnknownElements {
            guard let last = state.lastScheduledRun(ruleID: rule.id) else {
                // New rule: its clock starts now.
                state.setLastScheduledRun(current, ruleID: rule.id)
                continue
            }
            let reason: RunTrigger
            var note: String?
            switch scheduler.decision(for: rule.trigger, lastRun: last, now: current) {
            case .notScheduled, .wait:
                continue
            case .run:
                reason = .scheduled
            case .runLate(let missed):
                reason = .scheduledLate
                note = localized("Ran late (missed \(formatMissed(missed, now: current)))")
            }
            state.setLastScheduledRun(current, ruleID: rule.id)
            // Paused: the time passes without a run, and no catch-up later.
            guard !paused else { continue }
            report([await engine.scanAndRun(rule, reason: reason, note: note)])
        }
    }

    /// The soonest fire time across enabled schedule rules (`ruleID` limits
    /// it to one rule), or nil without schedules.
    public func nextScheduledFireDate(ruleID: UUID? = nil) -> Date? {
        let current = now
        return rules
            .filter { $0.isEnabled && $0.trigger.isSchedule && !$0.containsUnknownElements }
            .filter { ruleID == nil || $0.id == ruleID }
            .compactMap { scheduler.nextFireDate(for: $0.trigger, after: state.lastScheduledRun(ruleID: $0.id) ?? current) }
            .min()
    }

    /// Seconds the timer sleeps: until the soonest fire, capped.
    private func secondsUntilNextFire() -> TimeInterval? {
        nextScheduledFireDate().map { min(max($0.timeIntervalSince(now), 1), configuration.maxTimerSleep) }
    }

    /// One timer for the soonest fire; recomputed after each fire and on
    /// rule changes.
    private func restartTimer() {
        timerTask?.cancel()
        timerTask = nil
        guard started, configuration.runScheduleTimer, let delay = secondsUntilNextFire() else { return }
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        await checkSchedules()
        restartTimer()
    }

    private func formatMissed(_ date: Date, now: Date) -> String {
        let calendar = scheduler.calendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .short
        return formatter.string(from: date)
    }
}
