import Testing
import Foundation
@testable import Sync

/// Pins the configurable date tolerance in `FileDiffEngine.computeDifferences`: dates within
/// the tolerance compare as equal, the default stays at the historical 1 second, and 0 means
/// exact comparison.
@Suite struct DateToleranceTests {

    private let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", path: "/l", type: .iCloud)
    private let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", path: "/r", type: .dropBox)

    private func pair(secondsApart: TimeInterval, size: Int = 10) -> (l: [String: FileDiffEngine.FileInfo], r: [String: FileDiffEngine.FileInfo]) {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let l = ["a.txt": FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/l/a.txt"), modificationDate: base.addingTimeInterval(secondsApart), fileSize: size, isDirectory: false)]
        let r = ["a.txt": FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/r/a.txt"), modificationDate: base, fileSize: size, isDirectory: false)]
        return (l, r)
    }

    private func diffs(secondsApart: TimeInterval, tolerance: TimeInterval) -> [FileDifference] {
        let files = pair(secondsApart: secondsApart)
        return FileDiffEngine.computeDifferences(
            left: left,
            leftURL: URL(fileURLWithPath: "/l"),
            right: right,
            rightURL: URL(fileURLWithPath: "/r"),
            leftFilesInfo: files.l,
            rightFilesInfo: files.r,
            dateToleranceSeconds: tolerance
        )
    }

    @Test func testDatesWithinToleranceCompareEqual() {
        #expect(diffs(secondsApart: 3, tolerance: 5).isEmpty)
        #expect(diffs(secondsApart: 30, tolerance: 60).isEmpty)
    }

    @Test func testDatesBeyondToleranceReportADifference() {
        let result = diffs(secondsApart: 3, tolerance: 1)
        #expect(result.count == 1)
        #expect(result.first?.action == .copyToRight) // left is newer

        #expect(diffs(secondsApart: 90, tolerance: 60).count == 1)
    }

    @Test func testZeroToleranceComparesExactly() {
        #expect(diffs(secondsApart: 0.5, tolerance: 0).count == 1)
        #expect(diffs(secondsApart: 0, tolerance: 0).isEmpty)
    }

    @Test func testDefaultToleranceRemainsOneSecond() {
        let files = pair(secondsApart: 0.9)
        let result = FileDiffEngine.computeDifferences(
            left: left,
            leftURL: URL(fileURLWithPath: "/l"),
            right: right,
            rightURL: URL(fileURLWithPath: "/r"),
            leftFilesInfo: files.l,
            rightFilesInfo: files.r
        )
        #expect(result.isEmpty)
    }

    @Test func testSizeMismatchStillReportsInsideDateTolerance() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let l = ["a.txt": FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/l/a.txt"), modificationDate: base, fileSize: 10, isDirectory: false)]
        let r = ["a.txt": FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/r/a.txt"), modificationDate: base, fileSize: 12, isDirectory: false)]
        let result = FileDiffEngine.computeDifferences(
            left: left,
            leftURL: URL(fileURLWithPath: "/l"),
            right: right,
            rightURL: URL(fileURLWithPath: "/r"),
            leftFilesInfo: l,
            rightFilesInfo: r,
            dateToleranceSeconds: 3600
        )
        #expect(result.count == 1)
    }
}
