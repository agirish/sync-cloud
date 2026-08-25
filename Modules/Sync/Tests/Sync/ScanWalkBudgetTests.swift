import Foundation
import Testing
@testable import Sync

/// **A comparison whose walk was stopped must never say anything is missing.**
///
/// The scan's cold (disk-walk) branch was unbounded, and it is the branch a first switch to a
/// source takes — so it is the one that ran during the ten-minute hang reported on 2026-08-24. The
/// budget stops it; these pin what a stopped walk is then allowed to claim.
///
/// The safety direction is the whole point and it is asymmetric. A truncated side has seen some
/// entries for real, so differences among entries BOTH sides hold are still true, and so is
/// "present here, absent from the complete other side". What it cannot know is absence on its own
/// side — and a Missing row there would offer to copy into, or "restore" from, a folder the walk
/// simply never reached.
@Suite struct ScanWalkBudgetTests {

    /// A real directory tree on disk — the enumerator is the subject, so a mock would be testing
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

    @Test func anUnboundedWalkStillReadsEverything() throws {
        let root = try makeTree(files: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let all = try FileDiffEngine.getFilesInDirectory(root)
        #expect(all.count == 40, "20 directories + 20 files, got \(all.count)")
        #expect(all[""] == nil, "an unbounded walk marked the root unexplored")
    }

    @Test func aBudgetedWalkStopsAndSaysSo() throws {
        let root = try makeTree(files: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let some = try FileDiffEngine.getFilesInDirectory(root, maxEntries: 10)
        #expect(some[""]?.isUnexplored == true,
                "the truncated walk did not mark the root unexplored — the diff will mint Missing rows for everything it never reached")
        // The root record is synthetic and added after the walk, so the entries it actually read
        // are one fewer than the map holds.
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

    /// **The safety property.** With the left walk truncated, nothing on the left may be reported
    /// missing — the right holds files the left never got to, and offering to copy them in would
    /// be acting on an observation nobody made.
    private var leftProvider: CloudProvider {
        CloudProvider(id: "L", displayName: "Left", imageName: "folder", path: "/l", type: .iCloud)
    }
    private var rightProvider: CloudProvider {
        CloudProvider(id: "R", displayName: "Right", imageName: "folder", path: "/r", type: .iCloud)
    }

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

    /// **A warm scan of a budget-stopped tree must banner its side.** The warm branch derives its
    /// maps from the cached pane trees, and a stopped walk's root was READABLE — so no `""` record
    /// exists, and the truncation lives only in per-directory `isUnexplored` marks an ordinary
    /// locked folder also wears. `prefetchedTreeWalkStopped` is the provenance that separates them,
    /// and before it was read here a warm scan of a truncated tree published `.complete` with no
    /// banner while the cold branch of the very same pair bannered.
    ///
    /// Premise-guarded on the branch actually taken: the mock records every directory listing, and
    /// the warm branch's whole identity is that it makes none. A test that fell through to the
    /// cold branch would be asserting the OTHER overload.
    @MainActor
    @Test func aWarmScanOverATruncatedCachedTreeBannersItsSide() async throws {
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
        manager.prefetchedTreeWalkStopped.insert("/l")

        let listings = LockedBox(0)
        mockFM.onEnumerate = { _ in listings.withLock { $0 += 1 } }

        await manager.scanDirectories(left: leftProvider, leftPath: "/l",
                                      right: rightProvider, rightPath: "/r")

        try #require(listings.withLock { $0 } == 0,
                     "the scan enumerated a directory — it took the cold branch, and this test is asserting nothing about the warm one")
        #expect(manager.lastScanCoverage == PartialComparison(left: true, right: false),
                "a warm scan of a truncated left tree published \(manager.lastScanCoverage) — the banner stays down over a comparison that is quietly a floor")
    }

    /// The same warm pair WITHOUT the provenance bit is complete: the left's unexplored directory
    /// is then an ordinary locked folder, whose rows `compare` already suppresses precisely. The
    /// bit — not the mark — is what changes the verdict, which is the conjunction's other half at
    /// this call site.
    @MainActor
    @Test func aWarmScanWithoutTheStoppedBitStaysComplete() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/l"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/r"), withIntermediateDirectories: true)
        let manager = FileSyncManager(fileManager: mockFM)
        manager.prefetchedTrees["/l"] = [
            FileNode(id: "/l/deep", name: "deep", isDirectory: true, children: [], isUnexplored: true),
        ]
        manager.prefetchedTrees["/r"] = [
            FileNode(id: "/r/other.txt", name: "other.txt", isDirectory: false),
        ]
        try #require(manager.prefetchedTreeWalkStopped.isEmpty, "the fixture armed the bit it exists to leave down")

        let listings = LockedBox(0)
        mockFM.onEnumerate = { _ in listings.withLock { $0 += 1 } }
        await manager.scanDirectories(left: leftProvider, leftPath: "/l",
                                      right: rightProvider, rightPath: "/r")

        try #require(listings.withLock { $0 } == 0, "the scan took the cold branch")
        #expect(manager.lastScanCoverage == .complete,
                "an ordinary locked folder bannered a warm scan — the warning people learn to stop reading")
    }

    /// **One verb drops the trees AND their provenance.** Every invalidation site goes through
    /// `dropPrefetchedTrees`; a site clearing the trees alone would leave a stale bit to be re-read
    /// the next time the same focus path is cached by a slice, and the banner would outlive the
    /// truncation it described.
    @MainActor
    @Test func droppingThePrefetchedTreesDropsTheirProvenanceWithThem() {
        let manager = FileSyncManager()
        manager.prefetchedTrees["/l"] = [FileNode(id: "/l/a", name: "a", isDirectory: false)]
        manager.prefetchedTreeWalkStopped.insert("/l")

        manager.dropPrefetchedTrees()

        #expect(manager.prefetchedTrees.isEmpty)
        #expect(manager.prefetchedTreeWalkStopped.isEmpty,
                "the trees were dropped and their walk-stopped provenance survived them")
    }

    /// The other direction stays live: what the truncated side DID see, it saw. Absence on the
    /// complete side is a real observation, so those rows must survive — a budget that silenced
    /// them would turn a slow comparison into a quietly empty one.
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
