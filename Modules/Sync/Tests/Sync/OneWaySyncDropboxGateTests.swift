import Foundation
import Testing
@testable import Sync

/// Dropbox caught up (DI): running, for 5 minutes since it started or the Mac woke, and nothing
/// still arriving; and nothing counts as synced until Dropbox reports the upload.
@Suite struct OneWaySyncDropboxGateTests {
    static let t0 = Date(timeIntervalSince1970: 1_793_361_600)
    static let synced = ["/Dropbox/Documents/Finance", "/Dropbox/Documents/Legal"]

    func running(since: Date) -> CloudAppStatusModel {
        var status = CloudAppStatusModel()
        status.app(.dropbox, isRunning: true, at: since)
        return status
    }

    func check(_ status: CloudAppStatusModel, _ arrivals: OneWaySyncArrivals = OneWaySyncArrivals(),
               wake: Date? = nil, at minutes: Double) -> OneWaySyncDropboxGate.Verdict {
        OneWaySyncDropboxGate.check(status: status, arrivals: arrivals, lastWake: wake, now: Self.t0.addingTimeInterval(minutes * 60))
    }

    @Test func dropboxMustHaveRunFiveMinutes() {
        let status = running(since: Self.t0)
        #expect(check(status, at: 4.9) == .waiting(.dropboxJustStarted(until: Self.t0.addingTimeInterval(300))))
        #expect(check(status, at: 5) == .caughtUp(holdingBack: []))
        // Seen running again later doesn't restart the five minutes.
        var again = status
        again.app(.dropbox, isRunning: true, at: Self.t0.addingTimeInterval(240))
        #expect(check(again, at: 5) == .caughtUp(holdingBack: []))
    }

    @Test func aProcessStartReadFromTheSystemCounts() {
        var status = CloudAppStatusModel()
        status.app(.dropbox, isRunning: true, at: Self.t0, startedAt: Self.t0.addingTimeInterval(-3600))
        #expect(check(status, at: 0) == .caughtUp(holdingBack: []))
        // A start in the future is clamped to now.
        var odd = CloudAppStatusModel()
        odd.app(.dropbox, isRunning: true, at: Self.t0, startedAt: Self.t0.addingTimeInterval(3600))
        #expect(odd.runningSince[.dropbox] == Self.t0)
    }

    /// A restart between two looks: the process start says so, and the five minutes start again.
    @Test func aRestartSeenOnlyByItsStartTimeStartsTheFiveMinutesAgain() {
        var status = CloudAppStatusModel()
        status.app(.dropbox, isRunning: true, at: Self.t0, startedAt: Self.t0.addingTimeInterval(-3600))
        status.app(.dropbox, isRunning: true, at: Self.t0.addingTimeInterval(600), startedAt: Self.t0.addingTimeInterval(590))
        #expect(status.runningSince[.dropbox] == Self.t0.addingTimeInterval(590))
        #expect(check(status, at: 12) == .waiting(.dropboxJustStarted(until: Self.t0.addingTimeInterval(890))))
        // The same start read again changes nothing.
        status.app(.dropbox, isRunning: true, at: Self.t0.addingTimeInterval(900), startedAt: Self.t0.addingTimeInterval(590))
        #expect(status.runningSince[.dropbox] == Self.t0.addingTimeInterval(590))
    }

    /// A process start dated after now (the clock set back since it started) can't be placed: it
    /// is left out, so the wait doesn't start again at every look.
    @Test func aStartDatedAfterNowIsLeftOut() {
        var status = CloudAppStatusModel()
        let start = Self.t0.addingTimeInterval(3600)
        status.app(.dropbox, isRunning: true, at: Self.t0, startedAt: start)
        status.app(.dropbox, isRunning: true, at: Self.t0.addingTimeInterval(60), startedAt: start)
        status.app(.dropbox, isRunning: true, at: Self.t0.addingTimeInterval(400), startedAt: start)
        #expect(status.runningSince[.dropbox] == Self.t0)
        #expect(check(status, at: 6.7) == .caughtUp(holdingBack: []))
    }

