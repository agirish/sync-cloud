import Testing
import Foundation
import SwiftUI
import AppKit
import Combine
@testable import Design

/// The Compare header's timeline ticks exactly where its readout changes: the pill's age, its
/// spoken form, the stale flag and the tooltip's stamp. Checked from both sides — the readout never
/// changes between two ticks (no label left stale), and it does change at every tick (no tick
/// wasted, which is the whole point of replacing the 30 s period).
@Suite struct ScanFreshnessScheduleTests {

    private struct Reading: Equatable {
        let freshness: ScanFreshness.Result
        let stamp: String
    }

    private func reading(_ anchor: Date, _ now: Date, _ calendar: Calendar) -> Reading {
        Reading(freshness: ScanFreshness.describe(scanDate: anchor, now: now),
                stamp: ScanFreshness.stamp(scanDate: anchor, now: now, calendar: calendar))
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// Fractional anchors, so seams fall between whole seconds. One anchor sits late in its day, so
    /// the stamp's midnight falls inside the first hour, between minute seams.
    private var cases: [(anchor: Date, zone: String)] {
        [(Date(timeIntervalSinceReferenceDate: 815_000_000.123_456), "Asia/Kolkata"),
         (Date(timeIntervalSinceReferenceDate: 815_000_000.123_456), "America/Los_Angeles"),
         (Date(timeIntervalSince1970: 1_000_000.37), "UTC"),
         // 23:59:40 UTC: midnight arrives 20 s in, while the age still reads "just now".
         (Date(timeIntervalSince1970: 86_400 * 20_000 - 20.6), "UTC")]
    }

    @Test func theReadoutChangesAtEveryTickAndNowhereElse() {
        let horizon: TimeInterval = 3 * 86_400
        for (anchor, zone) in cases {
            let cal = calendar(zone)
            let schedule = ScanFreshnessSchedule(anchor: anchor, calendar: cal)
            let ticks = Array(schedule.entries(from: anchor, mode: .normal)
                .prefix { $0 <= anchor.addingTimeInterval(horizon) })
            #expect(ticks.first == anchor, "\(zone): the first entry must draw at once")
            #expect(ticks == ticks.sorted() && Set(ticks).count == ticks.count, "\(zone): out of order or repeated")

            for (index, tick) in ticks.enumerated() {
                let here = reading(anchor, tick, cal)
                if index > 0 {
                    #expect(reading(anchor, tick.addingTimeInterval(-0.02), cal) != here,
                            "\(zone): a wasted tick at +\(tick.timeIntervalSince(anchor)) s")
                }
                let end = index + 1 < ticks.count ? ticks[index + 1]
                    : anchor.addingTimeInterval(horizon + ScanFreshnessSchedule.nudge)
                // Every second for the first two hours, where seams are dense; every 7 s after.
                // Up to the seam itself: each tick lands `nudge` after its seam, so the last
                // `nudge` before a tick already shows the next label.
                let seam = end.addingTimeInterval(-ScanFreshnessSchedule.nudge)
                var t = tick
                while t < seam {
                    #expect(reading(anchor, t, cal) == here,
                            "\(zone): the readout changed at +\(t.timeIntervalSince(anchor)) s with no tick")
                    t = t.addingTimeInterval(t.timeIntervalSince(anchor) < 7200 ? 1 : 7)
                }
                #expect(reading(anchor, seam.addingTimeInterval(-0.001), cal) == here,
                        "\(zone): the readout changed just before +\(end.timeIntervalSince(anchor)) s")
            }
        }
    }

    /// The cost the period paid: 120 rebuilds an hour, forever. Now 60 in the first hour, one an
    /// hour to a day (plus the midnight), one a day after.
    @Test func anIdleHeaderTicksOnceAnHourThenOnceADay() {
        let anchor = Date(timeIntervalSince1970: 1_000_000.37)
        let ticks = Array(ScanFreshnessSchedule(anchor: anchor, calendar: calendar("UTC"))
            .entries(from: anchor, mode: .normal).prefix(200))
        func count(_ from: TimeInterval, _ to: TimeInterval) -> Int {
            ticks.filter { $0 > anchor.addingTimeInterval(from) && $0 <= anchor.addingTimeInterval(to) }.count
        }
        // Windows end a second past a seam, since each tick lands `nudge` after its seam. This
        // anchor's midnight falls near +10 h, outside all three.
        #expect(count(0, 3601) == 60 + 1)                 // 30 s, 1–59 min, 1 h
        #expect(count(3601, 7201) == 1)                   // 2 h
        #expect(count(86_401, 10 * 86_400 + 1) == 9)      // 2 d … 10 d: the day ladder is endless
    }

    /// A view that appears mid-ladder draws at once, then waits for the next seam — not for the
    /// next 30 s mark, and not for a seam already past.
    @Test func startingMidLadderYieldsStartThenTheNextSeam() {
        let anchor = Date(timeIntervalSince1970: 1_000_000.37)
        let start = anchor.addingTimeInterval(5 * 3600 + 17)
        let entries = Array(ScanFreshnessSchedule(anchor: anchor, calendar: calendar("UTC"))
            .entries(from: start, mode: .normal).prefix(2))
        #expect(entries[0] == start)
        #expect(abs(entries[1].timeIntervalSince(anchor) - (6 * 3600 + ScanFreshnessSchedule.nudge)) < 0.001)
    }

    /// A threshold that is not on a seam still gets its own tick, so the stale flip is never late.
    @Test func anOffSeamThresholdGetsItsOwnTick() {
        let anchor = Date(timeIntervalSince1970: 1_000_000.37)
        let ticks = Array(ScanFreshnessSchedule(anchor: anchor, staleAfter: 3 * 86_400 + 90,
                                                calendar: calendar("UTC"))
            .entries(from: anchor, mode: .normal).prefix(200))
        #expect(ticks.contains { abs($0.timeIntervalSince(anchor) - (3 * 86_400 + 90 + ScanFreshnessSchedule.nudge)) < 0.001 })
        #expect(ticks == ticks.sorted())
    }

    /// A wake, clock or zone change bumps the view's epoch, and a schedule with a new epoch is a
    /// different schedule — which is what makes the timeline restart from now rather than wait
    /// out a tick that may be a day away.
    @Test func aNewEpochIsANewSchedule() {
        let anchor = Date(timeIntervalSince1970: 1_000_000.37)
        let cal = calendar("UTC")
        #expect(ScanFreshnessSchedule(anchor: anchor, calendar: cal, epoch: 0)
                == ScanFreshnessSchedule(anchor: anchor, calendar: cal, epoch: 0))
        #expect(ScanFreshnessSchedule(anchor: anchor, calendar: cal, epoch: 0)
                != ScanFreshnessSchedule(anchor: anchor, calendar: cal, epoch: 1))
    }

    /// The three events that move the clock under a sparse schedule each fire `clockChanges`.
    @MainActor @Test func clockChangesFiresOnZoneClockAndWake() async {
        var fired = 0
        let sub = ScanFreshnessSchedule.clockChanges.sink { fired += 1 }
        defer { sub.cancel() }
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<50 where fired < 3 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(fired == 3)
    }
}
