import Foundation

/// Runaway protection (spec §5.6): one file may pass through at most
/// `limit` rule runs within `window` seconds. A file keeps its chain across
/// moves (same file key) and across copies the engine makes (lineage), so
/// two rules copying a file back and forth also trip the guard.
struct LoopGuard: Sendable {
    var limit: Int
    var window: TimeInterval

    private var runs: [String: [(date: Date, ruleID: UUID)]] = [:]
    private var blockedUntil: [String: Date] = [:]
    /// Canonical path of engine output → chain key of the file it came from.
    private var lineage: [String: (chain: String, expires: Date)] = [:]

    init(limit: Int = 10, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// The chain a candidate belongs to: its source's chain if the engine
    /// produced it recently, else its own file key.
    mutating func chainKey(for url: URL, fileKey: String, now: Date) -> String {
        lineage = lineage.filter { $0.value.expires > now }
        return lineage[FolderScanner.canonicalPath(url)]?.chain ?? fileKey
    }

    mutating func noteProduced(_ url: URL, chain: String, now: Date) {
        lineage[FolderScanner.canonicalPath(url)] = (chain, now.addingTimeInterval(window))
    }

    func isBlocked(_ chain: String, now: Date) -> Bool {
        (blockedUntil[chain] ?? .distantPast) > now
    }

    /// Records rule runs on a chain. Returns the rules involved, in first-run
    /// order, the moment the chain goes over the limit; nil otherwise.
    mutating func record(_ chain: String, ruleIDs: [UUID], now: Date) -> [UUID]? {
        guard !ruleIDs.isEmpty else { return nil }
        let cutoff = now.addingTimeInterval(-window)
        var entries = (runs[chain] ?? []).filter { $0.date > cutoff }
        entries += ruleIDs.map { (now, $0) }
        runs[chain] = entries
        prune(cutoff: cutoff)

        guard entries.count > limit, !isBlocked(chain, now: now) else { return nil }
        blockedUntil[chain] = now.addingTimeInterval(window)
        var seen: Set<UUID> = []
        return entries.map(\.ruleID).filter { seen.insert($0).inserted }
    }

    private mutating func prune(cutoff: Date) {
        if runs.count > 1_000 {
            runs = runs.filter { $0.value.contains { $0.date > cutoff } }
        }
        if blockedUntil.count > 100 {
            blockedUntil = blockedUntil.filter { $0.value > cutoff }
        }
    }
}