    @Test func aClockSetBackStartsTheWaitsAfresh() {
        var status = running(since: Self.t0)
        let earlier = Self.t0.addingTimeInterval(-3600)
        status.app(.dropbox, isRunning: true, at: earlier)
        #expect(status.runningSince[.dropbox] == earlier)
        // A wake and an arrival dated ahead of now are left out, not waited for.
        var arrivals = OneWaySyncArrivals()
        arrivals.noteArrival(at: Self.t0)
        #expect(OneWaySyncDropboxGate.check(status: status, arrivals: arrivals, lastWake: Self.t0,
                                            now: earlier.addingTimeInterval(300)) == .caughtUp(holdingBack: []))
        arrivals.noteArrival(at: earlier.addingTimeInterval(300))
        #expect(arrivals.busySince == earlier.addingTimeInterval(300))
    }

    @Test func aWakeStartsTheFiveMinutesAgain() {
        let status = running(since: Self.t0.addingTimeInterval(-3600))
        #expect(check(status, wake: Self.t0, at: 2) == .waiting(.dropboxJustStarted(until: Self.t0.addingTimeInterval(300))))
        #expect(check(status, wake: Self.t0, at: 5) == .caughtUp(holdingBack: []))
    }

    @Test func notRunningWaitsSilentlyThenStopsTheSync() {
        #expect(check(CloudAppStatusModel(), at: 0) == .waiting(.dropboxNotSeenRunning))
        var status = running(since: Self.t0.addingTimeInterval(-3600))
        status.app(.dropbox, isRunning: false, at: Self.t0)
        #expect(status.runningSince[.dropbox] == nil)
        #expect(check(status, at: 4.9) == .waiting(.dropboxNotSeenRunning))
        #expect(check(status, at: 5) == .stop(.dropboxNotRunning(since: Self.t0)))
        // Back again: five more minutes from now.
        status.app(.dropbox, isRunning: true, at: Self.t0.addingTimeInterval(600))
        #expect(check(status, at: 12) == .waiting(.dropboxJustStarted(until: Self.t0.addingTimeInterval(900))))
    }

    func batch(_ events: [FolderWatchEvent] = [], rescans: [FolderWatchRescan] = []) -> FolderWatchBatch {
        FolderWatchBatch(events: events, rescans: rescans)
    }

    func event(_ path: String, own: Bool = false) -> FolderWatchEvent {
        FolderWatchEvent(id: 1, root: "/Dropbox/Documents", path: path, realPath: path, change: [.modified, .isFile], isOwn: own)
    }

    @Test func onlyChangesFromElsewhereInSyncedFoldersCount() {
        var arrivals = OneWaySyncArrivals()
        let at = Self.t0.addingTimeInterval(600)
        arrivals.note(batch([event("/Dropbox/Documents/Finance/a.pdf", own: true)]), syncedFolders: Self.synced, at: at)
        arrivals.note(batch([event("/Dropbox/Documents/Work/a.pdf")]), syncedFolders: Self.synced, at: at)
        arrivals.note(batch([event("/Dropbox/Documents/Financed/a.pdf")]), syncedFolders: Self.synced, at: at)
        arrivals.note(batch([event("/Dropbox/Documents/Finance/.SyncCloud-swap-1-a.pdf")]), syncedFolders: Self.synced, at: at)
        #expect(arrivals.lastArrival == nil)
        arrivals.note(batch([event("/Dropbox/Documents/Legal/2019/b.pdf")]), syncedFolders: Self.synced, at: at)
        #expect(arrivals.lastArrival == at)
    }

    @Test func aRescanOverTheSyncedFoldersCountsAsAnArrival() {
        var arrivals = OneWaySyncArrivals()
        arrivals.note(batch(rescans: [FolderWatchRescan(root: "/Dropbox/Documents", path: "/Dropbox/Documents/Work", reason: .mustScanSubDirs, id: 1)]),
                      syncedFolders: Self.synced, at: Self.t0)
        #expect(arrivals.lastArrival == nil)
        arrivals.note(batch(rescans: [FolderWatchRescan(root: "/Dropbox/Documents", path: "/Dropbox/Documents", reason: .eventsDropped, id: 1)]),
                      syncedFolders: Self.synced, at: Self.t0)
        #expect(arrivals.lastArrival == Self.t0)
    }

    @Test func arrivalsWaitUntilThirtySecondsQuiet() {
        let status = running(since: Self.t0.addingTimeInterval(-3600))
        var arrivals = OneWaySyncArrivals()
        arrivals.noteArrival(at: Self.t0)
        #expect(check(status, arrivals, at: 0.4) == .waiting(.changesArriving(since: Self.t0)))
        #expect(check(status, arrivals, at: 0.5) == .caughtUp(holdingBack: []))
    }

    @Test func neverQuietForThirtyMinutesStopsTheSync() {
        let status = running(since: Self.t0.addingTimeInterval(-3600))
        var arrivals = OneWaySyncArrivals()
        for second in stride(from: 0.0, through: 1780, by: 20) { arrivals.noteArrival(at: Self.t0.addingTimeInterval(second)) }
        #expect(arrivals.busySince == Self.t0)
        #expect(check(status, arrivals, at: 29.9) == .waiting(.changesArriving(since: Self.t0)))
        arrivals.noteArrival(at: Self.t0.addingTimeInterval(1800))
        #expect(check(status, arrivals, at: 30) == .stop(.dropboxNeverQuiet(since: Self.t0)))
        // A quiet spell ends the stretch: the next arrival starts a new one.
        arrivals.noteArrival(at: Self.t0.addingTimeInterval(31 * 60))
        #expect(arrivals.busySince == Self.t0.addingTimeInterval(31 * 60))
    }

    /// One file saving every 20 s doesn't hold up the sync: after two minutes it waits on its
    /// own, and nothing else is held back.
    @Test func aFileThatKeepsChangingHoldsBackOnlyItself() {
        let status = running(since: Self.t0.addingTimeInterval(-3600))
        var arrivals = OneWaySyncArrivals()
        let busy = "/Dropbox/Documents/Finance/budget.numbers"
        let batch = batch([event(busy)])
        for second in stride(from: 0.0, through: 60, by: 20) {
            arrivals.note(batch, syncedFolders: Self.synced, at: Self.t0.addingTimeInterval(second))
        }
        // At first it is any arrival.
        #expect(check(status, arrivals, at: 1) == .waiting(.changesArriving(since: Self.t0)))
        for second in stride(from: 80.0, through: 40 * 60, by: 20) {
            arrivals.note(batch, syncedFolders: Self.synced, at: Self.t0.addingTimeInterval(second))
        }
        #expect(check(status, arrivals, at: 40) == .caughtUp(holdingBack: [busy]))
        // Another file arriving still waits, and only from its own arrival: no 30-minute stop.
        arrivals.note(self.batch([event("/Dropbox/Documents/Legal/lease.pdf")]), syncedFolders: Self.synced, at: Self.t0.addingTimeInterval(40 * 60))
        #expect(check(status, arrivals, at: 40.2) == .waiting(.changesArriving(since: Self.t0.addingTimeInterval(40 * 60))))
        // Quiet for 30 s, it is let go.
        #expect(check(status, arrivals, at: 41) == .caughtUp(holdingBack: []))
    }

    // MARK: Upload confirmation

    final class Readings: @unchecked Sendable {
        let lock = NSLock()
        var script: [String: [OneWaySyncUploads.Reading]]
        var idReads: [String] = []
        var settled: [String] = []
        init(_ script: [String: [OneWaySyncUploads.Reading]]) { self.script = script }
        func next(_ path: String) -> OneWaySyncUploads.Reading {
            lock.lock(); defer { lock.unlock() }
            guard var queue = script[path], !queue.isEmpty else { return .upload(.pending) }
            let reading = queue.removeFirst()
            script[path] = queue.isEmpty ? [reading] : queue
            return reading
        }
        func id(_ path: String) -> UInt64? {
            lock.lock(); defer { lock.unlock() }
            idReads.append(path)
            return 42
        }
    }

    /// The deadline is a minute and every file settles in three rounds, so no wall clock decides it.
    @Test func anUploadIsConfirmedOnlyWhenDropboxSaysSoAndItsIDIsReadThen() async {
        let readings = Readings([
            "/d/a.pdf": [.upload(.pending), .upload(.unknown), .upload(.uploaded)],
            "/d/b.pdf": [.upload(.pending), .upload(.refused("name not allowed"))],
            "/d/d.pdf": [.upload(.pending), .gone],
            "/d/e.pdf": [.ignoredByDropbox],
        ])
        let outcomes = await OneWaySyncUploads.confirm(
            ["/d/a.pdf", "/d/b.pdf", "/d/d.pdf", "/d/e.pdf"], interval: .milliseconds(10), deadline: .seconds(60),
            reading: { readings.next($0) }, documentID: { readings.id($0) },
            settled: { path, _ in readings.lock.lock(); readings.settled.append(path); readings.lock.unlock() })
        #expect(outcomes == ["/d/a.pdf": .uploaded(documentID: 42), "/d/b.pdf": .refused("name not allowed"),
                             "/d/d.pdf": .gone, "/d/e.pdf": .refused("Dropbox ignores it")])
        #expect(readings.idReads == ["/d/a.pdf"])
        // Each as soon as it is known, round by round.
        #expect(readings.settled == ["/d/e.pdf", "/d/b.pdf", "/d/d.pdf", "/d/a.pdf"])
    }

    @Test func aFileNeverReportedUploadedIsNotConfirmedAtTheDeadline() async {
        let outcomes = await OneWaySyncUploads.confirm(
            ["/d/c.pdf"], interval: .milliseconds(10), deadline: .milliseconds(200),
            reading: { _ in .upload(.unknown) }, documentID: { _ in 1 })
        #expect(outcomes == ["/d/c.pdf": .notConfirmed])
    }

    /// Cancelled while a read hangs: the wait ends then, not when the read lets go.
    @Test func aCancelDuringAHungReadEndsTheWait() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            await OneWaySyncUploads.confirm(["/d/a.pdf"], interval: .seconds(1), deadline: .seconds(600),
                                            reading: { _ in started.signal(); _ = release.wait(timeout: .now() + 30); return .upload(.uploaded) },
                                            documentID: { _ in 1 })
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { _ = started.wait(timeout: .now() + 30); continuation.resume() }
        }
        let cancelled = ContinuousClock.now
        task.cancel()
        let outcomes = await task.value
        #expect(ContinuousClock.now - cancelled < .seconds(20))
        #expect(outcomes == ["/d/a.pdf": .notConfirmed])
        release.signal()
    }

    /// A read that hangs (File Provider has hung before) doesn't hold the answer past the deadline.
    @Test func aHungReadEndsAtTheDeadline() async {
        let release = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now
        let outcomes = await OneWaySyncUploads.confirm(
            ["/d/a.pdf"], interval: .milliseconds(10), deadline: .milliseconds(300),
            reading: { _ in _ = release.wait(timeout: .now() + 30); return .upload(.uploaded) }, documentID: { _ in 1 })
        release.signal()
        #expect(outcomes == ["/d/a.pdf": .notConfirmed])
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func theRealReadingTellsAGoneFileAndDropboxsIgnoreMark() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let ignored = try world.write(.dropbox, "Finance/.DS_Store", "x")
        setxattr(ignored.path, "com.dropbox.ignored", "1", 1, 0, 0)
        let plain = try world.write(.dropbox, "Finance/a.pdf", "a")
        #expect(OneWaySyncUploads.reading(at: ignored.path) == .ignoredByDropbox)
        #expect(OneWaySyncUploads.reading(at: world.dropbox.appendingPathComponent("Finance/gone.pdf").path) == .gone)
        // Outside any cloud folder: unknown, which keeps it waiting.
        #expect(OneWaySyncUploads.reading(at: plain.path) == .upload(.unknown))
    }

    @Test func aCancelledWaitConfirmsNothing() async {
        let task = Task {
            await OneWaySyncUploads.confirm(["/d/a.pdf"], interval: .seconds(60), deadline: .seconds(600),
                                            reading: { _ in .upload(.pending) }, documentID: { _ in nil })
        }
        task.cancel()
        let outcomes = await task.value
        #expect(outcomes == ["/d/a.pdf": .notConfirmed])
    }
}
