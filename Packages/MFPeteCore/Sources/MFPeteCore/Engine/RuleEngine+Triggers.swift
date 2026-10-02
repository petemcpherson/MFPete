import Foundation

/// Trigger routing (spec §3.1, §5.4): settled file events, removed files,
/// apply-to-existing, and processed-record resets.
extension RuleEngine {
    /// Runs file-event rules on settled files. "File added" rules get
    /// `added`; "File modified" rules get `modified`. A rule skips items it
    /// just produced, while other rules see them as added (chaining). Edits
    /// the engine itself made never count as modifications. The loop guard
    /// drops files whose chain went over the limit.
    public func handleFileEvents(added: [URL], modified: [URL]) async -> [RunSummary] {
        guard !isPaused else { return [] }
        let now = environment.now()
        var summaries: [RunSummary] = []

        let addedRules = rules.filter { $0.trigger == .fileAdded }
        if !added.isEmpty, !addedRules.isEmpty {
            var suppressed: [String: UUID] = [:]
            for url in added {
                if let producer = selfChangeProducer(of: url) {
                    suppressed[FolderScanner.canonicalPath(url)] = producer
                }
            }
            let (candidates, chains) = loopChains(for: added, now: now)
            summaries += await run(
                rules: addedRules, candidates: candidates, reason: .fileEvent,
                bypassBulkGuard: false, suppressed: suppressed, chains: chains
            )
        }

        let modifiedRules = rules.filter { $0.trigger == .fileModified }
        if !modified.isEmpty, !modifiedRules.isEmpty {
            let external = modified.filter { selfChangeProducer(of: $0) == nil }
            let (candidates, chains) = loopChains(for: external, now: now)
            if !candidates.isEmpty {
                summaries += await run(
                    rules: modifiedRules, candidates: candidates, reason: .fileEvent,
                    bypassBulkGuard: false, suppressed: [:], chains: chains
                )
            }
        }
        return summaries
    }

    /// Chain keys for loop-guard bookkeeping, minus files whose chain is
    /// blocked. Files that vanished are dropped too.
    private func loopChains(for urls: [URL], now: Date) -> ([URL], [String: String]) {
        var kept: [URL] = []
        var chains: [String: String] = [:]
        for url in urls {
            guard let snapshot = try? FileSnapshot(reading: url) else { continue }
            let chain = loopGuard.chainKey(for: url, fileKey: snapshot.fileKey, now: now)
            if loopGuard.isBlocked(chain, now: now) { continue }
            kept.append(url)
            chains[FolderScanner.canonicalPath(url)] = chain
        }
        return (kept, chains)
    }

    /// "File removed" rules (spec §3.1). The file is gone, so only name,
    /// extension, kind-by-extension, and path conditions can match, and only
    /// "Show notification" actions run. Other actions are logged as skipped.
    /// No processed records: the file has no identity left to record.
    public func handleRemoved(_ urls: [URL]) async -> [RunSummary] {
        guard !isPaused else { return [] }
        let removedRules = rules.filter { $0.trigger == .fileRemoved && $0.isEnabled && !$0.containsUnknownElements }
        guard !urls.isEmpty, !removedRules.isEmpty else { return [] }

        let startedAt = environment.now()
        var summaries: [RunSummary] = []
        var records: [ActivityRecord] = []
        for rule in removedRules {
            var summary = RunSummary(ruleID: rule.id, ruleName: rule.name, trigger: .fileEvent, startedAt: startedAt)
            let filter = IgnoreFilter(includeHidden: rule.options.includeHidden)
            for url in urls where FolderScanner.rule(rule, covers: url) && !filter.isIgnored(url) {
                // Attributes that need the file on disk stay empty, so their
                // conditions do not match.
                let snapshot = FileSnapshot(url: url)
                guard evaluator.matches(rule.conditions, snapshot: snapshot, now: startedAt) else { continue }
                summary.matched += 1
                var acted = false
                for action in rule.actions {
                    var record = ActivityRecord(
                        timestamp: startedAt,
                        ruleID: rule.id,
                        ruleName: rule.name,
                        action: action.displayName,
                        sourcePath: url.path,
                        result: .success,
                        runTrigger: .fileEvent
                    )
                    if case .notify(let message) = action {
                        let body = executor.renderer.renderText(message, snapshot: snapshot, now: startedAt)
                        await environment.notifier.showActionNotification(title: rule.name, body: body, ruleID: rule.id)
                        acted = true
                    } else {
                        record.result = .skipped
                        record.message = localized("Not available for removed files")
                    }
                    records.append(record)
                }
                if acted { summary.actedOn += 1 } else { summary.skippedOther += 1 }
            }
            if summary.actedOn > 0 { summary.dominantVerb = localized("removed") }
            summary.finishedAt = environment.now()
            summaries.append(summary)
        }
        await log(records)
        return summaries
    }

