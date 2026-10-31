import Foundation
import Testing
@testable import Sync

/// History entries: written before anything is applied, ticked off step by step, readable after a
/// crash at any point, kept 90 days.
@Suite struct OneWaySyncHistoryTests {

    static let t0 = OneWayWorld.t0
    static let firstRun = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    /// One of every action, so a saved form that can't come back fails here.
    static let steps: [OneWaySyncStep] = [
        OneWaySyncStep(action: .moveFolderInDropbox(from: "Finance/Receipts", to: "Finance/2026/Receipts")),
        OneWaySyncStep(action: .moveToRemoved(dropboxPath: "Legal/a.pdf", cause: .deletedInICloud), record: 1),
        OneWaySyncStep(action: .moveToRemoved(dropboxPath: "Legal/b.pdf", cause: .movedOutInICloud(to: "Work/b.pdf")), record: 2),
        OneWaySyncStep(action: .moveToRemoved(dropboxPath: "Legal/c.pdf", cause: .duplicateOfAdoptedFile("Legal/d.pdf")), record: 3),
        OneWaySyncStep(action: .replace(dropboxPath: "Finance/W-2.pdf", with: "Finance/W-2.pdf", needsDownload: true,
                                        previousIsDropboxEdit: false), record: 4),
        OneWaySyncStep(action: .moveInDropbox(from: "Finance/W-2.pdf", to: "Finance/2026 W-2.pdf"), record: 4,
                       undoesDropboxChange: true),
        OneWaySyncStep(action: .moveBackFromRemoved(removedPath: "SyncCloud Removed/x.pdf", to: "Finance/x.pdf"), record: 5),
        OneWaySyncStep(action: .copy(from: "Finance/new.pdf", to: "Finance/new.pdf", needsDownload: false)),
        OneWaySyncStep(action: .adopt(iCloudPath: "Finance/same.pdf", dropboxPath: "Finance/same.pdf")),
        OneWaySyncStep(action: .setTags(dropboxPath: "Finance/t.pdf", tags: ["Red"]), record: 6),
        OneWaySyncStep(action: .forget(dropboxPath: "Finance/gone.pdf"), record: 7),
    ]

    static let held: [OneWaySyncWait] = [
        OneWaySyncWait(subject: .file(iCloudPath: "Legal/POA.pdf", dropboxPath: "Legal/POA.pdf"), reason: .editedInDropbox),
        OneWaySyncWait(subject: .folder("Health"), reason: .syncedFolderRenamedInICloud(to: "Medical")),
        OneWaySyncWait(subject: .file(iCloudPath: nil, dropboxPath: "Legal/x.pdf"), reason: .nameTakenByDropboxOnlyFile("Legal/x.pdf")),
        // Waits SyncCloud resolves itself aren't the user's: not "wait for you".
        OneWaySyncWait(subject: .file(iCloudPath: "Legal/y.pdf", dropboxPath: "Legal/y.pdf"), reason: .contentsNotRead),
    ]

    static func store() -> (OneWayScratch, OneWaySyncHistoryStore) {
        let scratch = OneWayScratch()
        return (scratch, scratch.store.history)
    }

    @Test func theEntryIsOnDiskBeforeAnythingIsApplied() throws {
        let (_, history) = Self.store()
        let entry = try #require(try history.begin(steps: Self.steps, held: Self.held, firstRun: Self.firstRun, now: Self.t0))
        // Read back from disk, not from the value `begin` returned.
        let saved = try #require(history.entry(entry.id))
        #expect(saved.steps.map(\.step) == Self.steps)
        #expect(saved.steps.allSatisfy { $0.status == .pending })
        #expect(saved.held == Array(Self.held.prefix(3)))
        #expect(saved.finishedAt == nil)
        #expect(saved.unconfirmedSteps == Array(Self.steps.indices))
        #expect(history.unfinished(firstRun: Self.firstRun).map(\.id) == [entry.id])
        // One from before a new first run names records that are gone.
        #expect(history.unfinished(firstRun: UUID()).isEmpty)
    }

