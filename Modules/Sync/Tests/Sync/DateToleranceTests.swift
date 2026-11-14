import Testing
import Foundation
@testable import Sync

/// Pins the configurable date tolerance in `FileDiffEngine.computeDifferences`: dates within the
/// tolerance compare as equal, the default is 1 second, and 0 means exact comparison.
@Suite struct DateToleranceTests {

    private let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: "/l", type: .iCloud)
    private let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: "/r", type: .dropBox)

    /// One file on each side, the left `apart` seconds newer; a nil tolerance takes the default.
    private func diffs(apart: TimeInterval, tolerance: TimeInterval?, rightSize: Int = 10) -> [FileDifference] {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let l = ["a.txt": FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/l/a.txt"), modificationDate: base.addingTimeInterval(apart), fileSize: 10, isDirectory: false)]
        let r = ["a.txt": FileDiffEngine.FileInfo(url: URL(fileURLWithPath: "/r/a.txt"), modificationDate: base, fileSize: rightSize, isDirectory: false)]
        guard let tolerance else {
            return FileDiffEngine.computeDifferences(left: left, leftURL: URL(fileURLWithPath: "/l"), right: right,
                                                     rightURL: URL(fileURLWithPath: "/r"), leftFilesInfo: l, rightFilesInfo: r)
        }
        return FileDiffEngine.computeDifferences(left: left, leftURL: URL(fileURLWithPath: "/l"), right: right,
                                                 rightURL: URL(fileURLWithPath: "/r"), leftFilesInfo: l, rightFilesInfo: r,
                                                 dateToleranceSeconds: tolerance)
    }

    /// (seconds apart, tolerance or nil for the default, differences expected). The default rows
    /// pin it to 1 second from both sides.
    @Test(arguments: [
        (3.0, 5.0, 0), (30, 60, 0),           // within the tolerance
        (3, 1, 1), (90, 60, 1),               // beyond it
        (0.5, 0, 1), (0, 0, 0),               // zero compares exactly
        (0.9, nil, 0), (1.5, nil, 1),         // the default
    ] as [(TimeInterval, TimeInterval?, Int)])
    func testDatesCompareEqualOnlyWithinTheTolerance(apart: TimeInterval, tolerance: TimeInterval?, count: Int) {
        #expect(diffs(apart: apart, tolerance: tolerance).count == count)
    }

    @Test func aDifferenceBeyondToleranceCopiesTheNewerSide() {
        let result = diffs(apart: 3, tolerance: 1)
        #expect(result.first?.action == .copyToRight) // left is newer
        #expect(result.first?.relativePath == "a.txt")
        #expect(result.first?.type == .differentDates)
    }

    @Test func testSizeMismatchStillReportsInsideDateTolerance() {
        let result = diffs(apart: 0, tolerance: 3600, rightSize: 12)
        #expect(result.count == 1)
        #expect(result.first?.relativePath == "a.txt")
        // The engine files a size difference under the generic "differentDates" type.
        #expect(result.first?.type == .differentDates)
    }
}
