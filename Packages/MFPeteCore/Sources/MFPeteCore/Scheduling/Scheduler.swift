import Foundation

/// Fire-date math for schedule triggers (spec §3.2). Pure functions so DST
/// and missed-run cases can be tested with a fixed calendar and clock.
public struct Scheduler: Sendable {
    public var calendar: Calendar

    /// A run counts as late, and is logged "Ran late", when it starts more
    /// than this long after its scheduled time.
    public static let lateTolerance: TimeInterval = 60

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The first fire time strictly after `date`. Nil for file-event
    /// triggers and for weekly triggers with no days.
    public func nextFireDate(for trigger: Trigger, after date: Date) -> Date? {
        switch trigger {
        case .fileAdded, .fileModified, .fileRemoved:
            return nil
        case .interval(let minutes):
            let minutes = max(minutes, Trigger.minimumIntervalMinutes)
            return date.addingTimeInterval(TimeInterval(minutes) * 60)
        case .daily(let hour, let minute, let days) where days > 1:
            // Count from the time slot of the last run (a late run counts
            // from the time it missed), so the time of day never drifts.
            let time = DateComponents(hour: hour, minute: minute, second: 0)
            guard let slot = previous(before: date, matching: time),
                  let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: slot))
            else { return next(after: date, matching: time) }
            return next(after: day.addingTimeInterval(-1), matching: time)
        case .daily(let hour, let minute, _):
            return next(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0))
        case .weekly(let weekdays, let hour, let minute):
            return weekdays
                .compactMap { next(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: $0)) }
                .min()
        }
    }

    /// The latest fire time at or before `date`, used to name a missed run
    /// ("missed 09:00"). Interval triggers and every-few-days triggers have
    /// no fixed times without a last run, so nil.
    public func previousFireDate(for trigger: Trigger, onOrBefore date: Date) -> Date? {
        switch trigger {
        case .fileAdded, .fileModified, .fileRemoved, .interval:
            return nil
        case .daily(_, _, let days) where days > 1:
            return nil
        case .daily(let hour, let minute, _):
            return previous(before: date, matching: DateComponents(hour: hour, minute: minute, second: 0))
        case .weekly(let weekdays, let hour, let minute):
            return weekdays
                .compactMap { previous(before: date, matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: $0)) }
                .max()
        }
    }

    /// What to do for a schedule rule at `now`, given when it last ran.
    public func decision(for trigger: Trigger, lastRun: Date, now: Date) -> Decision {
        guard let due = nextFireDate(for: trigger, after: lastRun) else { return .notScheduled }
        guard due <= now else { return .wait(until: due) }
        // Several fire times may have passed while asleep or closed. Run once
        // (no backlog) and name the most recent one.
        let missed = previousFireDate(for: trigger, onOrBefore: now) ?? latestFireDate(for: trigger, from: due, onOrBefore: now)
        if now.timeIntervalSince(missed) > Scheduler.lateTolerance {
            return .runLate(missed: missed)
        }
        return .run
    }

    /// The last run to record for a rule that has never run, so its first
    /// run is the next scheduled time. An every-few-days rule counts back so
    /// it does not wait several days for its first run.
    public func initialLastRun(for trigger: Trigger, now: Date) -> Date {
        guard case .daily(_, _, let days) = trigger, days > 1,
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: now)
        else { return now }
        return start
    }

    /// For every-few-days triggers: steps from `due` to the latest fire time
    /// at or before `now`. Other triggers keep `due`.
    private func latestFireDate(for trigger: Trigger, from due: Date, onOrBefore now: Date) -> Date {
        guard case .daily(_, _, let days) = trigger, days > 1 else { return due }
        var latest = due
        while let next = nextFireDate(for: trigger, after: latest), next <= now {
            latest = next
        }
        return latest
    }

    public enum Decision: Hashable, Sendable {
        case notScheduled
        case wait(until: Date)
        case run
        /// The scheduled time passed while the Mac slept or the app was closed.
        case runLate(missed: Date)
    }

    private func next(after date: Date, matching components: DateComponents) -> Date? {
        // `.nextTime` maps a time skipped by a DST jump to the next valid
        // time; `.first` picks the first of a repeated hour.
        calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    private func previous(before date: Date, matching components: DateComponents) -> Date? {
        // Searching backward from just after `date` includes `date` itself.
        calendar.nextDate(
            after: date.addingTimeInterval(1),
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .backward
        )
    }
}
