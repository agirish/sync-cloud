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
