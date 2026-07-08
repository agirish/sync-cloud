import Testing
import Foundation
import Combine
@testable import Sync

/// Coverage for FileSyncManager state-machine behavior the audit found untested: the Google-Drive
/// date-noise filter in applyFilters(), the verified-same-content suppression (and its reset on a
/// fresh scan), and the bulk syncAll happy path with its per-item undo registration.
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

        let l = CloudProvider(id: "l", displayName: "L", imageName: "folder", path: "/src", type: .iCloud)
        let r = CloudProvider(id: "r", displayName: "R", imageName: "folder", path: "/dst", type: .iCloud)
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

        // A load+scan cycle runs several filter passes over unchanged inputs. Each rebuilds
        // fresh arrays, but republishing an equal tree makes SwiftUI rebuild the pane List,
        // and a rebuild landing mid-click drops it ("dead clicks"). So an identical pass must
        // touch no @Published property — ObservableObject must not announce a change.
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
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.undoManager = UndoManager()

        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let names = ["a.txt", "b.txt", "c.txt"]
        for n in names {
            mockFM.virtualDisk["/src/\(n)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        // Three copyToRight diffs (collision-free destinations) plus one copyToLeft that must be ignored.
        var diffs = names.map { n in
            FileDifference(relativePath: n, leftItemPath: "/src/\(n)", rightItemPath: "/dst/\(n)",
                           type: .missingOnRight, action: .copyToRight, description: "Missing on right")
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

        // Undoing the bulk op must remove every copied destination (source stays; it was a copy).
        func remainingDst() -> Int { names.filter { mockFM.virtualDisk["/dst/\($0)"] != nil }.count }
        manager.undoManager?.undo()
        let deadline = Date().addingTimeInterval(3.0)
        while remainingDst() > 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 40_000_000)
            if remainingDst() > 0, manager.undoManager?.canUndo == true {
                manager.undoManager?.undo()
            }
        }

        #expect(remainingDst() == 0)
        for n in names { #expect(mockFM.virtualDisk["/src/\(n)"] != nil) }
    }
}
