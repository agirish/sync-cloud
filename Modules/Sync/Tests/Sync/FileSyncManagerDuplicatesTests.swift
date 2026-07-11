import Testing
import Foundation
@testable import Sync

/// Manager-level coverage for Tidy: the end-to-end scan (real files, so the SHA-256 layer runs)
/// and the resolve path (mock disk, so we can assert what gets trashed without touching ~/.Trash).
@Suite struct FileSyncManagerDuplicatesTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TidyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func findDuplicatesDetectsIdenticalFileEndToEnd() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two identical report.pdf files under different folders; distinct siblings keep the two
        // folders from themselves being reported as identical.
        try write(root.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("A/a-only.txt"), bytes: 8, fill: 0x61)
        try write(root.appendingPathComponent("B/b-only.txt"), bytes: 12, fill: 0x62)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)

        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.count == 1)
        let g = try #require(manager.duplicateGroups.first)
        #expect(g.matchType == .identical)
        #expect(g.isDirectory == false)
        #expect(g.name == "report.pdf")
        #expect(g.reclaimableBytes == 5000)
    }

    @MainActor
    @Test func findDuplicatesFindsNothingWhenTreeIsUnique() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("one.bin"), bytes: 5000, fill: 0x01)
        try write(root.appendingPathComponent("two.bin"), bytes: 5000, fill: 0x02)  // same size, different bytes

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)

        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.isEmpty)
    }

    @MainActor
    @Test func resolveTrashesRedundantCopyAndDropsGroup() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        let size: [FileAttributeKey: Any] = [.size: 8192]
        mockFM.virtualDisk["/root/A/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        mockFM.virtualDisk["/root/B/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)

        let keeper = DuplicateCopy(id: "/root/A/report.pdf", name: "report.pdf", isDirectory: false,
                                   size: 8192, itemCount: 1, modificationDate: nil, uniqueItemCount: 0,
                                   depth: 2, isRecommendedKeeper: true)
        let redundant = DuplicateCopy(id: "/root/B/report.pdf", name: "report.pdf", isDirectory: false,
                                      size: 8192, itemCount: 1, modificationDate: nil, uniqueItemCount: 0,
                                      depth: 2, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .identical, name: "report.pdf", isDirectory: false,
                                   copies: [keeper, redundant], reclaimableBytes: 8192)
        manager.duplicateGroups = [group]

        await manager.resolveDuplicateGroup(group)
        await waitUntil("redundant copy trashed") { mockFM.virtualDisk["/root/B/report.pdf"] == nil }

        #expect(mockFM.trashedPaths.count == 1)                               // exactly one trashed
        #expect(mockFM.virtualDisk["/root/A/report.pdf"] != nil)             // keeper untouched
        #expect(manager.duplicateGroups.isEmpty)
        #expect(manager.banner?.severity == .success)
    }

    @MainActor
    @Test func nameOnlyGroupHasNoRemovalAndStaysUntilDismissed() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        let a = DuplicateCopy(id: "/root/Screenshots", name: "Screenshots", isDirectory: true,
                              size: 100, itemCount: 2, modificationDate: nil, uniqueItemCount: 0,
                              depth: 0, isRecommendedKeeper: true)
        let b = DuplicateCopy(id: "/root/Work/Screenshots", name: "Screenshots", isDirectory: true,
                              size: 100, itemCount: 2, modificationDate: nil, uniqueItemCount: 2,
                              depth: 1, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .nameOnly, name: "Screenshots", isDirectory: true,
                                   copies: [a, b], reclaimableBytes: 0)
        manager.duplicateGroups = [group]

        // "Apply recommended" must never touch a name-only group.
        await manager.applyRecommendedDuplicates()
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.duplicateGroups.count == 1)

        // But it can be dismissed manually ("Keep separate").
        manager.dismissDuplicateGroup(group)
        #expect(manager.duplicateGroups.isEmpty)
    }
}