    @Test func aSyncThatChangedAndHeldNothingGetsNoEntry() throws {
        let (scratch, history) = Self.store()
        let onlyItsOwn = [OneWaySyncWait(subject: .file(iCloudPath: "a", dropboxPath: "a"), reason: .contentsNotRead)]
        #expect(try history.begin(steps: [], held: onlyItsOwn, firstRun: Self.firstRun, now: Self.t0) == nil)
        #expect(scratch.names(in: history.directory) == [])
        // Holding something is enough…
        let held = Array(Self.held.prefix(2))
        #expect(try history.begin(steps: [], held: held, firstRun: Self.firstRun, now: Self.t0) != nil)
        // …once: the next pass, still holding the same, in any order, is no new entry.
        #expect(try history.begin(steps: [], held: held.reversed(), firstRun: Self.firstRun, now: Self.t0 + 900) == nil)
        // Something new held is.
        #expect(try history.begin(steps: [], held: Array(Self.held.prefix(1)), firstRun: Self.firstRun, now: Self.t0 + 1800) != nil)
        // Adopting or forgetting changes only the record.
        let recordOnly = [Self.steps[8], Self.steps[10]]
        #expect(try history.begin(steps: recordOnly, held: [], firstRun: Self.firstRun, now: Self.t0) == nil)
        #expect(scratch.names(in: history.directory).count == 2)
        // A file changed is an entry, whatever was held before.
        #expect(try history.begin(steps: [Self.steps[7]], held: Array(Self.held.prefix(1)), firstRun: Self.firstRun, now: Self.t0 + 2700) != nil)
    }

