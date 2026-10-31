//
//  OneWaySyncDropboxGate.swift
//  SyncCloud
//

import Foundation

/// What is still arriving in Dropbox's synced folders, from the folder watcher's events. Dropbox
/// puts every change from elsewhere there; SyncCloud's own writes don't count.
///
/// A file that keeps changing (an app saving every few seconds, a log) is set aside after
/// `OneWaySyncDropboxGate.keepsChangingAfter`, so it holds back only itself, as the design's
/// Settle step says, never the whole sync.
public struct OneWaySyncArrivals: Equatable, Sendable {
    struct Stretch: Equatable, Sendable {
        var since: Date
        var last: Date
    }

    /// Each path changing lately: when its current run of changes began, and its last change.
    private(set) var paths: [String: Stretch] = [:]
    /// The last change from elsewhere that counts, from a file not set aside.
    public private(set) var lastArrival: Date?
    /// When the current stretch of those arrivals began: each one less than `quietFor` after the
    /// one before it.
    public private(set) var busySince: Date?

    public init() {}

    /// Notes a watcher batch delivered at `now`. `syncedFolders` are the Dropbox synced folders,
    /// spelled as the watcher's root is. A rescan means changes may have been missed anywhere
    /// below it, which counts as an arrival no file can be set aside for.
    public mutating func note(_ batch: FolderWatchBatch, syncedFolders: [String], at now: Date) {
        func inside(_ path: String) -> Bool {
            !OneWaySyncPath.name(path).hasPrefix(OneWaySyncPlanner.temporaryNamePrefix)
                && syncedFolders.contains { OneWaySyncDisk.isWithin(path, $0) }
        }
        let changed = Set(batch.events.filter { !$0.isOwn && inside($0.path) }.map(\.path))
        let rescanned = batch.rescans.contains { rescan in
            syncedFolders.contains { OneWaySyncDisk.isWithin(rescan.path, $0) || OneWaySyncDisk.isWithin($0, rescan.path) }
        }
        guard !changed.isEmpty || rescanned else { return }
        forgetQuietPaths(at: now)
        var counts = rescanned
        for path in changed where note(path, at: now) { counts = true }
        if counts { count(at: now) }
    }

    /// A change to `path`, or somewhere unknown when nil, at `now`.
    public mutating func noteArrival(of path: String? = nil, at now: Date) {
        forgetQuietPaths(at: now)
        if let path, !note(path, at: now) { return }
        count(at: now)
    }

    /// Drops the paths quiet for `quietFor`. A time ahead of now means the clock was set back:
    /// that history starts again.
    private mutating func forgetQuietPaths(at now: Date) {
        paths = paths.filter { $0.value.last <= now && now.timeIntervalSince($0.value.last) < OneWaySyncDropboxGate.quietFor }
    }

    /// Notes a change to `path`; whether it counts as an arrival, which it doesn't once the file
    /// has kept changing for `keepsChangingAfter`.
    private mutating func note(_ path: String, at now: Date) -> Bool {
        var stretch = paths[path] ?? Stretch(since: now, last: now)
        stretch.last = now
        paths[path] = stretch
        return now.timeIntervalSince(stretch.since) < OneWaySyncDropboxGate.keepsChangingAfter
    }

    private mutating func count(at now: Date) {
        if lastArrival.map({ $0 > now || now.timeIntervalSince($0) >= OneWaySyncDropboxGate.quietFor }) ?? true { busySince = now }
        lastArrival = now
    }

    /// The files set aside at `now`: changing for `keepsChangingAfter` with no quiet spell, and
    /// changed within the last `quietFor`.
    public func keptChanging(at now: Date) -> [String] {
        paths.filter { _, stretch in
            stretch.last <= now && now.timeIntervalSince(stretch.last) < OneWaySyncDropboxGate.quietFor
                && stretch.last.timeIntervalSince(stretch.since) >= OneWaySyncDropboxGate.keepsChangingAfter
        }.keys.sorted()
    }
}

/// **Dropbox caught up** (decision DI): SyncCloud writes into Dropbox only once the Dropbox app is
/// running, has run for 5 minutes since it started or the Mac woke, and nothing is still arriving
/// in the synced folders. Dropbox's changes from elsewhere reach this Mac only while the app runs,
/// so before then Dropbox's copy here may be behind and a write could land on a stale file.
///
/// Reads RD68's one status model (`CloudAppStatusModel`) for whether the app runs, so one-way sync
/// and the panes never disagree about it.
public enum OneWaySyncDropboxGate {
    public static let runningFor: TimeInterval = 5 * 60
    /// The synced folders settle: no arrival for this long.
    public static let quietFor: TimeInterval = 30
    /// Arrivals with no quiet spell for this long raise a row.
    public static let neverQuietFor: TimeInterval = 30 * 60
    /// A file changing this long with no quiet spell is set aside: it waits on its own.
    public static let keepsChangingAfter: TimeInterval = 2 * 60

    public enum Wait: Equatable, Sendable {
        /// Not seen running yet, or missing for less than the grace: no row until then.
        case dropboxNotSeenRunning
        case dropboxJustStarted(until: Date)
        case changesArriving(since: Date)
    }

    /// What stops the whole sync with a row under *Needs you*.
    public enum Stop: Equatable, Sendable {
        /// Missing for `CloudAppStatusModel.notRunningGrace`, the same 5 minutes RD68 waits.
        case dropboxNotRunning(since: Date)
        case dropboxNeverQuiet(since: Date)
    }

    public enum Verdict: Equatable, Sendable {
        /// Writing may go ahead, except to the files still changing on their own.
        case caughtUp(holdingBack: [String])
        case waiting(Wait)
        case stop(Stop)
    }

    /// Whether a pass may write into Dropbox at `now`. `lastWake` is when the Mac last woke.
    public static func check(status: CloudAppStatusModel, arrivals: OneWaySyncArrivals,
                             lastWake: Date?, now: Date) -> Verdict {
        if let missing = status.missingSince[.dropbox] {
            return now.timeIntervalSince(missing) >= CloudAppStatusModel.notRunningGrace
                ? .stop(.dropboxNotRunning(since: missing)) : .waiting(.dropboxNotSeenRunning)
        }
        guard let running = status.runningSince[.dropbox] else { return .waiting(.dropboxNotSeenRunning) }
        // A wake dated ahead of now (a clock set back) can't be placed; it is left out.
        let since = max(running, lastWake.flatMap { $0 <= now ? $0 : nil } ?? running)
        if now.timeIntervalSince(since) < runningFor {
            return .waiting(.dropboxJustStarted(until: since.addingTimeInterval(runningFor)))
        }
        // An arrival dated ahead of now (a clock set back) is history that starts again.
        if let last = arrivals.lastArrival, last <= now, now.timeIntervalSince(last) < quietFor {
            let busy = arrivals.busySince ?? last
            return now.timeIntervalSince(busy) >= neverQuietFor
                ? .stop(.dropboxNeverQuiet(since: busy)) : .waiting(.changesArriving(since: busy))
        }
        return .caughtUp(holdingBack: arrivals.keptChanging(at: now))
    }
}
