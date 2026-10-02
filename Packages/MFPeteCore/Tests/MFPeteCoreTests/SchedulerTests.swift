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
