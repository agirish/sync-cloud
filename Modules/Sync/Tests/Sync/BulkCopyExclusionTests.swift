import Testing
import Foundation
@testable import Sync

/// Pins the verified-copy bulk run (`bulkCopyDifferencesLeftToRight`) into the same mutual
/// exclusion as `syncAll` and Verify All. Both bulk runs write `bulkSyncProgress` and nil it on
/// exit, so overlapping runs interleave the counter, the first to finish tears down the other's
/// overlay, and the verified copy's writes stale syncAll's up-front destination stats.
@Suite struct BulkCopyExclusionTests {

    /// A source-only file and one difference per name. No collision seams: the verified-copy run
    /// overwrites unconditionally.
    @MainActor
    private func makeFixture(names: [String]) throws -> (FileSyncManager, MockFileManager, [FileDifference]) {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        var diffs: [FileDifference] = []
        for name in names {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            diffs.append(FileDifference(
                relativePath: name,
                leftItemPath: "/src/\(name)",
                rightItemPath: "/dst/\(name)",
                type: .missingOnRight,
                action: .copyToRight,
                description: "Missing"
            ))
        }
        manager.rawDifferences = diffs
        manager.differences = diffs
        return (manager, mockFM, diffs)
    }

    /// The two dates of a verified pair, a day apart, so "matched" cannot be an accident.
    static let leftDate = Date(timeIntervalSince1970: 1_600_000_000)
    static let rightDate = Date(timeIntervalSince1970: 1_600_086_400)