    /// Where Dropbox's file goes is ticked before it moves: a crash mid-move still leaves it.
    @Test func aStepStartedKeepsWhereItsFileWent() throws {
        let (_, history) = Self.store()
        let entry = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun, now: Self.t0))
        try history.tick(entry.id, step: 1, status: .started, now: Self.t0, keptAt: "SyncCloud Removed/2026-10-30/a.pdf")
        let read = try #require(history.entry(entry.id))
        #expect(read.steps[1].keptAt == "SyncCloud Removed/2026-10-30/a.pdf")
        #expect(read.unconfirmedSteps.contains(1))
        #expect(throws: (any Error).self) { try history.finish(UUID(), now: Self.t0) }
    }

    @Test func eachStepIsTickedOffAndFinishFoldsTheTicksIn() throws {
        let (scratch, history) = Self.store()
        let entry = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun, now: Self.t0))
        let recorded = OneWaySyncFileRecord(key: 4, iCloudPath: "Finance/W-2.pdf", dropboxPath: "Finance/W-2.pdf",
                                            iCloudID: 4, dropboxID: 10_004, size: 9, modified: 1_790_000_000)
        try history.tick(entry.id, step: 4, status: .applied, now: Self.t0, keptAt: "SyncCloud Removed/2026-10-30/W-2.pdf")
        try history.tick(entry.id, step: 4, status: .confirmed, now: Self.t0 + 9, recorded: recorded)
        try history.tick(entry.id, step: 1, status: .skipped("Dropbox’s copy changed"), now: Self.t0 + 10)

        // A crash here: the next launch reads the ticks.
        var read = try #require(history.entry(entry.id))
        #expect(read.steps[4].status == .confirmed)
        #expect(read.steps[4].at == Int64(Self.t0.timeIntervalSince1970) + 9)
        // The later tick kept what the earlier one said and didn't repeat.
        #expect(read.steps[4].keptAt == "SyncCloud Removed/2026-10-30/W-2.pdf")
        #expect(read.steps[4].recorded == recorded)
        #expect(read.steps[1].status == .skipped("Dropbox’s copy changed"))
        #expect(read.unconfirmedSteps == [0, 2, 3, 5, 6, 7, 8, 9, 10])

        try history.finish(entry.id, now: Self.t0 + 20)
        read = try #require(history.entry(entry.id))
        #expect(read.finishedAt == Int64(Self.t0.timeIntervalSince1970) + 20)
        #expect(read.steps[4].recorded == recorded)
        #expect(scratch.names(in: history.directory) == ["\(entry.id.uuidString).json"])
        #expect(history.unfinished(firstRun: Self.firstRun).isEmpty)
    }

    /// A crash mid-tick leaves a torn line: that step reads as unconfirmed, and the next tick,
    /// written after the launch that follows, still counts.
    @Test func aTornTickIsSkippedAndTheNextOneStillCounts() throws {
        let (_, history) = Self.store()
        let entry = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun, now: Self.t0))
        try history.tick(entry.id, step: 0, status: .confirmed, now: Self.t0)
        let handle = try FileHandle(forWritingTo: history.ticksURL(entry.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"step":1,"status":{"confi"#.utf8))
        try handle.close()
        try history.tick(entry.id, step: 2, status: .confirmed, now: Self.t0)

        let read = try #require(history.entry(entry.id))
        #expect(read.steps[0].status == .confirmed)
        #expect(read.steps[1].status == .pending)
        #expect(read.steps[2].status == .confirmed)
    }

    /// A crash after `finish` wrote the entry but before it removed the ticks: folding them again
    /// changes nothing.
    @Test func ticksFoldedTwiceReadTheSame() throws {
        let (_, history) = Self.store()
        let entry = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun, now: Self.t0))
        try history.tick(entry.id, step: 3, status: .failed("read failed"), now: Self.t0)
        let ticks = try Data(contentsOf: history.ticksURL(entry.id))
        try history.finish(entry.id, now: Self.t0 + 1)
        let finished = try #require(history.entry(entry.id))
        try ticks.write(to: history.ticksURL(entry.id))
        #expect(history.entry(entry.id) == finished)
    }

    @Test func entriesOfAnotherVersionAreSkipped() throws {
        let (_, history) = Self.store()
        let entry = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun, now: Self.t0))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: history.entryURL(entry.id))) as! [String: Any]
        json["version"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: history.entryURL(entry.id))
        #expect(history.entry(entry.id) == nil)
        #expect(history.entries().isEmpty)
    }

    @Test func entriesAreKeptNinetyDays() throws {
        let (_, history) = Self.store()
        let day: TimeInterval = 24 * 60 * 60
        let now = Self.t0 + 200 * day
        func finished(daysAgo: Double) throws -> UUID {
            let entry = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun,
                                                       now: now - daysAgo * day))
            try history.finish(entry.id, now: now - daysAgo * day)
            return entry.id
        }
        let kept = try finished(daysAgo: 89.9)
        let old = try finished(daysAgo: 90)
        let older = try finished(daysAgo: 150)
        // A sync a crash cut short stays until its recovery finishes it…
        let open = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun, now: now - 120 * day))
        // …unless it was of an earlier first run, whose records are gone.
        let stale = try #require(try history.begin(steps: Self.steps, held: [], firstRun: UUID(), now: now - day))
        // A file this build can't read goes once it is 90 days old.
        let recent = history.entryURL(UUID())
        try Data("x".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: now - day], ofItemAtPath: recent.path)
        let unreadable = history.entryURL(UUID())
        try Data("x".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.modificationDate: now - 91 * day], ofItemAtPath: unreadable.path)

        #expect(history.prune(now: now, firstRun: Self.firstRun) == 4)
        #expect(history.entry(stale.id) == nil)
        #expect(Set(history.entries().map(\.id)) == [kept, open.id])
        #expect(!FileManager.default.fileExists(atPath: unreadable.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(history.entry(old) == nil && history.entry(older) == nil)
        // Newest first.
        #expect(history.entries().map(\.id) == [kept, open.id])
    }

    @Test func reverseIsOfferedForAFinishedEntryOfThisFirstRunUnderNinetyDays() throws {
        let (_, history) = Self.store()
        let entry = try #require(try history.begin(steps: Self.steps, held: [], firstRun: Self.firstRun, now: Self.t0))
        #expect(!OneWaySyncHistoryStore.canReverse(entry, firstRun: Self.firstRun, now: Self.t0))
        try history.finish(entry.id, now: Self.t0)
        let done = try #require(history.entry(entry.id))
        let ninety = TimeInterval(OneWaySyncHistoryStore.keep)
        #expect(OneWaySyncHistoryStore.canReverse(done, firstRun: Self.firstRun, now: Self.t0 + ninety - 1))
        #expect(!OneWaySyncHistoryStore.canReverse(done, firstRun: Self.firstRun, now: Self.t0 + ninety))
        // After a new first run, earlier entries can no longer be reversed.
        #expect(!OneWaySyncHistoryStore.canReverse(done, firstRun: UUID(), now: Self.t0))
        // A clock moved backwards can't vouch for the age.
        #expect(!OneWaySyncHistoryStore.canReverse(done, firstRun: Self.firstRun, now: Self.t0 - 60))
    }
}
