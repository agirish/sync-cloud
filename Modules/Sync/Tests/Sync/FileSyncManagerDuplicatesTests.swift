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

    // MARK: Group builders for state-level tests

    private func copy(_ path: String, keeper: Bool, size: Int = 1000) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: size, itemCount: 1, modificationDate: nil,
                      uniqueItemCount: keeper ? 0 : 1, depth: path.filter { $0 == "/" }.count,
                      isRecommendedKeeper: keeper)
    }
    private func grp(_ type: DuplicateMatchType, keeper: String, redundant: [String], reclaim: Int) -> DuplicateGroup {
        DuplicateGroup(matchType: type, name: (keeper as NSString).lastPathComponent, isDirectory: false,
                       copies: [copy(keeper, keeper: true)] + redundant.map { copy($0, keeper: false) },
                       reclaimableBytes: reclaim)
    }

    @MainActor
    @Test func summaryCountsOnlyBatchEligibleGroups() {
        let manager = FileSyncManager()
        manager.duplicateGroups = [
            grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 100),
            grp(.versions, keeper: "/a/r (1).doc", redundant: ["/a/r.doc"], reclaim: 50),
            grp(.overlapping(sharedFraction: 0.9), keeper: "/a/Inv", redundant: ["/b/Inv"], reclaim: 40),
            grp(.nameOnly, keeper: "/a/S", redundant: ["/b/S"], reclaim: 0),
        ]
        let s = manager.duplicateSummary
        #expect(s.groupCount == 4)
        #expect(s.reclaimableBytes == 100)   // identical only — versions/overlapping don't inflate it
        #expect(s.redundantCopyCount == 1)   // only the identical group's redundant copy
        #expect(s.needsReviewCount == 1)     // the name-only group
    }

    @MainActor
    @Test func applyRecommendedTrashesIdenticalButNotVersionsOrOverlapping() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        for p in ["/b/x", "/a/r.doc", "/b/Inv"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        manager.duplicateGroups = [
            grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000),
            grp(.versions, keeper: "/a/r (1).doc", redundant: ["/a/r.doc"], reclaim: 500),
            grp(.overlapping(sharedFraction: 0.9), keeper: "/a/Inv", redundant: ["/b/Inv"], reclaim: 400),
        ]

        await manager.applyRecommendedDuplicates()
        await waitUntil("identical redundant trashed") { mockFM.virtualDisk["/b/x"] == nil }

        #expect(mockFM.trashedPaths.count == 1)                       // only the identical copy
        #expect(mockFM.virtualDisk["/a/r.doc"] != nil)               // versions copy untouched
        #expect(mockFM.virtualDisk["/b/Inv"] != nil)                 // overlapping copy untouched
        #expect(manager.duplicateGroups.count == 2)                  // identical group removed, others remain
        #expect(!manager.duplicateGroups.contains { $0.matchType == .identical })
    }

    @MainActor
    @Test func resolveReturnsFalseAndKeepsGroupWhenNothingIsTrashed() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true                                // no Trash on this volume
        let manager = FileSyncManager(fileManager: mockFM)           // permanentDeleteConfirmer defaults to false
        mockFM.virtualDisk["/b/x"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 1000], contents: nil)
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000)
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false)                                         // nothing removed
        #expect(mockFM.virtualDisk["/b/x"] != nil)                   // file still there
        #expect(manager.duplicateGroups.count == 1)                  // group NOT dropped
        #expect(manager.banner == nil)                               // no false "Reclaimed" banner
    }

    @MainActor
    @Test func keepSeparatePersistsAcrossRescans() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("A/a-only.txt"), bytes: 8, fill: 0x61)
        try write(root.appendingPathComponent("B/b-only.txt"), bytes: 12, fill: 0x62)

        let manager = FileSyncManager()
        let suite = "TidyIgnoreTest-\(UUID().uuidString)"
        manager.duplicateIgnoreDefaults = UserDefaults(suiteName: suite)!
        defer { manager.duplicateIgnoreDefaults.removePersistentDomain(forName: suite) }

        await manager.findDuplicates(root: root)
        #expect(manager.duplicateGroups.count == 1)
        let group = try #require(manager.duplicateGroups.first)

        manager.keepDuplicateGroupSeparate(group)
        #expect(manager.duplicateGroups.isEmpty)

        // Rescan — a kept-separate cluster must not reappear.
        await manager.findDuplicates(root: root)
        #expect(manager.duplicateGroups.isEmpty)
    }

    @MainActor
    @Test func clearDuplicatesResetsScanState() {
        let manager = FileSyncManager()
        manager.duplicateGroups = [grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1)]
        manager.duplicateScanRoot = "/a"
        manager.hasFoundDuplicates = true

        manager.clearDuplicates()

        #expect(manager.duplicateGroups.isEmpty)
        #expect(manager.duplicateScanRoot == nil)
        #expect(manager.hasFoundDuplicates == false)
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
