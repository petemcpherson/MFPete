import Foundation

/// Remembers paths the engine just created or changed, and which rule did it,
/// for a short time. Phase 3 uses this to keep a rule from re-triggering on
/// its own output while other rules still see the item as added (spec §5.4).
public struct SelfChangeTracker: Sendable {
    public var ttl: TimeInterval
    private var entries: [String: (ruleID: UUID, expires: Date)] = [:]

    public init(ttl: TimeInterval = 10) {
        self.ttl = ttl
    }

    public mutating func record(_ url: URL, ruleID: UUID, now: Date) {
        entries[FolderScanner.canonicalPath(url)] = (ruleID, now.addingTimeInterval(ttl))
    }

    /// The rule that produced the item at `url`, if the record is still fresh.
    public mutating func producer(of url: URL, now: Date) -> UUID? {
        prune(now: now)
        return entries[FolderScanner.canonicalPath(url)]?.ruleID
    }

    public mutating func prune(now: Date) {
        entries = entries.filter { $0.value.expires > now }
    }

    public var count: Int { entries.count }
}
