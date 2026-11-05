import AppKit
import Combine
import SwiftUI

/// The instants at which `ScanFreshness`'s readout can change, as a `TimelineSchedule`: 30 s, 1
/// min, each minute to an hour, each hour to a day, each day after, plus `ScanFreshness.staleAfter`
/// and the first local midnight, where the tooltip's stamp switches to a date. Counted from
/// `anchor`, the date the age is measured from.
///
/// Not `.periodic(by: 30)`: the Compare header wraps its whole ladder in this timeline (see
/// `DifferencesView.withScanFreshness`), and a 30 s period would rebuild it 120 times an hour, idle
/// or hidden, for a label that changes hourly after the first. This draws the same labels at the
/// same moments and nothing in between.
///
/// Each point is `nudge` past its seam: `relative` floors, so a tick a hair early would draw the
/// old label and leave it until the next tick.
///
/// Sparse ticks must restart when the clock moves under them: with an hour or a day between ticks,
/// a sleep, clock change or time-zone change could leave the age or stamp wrong that long. `epoch`
/// is bumped on each of those (`clockChanges`), and a schedule with a new epoch restarts from now.
public struct ScanFreshnessSchedule: TimelineSchedule, Sendable, Equatable {
    public let anchor: Date
    public let staleAfter: TimeInterval
    public let calendar: Calendar
    /// Bumped by the view when `clockChanges` fires, so the timeline restarts from now.
    public let epoch: Int

    static let nudge: TimeInterval = 0.01

    public init(anchor: Date, staleAfter: TimeInterval = ScanFreshness.staleAfter,
                calendar: Calendar = .current, epoch: Int = 0) {
        self.anchor = anchor
        self.staleAfter = staleAfter
        self.calendar = calendar
        self.epoch = epoch
    }

    /// Fires when a schedule's ticks may no longer fall where its readout changes: the Mac woke
    /// (timers may have counted only awake time), the clock was set, or the time zone changed (the
    /// stamp's midnight and wording move). Delivered on the main queue. Built once, because a view
    /// body reads it on every run, twice in the Compare header.
    @MainActor
    public static let clockChanges: AnyPublisher<Void, Never> = {
        Publishers.MergeMany(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification),
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }()

    /// `startDate` first, so the view draws at once, then every change point after it.
    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var points = changePoints().lazy.filter { $0 > startDate }.makeIterator()
        var first: Date? = startDate
        return AnyIterator {
            if let date = first {
                first = nil
                return date
            }
            return points.next()
        }
    }

    /// Every change point after `anchor`, ascending and endless (one a day once a day has passed).
    public func changePoints() -> AnySequence<Date> {
        var offsets: Set<TimeInterval> = [30]
        for minute in 1..<60 { offsets.insert(TimeInterval(minute * 60)) }
        for hour in 1...24 { offsets.insert(TimeInterval(hour * 3600)) }
        offsets.insert(staleAfter)
        let firstDays = Int(staleAfter / 86_400) + 1
        for day in 1...firstDays { offsets.insert(TimeInterval(day * 86_400)) }
        let finite = offsets.filter { $0 > 0 }.sorted()
            .map { anchor.addingTimeInterval($0 + Self.nudge) }

        let midnight = calendar.nextDate(after: anchor, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                         matchingPolicy: .nextTime)
            .map { $0.addingTimeInterval(Self.nudge) }
        let head = Set(finite + [midnight].compactMap { $0 }).sorted()

        return AnySequence { () -> AnyIterator<Date> in
            var index = 0
            var day = firstDays + 1
            return AnyIterator {
                if index < head.count {
                    defer { index += 1 }
                    return head[index]
                }
                defer { day += 1 }
                return anchor.addingTimeInterval(TimeInterval(day * 86_400) + Self.nudge)
            }
        }
    }
}