    /// A pair on both sides, same size, dates a day apart: the only shape a verified offer holds.
    /// The run sets the right file's date and copies nothing, so a run that went through shows as
    /// the right file taking `leftDate`.
    @MainActor
    private func addVerifiedPair(_ mockFM: MockFileManager, _ name: String) -> FileDifference {
        mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.modificationDate: Self.leftDate, .size: 9], contents: nil)
        mockFM.virtualDisk["/dst/\(name)"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.modificationDate: Self.rightDate, .size: 9], contents: nil)
        return FileDifference(relativePath: name, leftItemPath: "/src/\(name)", rightItemPath: "/dst/\(name)",
                              type: .differentDates, action: .copyToRight, description: "Different dates",
                              leftFileSize: 9, rightFileSize: 9)
    }

    private func rightDate(_ mockFM: MockFileManager, _ name: String) -> Date? {
        (try? mockFM.attributesOfItem(atPath: "/dst/\(name)"))?[.modificationDate] as? Date
    }

    /// Compares fields, since banner equality includes a per-publish id.
    @MainActor
    private func refused(_ manager: FileSyncManager) -> Bool {
        manager.banner?.message == "Wait for the current operation to finish before copying"
            && manager.banner?.severity == .warning
    }

    /// A verified copy started while another bulk run is in flight refuses with a banner: no files
    /// touched, no rows marked, and the running run's flag left alone.
    ///
    /// Built as production reaches it: one real operation first, so the offer is stamped at a
    /// moved epoch (at 0 every comparison matches vacuously). Then `isBulkSyncRunning` is latched
    /// without moving the epoch or count, which is `syncAll`'s prepare window before its prompt.
    /// `confirmVerifiedCopy`'s two guards pass, so only `bulkCopyDifferencesLeftToRight`'s
    /// exclusion can refuse.
    @MainActor
    @Test func testVerifiedCopyRefusedWhileAnotherBulkRunIsInFlight() async throws {
        let (manager, mockFM, diffs) = try makeFixture(names: ["a.txt"])

        await manager.enqueueFileOperation { }
        try #require(manager.fileOperationsEpoch > 0)
        try #require(manager.activeFileOperationsCount == 0)

        manager.isBulkSyncRunning = true
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: diffs, asOf: manager.fileOperationsEpoch)
        // Both confirm-time guards pass; only bulkCopy's exclusion can refuse from here.
        try #require(manager.verifiedIdenticalForCopy?.asOf == manager.fileOperationsEpoch)
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(refused(manager))
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.syncingDifferenceIds.isEmpty)
        #expect(manager.differences.count == 1)
        // The refusal path must not reset the running run's flag.
        #expect(manager.isBulkSyncRunning)
        manager.isBulkSyncRunning = false
    }

    /// A verified copy also refuses while Verify All runs: its writes would be hashed mid-write and
    /// could record bogus "identical" results. Built at a moved epoch, like the test above, so the
    /// guards it passes through on the way to `isVerifyAllRunning` aren't vacuous.
    @MainActor
    @Test func testVerifiedCopyRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM, _) = try makeFixture(names: [])
        let diffs = [addVerifiedPair(mockFM, "a.txt")]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.enqueueFileOperation { }
        try #require(manager.fileOperationsEpoch > 0)
        try #require(manager.activeFileOperationsCount == 0)

        manager.isVerifyAllRunning = true
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: diffs, asOf: manager.fileOperationsEpoch, fileManager: mockFM)
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(refused(manager))
        #expect(rightDate(mockFM, "a.txt") == Self.rightDate)
        #expect(manager.isVerifyAllRunning)
        manager.isVerifyAllRunning = false

        // With the verify run finished, the identical offer goes through.
        manager.banner = nil
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: diffs, asOf: manager.fileOperationsEpoch, fileManager: mockFM)
        await manager.confirmVerifiedCopy()?.value
        #expect(rightDate(mockFM, "a.txt") == Self.leftDate)
        #expect(!refused(manager))
    }

    /// While a verified copy is in flight it holds `isBulkSyncRunning`, so a concurrent `syncAll`
    /// is dropped before touching any file, and the run's exit releases the flag and tears down
    /// only its own progress.
    ///
    /// The run is held by its own write (a date, since it copies nothing), not by an operation
    /// parked ahead of it: an offer confirms only with the queue empty and its epoch current, so
    /// that state is unreachable. A second verified copy is unreachable too (the confirm nils the
    /// offer, and Verify All won't run during a bulk run); its refusal banner is pinned by
    /// `testVerifiedCopyRefusedWhileAnotherBulkRunIsInFlight`.
    @MainActor
    @Test(.parksAThread) func testVerifiedCopyExcludesConcurrentBulkRuns() async throws {
        let (manager, mockFM, fixtureDiffs) = try makeFixture(names: ["b.txt"])
        let verifiedDiff = addVerifiedPair(mockFM, "a.txt")
        let bulkDiff = fixtureDiffs[0]
        manager.rawDifferences = [verifiedDiff, bulkDiff]
        manager.differences = [verifiedDiff, bulkDiff]

        // Park the first date this run sets, so it is in flight during the assertions below, with
        // no sleeps and nothing queued ahead. The park is bounded and records its timeout, or a run
        // that was never held would look the same as one held while the drop happened.
        let gate = ParkGate()
        let parked = LockedBox(false)
        mockFM.beforeSetAttributes = { _ in
            let isFirst = parked.withLock { seen in defer { seen = true }; return !seen }
            guard isFirst else { return }
            gate.park()
        }

        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: [verifiedDiff], asOf: manager.fileOperationsEpoch, fileManager: mockFM)
        let copyTask = manager.confirmVerifiedCopy()
        try #require(copyTask != nil, "nothing is in flight and the stamp is current: the confirm must be accepted")
        await awaitSignal(gate.entered)
        #expect(manager.isBulkSyncRunning)
        #expect(manager.bulkSyncProgress != nil)

        // A bulk sync started now must be dropped, not queued behind the run. `syncAll` drops a
        // re-entrant run silently, so there is nothing to poll for: awaiting it before the release
        // proves the drop happened while the verified run was still parked.
        //
        // The silence is asserted because it names the guard: the run also holds
        // `syncingDifferenceIds`, so without the `isBulkSyncRunning` drop the next guard would
        // catch it and every other assertion would pass. That guard shows a banner; this one doesn't.
        let syncAllTask = Task { await manager.syncAll(direction: .copyToRight, subset: [bulkDiff]) }
        await syncAllTask.value
        #expect(manager.isBulkSyncRunning, "the verified run must still hold the exclusion it was dropped against")
        #expect(manager.banner == nil,
                "a re-entrant bulk run is dropped silently — a banner means a different guard refused it")

        gate.release.signal()
        await copyTask?.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the run was never actually held in flight")

        // Only the verified run's work happened; the dropped syncAll never touched b.txt.
        #expect(rightDate(mockFM, "a.txt") == Self.leftDate)
        #expect(mockFM.virtualDisk["/dst/b.txt"] == nil)
        #expect(manager.differences.map(\.relativePath) == ["b.txt"])
        // Exclusion fully released and progress torn down once the run exits.
        #expect(!manager.isBulkSyncRunning)
        #expect(manager.bulkSyncProgress == nil)
        #expect(manager.activeProgress == nil)
        #expect(manager.syncingDifferenceIds.isEmpty)
    }
}
