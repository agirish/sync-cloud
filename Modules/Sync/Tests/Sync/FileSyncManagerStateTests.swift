import Testing
import Foundation
import Combine
@testable import Sync

/// FileSyncManager state: the Google Drive date-noise filter in applyFilters(), verified-same
/// suppression (reset by a fresh scan), and the bulk syncAll happy path with its undo.
@Suite struct FileSyncManagerStateTests {

    private func dateDiff(_ rel: String, action: FileDifference.SyncAction, leftSize: Int?, rightSize: Int?) -> FileDifference {
        FileDifference(
            relativePath: rel,
            leftItemPath: "/l/\(rel)", rightItemPath: "/r/\(rel)",
            type: .differentDates, action: action,
            description: "diff", leftFileSize: leftSize, rightFileSize: rightSize)
    }

    // MARK: applyFilters — Google Drive newer-date-only noise filter

    @MainActor
    @Test func testGoogleDriveFilterHidesOnlyRightNewerSameSize() async {
        let manager = FileSyncManager()
        // The one that must be hidden: right-is-newer (copyToLeft), same size, on a Drive right pane.
        let noise = dateDiff("noise.txt", action: .copyToLeft, leftSize: 100, rightSize: 100)
        // Must survive: opposite direction (left newer).
        let keepDirection = dateDiff("dir.txt", action: .copyToRight, leftSize: 100, rightSize: 100)
        // Must survive: sizes differ, so it is a real change, not date noise.
        let keepSize = dateDiff("size.txt", action: .copyToLeft, leftSize: 100, rightSize: 200)

        manager.rawDifferences = [noise, keepDirection, keepSize]
        manager.lastRightProviderType = .googleDrive
        manager.ignoreGoogleDriveNewerDateOnly = true // didSet kicks off an async pass
        // The didSet's pass is fire-and-forget; await one explicitly for a deterministic
        // read (the generation guard makes both passes publish identical state).
        await manager.applyFilters()

        let ids = Set(manager.differences.map(\.id))
        #expect(!ids.contains(noise.id))
        #expect(ids.contains(keepDirection.id))
        #expect(ids.contains(keepSize.id))
    }

    @MainActor
    @Test func testGoogleDriveFilterInactiveWhenRightIsNotDriveOrToggleOff() async {
        let manager = FileSyncManager()
        let noise = dateDiff("noise.txt", action: .copyToLeft, leftSize: 100, rightSize: 100)
        manager.rawDifferences = [noise]

        // Toggle on, but the right pane is not Google Drive -> nothing filtered.
        manager.lastRightProviderType = .iCloud
        manager.ignoreGoogleDriveNewerDateOnly = true
        await manager.applyFilters()
        #expect(manager.differences.count == 1)

        // Right pane is Drive, but the toggle is off -> nothing filtered.
        manager.ignoreGoogleDriveNewerDateOnly = false
        manager.lastRightProviderType = .googleDrive
        await manager.applyFilters()
        #expect(manager.differences.count == 1)
    }

    // MARK: verifiedSameDifferenceIds suppression

    @MainActor
    @Test func testVerifiedDifferenceSuppressedThenClearedByRescan() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        let diff = dateDiff("same.txt", action: .copyToRight, leftSize: 10, rightSize: 10)
        manager.rawDifferences = [diff]
        manager.verifiedSameDifferenceIds.insert(diff.id)
        await manager.applyFilters()
        // Verified-identical ids are hidden from the list until the next scan.
        #expect(manager.differences.isEmpty)

