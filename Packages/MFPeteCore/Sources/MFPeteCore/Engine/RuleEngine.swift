import Foundation

/// Runs rules: lists candidates, tests conditions, performs actions, and logs
/// the results (spec §2.1). All engine state lives in this actor (D13).
public actor RuleEngine {
    public struct Configuration: Sendable {
        /// Files processed in parallel (spec §5.7). Actions on one file are serial.
        public var maxConcurrentFiles: Int
        /// How long the engine remembers its own output (spec §5.4).
        public var selfChangeTTL: TimeInterval

        public init(maxConcurrentFiles: Int = 4, selfChangeTTL: TimeInterval = 10) {
            self.maxConcurrentFiles = maxConcurrentFiles
            self.selfChangeTTL = selfChangeTTL
        }
    }

    private let activityStore: ActivityStore
    let processedStore: ProcessedStore
    let environment: ActionEnvironment
    private let configuration: Configuration
    let executor: ActionExecutor
    let evaluator: ConditionEvaluator

    /// Rules in dashboard order (D5).
    public private(set) var rules: [Rule] = []
    public private(set) var isPaused = false
    private var running: Set<UUID> = []
    private var statuses: [UUID: RuleStatus] = [:]
    private var selfChanges: SelfChangeTracker

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
        return .completed(await scanAndRun(rule, reason: .manual))
    }

    /// Full scan of the rule's scope folders. Used by Run Now and, from
    /// Phase 3, by scheduled runs and apply-to-existing.
    public func scanAndRun(_ rule: Rule, reason: RunTrigger) async -> RunSummary {
        let startedAt = environment.now()
        guard reason == .manual || (rule.isEnabled && !isPaused) else {
            return RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
        }
        running.insert(rule.id)
        defer { running.remove(rule.id) }

        let (healthy, errorSummary) = await checkFolders(rule, reason: reason, startedAt: startedAt)
        var scoped = rule
        scoped.scope = healthy
        let candidates = healthy.flatMap { FolderScanner.candidates(in: $0, options: rule.options) }

        let (summaries, seenKeys) = await process(rules: [scoped], candidates: candidates, reason: reason)
        var summary = summaries[rule.id] ?? RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
        summary.startedAt = startedAt
        summary.ruleErrors = errorSummary

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

    /// Runs one rule on the given files (file events, Phase 3).
    public func run(rule: Rule, candidates: [URL], reason: RunTrigger) async -> RunSummary {
        let summaries = await run(rules: [rule], candidates: candidates, reason: reason)
        return summaries.first ?? RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: environment.now())
    }

    /// Runs several rules on the same files in dashboard order (D5). If a rule
    /// moves or trashes a file, later rules skip it. "Stop processing other
    /// rules" ends the chain for files that rule matched. Disabled rules and
    /// all automatic runs while paused are skipped. Returns one summary per
    /// rule that ran, in order.
    public func run(rules: [Rule], candidates: [URL], reason: RunTrigger) async -> [RunSummary] {
        let startedAt = environment.now()
        if isPaused && reason != .manual { return [] }
        let eligible = rules
            .filter { reason == .manual || $0.isEnabled }
            .filter { !$0.containsUnknownElements && $0.trigger != .fileRemoved }
            .sorted { $0.order < $1.order }
        guard !eligible.isEmpty else { return [] }

        eligible.forEach { running.insert($0.id) }
        defer { eligible.forEach { running.remove($0.id) } }

        var scopedRules: [Rule] = []
        var ruleErrors: [UUID: [String]] = [:]
        for rule in eligible {
            let (healthy, errors) = await checkFolders(rule, reason: reason, startedAt: startedAt)
            var scoped = rule
            scoped.scope = healthy
            scopedRules.append(scoped)
            ruleErrors[rule.id] = errors
        }

        let (summaries, _) = await process(rules: scopedRules, candidates: candidates, reason: reason)
        let finishedAt = environment.now()
        return eligible.map { rule in
            var summary = summaries[rule.id] ?? RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: reason, startedAt: startedAt)
            summary.startedAt = startedAt
            summary.finishedAt = finishedAt
            summary.ruleErrors = ruleErrors[rule.id] ?? []
            return summary
        }
    }

    // MARK: - Pipeline

    /// Checks each scope folder. Returns the usable folders and error text for
    /// the rest. Logs a rule-level entry only when the status changes, so a
    /// missing folder does not fill the log on every run.
    private func checkFolders(_ rule: Rule, reason: RunTrigger, startedAt: Date) async -> ([FolderRef], [String]) {
        var healthy: [FolderRef] = []
        var errors: [String] = []
        var newStatus: RuleStatus?
        for folder in rule.scope {
            switch FolderHealth.check(folder) {
            case .ok:
                healthy.append(folder)
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
        } else if case .folderMissing = statuses[rule.id] {
            statuses[rule.id] = nil
        } else if case .noPermission = statuses[rule.id] {
            statuses[rule.id] = nil
        }
        return (healthy, errors)
    }

    /// Processes candidates with up to `maxConcurrentFiles` files at a time.
    /// Returns summaries by rule ID and the file keys of every candidate seen.
    private func process(rules: [Rule], candidates: [URL], reason: RunTrigger) async -> ([UUID: RunSummary], Set<String>) {
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

        let context = FileContext(
            executor: executor,
            evaluator: evaluator,
            processedStore: processedStore,
            now: environment.now,
            reason: reason
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

        await log(records)

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

    private func log(_ records: [ActivityRecord]) async {
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
    }

    /// Runs every applicable rule on one file, serially, in order.
    static func processFile(_ url: URL, rules: [Rule], context: FileContext) async -> FileWork {
        var work = FileWork()
        var current = url
        for rule in rules {
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
