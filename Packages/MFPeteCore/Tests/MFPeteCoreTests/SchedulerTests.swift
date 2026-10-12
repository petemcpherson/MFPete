import Foundation
import Testing
@testable import MFPeteCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

struct SchedulerTests {
    let utc = Scheduler(calendar: utcCalendar)
    let ny = Scheduler(calendar: newYork)

    @Test func fileEventTriggersHaveNoFireDate() {
        #expect(utc.nextFireDate(for: .fileAdded, after: testNow) == nil)
        #expect(utc.nextFireDate(for: .weekly(weekdays: [], hour: 9, minute: 0), after: testNow) == nil)
    }

    @Test func intervalAddsMinutesWithMinimum() {
        #expect(utc.nextFireDate(for: .interval(minutes: 30), after: testNow) == testNow.addingTimeInterval(30 * 60))
        #expect(utc.nextFireDate(for: .interval(minutes: 1), after: testNow) == testNow.addingTimeInterval(5 * 60))
    }

    @Test func dailyFiresLaterTodayOrTomorrow() {
        // testNow is 2026-10-01 12:00 UTC.
        #expect(utc.nextFireDate(for: .daily(hour: 18, minute: 30), after: testNow) == date(utcCalendar, 2026, 10, 1, 18, 30))
        #expect(utc.nextFireDate(for: .daily(hour: 9, minute: 0), after: testNow) == date(utcCalendar, 2026, 10, 2, 9))
        // Exactly at the fire time: the next one is tomorrow.
        #expect(utc.nextFireDate(for: .daily(hour: 12, minute: 0), after: testNow) == date(utcCalendar, 2026, 10, 2, 12))
    }

    @Test func weeklyPicksSoonestDay() {
        // 2026-09-28 is a Monday. Mon (2), Wed (4), Fri (6) at 18:00.
        let trigger = Trigger.weekly(weekdays: [2, 4, 6], hour: 18, minute: 0)
        let mondayEvening = date(utcCalendar, 2026, 9, 28, 19)
        #expect(utc.nextFireDate(for: trigger, after: mondayEvening) == date(utcCalendar, 2026, 9, 30, 18))
        let fridayNight = date(utcCalendar, 2026, 10, 2, 20)
        #expect(utc.nextFireDate(for: trigger, after: fridayNight) == date(utcCalendar, 2026, 10, 5, 18))
    }

    @Test func dailyAcrossSpringForward() {
        // DST starts 2026-03-08 at 02:00 in New York: that day has 23 hours.
        let saturday = date(newYork, 2026, 3, 7, 9)
        let next = ny.nextFireDate(for: .daily(hour: 9, minute: 0), after: saturday)!
        #expect(next.timeIntervalSince(saturday) == 23 * 3600)
        #expect(newYork.component(.hour, from: next) == 9)
    }

    @Test func skippedTimeMovesToNextValidTime() {
        // 02:30 does not exist on 2026-03-08 in New York.
        let next = ny.nextFireDate(for: .daily(hour: 2, minute: 30), after: date(newYork, 2026, 3, 7, 12))!
        #expect(newYork.component(.day, from: next) == 8)
        #expect(newYork.component(.hour, from: next) == 3)
    }

    @Test func repeatedTimeFiresOnce() {
        // 01:30 happens twice on 2026-11-01 in New York. Fire on the first.
        let next = ny.nextFireDate(for: .daily(hour: 1, minute: 30), after: date(newYork, 2026, 10, 31, 12))!
        #expect(newYork.timeZone.isDaylightSavingTime(for: next))
        let following = ny.nextFireDate(for: .daily(hour: 1, minute: 30), after: next)!
        #expect(newYork.component(.day, from: following) == 2)
    }

    @Test func dailyAcrossFallBack() {
        // DST ends 2026-11-01: that day has 25 hours.
        let saturday = date(newYork, 2026, 10, 31, 9)
        let next = ny.nextFireDate(for: .daily(hour: 9, minute: 0), after: saturday)!
        #expect(next.timeIntervalSince(saturday) == 25 * 3600)
    }

