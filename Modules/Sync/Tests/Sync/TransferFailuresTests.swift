import Foundation
import Testing
@testable import Sync

/// What a partial bulk transfer leaves behind for the Differences table to show.
///
/// The rows themselves were never the problem — `removeResolvedDifferences(matching:)` only drops
/// successes, so failures stay in the list. What was missing is any record of WHICH ones, and the
/// rules that record has to follow are all about staleness.
@MainActor
@Suite struct TransferFailuresTests {

    private static let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", path: "/left", type: .iCloud)
    private static let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", path: "/right", type: .iCloud)

    private func diff(_ name: String) -> FileDifference {
        FileDifference(relativePath: name, leftItemPath: "/l/\(name)", rightItemPath: "/r/\(name)",
                       type: .missingOnRight, action: .copyToRight, description: "d")
    }

    private func failure(_ name: String) -> (FileDifference, Error) {
        (diff(name), NSError(domain: "test", code: 1))
    }

    private func manager() -> FileSyncManager { FileSyncManager(fileManager: MockFileManager()) }

    @Test func testAPartialRunRecordsExactlyTheFailedRows() {
        let m = manager()
        let a = failure("a"), b = failure("b")

        m.recordTransferFailures([a, b])

        #expect(m.lastTransferFailures?.ids == Set([a.0.id, b.0.id]))
    }

    /// The half that is easy to leave out: a CLEAN run has to clear the previous run's record, or
    /// the Failed filter keeps offering rows that have since gone through and its count becomes a
    /// number nobody can reconcile.
    @Test func testACleanRunClearsThePreviousRunsFailures() {
        let m = manager()
        m.recordTransferFailures([failure("a")])
        #expect(m.lastTransferFailures != nil)

        m.recordTransferFailures([])

        #expect(m.lastTransferFailures == nil)
    }

    /// Two runs failing on the SAME rows must still publish as two events. The id set is equal, so
    /// a view watching the set would never see the second run — it would sit on whatever filter the
    /// user had switched back to, with a fresh alert on screen and nothing to click. The per-publish
    /// `id` is what makes them distinguishable, and it is part of `Equatable` on purpose.
    @Test func testTwoRunsFailingOnTheSameRowsPublishAsTwoEvents() {
        let m = manager()
        let a = failure("a")

        m.recordTransferFailures([a])
        let first = m.lastTransferFailures
        m.recordTransferFailures([a])
        let second = m.lastTransferFailures

        #expect(first?.ids == second?.ids, "the fixture must fail on the same rows, or this proves nothing")
        #expect(first != second)
        #expect(first?.id != second?.id)
    }

    /// A scan regenerates every row id, so a kept record would match nothing — harmless in itself,
    /// but it would leave the Failed filter in the menu at a count of zero with the user selected
    /// into an empty list.
    @Test func testAFreshScanClearsTheRecord() async {
        let mockFM = MockFileManager()
        try? mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try? mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)
        let m = FileSyncManager(fileManager: mockFM)
        m.recordTransferFailures([failure("a")])
        #expect(m.lastTransferFailures != nil)

        await m.scanDirectories(left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right")

        #expect(m.hasScanned, "the scan must have published, or the clear below proves nothing")
        #expect(m.lastTransferFailures == nil)
    }
}