    // MARK: - Apply to existing files (spec §3.4)

    /// Files in the rule's scope that match now and are not yet processed.
    public func existingMatchCount(for rule: Rule) async -> Int {
        let folders = rule.scope.filter { FolderHealth.check($0) == .ok }
        let candidates = folders.flatMap { FolderScanner.candidates(in: $0, options: rule.options) }
        return await actionableCount(rule, candidates: candidates)
    }

    /// "Only new files": records the current matches as processed so the
    /// rule leaves them alone. Returns their file keys, so "Apply" can undo
    /// it. Unchanged files only: editing one later makes it eligible (D6).
    @discardableResult
    public func markExistingProcessed(for rule: Rule) async -> Set<String> {
        let now = environment.now()
        var keys: Set<String> = []
        for folder in rule.scope where FolderHealth.check(folder) == .ok {
            for url in FolderScanner.candidates(in: folder, options: rule.options) {
                guard let snapshot = try? FileSnapshot(reading: url),
                      evaluator.matches(rule.conditions, snapshot: snapshot, now: now)
                else { continue }
                let modified = snapshot.dateModified ?? .distantPast
                let processed = (try? await processedStore.isProcessed(
                    ruleID: rule.id, fileKey: snapshot.fileKey, modifiedAt: modified
                )) ?? false
                guard !processed else { continue }
                try? await processedStore.markProcessed(ruleID: rule.id, fileKey: snapshot.fileKey, modifiedAt: modified)
                keys.insert(snapshot.fileKey)
            }
        }
        return keys
    }

    /// "Apply": forgets the given records, then runs the rule on everything
    /// in scope. The user already confirmed, so the bulk guard is skipped.
    public func applyToExisting(_ rule: Rule, forgetting fileKeys: Set<String>) async -> RunSummary {
        try? await processedStore.remove(ruleID: rule.id, fileKeys: fileKeys)
        return await scanAndRun(rule, reason: .applyExisting, bypassBulkGuard: true)
    }

    /// "Run Again on All Files" (D6): the next run treats every file as new.
    public func resetProcessed(ruleID: UUID) async {
        try? await processedStore.reset(ruleID: ruleID)
    }

    /// Settings › Advanced › "Reset processed-file history": every rule
    /// re-evaluates existing files on its next run.
    public func resetAllProcessed() async {
        try? await processedStore.resetAll()
    }

    // MARK: - Volumes (spec §11)

    /// Marks rules with a folder on the volume as unavailable (unmounted)
    /// or clears that state (mounted). No log entries either way.
    public func setVolume(_ volumePath: String, mounted: Bool) {
        let root = FolderScanner.canonicalPath(URL(fileURLWithPath: volumePath))
        for rule in rules {
            guard let folder = rule.scope.first(where: {
                let path = FolderScanner.canonicalPath($0.url)
                return path == root || path.hasPrefix(root + "/")
            }) else { continue }
            if mounted {
                if case .folderUnavailable = status(of: rule.id) { setStatus(nil, of: rule.id) }
            } else {
                setStatus(.folderUnavailable(folder.tildeAbbreviated()), of: rule.id)
            }
        }
    }
}
