import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// Pins the bulk-failure alert aggregation: `currentError` holds one error at a time, so a
/// bulk run with several failures must present a single aggregate summary (every failure is
/// still logged individually) instead of presenting per failure and leaving only the last
/// one visible.
@Suite struct BulkFailureAggregationTests {

    private func makeMissingSourceDiff(_ name: String) -> FileDifference {
        FileDifference(
            relativePath: name,
            leftItemPath: "/src/\(name)",
            rightItemPath: "/dst/\(name)",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing"
        )
    }

    @MainActor
    @Test func testSyncAllWithTwoFailuresPresentsOneAggregateError() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        // Neither source exists on the virtual disk, so both copies fail.
        let diffs = [makeMissingSourceDiff("a.txt"), makeMissingSourceDiff("b.txt")]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        let error = try #require(manager.currentError)
        #expect(error.title == "Sync Failed")
        #expect(error.message.contains("2 items"))
        #expect(error.message.contains("Activity Log"))
        // The alert carries the first failure's details (worker order is nondeterministic,
        // so "first" is whichever the run collected first — one of the two sources).
        #expect(error.path == "/src/a.txt" || error.path == "/src/b.txt")
        #expect(error.reason?.isEmpty == false)
        #expect(error.isRetryable == false)
    }

    @MainActor
    @Test func testSyncAllWithSingleFailureKeepsPerItemError() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let diff = makeMissingSourceDiff("only.txt")
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        await manager.syncAll(direction: .copyToRight)

        let error = try #require(manager.currentError)
        #expect(error.title == "Sync Failed")
        #expect(error.message == "Couldn’t sync “only.txt”.")
        #expect(error.path == "/src/only.txt")
    }

    /// A bulk run whose ONLY failure is a single file must still land in the persistent audit log,
    /// not just the (ephemeral) alert. The single-failure branch relies on `present()` to write the
    /// error line — unlike the `> 1` branch, it logs no line of its own — so these tests guard the
    /// invariant end-to-end: if either the branch stops calling `present()` or `present()` stops
    /// logging, a one-file failure would silently vanish from the log and these would fail.
    @MainActor
    @Test func testSyncAllSingleFailureIsLoggedAsError() async throws {
        let log = LogCapture()
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let diff = makeMissingSourceDiff("onlySyncLog.txt")
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        await manager.syncAll(direction: .copyToRight)

        #expect(await loggerHasError(log, containing: "onlySyncLog.txt"))
    }

    /// True when `log` captured an ERROR entry whose message contains `fragment` — the fragment is
    /// a per-test unique file name, so another test's lines can't false-match. A capture, not the
    /// shared buffer, so the rest of the package logging past the line cannot take it away.
    @MainActor
    private func loggerHasError(_ log: LogCapture, containing fragment: String) async -> Bool {
        await log.holds(.error, containing: fragment)
    }

    @Test func testBulkFailedConstructorShape() {
        let error = SyncError.bulkFailed(
            verb: "copy",
            failureCount: 3,
            firstPath: "/src/a.txt",
            firstReason: "disk full"
        )
        #expect(error.title == "Copy Failed")
        // Names where the failed ROWS are, not only where the error text is. `firstItem` is no
        // longer in the message — one name out of N was never the useful part, and the filter
        // shows all of them.
        #expect(error.message == "Couldn’t copy 3 items. They are listed under the “Failed to transfer” filter; the reason for each is in the Activity Log.")
        #expect(error.path == "/src/a.txt")
        #expect(error.reason == "disk full")
        #expect(error.isRetryable == false)
    }

    // MARK: The failed rows, recorded where the table can find them

    /// The CALL SITE, not the rule: `recordTransferFailures` is unit-tested on its own, and a pure
    /// function's test says nothing about whether anything calls it. This drives a real `syncAll`
    /// whose copies all fail and asserts the record came out the other end.
    @MainActor
    @Test func testSyncAllRecordsItsFailedRowsForTheFailedFilter() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let diffs = [makeMissingSourceDiff("a.txt"), makeMissingSourceDiff("b.txt")]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        #expect(manager.lastTransferFailures?.ids == Set(diffs.map(\.id)))
        // ...and the rows themselves are still in the list for that filter to select — a record
        // pointing at rows the run had removed would show an empty table.
        #expect(Set(manager.differences.map(\.id)) == Set(diffs.map(\.id)))
    }

    /// The same call site's other half: a run with nothing to report clears the record. Without
    /// this the Failed filter would keep offering the previous run's rows after they went through.
    @MainActor
    @Test func testACleanSyncAllClearsAPreviousRunsFailedRows() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // A real, copyable file this time, so the run succeeds.
        mockFM.virtualDisk["/src/ok.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let diff = makeMissingSourceDiff("ok.txt")
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        // Stand in for an earlier partial run.
        manager.recordTransferFailures([(makeMissingSourceDiff("old.txt"), NSError(domain: "t", code: 1))])

        await manager.syncAll(direction: .copyToRight)

        #expect(manager.currentError == nil, "the fixture must SUCCEED, or this passes for the wrong reason")
        #expect(manager.lastTransferFailures == nil)
    }

    /// The SECOND bulk path — Verify All's Match Dates — records its failed rows and logs each as
    /// an error too.
    ///
    /// This test exists because deleting the call in this path left all 1403 Sync tests green: the
    /// `syncAll` test above covers one site and says nothing about the other, and two call sites
    /// with identical code is exactly the shape where one gets fixed and one does not. The run
    /// copied then; it sets dates now (review E6), so the failure is a date that cannot be set:
    /// the right files are locked (`uchg`), which `utimensat` refuses and a stat does not see.
    @MainActor
    @Test func testTheMatchDatesPathRecordsAndLogsItsFailedRowsToo() async throws {
        let log = LogCapture()
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MatchDatesFailure-\(UUID().uuidString)")
        let left = base.appendingPathComponent("left"), right = base.appendingPathComponent("right")
        for dir in [left, right] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        var diffs: [FileDifference] = []
        for name in ["v1-locked.txt", "v2-locked.txt"] {
            let l = left.appendingPathComponent(name), r = right.appendingPathComponent(name)
            try Data("same".utf8).write(to: l)
            try Data("same".utf8).write(to: r)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: l.path)
            try #require(chflags(r.path, UInt32(UF_IMMUTABLE)) == 0)
            diffs.append(FileDifference(relativePath: name, leftItemPath: l.path, rightItemPath: r.path,
                                        type: .differentDates, action: .copyToRight, description: "d",
                                        leftFileSize: 4, rightFileSize: 4))
        }
        defer {
            for diff in diffs { _ = chflags(diff.rightItemPath, 0) }
            try? fm.removeItem(at: base)
        }
        let manager = FileSyncManager()
        manager.rawDifferences = diffs
        manager.differences = diffs
        let stamps = Dictionary(uniqueKeysWithValues: diffs.map { ($0.id, FilePairStamp.read($0, fileManager: fm)) })

        // `asOf` is re-checked against the live epoch at the point the write is ordered; passing
        // the current one is what a confirm with nothing in between would have carried.
        await manager.bulkCopyDifferencesLeftToRight(diffs, asOf: manager.fileOperationsEpoch, stamps: stamps)

        #expect(manager.lastTransferFailures?.ids == Set(diffs.map(\.id)), "the failed rows were not marked")
        #expect(manager.banner?.message == "0 dates matched; 2 failed")
        #expect(await loggerHasError(log, containing: "v1-locked.txt"))
        #expect(await loggerHasError(log, containing: "v2-locked.txt"))
    }
}