    @Test func previousFireDate() {
        #expect(utc.previousFireDate(for: .daily(hour: 9, minute: 0), onOrBefore: testNow) == date(utcCalendar, 2026, 10, 1, 9))
        #expect(utc.previousFireDate(for: .daily(hour: 12, minute: 0), onOrBefore: testNow) == testNow)
        #expect(utc.previousFireDate(for: .interval(minutes: 10), onOrBefore: testNow) == nil)
    }

    @Test func missedDailyRunsOnceLate() {
        // Last ran two days ago; 9:00 passed twice. One late run, naming today's 9:00.
        let decision = utc.decision(for: .daily(hour: 9, minute: 0), lastRun: date(utcCalendar, 2026, 9, 29, 9), now: testNow)
        #expect(decision == .runLate(missed: date(utcCalendar, 2026, 10, 1, 9)))
    }

    @Test func onTimeDailyRuns() {
        let now = date(utcCalendar, 2026, 10, 1, 9, 0, 30)
        let decision = utc.decision(for: .daily(hour: 9, minute: 0), lastRun: date(utcCalendar, 2026, 9, 30, 9), now: now)
        #expect(decision == .run)
    }

    @Test func notYetDue() {
        let decision = utc.decision(for: .daily(hour: 9, minute: 0), lastRun: date(utcCalendar, 2026, 10, 1, 9), now: testNow)
        #expect(decision == .wait(until: date(utcCalendar, 2026, 10, 2, 9)))
    }

    @Test func everyFewDaysCountsFromLastSlot() {
        let every3 = Trigger.daily(hour: 9, minute: 0, days: 3)
        // Ran on time Oct 1 at 9:00: next is Oct 4 at 9:00.
        #expect(utc.nextFireDate(for: every3, after: date(utcCalendar, 2026, 10, 1, 9, 0, 5)) == date(utcCalendar, 2026, 10, 4, 9))
        // Ran late at 15:00 for the 9:00 slot: still Oct 4 at 9:00.
        #expect(utc.nextFireDate(for: every3, after: date(utcCalendar, 2026, 10, 1, 15)) == date(utcCalendar, 2026, 10, 4, 9))
    }

    @Test func everyFewDaysKeepsTimeAcrossDST() {
        // Ran Saturday Oct 31 at 9:00 EDT; clocks fall back Nov 1.
        let next = ny.nextFireDate(for: .daily(hour: 9, minute: 0, days: 3), after: date(newYork, 2026, 10, 31, 9))!
        #expect(next == date(newYork, 2026, 11, 3, 9))
    }

    @Test func newEveryFewDaysRuleRunsAtNextTime() {
        let every3 = Trigger.daily(hour: 9, minute: 0, days: 3)
        // Created at noon, after 9:00: first run tomorrow, not in three days.
        let start = utc.initialLastRun(for: every3, now: testNow)
        #expect(utc.nextFireDate(for: every3, after: start) == date(utcCalendar, 2026, 10, 2, 9))
        // Created before 9:00: first run today.
        let early = date(utcCalendar, 2026, 10, 1, 8)
        #expect(utc.nextFireDate(for: every3, after: utc.initialLastRun(for: every3, now: early)) == date(utcCalendar, 2026, 10, 1, 9))
        #expect(utc.initialLastRun(for: .daily(hour: 9, minute: 0), now: testNow) == testNow)
    }

    @Test func missedEveryFewDaysNamesLatestSlot() {
        // Last ran Sep 22 at 9:00; slots Sep 25 and Sep 28 passed, Oct 1 9:00 too.
        let decision = utc.decision(for: .daily(hour: 9, minute: 0, days: 3), lastRun: date(utcCalendar, 2026, 9, 22, 9), now: testNow)
        #expect(decision == .runLate(missed: date(utcCalendar, 2026, 10, 1, 9)))
    }

    @Test func intervalDecisions() {
        let trigger = Trigger.interval(minutes: 30)
        if case .wait = utc.decision(for: trigger, lastRun: testNow.addingTimeInterval(-10 * 60), now: testNow) {} else {
            Issue.record("Expected wait")
        }
        #expect(utc.decision(for: trigger, lastRun: testNow.addingTimeInterval(-30 * 60 - 10), now: testNow) == .run)
        let lastRun = testNow.addingTimeInterval(-2 * 3600)
        #expect(utc.decision(for: trigger, lastRun: lastRun, now: testNow) == .runLate(missed: lastRun.addingTimeInterval(30 * 60)))
    }
}
