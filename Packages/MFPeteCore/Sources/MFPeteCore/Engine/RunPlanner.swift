import Foundation

/// Predicts what a rule would do without touching the file system (Preview).
/// Reuses the evaluator, pattern renderer, and conflict resolver, with a
/// virtual overlay so files planned earlier in the run count as existing.
struct RunPlanner {
    var evaluator: ConditionEvaluator
    var renderer: PatternRenderer
    var now: Date

    /// Paths planned to appear, and paths planned to go away.
    private var added: Set<String> = []
    private var removed: Set<String> = []

    init(evaluator: ConditionEvaluator, renderer: PatternRenderer, now: Date) {
        self.evaluator = evaluator
        self.renderer = renderer
        self.now = now
    }

    mutating func plan(_ snapshot: FileSnapshot, rule: Rule) -> [PlannedStep] {
        var steps: [PlannedStep] = []
        var current: FileSnapshot? = snapshot
        for action in rule.actions {
            guard let file = current else { break }
            let (step, next) = simulate(action, file)
            steps.append(step)
            current = next
            if case .willSucceed = step.outcome { continue }
            break
        }
        return steps
    }

    private mutating func simulate(_ action: Action, _ file: FileSnapshot) -> (PlannedStep, FileSnapshot?) {
        let url = file.url
        func step(_ destination: URL?, _ outcome: PlannedStep.Outcome = .willSucceed) -> PlannedStep {
            PlannedStep(action: action, destination: destination, outcome: outcome)
        }
        func fail(_ error: ActionError) -> (PlannedStep, FileSnapshot?) {
            (step(nil, .willFail(error.errorDescription ?? "")), nil)
        }

        switch action {
        case .move(let folder, let policy):
            guard folderExists(folder.url) else { return fail(.destinationMissing(folder.tildeAbbreviated())) }
            return place(file, in: folder.url, named: file.fullName, policy: policy, copy: false, step: step)

        case .copy(let folder, let policy):
            guard folderExists(folder.url) else { return fail(.destinationMissing(folder.tildeAbbreviated())) }
            return place(file, in: folder.url, named: file.fullName, policy: policy, copy: true, step: step)

        case .rename(let pattern, let policy):
            let folder = url.deletingLastPathComponent()
            if PatternRenderer.containsCounter(pattern) {
                var counter = 1
                while true {
                    let name = renderer.render(pattern, snapshot: file, now: now, counter: counter)
                    guard !name.isEmpty else { return fail(.emptyName) }
                    let target = folder.appendingPathComponent(name)
                    if ActionExecutor.samePath(url, target) || !exists(target) {
                        return relocate(file, to: target, step: step)
                    }
                    counter += 1
                }
            }
            let name = renderer.render(pattern, snapshot: file, now: now)
            guard !name.isEmpty else { return fail(.emptyName) }
            return place(file, in: folder, named: name, policy: policy, copy: false, step: step)

        case .changeExtension(let newExtension):
            let ext = ConditionEvaluator.normalizeExtension(newExtension)
            let name = ext.isEmpty ? file.name : "\(file.name).\(ext)"
            return place(file, in: url.deletingLastPathComponent(), named: name, policy: .keepBoth, copy: false, step: step)

        case .trash:
            markRemoved(url)
            return (step(nil), nil)

        case .sortIntoSubfolder(let base, let pattern):
            guard folderExists(base.url) else { return fail(.destinationMissing(base.tildeAbbreviated())) }
            var folder = base.url
            for segment in renderer.renderPathSegments(pattern, snapshot: file, now: now) {
                folder.appendPathComponent(segment, isDirectory: true)
                markAdded(folder)
            }
            return place(file, in: folder, named: file.fullName, policy: .keepBoth, copy: false, step: step)

        case .unarchive(let destination, let trashArchive):
            guard file.fileExtension.lowercased() == "zip", !file.isDirectory else { return fail(.unsupportedArchive) }
            let folder = destination?.url ?? url.deletingLastPathComponent()
            if let destination, !folderExists(folder) {
                return fail(.destinationMissing(destination.tildeAbbreviated()))
            }
            if trashArchive {
                markRemoved(url)
                return (step(folder), nil)
            }
            return (step(folder), file)

        case .addTags, .removeTags, .open, .revealInFinder, .notify:
            return (step(url), file)

        case .unknown:
            return (step(nil, .willFail(localized("Unknown action"))), nil)
        }
    }

    private mutating func place(
        _ file: FileSnapshot,
        in folder: URL,
        named name: String,
        policy: ConflictPolicy,
        copy: Bool,
        step: (URL?, PlannedStep.Outcome) -> PlannedStep
    ) -> (PlannedStep, FileSnapshot?) {
        let target = folder.appendingPathComponent(name, isDirectory: file.isDirectory)
        if !copy, ActionExecutor.samePath(file.url, target) {
            return (step(target, .willSucceed), file)
        }
        switch resolver.resolve(destination: target, policy: policy) {
        case .skip:
            return (step(nil, .willSkip(localized("Skipped: name exists"))), file)
        case .replaceAfterTrashing(let destination), .proceed(let destination):
            if copy {
                markAdded(destination)
                return (step(destination, .willSucceed), file)
            }
            return relocate(file, to: destination, step: step)
        }
    }

    private mutating func relocate(
        _ file: FileSnapshot,
        to destination: URL,
        step: (URL?, PlannedStep.Outcome) -> PlannedStep
    ) -> (PlannedStep, FileSnapshot?) {
        markRemoved(file.url)
        markAdded(destination)
        return (step(destination, .willSucceed), file.relocated(to: destination))
    }

    // MARK: - Virtual file system

    private var resolver: ConflictResolver {
        let added = added, removed = removed
        return ConflictResolver { url in
            let path = RunPlanner.key(url)
            if added.contains(path) { return true }
            if removed.contains(path) { return false }
            return ConflictResolver.diskItemExists(url)
        }
    }

    private func exists(_ url: URL) -> Bool {
        resolver.itemExists(url)
    }

    private func folderExists(_ url: URL) -> Bool {
        if added.contains(RunPlanner.key(url)) { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private mutating func markAdded(_ url: URL) {
        let path = RunPlanner.key(url)
        added.insert(path)
        removed.remove(path)
    }

    private mutating func markRemoved(_ url: URL) {
        let path = RunPlanner.key(url)
        removed.insert(path)
        added.remove(path)
    }

    private static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

extension RuleEngine {
    /// Dry run for Preview (spec §8.3): matching files in the rule's scope and
    /// each planned step with predicted destinations. Makes no changes.
    public func plan(rule: Rule) async -> [PlannedFileResult] {
        let now = environment.now()
        var planner = RunPlanner(evaluator: evaluator, renderer: executor.renderer, now: now)
        var results: [PlannedFileResult] = []
        for folder in rule.scope where FolderHealth.check(folder) == .ok {
            for url in FolderScanner.candidates(in: folder, options: rule.options) {
                guard let snapshot = try? FileSnapshot(reading: url),
                      planner.evaluator.matches(rule.conditions, snapshot: snapshot, now: now)
                else { continue }
                let processed = (try? await processedStore.isProcessed(
                    ruleID: rule.id,
                    fileKey: snapshot.fileKey,
                    modifiedAt: snapshot.dateModified ?? .distantPast
                )) ?? false
                // Already processed files are listed but not simulated, since
                // a real run leaves them alone.
                let steps = processed ? [] : planner.plan(snapshot, rule: rule)
                results.append(PlannedFileResult(file: url, alreadyProcessed: processed, steps: steps))
            }
        }
        return results
    }
}
