import Testing
import Foundation
@testable import Sync

/// Pins `syncFile`'s return value — the "did the operation actually run" signal the guided
/// review records outcomes from. This must stay truthful independent of the differences list:
/// the post-operation rescan regenerates row UUIDs, so list-based inference lies mid-session.
@Suite struct SyncFileOutcomeTests {

    /// A manager over a mock disk with `/src/test.txt` present and the collision seams stubbed
    /// (no NSAlert can appear); the returned difference copies it to `/dst/test.txt`.
    @MainActor
    private func makeFixture(destinationExists: Bool = false) throws -> (FileSyncManager, MockFileManager, FileDifference) {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        if destinationExists {
            mockFM.virtualDisk["/dst/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }

        let manager = FileSyncManager(fileManager: mockFM)
        manager.collisionResolver = { _, _, _ in .replace }
        manager.bulkCollisionResolver = { _, _, _ in (.replace, true) }

        let diff = FileDifference(
            relativePath: "test.txt",
            leftItemPath: "/src/test.txt",
            rightItemPath: "/dst/test.txt",
            type: destinationExists ? .differentDates : .missingOnRight,
            action: .copyToRight,
            description: "test"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        return (manager, mockFM, diff)
    }

    @MainActor
    @Test func plainCopyReturnsTrue() async throws {
        let (manager, mockFM, diff) = try makeFixture()
        let succeeded = await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        #expect(succeeded)
        #expect(mockFM.virtualDisk["/dst/test.txt"] != nil)
        #expect(manager.differences.isEmpty)
    }

    @MainActor
    @Test func sanctionedReplaceReturnsTrue() async throws {
        let (manager, mockFM, diff) = try makeFixture(destinationExists: true)
        let succeeded = await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        #expect(succeeded)
        // The replace went through the trash-backup path, as ever.
        #expect(mockFM.trashedPaths.count == 1)
    }

    @MainActor
    @Test func keepBothReturnsTrue() async throws {
        let (manager, mockFM, diff) = try makeFixture(destinationExists: true)
        manager.collisionResolver = { _, _, _ in .keepBoth }
        let succeeded = await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        #expect(succeeded)
        // Original untouched; the copy landed at a unique sibling.
        #expect(mockFM.virtualDisk["/dst/test.txt"] != nil)
        #expect(mockFM.virtualDisk.keys.contains { $0.hasPrefix("/dst/test") && $0 != "/dst/test.txt" })
    }

    @MainActor
    @Test func skipAtCollisionReturnsFalse() async throws {
        let (manager, mockFM, diff) = try makeFixture(destinationExists: true)
        manager.collisionResolver = { _, _, _ in .skip }
        let succeeded = await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        #expect(!succeeded)
        // Nothing happened: no trash, difference still live, no error presented.
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.differences.count == 1)
        #expect(manager.currentError == nil)
    }

    @MainActor
    @Test func failedOperationReturnsFalseAndPresentsTheError() async throws {
        let (manager, mockFM, diff) = try makeFixture()
        // Vanish the source so the copy itself throws.
        mockFM.virtualDisk.removeValue(forKey: "/src/test.txt")
        let succeeded = await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        #expect(!succeeded)
        #expect(manager.currentError != nil)
        #expect(manager.differences.count == 1)
    }
}
