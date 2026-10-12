import Foundation

/// Runs rules: lists candidates, tests conditions, performs actions, and logs
/// the results (spec §2.1). All engine state lives in this actor (D13).
public actor RuleEngine {
    public struct Configuration: Sendable {
        /// Files processed in parallel (spec §5.7). Actions on one file are serial.
        public var maxConcurrentFiles: Int
        /// How long the engine remembers its own output (spec §5.4).
        public var selfChangeTTL: TimeInterval
        /// Runs that would act on more files than this ask first (spec §5.6).
        public var bulkThreshold: Int
        /// Rule runs one file may go through within `loopWindow` (spec §5.6).
        public var loopLimit: Int
        public var loopWindow: TimeInterval

        public static let defaultBulkThreshold = 50

        public init(
            maxConcurrentFiles: Int = 4,
            selfChangeTTL: TimeInterval = 10,
            bulkThreshold: Int = Configuration.defaultBulkThreshold,
            loopLimit: Int = 10,
            loopWindow: TimeInterval = 60
        ) {
            self.maxConcurrentFiles = maxConcurrentFiles
            self.selfChangeTTL = selfChangeTTL
            self.bulkThreshold = bulkThreshold
            self.loopLimit = loopLimit
            self.loopWindow = loopWindow
        }
    }

    private let activityStore: ActivityStore
    let processedStore: ProcessedStore
    let environment: ActionEnvironment
    private var configuration: Configuration
    let executor: ActionExecutor
    let evaluator: ConditionEvaluator

    /// Rules in dashboard order (D5).
    public private(set) var rules: [Rule] = []
    public private(set) var isPaused = false
    private var running: Set<UUID> = []
    private var statuses: [UUID: RuleStatus] = [:]
    private var selfChanges: SelfChangeTracker
    var loopGuard: LoopGuard
    /// Bulk runs waiting for the user. `candidates` is nil for full scans.
    private var pendingBulk: [UUID: (request: BulkApprovalRequest, candidates: [URL]?)] = [:]

    /// Events for the UI: automatic run summaries, bulk and apply-to-existing
    /// prompts, loop alerts. One consumer (the app's engine controller).
    public nonisolated let events: AsyncStream<EngineEvent>
    private nonisolated let eventContinuation: AsyncStream<EngineEvent>.Continuation

    public init(
        activityStore: ActivityStore,
        processedStore: ProcessedStore,
        environment: ActionEnvironment = ActionEnvironment(),
        configuration: Configuration = Configuration()
    ) {
        self.activityStore = activityStore
        self.processedStore = processedStore
        self.environment = environment
        self.configuration = configuration
        self.executor = ActionExecutor(environment: environment)
        self.evaluator = ConditionEvaluator(calendar: environment.calendar)
        self.selfChanges = SelfChangeTracker(ttl: configuration.selfChangeTTL)
        self.loopGuard = LoopGuard(limit: configuration.loopLimit, window: configuration.loopWindow)
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        eventContinuation.finish()
    }

    nonisolated func emit(_ event: EngineEvent) {
        eventContinuation.yield(event)
    }

    // MARK: - State

    public func setRules(_ rules: [Rule]) {
        self.rules = rules.sorted { $0.order < $1.order }
        let ids = Set(rules.map(\.id))
        statuses = statuses.filter { ids.contains($0.key) }
    }

    /// Global pause. Automatic runs do nothing while paused; Run Now still works (D14).
    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    public func isRunning(_ ruleID: UUID) -> Bool {
        running.contains(ruleID)
    }

    public func status(of ruleID: UUID) -> RuleStatus {
        statuses[ruleID] ?? .ok
    }

    /// Clears an error badge (the user opened the rule, spec §13).
    public func clearStatus(of ruleID: UUID) {
        statuses[ruleID] = nil
    }

    func setStatus(_ status: RuleStatus?, of ruleID: UUID) {
        statuses[ruleID] = status
    }

    /// Settings › Advanced › bulk guard threshold (spec §5.6).
    public func setBulkThreshold(_ threshold: Int) {
        configuration.bulkThreshold = max(1, threshold)
    }

    public var bulkThreshold: Int { configuration.bulkThreshold }

    /// The rule that just created or changed the item at `url`, if any (spec §5.4).
    public func selfChangeProducer(of url: URL) -> UUID? {
        selfChanges.producer(of: url, now: environment.now())
    }

    // MARK: - Running

    /// Run Now (D14): full scan of the rule's scope, same as a scheduled run.
    /// Works on disabled rules and while paused. Respects processed records.
    public func runNow(ruleID: UUID) async -> RunNowResult {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return .ruleNotFound }
        if rule.trigger == .fileRemoved { return .notAvailableForFileRemoved }
        if rule.containsUnknownElements { return .unsupportedElements }
        if running.contains(ruleID) { return .alreadyRunning }
        let summary = await scanAndRun(rule, reason: .manual)
        if let request = summary.pendingApproval { return .needsApproval(request) }
        return .completed(summary)
    }

    /// Full scan of the rule's scope folders. Used by Run Now, scheduled
    /// runs, apply-to-existing, and the FSEvents fallback scan. `note` is
    /// stored as detail on every activity entry ("Ran late (missed 09:00)").
    /// The bulk guard applies unless bypassed or applying to existing files.
    public func scanAndRun(
        _ rule: Rule,
        reason: RunTrigger,
        note: String? = nil,
        bypassBulkGuard: Bool = false
    ) async -> RunSummary {
        let startedAt = environment.now()
        guard reason == .manual || (rule.isEnabled && !isPaused) else {
            return RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
        }
        guard !running.contains(rule.id) || reason == .manual else {
            // An automatic full scan while the rule already runs adds nothing.
            return RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
        }
        running.insert(rule.id)
        defer { running.remove(rule.id) }

        if rule.emptiesTrash {
            return await emptyTrash(rule, reason: reason, note: note, startedAt: startedAt)
        }

        let (healthy, errorSummary) = await checkFolders(rule, reason: reason, startedAt: startedAt)
        var scoped = rule
        scoped.scope = healthy
        let candidates = healthy.flatMap { FolderScanner.candidates(in: $0, options: rule.options) }

        if !bypassBulkGuard, reason != .applyExisting,
           let request = await bulkRequest(for: scoped, candidates: candidates, reason: reason, keepCandidates: false) {
            var summary = RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
            summary.pendingApproval = request
            summary.ruleErrors = errorSummary
            return summary
        }

        let (summaries, seenKeys) = await process(rules: [scoped], candidates: candidates, reason: reason, note: note)
        var summary = summaries[rule.id] ?? RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
        summary.startedAt = startedAt
        summary.ruleErrors = errorSummary
        summary.note = note

        // Forget files that are gone, but only when every folder was scanned.
        if healthy.count == rule.scope.count,
           let known = try? await processedStore.fileKeys(ruleID: rule.id) {
            try? await processedStore.remove(ruleID: rule.id, fileKeys: known.subtracting(seenKeys))
        }

        if reason == .manual, summary.actedOn + summary.failed + summary.skippedOther == 0 {
            let message = summary.skippedProcessed > 0
                ? localized("No new matching files (\(summary.skippedProcessed) already processed)")
                : localized("No matching files")
            await log([ActivityRecord(
                timestamp: environment.now(),
                ruleID: rule.id,
                ruleName: rule.name,
                action: localized("Run"),
                sourcePath: rule.scope.first?.path ?? "",
                result: .skipped,
                message: message,
                runTrigger: reason
            )])
        }
        summary.finishedAt = environment.now()
        return summary
    }

    /// Runs one rule on the given files.
    public func run(rule: Rule, candidates: [URL], reason: RunTrigger, bypassBulkGuard: Bool = false) async -> RunSummary {
        let summaries = await run(rules: [rule], candidates: candidates, reason: reason, bypassBulkGuard: bypassBulkGuard)
        return summaries.first ?? RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: environment.now())
    }

    /// Runs several rules on the same files in dashboard order (D5). If a rule
    /// moves or trashes a file, later rules skip it. "Stop processing other
    /// rules" ends the chain for files that rule matched. Disabled rules and
    /// all automatic runs while paused are skipped. Returns one summary per
    /// rule that ran, in order. A rule over the bulk threshold is held back
    /// and its summary carries `pendingApproval`.
    public func run(rules: [Rule], candidates: [URL], reason: RunTrigger, bypassBulkGuard: Bool = false) async -> [RunSummary] {
        await run(rules: rules, candidates: candidates, reason: reason, bypassBulkGuard: bypassBulkGuard, suppressed: [:], chains: nil)
    }

    /// `suppressed` maps a candidate's canonical path to the rule that just
    /// produced it; that rule skips it (spec §5.4). `chains` maps canonical
    /// paths to loop-guard chain keys; pass it for file-event runs.
    func run(
        rules: [Rule],
        candidates: [URL],
        reason: RunTrigger,
        bypassBulkGuard: Bool,
        suppressed: [String: UUID],
        chains: [String: String]?
    ) async -> [RunSummary] {
        let startedAt = environment.now()
        if isPaused && reason != .manual { return [] }
        let eligible = rules
            .filter { reason == .manual || $0.isEnabled }
            .filter { !$0.containsUnknownElements && $0.trigger != .fileRemoved && !$0.emptiesTrash }
            .sorted { $0.order < $1.order }
        guard !eligible.isEmpty else { return [] }

        eligible.forEach { running.insert($0.id) }
        defer { eligible.forEach { running.remove($0.id) } }

        var scopedRules: [Rule] = []
        var ruleErrors: [UUID: [String]] = [:]
        var held: [UUID: BulkApprovalRequest] = [:]
        for rule in eligible {
            let (healthy, errors) = await checkFolders(rule, reason: reason, startedAt: startedAt)
            var scoped = rule
            scoped.scope = healthy
            ruleErrors[rule.id] = errors
            if !bypassBulkGuard,
               let request = await bulkRequest(for: scoped, candidates: candidates, reason: reason, keepCandidates: true) {
                held[rule.id] = request
                continue
            }
            scopedRules.append(scoped)
        }

        var summaries: [UUID: RunSummary] = [:]
        if !scopedRules.isEmpty {
            (summaries, _) = await process(rules: scopedRules, candidates: candidates, reason: reason, suppressed: suppressed, chains: chains)
        }
        let finishedAt = environment.now()
        return eligible.map { rule in
            var summary = summaries[rule.id] ?? RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
            summary.startedAt = startedAt
            summary.finishedAt = finishedAt
            summary.ruleErrors = ruleErrors[rule.id] ?? []
            summary.pendingApproval = held[rule.id]
            return summary
        }
    }

    // MARK: - Empty Trash

    /// Runs an Empty Trash rule: one call for the whole Trash, one activity
    /// entry. Folders, conditions, processed records, and the bulk guard do
    /// not apply.
    private func emptyTrash(_ rule: Rule, reason: RunTrigger, note: String?, startedAt: Date) async -> RunSummary {
        var summary = RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
        summary.note = note
        let trashPath = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.path ?? ""
        var record = ActivityRecord(
            timestamp: startedAt,
            ruleID: rule.id,
            ruleName: rule.name,
            action: Action.emptyTrash.displayName,
            sourcePath: trashPath,
            result: .success,
            detail: note ?? "",
            runTrigger: reason
        )
        do {
            let count = try await environment.emptyTrash()
            summary.matched = count
            summary.actedOn = count
            summary.dominantVerb = Action.emptyTrash.pastTenseVerb
            if count == 0 {
                record.result = .skipped
                record.message = localized("The Trash was already empty")
            } else {
                record.message = count == 1 ? localized("Deleted 1 item") : localized("Deleted \(count) items")
            }
            if case .error = statuses[rule.id] { statuses[rule.id] = nil }
        } catch {
            let message = error.localizedDescription
            summary.ruleErrors = [message]
            record.result = .failed
            record.message = message
            statuses[rule.id] = .error(message)
        }
        summary.finishedAt = environment.now()
        await log([record])
        return summary
    }

    // MARK: - Bulk guard

    /// Creates a bulk approval request if the rule would act on more files
    /// than the threshold (spec §5.6). Automatic runs also emit it as an
    /// event; manual runs return it to the caller.
    private func bulkRequest(
        for rule: Rule,
        candidates: [URL],
        reason: RunTrigger,
        keepCandidates: Bool
    ) async -> BulkApprovalRequest? {
        let threshold = configuration.bulkThreshold
        let covered = candidates.filter { FolderScanner.rule(rule, covers: $0) }
        guard covered.count > threshold else { return nil }
        let count = await actionableCount(rule, candidates: covered)
        guard count > threshold else { return nil }
        let request = BulkApprovalRequest(ruleID: rule.id, ruleName: rule.name, fileCount: count, trigger: reason)
        pendingBulk[request.id] = (request, keepCandidates ? covered : nil)
        if reason != .manual { emit(.bulkApprovalRequested(request)) }
        return request
    }

    /// Files among `candidates` the rule would act on now: covered, not
    /// ignored, matching, and not already processed.
    func actionableCount(_ rule: Rule, candidates: [URL]) async -> Int {
        let now = environment.now()
        let filter = IgnoreFilter(includeHidden: rule.options.includeHidden)
        var count = 0
        for url in candidates where FolderScanner.rule(rule, covers: url) && !filter.isIgnored(url) {
            guard let snapshot = try? FileSnapshot(reading: url),
                  evaluator.matches(rule.conditions, snapshot: snapshot, now: now)
            else { continue }
            let processed = (try? await processedStore.isProcessed(
                ruleID: rule.id, fileKey: snapshot.fileKey, modifiedAt: snapshot.dateModified ?? .distantPast
            )) ?? false
            if !processed { count += 1 }
        }
        return count
    }

    public var pendingBulkRequests: [BulkApprovalRequest] {
        pendingBulk.values.map(\.request)
    }

    /// Answers a bulk prompt. Run returns the summary of the run, which
    /// skips the guard; Cancel drops the request and returns nil.
    public func resolveBulkApproval(_ requestID: UUID, approve: Bool) async -> RunSummary? {
        guard let pending = pendingBulk.removeValue(forKey: requestID), approve,
              let rule = rules.first(where: { $0.id == pending.request.ruleID })
        else { return nil }
        let summary: RunSummary
        if let candidates = pending.candidates {
            summary = await run(rule: rule, candidates: candidates, reason: pending.request.trigger, bypassBulkGuard: true)
        } else {
            summary = await scanAndRun(rule, reason: pending.request.trigger, bypassBulkGuard: true)
        }
        return summary
    }

    // MARK: - Pipeline

    /// Checks each scope folder. Returns the usable folders and error text for
    /// the rest. Logs a rule-level entry only when the status changes, so a
    /// missing folder does not fill the log on every run.
    private func checkFolders(_ rule: Rule, reason: RunTrigger, startedAt: Date) async -> ([FolderRef], [String]) {
        var healthy: [FolderRef] = []
        var errors: [String] = []
        var newStatus: RuleStatus?
        var unavailable: String?
        for folder in rule.scope {
            switch FolderHealth.check(folder) {
            case .ok:
                healthy.append(folder)
            case .unavailable:
                // Unmounted volume: skip quietly, no log entry (spec §11).
                unavailable = unavailable ?? folder.tildeAbbreviated()
            case .missing:
                let path = folder.tildeAbbreviated()
                errors.append(localized("Folder missing: \(path)"))
                newStatus = newStatus ?? .folderMissing(path)
            case .noPermission:
                let path = folder.tildeAbbreviated()
                errors.append(localized("No permission: \(path)"))
                newStatus = newStatus ?? .noPermission(path)
            }
        }
        if let newStatus {
            if statuses[rule.id] != newStatus {
                statuses[rule.id] = newStatus
                await log(errors.map { message in
                    ActivityRecord(
                        timestamp: startedAt,
                        ruleID: rule.id,
                        ruleName: rule.name,
                        action: localized("Check folders"),
                        sourcePath: rule.scope.first?.path ?? "",
                        result: .failed,
                        message: message,
                        runTrigger: reason
                    )
                })
            }
        } else if let unavailable {
            statuses[rule.id] = .folderUnavailable(unavailable)
        } else if let status = statuses[rule.id] {
            switch status {
            case .folderMissing, .noPermission, .folderUnavailable: statuses[rule.id] = nil
            case .ok, .error: break
            }
        }
        return (healthy, errors)
    }

    /// Processes candidates with up to `maxConcurrentFiles` files at a time.
    /// Returns summaries by rule ID and the file keys of every candidate seen.
    private func process(
        rules: [Rule],
        candidates: [URL],
        reason: RunTrigger,
        note: String? = nil,
        suppressed: [String: UUID] = [:],
        chains: [String: String]? = nil
    ) async -> ([UUID: RunSummary], Set<String>) {
        let startedAt = environment.now()
        var summaries: [UUID: RunSummary] = [:]
        var verbs: [UUID: [String]] = [:]
        for rule in rules {
            summaries[rule.id] = RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
        }
        var seenKeys: Set<String> = []
        var records: [ActivityRecord] = []
        var failures: [UUID: String] = [:]
        var permissionDenied: [UUID: String] = [:]
        var loops: [LoopAlert] = []

        let context = FileContext(
            executor: executor,
            evaluator: evaluator,
            processedStore: processedStore,
            now: environment.now,
            reason: reason,
            suppressed: suppressed
        )
        let limit = max(1, configuration.maxConcurrentFiles)

        await withTaskGroup(of: FileWork.self) { group in
            var pending = candidates.makeIterator()
            for _ in 0..<limit {
                guard let url = pending.next() else { break }
                group.addTask { await RuleEngine.processFile(url, rules: rules, context: context) }
            }
            for await work in group {
                if let url = pending.next() {
                    group.addTask { await RuleEngine.processFile(url, rules: rules, context: context) }
                }
                // Record output as soon as each file finishes so file events
                // for it are recognized as the engine's own (Phase 3).
                let now = environment.now()
                for (ruleID, url) in work.produced {
                    selfChanges.record(url, ruleID: ruleID, now: now)
                }
                if let chains, let chain = chains[FolderScanner.canonicalPath(work.source)] {
                    for (_, url) in work.produced {
                        loopGuard.noteProduced(url, chain: chain, now: now)
                    }
                    let acted = rules.map(\.id).filter { work.results[$0]?.kind == .actedOn }
                    if let involved = loopGuard.record(chain, ruleIDs: acted, now: now) {
                        let names = involved.compactMap { id in rules.first { $0.id == id }?.name }
                        loops.append(LoopAlert(ruleIDs: involved, ruleNames: names, filePath: work.source.path))
                    }
                }
                if let key = work.fileKey { seenKeys.insert(key) }
                records += work.records
                failures.merge(work.failures) { first, _ in first }
                permissionDenied.merge(work.permissionDenied) { first, _ in first }
                for (ruleID, result) in work.results {
                    summaries[ruleID]?.add(result)
                    if let verb = result.verb { verbs[ruleID, default: []].append(verb) }
                }
            }
        }

        if let note {
            for index in records.indices { records[index].detail = note }
        }
        for alert in loops {
            records.append(ActivityRecord(
                timestamp: environment.now(),
                ruleID: alert.ruleIDs.first ?? rules.first?.id ?? UUID(),
                ruleName: alert.ruleNames.first ?? "",
                action: localized("Loop guard"),
                sourcePath: alert.filePath,
                result: .failed,
                message: alert.message,
                runTrigger: reason
            ))
        }
        await log(records)
        loops.forEach { emit(.loopDetected($0)) }

        for rule in rules {
            summaries[rule.id]?.dominantVerb = RuleEngine.dominantVerb(verbs[rule.id] ?? [])
            if let path = permissionDenied[rule.id] {
                statuses[rule.id] = .noPermission(path)
            } else if let message = failures[rule.id] {
                statuses[rule.id] = .error(message)
            } else if summaries[rule.id]?.actedOn ?? 0 > 0, case .error = statuses[rule.id] {
                // Error badge clears on the next successful run (spec §13).
                statuses[rule.id] = nil
            }
        }
        return (summaries, seenKeys)
    }

    func log(_ records: [ActivityRecord]) async {
        guard !records.isEmpty else { return }
        try? await activityStore.add(records)
    }

    static func dominantVerb(_ verbs: [String]) -> String? {
        guard let first = verbs.first else { return nil }
        return verbs.allSatisfy { $0 == first } ? first : localized("processed")
    }

    // MARK: - One file

    struct FileContext: Sendable {
        var executor: ActionExecutor
        var evaluator: ConditionEvaluator
        var processedStore: ProcessedStore
        var now: @Sendable () -> Date
        var reason: RunTrigger
        /// Canonical candidate path → rule that produced it (spec §5.4).
        var suppressed: [String: UUID] = [:]
    }

    /// Runs every applicable rule on one file, serially, in order.
    static func processFile(_ url: URL, rules: [Rule], context: FileContext) async -> FileWork {
        var work = FileWork(source: url)
        var current = url
        let producer = context.suppressed.isEmpty ? nil : context.suppressed[FolderScanner.canonicalPath(url)]
        for rule in rules {
            // A rule never re-triggers on its own output; other rules do.
            if rule.id == producer, current == url { continue }
            guard FolderScanner.rule(rule, covers: current) else { continue }
            if IgnoreFilter(includeHidden: rule.options.includeHidden).isIgnored(current) { continue }
            // The file may have vanished since it was listed. Nothing to do.
            guard let snapshot = try? FileSnapshot(reading: current) else { break }
            if work.fileKey == nil { work.fileKey = snapshot.fileKey }

            let startedAt = context.now()
            guard context.evaluator.matches(rule.conditions, snapshot: snapshot, now: startedAt) else { continue }

            var result = FileResult(kind: .actedOn)
            let modifiedAt = snapshot.dateModified ?? .distantPast
            let processed = (try? await context.processedStore.isProcessed(
                ruleID: rule.id, fileKey: snapshot.fileKey, modifiedAt: modifiedAt
            )) ?? false
            if processed {
                result.kind = .skippedProcessed
                work.results[rule.id] = result
                if rule.options.stopOtherRules { break }
                continue
            }

            var location: URL? = current
            var verbs: [(verb: String, isSideEffect: Bool)] = []
            for action in rule.actions {
                guard let at = location else { break }
                let outcome = await context.executor.execute(action, on: at, rule: rule)
                work.records.append(ActivityRecord(
                    timestamp: startedAt,
                    ruleID: rule.id,
                    ruleName: rule.name,
                    action: action.displayName,
                    sourcePath: at.path,
                    destinationPath: outcome.destinationPath,
                    result: outcome.result,
                    message: outcome.message,
                    runTrigger: context.reason
                ))
                work.produced += outcome.producedURLs.map { (rule.id, $0) }
                if outcome.permissionDenied {
                    work.permissionDenied[rule.id] = at.deletingLastPathComponent().path
                }
                location = outcome.currentURL
                if outcome.result == .success {
                    verbs.append((action.pastTenseVerb, action.isSideEffectOnly))
                    continue
                }
                // A failed or skipped action stops the rest of the chain.
                if outcome.result == .failed {
                    result.kind = .failed
                    work.failures[rule.id] = outcome.message ?? localized("Action failed")
                } else {
                    result.kind = .skippedOther
                }
                break
            }
            result.verb = (verbs.last(where: { !$0.isSideEffect }) ?? verbs.last)?.verb

            if result.kind != .failed {
                // Record the current modification date so a later edit makes
                // the file eligible again (D6). Failed files retry next run.
                var recordDate = modifiedAt
                if let location, let refreshed = try? FileSnapshot(reading: location).dateModified {
                    recordDate = max(recordDate, refreshed)
                }
                try? await context.processedStore.markProcessed(
                    ruleID: rule.id, fileKey: snapshot.fileKey, modifiedAt: recordDate
                )
            }
            work.results[rule.id] = result

            // D5: once a rule moves or trashes the file, later rules skip it.
            guard let location,
                  FolderScanner.canonicalPath(location.deletingLastPathComponent())
                    == FolderScanner.canonicalPath(current.deletingLastPathComponent())
            else { break }
            current = location
            if rule.options.stopOtherRules { break }
        }
        return work
    }

    struct FileWork: Sendable {
        var source: URL
        var fileKey: String?
        var results: [UUID: FileResult] = [:]
        var records: [ActivityRecord] = []
        var produced: [(UUID, URL)] = []
        var failures: [UUID: String] = [:]
        var permissionDenied: [UUID: String] = [:]
    }

    struct FileResult: Sendable {
        enum Kind: Sendable { case actedOn, skippedProcessed, skippedOther, failed }
        var kind: Kind
        var verb: String?
    }
}

extension RunSummary {
    mutating func add(_ result: RuleEngine.FileResult) {
        matched += 1
        switch result.kind {
        case .actedOn: actedOn += 1
        case .skippedProcessed: skippedProcessed += 1
        case .skippedOther: skippedOther += 1
        case .failed: failed += 1
        }
    }
}

extension Action {
    /// Actions that do not change the file (open, reveal, notify). Summaries
    /// prefer the verb of a real file change.
    var isSideEffectOnly: Bool {
        switch self {
        case .open, .revealInFinder, .notify: return true
        default: return false
        }
    }
}
