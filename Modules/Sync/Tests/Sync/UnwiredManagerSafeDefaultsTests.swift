import Testing
import Foundation
@testable import Sync

/// Pins the fail-safe defaults of a freshly constructed `FileSyncManager` whose alert seams
/// (`collisionResolver`, `bulkCollisionResolver`, `permanentDeleteConfirmer`) were never wired.
/// Since Sync no longer depends on Design, the defaults are pure values instead of NSAlerts:
/// an unwired manager must skip collisions rather than overwrite, refuse permanent deletion,
/// and never require UI — `swift test` stays headless by construction, not just by convention.
@Suite struct UnwiredManagerSafeDefaultsTests {

    // MARK: - Default seam values (headless by construction)

    /// A collision context with the given flags, for exercising the default seams directly.
    private static func collision(isMove: Bool = false, isDirectory: Bool = false) -> FileCollision {
        FileCollision(sourcePath: "/src/collide.txt", destinationPath: "/dst/collide.txt", isMove: isMove, isDirectory: isDirectory)
    }

    /// The default single-item resolver answers `.skip` for both copies and moves, without UI.
    @MainActor
    @Test func testDefaultCollisionResolverSkips() {
        let manager = FileSyncManager()

        #expect(manager.collisionResolver(Self.collision(isMove: false)) == .skip)
        #expect(manager.collisionResolver(Self.collision(isMove: true)) == .skip)
        // A folder collision defaults to skip too — the isDirectory flag only affects wording.
        #expect(manager.collisionResolver(Self.collision(isDirectory: true)) == .skip)
    }

    /// The default bulk resolver skips the conflicting item and does not latch "apply to all",
    /// so a later wired resolver would still be consulted per item.
    @MainActor
    @Test func testDefaultBulkCollisionResolverSkipsWithoutApplyToAll() {
        let manager = FileSyncManager()

        let (resolution, applyToAll) = manager.bulkCollisionResolver(Self.collision())
        #expect(resolution == .skip)
        #expect(applyToAll == false)
    }

    /// The default transfer confirmer proceeds without UI — an unwired manager keeps its
    /// pre-confirmation behavior (transfers just run; replaces still prompt separately).
    @MainActor
    @Test func testDefaultTransferConfirmerProceeds() {
        let manager = FileSyncManager()

        let summary = TransferSummary(isMove: false, itemCount: 1, firstItemName: "a.txt", sourceDirectory: "/src", destinationDirectory: "/dst")
        #expect(manager.transferConfirmer(summary) == true)
    }

    /// The default permanent-delete confirmer refuses, without UI.
    @MainActor
    @Test func testDefaultPermanentDeleteConfirmerRefuses() {
        let manager = FileSyncManager()

        #expect(manager.permanentDeleteConfirmer(["data.bin"]) == false)
    }

    // MARK: - Filesystem behavior through the unwired defaults

    /// Copying onto an existing file with no resolver wired skips the item: the destination
    /// keeps its original attributes, nothing is trashed, and no copy primitive ever runs.
    @MainActor
    @Test func testUnwiredCopyCollisionSkipsAndLeavesDestinationUntouched() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/safeDefault.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/safeDefault.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        let node = FileNode(id: "/src/safeDefault.txt", name: "safeDefault.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        #expect(copied.isEmpty)
        #expect(mockFM.calledCopyItem == false)
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(mockFM.virtualDisk["/dst/safeDefault.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5)
        #expect(mockFM.virtualDisk["/dst/safeDefault 2.txt"] == nil)
        #expect(mockFM.virtualDisk["/src/safeDefault.txt"] != nil)
        #expect(manager.currentError == nil)
    }

    /// Moving onto an existing file with no resolver wired skips the item: the source stays
    /// in place and the destination is not replaced.
    @MainActor
    @Test func testUnwiredMoveCollisionSkipsAndLeavesBothSidesUntouched() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/safeMoveDefault.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/safeMoveDefault.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        let node = FileNode(id: "/src/safeMoveDefault.txt", name: "safeMoveDefault.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(mockFM.virtualDisk["/src/safeMoveDefault.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/safeMoveDefault.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5)
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.currentError == nil)
    }

    /// When the Trash is unavailable and no confirmer is wired, the item must survive:
    /// the default answer is "no", so nothing is permanently deleted.
    @MainActor
    @Test func testUnwiredDeleteWithTrashFailureDoesNotPermanentlyDelete() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/precious.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // Simulate a network volume that doesn't support the trash bin.
        mockFM.shouldFailTrash = true

        await manager.deleteItems(at: ["/src/precious.bin"], fileManager: mockFM)

        #expect(mockFM.virtualDisk["/src/precious.bin"] != nil)
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.currentError == nil)
    }
}