        // A fresh scan must clear the verified set so nothing is wrongly suppressed afterwards.
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/new.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let l = CloudProvider(id: "l", displayName: "L", imageName: "folder", rootPath: "/src", type: .iCloud)
        let r = CloudProvider(id: "r", displayName: "R", imageName: "folder", rootPath: "/dst", type: .iCloud)
        await manager.scanDirectories(left: l, leftPath: "/src", right: r, rightPath: "/dst")

        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 1)
        #expect(manager.differences.first?.relativePath == "new.txt")
    }

    // MARK: applyFilters — no-op republish suppression (dead-click guard)

    @MainActor
    @Test func testUnchangedFilterPassDoesNotRepublish() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = [FileNode(id: "/l/a", name: "a", isDirectory: false)]
        manager.rawRightTree = [FileNode(id: "/r/b", name: "b", isDirectory: false)]
        manager.rawDifferences = [dateDiff("a", action: .copyToRight, leftSize: 1, rightSize: 2)]

        // First pass settles the published state.
        await manager.applyFilters()

        // A load+scan cycle runs several filter passes over unchanged inputs, and republishing an
        // equal tree makes SwiftUI rebuild the pane List, which drops a click landing mid-rebuild
        // ("dead clicks"). So an identical pass must touch no @Published property.
        var willChangeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in willChangeCount += 1 }
        defer { cancellable.cancel() }

        await manager.applyFilters()
        #expect(willChangeCount == 0)

        // Sanity: a genuine change must still publish, so the guard isn't over-suppressing.
        manager.rawDifferences = []
        await manager.applyFilters()
        #expect(willChangeCount > 0)
    }

    // MARK: syncAll bulk copy + undo

    @MainActor
    @Test func testSyncAllCopyToRightOnlySyncsDirectionAndUndoesAll() async throws {
        let store = makeTempHistoryStore(prefix: "FileSyncManagerStateTest")
        defer { removeHistoryStoreFiles(store) }
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.syncHistoryStore = store
        manager.undoManager = UndoManager()

        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let names = ["a.txt", "b.txt", "c.txt"]
        let sizes = ["a.txt": 10, "b.txt": 20, "c.txt": 30]
        for n in names {
            mockFM.virtualDisk["/src/\(n)"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: sizes[n]!], contents: nil)
        }
        // Three copyToRight diffs (collision-free destinations) plus one copyToLeft that must be ignored.
        var diffs = names.map { n in
            FileDifference(relativePath: n, leftItemPath: "/src/\(n)", rightItemPath: "/dst/\(n)",
                           type: .missingOnRight, action: .copyToRight, description: "Missing on right",
                           leftFileSize: sizes[n])
        }
        diffs.append(FileDifference(relativePath: "z.txt", leftItemPath: "/src/z.txt", rightItemPath: "/dst/z.txt",
                                    type: .missingOnLeft, action: .copyToLeft, description: "Missing on left"))
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        // Only the copyToRight items were copied; each landed at its destination.
        for n in names { #expect(mockFM.virtualDisk["/dst/\(n)"] != nil) }
        // The synced diffs are removed; the opposite-direction one is untouched.
        #expect(manager.differences.map(\.relativePath) == ["z.txt"])
        #expect(manager.undoManager?.canUndo == true)

        // Every item is recorded in Sync History under one run id, with its size.
        #expect(store.records.count == 3)
        #expect(Set(store.records.map(\.runId)).count == 1)
        #expect(store.records.allSatisfy { $0.action == .copy && $0.direction == "→ Right" })
        #expect(Set(store.records.compactMap(\.sizeBytes)) == [10, 20, 30])
        #expect(store.recordsForRun(try #require(store.lastRunId)).count == 3)

        // Undoing the bulk op must remove every copied destination (source stays; it was a copy).
        func remainingDst() -> Int { names.filter { mockFM.virtualDisk["/dst/\($0)"] != nil }.count }
        // One ⌘Z undoes the whole run, so it is pressed once: pressing again while anything was
        // left would pass a run registered as three groups.
        manager.undoManager?.undo()
        #expect(manager.undoManager?.canUndo == false, "the bulk run was registered as more than one undo")
        // A bound, not a pace: the removals run as file-queue operations, which a loaded run can
        // hold up for seconds (docs/flaky-tests.md, "Fixed pumps and fixed sleeps"). The copies are
        // asserted present above, so this waits on a real transition.
        await waitUntil("every copied destination removed") { remainingDst() == 0 }
        for n in names { #expect(mockFM.virtualDisk["/src/\(n)"] != nil) }
    }
}
