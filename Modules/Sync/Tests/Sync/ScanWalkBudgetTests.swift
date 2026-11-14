import Foundation
import Testing
@testable import Sync

/// A comparison whose walk was stopped must never say anything is missing. The cold (disk-walk)
/// branch, which a first switch to a source takes, is bounded by a budget; these pin what a stopped
/// walk may then claim. The rule is asymmetric: a truncated side's entries are real, so differences
/// among entries both sides hold stay true, and so does "present here, absent from the complete
/// other side". Absence on its own side it can't know, and a Missing row there would offer to copy
/// into, or restore from, a folder the walk never reached.
@Suite struct ScanWalkBudgetTests {

    /// A real directory tree on disk: the enumerator is the subject, so a mock would test
    /// something else.
    private func makeTree(files: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanbudget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<files {
            let dir = root.appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("f\(i).txt"))
        }
        return root
    }

    // MARK: - The bound itself

    @Test func aBudgetedWalkStopsAndSaysSo() throws {
        let root = try makeTree(files: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let some = try FileDiffEngine.getFilesInDirectory(root, maxEntries: 10)
        #expect(some[""]?.isUnexplored == true,
                "the truncated walk did not mark the root unexplored — the diff will mint Missing rows for everything it never reached")
        // The root record is synthetic and added after the walk, so the walk read one fewer entry
        // than the map holds.
        #expect(some.count <= 12, "the walk ran well past its budget: \(some.count) entries against 10")
        #expect(some.count > 1, "the walk recorded nothing — the budget stopped it before it started")
    }

    /// A budget larger than the tree must leave no trace at all. Otherwise every ordinary scan
    /// would start claiming its side is incomplete, and every Missing row in the app would vanish.
    @Test func aBudgetTheTreeNeverReachesChangesNothing() throws {
        let root = try makeTree(files: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let bounded = try FileDiffEngine.getFilesInDirectory(root, maxEntries: 10_000)
        let unbounded = try FileDiffEngine.getFilesInDirectory(root)
        #expect(bounded.keys.sorted() == unbounded.keys.sorted())
        #expect(bounded[""] == nil, "an unreached budget still marked the side incomplete")
    }

    // MARK: - What the diff then does with it, which is the part that matters

    private var leftProvider: CloudProvider {
        CloudProvider(id: "L", displayName: "Left", imageName: "folder", rootPath: "/l", type: .iCloud)
    }
    private var rightProvider: CloudProvider {
        CloudProvider(id: "R", displayName: "Right", imageName: "folder", rootPath: "/r", type: .iCloud)
    }

    /// The safety property: with the left walk truncated, nothing on the left may be reported
    /// missing. The right holds files the left never reached, and offering to copy them in would
    /// act on an observation nobody made.
    @Test func aTruncatedSideNeverGetsMissingRows() {
        let complete: [String: FileDiffEngine.FileInfo] = [
            "a.txt": .init(url: URL(fileURLWithPath: "/r/a.txt"), modificationDate: nil, fileSize: 1, isDirectory: false),
            "b.txt": .init(url: URL(fileURLWithPath: "/r/b.txt"), modificationDate: nil, fileSize: 1, isDirectory: false),
        ]
        let truncated: [String: FileDiffEngine.FileInfo] = [
            "": .init(url: URL(fileURLWithPath: "/l"), modificationDate: nil, fileSize: nil,
                      isDirectory: true, isUnexplored: true)
        ]
        let diffs = FileDiffEngine.computeDifferences(
            left: leftProvider, leftURL: URL(fileURLWithPath: "/l"),
            right: rightProvider, rightURL: URL(fileURLWithPath: "/r"),
            leftFilesInfo: truncated, rightFilesInfo: complete)
        #expect(diffs.isEmpty,
                "a truncated left side produced \(diffs.count) rows — every one of them claims something is missing from a folder the walk never read")
    }

    // MARK: - The warm branch, where the maps alone cannot say the walk was stopped

    /// A warm scan of a budget-stopped tree must banner its side. The warm branch builds its maps
    /// from the cached pane trees, and a stopped walk's root was readable, so there is no `""`
    /// record; the truncation shows only as `isUnexplored` marks, which an ordinary locked folder
    /// also wears. `prefetchedTreeWalkStopped` is what tells them apart. Premise-guarded on the
    /// branch: the warm branch lists no directories, so any listing means the cold one ran.
    ///
    /// The same warm pair without the walk-stopped bit is complete: the unexplored directory is
    /// then an ordinary locked folder, whose rows `compare` already suppresses. The bit, not the
    /// mark, changes the verdict.
    @MainActor
    @Test(arguments: [(true, PartialComparison(left: true, right: false)), (false, PartialComparison.complete)])
    func aWarmScanOverATruncatedCachedTreeBannersItsSide(walkStopped: Bool, coverage: PartialComparison) async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/l"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/r"), withIntermediateDirectories: true)
        let manager = FileSyncManager(fileManager: mockFM)

        // The left cache holds what a budget-stopped deep walk leaves behind: a directory the walk
        // never entered, marked unexplored, beside entries it really did read.
        manager.prefetchedTrees["/l"] = [
            FileNode(id: "/l/deep", name: "deep", isDirectory: true, children: [], isUnexplored: true),
            FileNode(id: "/l/seen.txt", name: "seen.txt", isDirectory: false),
        ]
        manager.prefetchedTrees["/r"] = [
            FileNode(id: "/r/other.txt", name: "other.txt", isDirectory: false),
        ]
        if walkStopped {
            manager.prefetchedTreeWalkStopped.insert("/l")
        } else {
            try #require(manager.prefetchedTreeWalkStopped.isEmpty, "the fixture armed the bit it exists to leave down")
        }

        let listings = LockedBox(0)
        mockFM.onEnumerate = { _ in listings.withLock { $0 += 1 } }

        await manager.scanDirectories(left: leftProvider, leftPath: "/l",
                                      right: rightProvider, rightPath: "/r")

        try #require(listings.withLock { $0 } == 0,
                     "the scan enumerated a directory — it took the cold branch, and this test is asserting nothing about the warm one")
        #expect(manager.lastScanCoverage == coverage, walkStopped
                ? "a warm scan of a truncated left tree published \(manager.lastScanCoverage) — the banner stays down over a comparison that is quietly a floor"
                : "an ordinary locked folder bannered a warm scan — the warning people learn to stop reading")
    }

    /// The other direction stays live: what the truncated side did see, it saw. Absence on the
    /// complete side is a real observation, so those rows must survive, or a slow comparison turns
    /// quietly empty.
    @Test func whatTheTruncatedSideDidSeeIsStillCompared() {
        let truncated: [String: FileDiffEngine.FileInfo] = [
            "": .init(url: URL(fileURLWithPath: "/l"), modificationDate: nil, fileSize: nil,
                      isDirectory: true, isUnexplored: true),
            "seen.txt": .init(url: URL(fileURLWithPath: "/l/seen.txt"), modificationDate: nil,
                              fileSize: 1, isDirectory: false),
        ]
        let complete: [String: FileDiffEngine.FileInfo] = [:]
        let diffs = FileDiffEngine.computeDifferences(
            left: leftProvider, leftURL: URL(fileURLWithPath: "/l"),
            right: rightProvider, rightURL: URL(fileURLWithPath: "/r"),
            leftFilesInfo: truncated, rightFilesInfo: complete)
        #expect(diffs.count == 1,
                "the entry the truncated walk really did read stopped being compared — expected one row, got \(diffs.count)")
        #expect(diffs.first?.relativePath == "seen.txt")
    }
}
