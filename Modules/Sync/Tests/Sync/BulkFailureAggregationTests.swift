import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// Pins the bulk-failure alert aggregation: `currentError` holds one error at a time, so a bulk
/// run with several failures presents one summary (each failure still logged) rather than one per
/// failure, which would leave only the last visible.
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
        #expect(error.message.contains("Activity’s log"))
        // The alert carries the first collected failure's details; worker order is
        // nondeterministic, so either source.
        #expect(error.path == "/src/a.txt" || error.path == "/src/b.txt")
        #expect(error.reason?.isEmpty == false)
        #expect(error.isRetryable == false)

        // The call site, not the rule (`recordTransferFailures` has its own tests): the run
        // records its failed rows for the Failed filter, and they are still listed for it to
        // select; otherwise it shows an empty table.
        #expect(manager.lastTransferFailures?.ids == Set(diffs.map(\.id)))
        #expect(Set(manager.differences.map(\.id)) == Set(diffs.map(\.id)))
    }

    /// A bulk run's single failure keeps its per-item error, and still reaches the persistent log,
    /// not just the alert. That branch logs nothing itself and relies on `present()`, so this fails
    /// if either the branch stops calling `present()` or `present()` stops logging.
    @MainActor
    @Test func testSyncAllWithSingleFailureKeepsPerItemError() async throws {
        let log = LogCapture()
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let diff = makeMissingSourceDiff("onlySyncLog.txt")
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        await manager.syncAll(direction: .copyToRight)

        let error = try #require(manager.currentError)
        #expect(error.title == "Sync Failed")
        #expect(error.message == "Couldn’t sync “onlySyncLog.txt”.")
        #expect(error.path == "/src/onlySyncLog.txt")
        #expect(await loggerHasError(log, containing: "onlySyncLog.txt"))
    }

    /// True when `log` captured an error entry containing `fragment`, a per-test file name so other
    /// tests' lines can't match. A capture, not the shared buffer, which other suites can evict.
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
        // Names where the failed rows are, not just the log. No single item name: the filter shows
        // all of them.
        #expect(error.message == "Couldn’t copy 3 items. They are listed under the “Failed to transfer” filter; the reason for each is in Activity’s log (⌘L).")
        #expect(error.path == "/src/a.txt")
        #expect(error.reason == "disk full")
        #expect(error.isRetryable == false)
    }

    // MARK: The failed rows, recorded where the table can find them

    /// A run with nothing to report clears the record, or the Failed filter keeps offering the
    /// previous run's rows after they went through.
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

    /// The second bulk path, Verify All's Match Dates, also records its failed rows and logs each
    /// as an error. Two call sites with the same code each need a test, or one can drift. The run
    /// sets dates, so the failure is a date that can't be set: the right files are locked (`uchg`),
    /// which `utimensat` refuses and a stat doesn't see.
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

        // `asOf` is re-checked against the live epoch when the write is ordered; the current one is
        // what a confirm with nothing in between carries.
        await manager.bulkCopyDifferencesLeftToRight(diffs, asOf: manager.fileOperationsEpoch, stamps: stamps)

        #expect(manager.lastTransferFailures?.ids == Set(diffs.map(\.id)), "the failed rows were not marked")
        #expect(manager.banner?.message == "0 dates matched; 2 failed")
        // One cause (the lock), so one group: a head line naming the first, and one line naming
        // both, sorted, rather than a line per file.
        let mine = await log.entries.filter { $0.level == .error && $0.message.contains(base.lastPathComponent) }
            .map { $0.message.components(separatedBy: " | Location: ")[0] }
        #expect(mine.count == 2, "\(mine)")
        #expect(mine.contains { $0.hasPrefix("Match dates: 2 item(s) failed — ") && $0.contains("v1-locked.txt: ") }, "\(mine)")
        #expect(mine.contains { $0.hasPrefix("Match dates: failed (")
            && $0.hasSuffix("\(right.path)/v1-locked.txt, \(right.path)/v2-locked.txt") }, "\(mine)")
    }
}
