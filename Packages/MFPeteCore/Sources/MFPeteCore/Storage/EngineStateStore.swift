import Foundation

/// Small engine state that must survive relaunch: the last FSEvents event ID
/// (spec §5.1) and when each schedule rule last ran (spec §3.2).
public protocol EngineStateStore: Sendable {
    func lastEventID() -> UInt64?
    func setLastEventID(_ id: UInt64)
    func lastScheduledRun(ruleID: UUID) -> Date?
    func setLastScheduledRun(_ date: Date?, ruleID: UUID)
    /// Drops schedule records for rules that no longer exist.
    func keepScheduledRuns(for ruleIDs: Set<UUID>)
}

/// `UserDefaults`-backed state for the app. `UserDefaults` is thread-safe.
public final class UserDefaultsEngineState: EngineStateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let eventIDKey = "engine.lastFSEventID"
    private static let scheduledRunsKey = "engine.lastScheduledRuns"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func lastEventID() -> UInt64? {
        // Stored as a string: property lists have no unsigned 64-bit type.
        defaults.string(forKey: Self.eventIDKey).flatMap(UInt64.init)
    }

    public func setLastEventID(_ id: UInt64) {
        defaults.set(String(id), forKey: Self.eventIDKey)
    }

    public func lastScheduledRun(ruleID: UUID) -> Date? {
        scheduledRuns()[ruleID.uuidString].map(Date.init(timeIntervalSinceReferenceDate:))
    }

    public func setLastScheduledRun(_ date: Date?, ruleID: UUID) {
        var runs = scheduledRuns()
        runs[ruleID.uuidString] = date?.timeIntervalSinceReferenceDate
        defaults.set(runs, forKey: Self.scheduledRunsKey)
    }

    public func keepScheduledRuns(for ruleIDs: Set<UUID>) {
        let keep = Set(ruleIDs.map(\.uuidString))
        let runs = scheduledRuns()
        let kept = runs.filter { keep.contains($0.key) }
        if kept.count != runs.count {
            defaults.set(kept, forKey: Self.scheduledRunsKey)
        }
    }

    private func scheduledRuns() -> [String: Double] {
        defaults.dictionary(forKey: Self.scheduledRunsKey) as? [String: Double] ?? [:]
    }
}

/// In-memory state for tests and headless use.
public final class InMemoryEngineState: EngineStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var eventID: UInt64?
    private var runs: [UUID: Date] = [:]

    public init(lastEventID: UInt64? = nil) {
        self.eventID = lastEventID
    }

    public func lastEventID() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return eventID
    }

    public func setLastEventID(_ id: UInt64) {
        lock.lock(); eventID = id; lock.unlock()
    }

    public func lastScheduledRun(ruleID: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return runs[ruleID]
    }

    public func setLastScheduledRun(_ date: Date?, ruleID: UUID) {
        lock.lock(); runs[ruleID] = date; lock.unlock()
    }

    public func keepScheduledRuns(for ruleIDs: Set<UUID>) {
        lock.lock(); runs = runs.filter { ruleIDs.contains($0.key) }; lock.unlock()
    }
}
