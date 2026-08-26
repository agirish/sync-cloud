import Testing
import Foundation
import Combine
@testable import Sync

/// Manager-level coverage for the duplicate finder: the end-to-end scan (real files, so the SHA-256 layer runs)
/// and the resolve path (mock disk, so we can assert what gets trashed without touching ~/.Trash).
@Suite struct FileSyncManagerDuplicatesTests {


    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func findDuplicatesDetectsIdenticalFileEndToEnd() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
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
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
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
    @Test func findDuplicatesCountsCandidatesSkippedForSize() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // Two byte-identical files over the (injected) hash cap: they are size-collision
        // candidates, but hashing skips both — so no group can form, and the scan must SAY so
        // instead of silently reporting "no duplicates".
        try write(root.appendingPathComponent("A/movie.mp4"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("B/movie.mp4"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        // `cache: nil` throughout. This test scans the SAME files at two different caps, and a
        // cache hit deliberately bypasses the cap — the cache holds digests, while the cap only
        // decides whether computing one is worth it. Sharing one across these scans would let the
        // real-cap run at line 3 answer for the capped run below it, which is correct behavior and
        // the wrong thing to measure here: what is under test is the SKIP classification.
        await manager.findDuplicates(root: root, maxBytesToHash: 1000, cache: nil)

        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.isEmpty)                      // identity unknown → no claim
        #expect(manager.duplicateScanSkips.tooLarge == 2)
        #expect(manager.duplicateScanSkips.cloudOnly == 0)
        #expect(manager.duplicateScanSkips.total == 2)

        // A rescan with the real cap hashes them — and resets the skip figure with the results.
        await manager.findDuplicates(root: root, cache: nil)
        #expect(manager.duplicateScanSkips == FileSyncManager.DuplicateScanSkips())
        #expect(manager.duplicateGroups.count == 1)

        // clearDuplicates resets it alongside the rest of the results state.
        await manager.findDuplicates(root: root, maxBytesToHash: 1000, cache: nil)
        #expect(manager.duplicateScanSkips.total == 2)
        manager.clearDuplicates()
        #expect(manager.duplicateScanSkips == FileSyncManager.DuplicateScanSkips())
    }

    @MainActor
    @Test func findDuplicatesSkipsAndCountsCloudOnlyCandidatesWithoutReadingThem() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // Two identical files "flagged" dataless via the injected seam (a real SF_DATALESS file
        // can't be fabricated), plus a genuinely local identical pair that must still group.
        try write(root.appendingPathComponent("A/cloud.mov"), bytes: 6000, fill: 0x43)
        try write(root.appendingPathComponent("B/cloud.mov"), bytes: 6000, fill: 0x43)
        try write(root.appendingPathComponent("A/local.pdf"), bytes: 5000, fill: 0x4C)
        try write(root.appendingPathComponent("B/local.pdf"), bytes: 5000, fill: 0x4C)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, isCloudOnly: { $0.hasSuffix("cloud.mov") })

        #expect(manager.duplicateScanSkips.cloudOnly == 2)
        #expect(manager.duplicateScanSkips.tooLarge == 0)
        // The unhashed cloud pair asserts nothing; the local pair still groups normally.
        #expect(manager.duplicateGroups.count == 1)
        #expect(manager.duplicateGroups.first?.name == "local.pdf")
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
        // Keepers must exist on disk too — resolve re-verifies them before trashing copies.
        for p in ["/b/x", "/a/r.doc", "/b/Inv", "/a/x", "/a/r (1).doc", "/a/Inv"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        manager.duplicateGroups = [
            grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000),
            grp(.versions, keeper: "/a/r (1).doc", redundant: ["/a/r.doc"], reclaim: 500),
            grp(.overlapping(sharedFraction: 0.9), keeper: "/a/Inv", redundant: ["/b/Inv"], reclaim: 400),
        ]

        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)
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
        mockFM.virtualDisk["/a/x"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 1000], contents: nil)
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000)
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false)                                         // nothing removed
        #expect(mockFM.virtualDisk["/b/x"] != nil)                   // file still there
        #expect(manager.duplicateGroups.count == 1)                  // group NOT dropped
        // No false "Reclaimed" banner — the original point of this assertion, which used to be
        // spelled `banner == nil` because declining produced no feedback of any kind. It now says
        // what happened: the copy could not be trashed and the permanent delete was declined, so
        // the file is still there. Silence was indistinguishable from the click doing nothing.
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("Reclaimed") != true)
        #expect(manager.banner?.message.contains("Kept") == true)
        #expect(manager.banner?.isUndoable != true)
    }

    @MainActor
    @Test func resolveRefusesWhenKeeperVanishedSinceScan() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        // Only the redundant copy is on disk — the keeper was deleted externally after the scan.
        mockFM.virtualDisk["/b/x"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 1000], contents: nil)
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000)
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/b/x"] != nil, "the last remaining copy must never be trashed")
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.duplicateGroups.count == 1, "group stays until a rescan re-establishes a keeper")
        #expect(manager.banner?.severity == .warning)
    }

    @MainActor
    @Test func applyRecommendedSkipsGroupsWhoseKeeperVanished() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        // Group 1 intact (keeper + copy); group 2's keeper is gone from disk.
        for p in ["/a/x", "/b/x", "/b/y"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        manager.duplicateGroups = [
            grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000),
            grp(.identical, keeper: "/a/y", redundant: ["/b/y"], reclaim: 1000),
        ]

        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)

        #expect(mockFM.virtualDisk["/b/x"] == nil, "intact group's copy is trashed")
        #expect(mockFM.virtualDisk["/b/y"] != nil, "keeper-less group's copy must never be trashed")
        #expect(manager.duplicateGroups.count == 1, "only the fully-resolved group is dropped")
        #expect(manager.duplicateGroups.first?.keeper.path == "/a/y")
        #expect(manager.banner?.severity == .warning, "partial outcome must not read as full success")
    }

    /// The keeper check is the half that protects the file being KEPT. This is the other half —
    /// and it is the one that destroys data when it is missing: a "redundant" copy rewritten in
    /// place between scan and click holds content nothing else has.
    @MainActor
    @Test func resolveRefusesWhenARedundantCopyWasRewrittenSinceScan() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        // Keeper is exactly as scanned; the copy's bytes were replaced (a re-export to the same
        // name), which the scan recorded as 1000 and the disk now reports as 4242.
        mockFM.virtualDisk["/a/x"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 1000], contents: nil)
        mockFM.virtualDisk["/b/x"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 4242], contents: nil)
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000)
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/b/x"] != nil, "a copy that is no longer a copy must never be trashed")
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.duplicateGroups.count == 1, "the group stays listed until a rescan re-establishes it")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("x") == true, "the banner must name the file it refused")
    }

    /// The blind batch is where an unlooked-at drifted copy would be destroyed, so it re-verifies
    /// the removal end too — while still resolving the groups that did not drift.
    @MainActor
    @Test func applyRecommendedSkipsGroupsWhoseRedundantCopyWasRewritten() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        for p in ["/a/x", "/b/x", "/a/y"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        // Group 2's redundant copy was rewritten after the scan.
        mockFM.virtualDisk["/b/y"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 77], contents: nil)
        manager.duplicateGroups = [
            grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000),
            grp(.identical, keeper: "/a/y", redundant: ["/b/y"], reclaim: 1000),
        ]

        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)

        #expect(mockFM.virtualDisk["/b/x"] == nil, "the undrifted group still resolves")
        #expect(mockFM.virtualDisk["/b/y"] != nil, "the rewritten copy must never be trashed")
        #expect(manager.duplicateGroups.count == 1)
        #expect(manager.duplicateGroups.first?.keeper.path == "/a/y")
        #expect(manager.banner?.severity == .warning, "a partial outcome must not read as full success")
    }

    /// **A folder's stat size is not its recursive content size**, so the drift check must never
    /// compare the two — the exemption the keeper check has always had, now expressed as a
    /// CONTENT comparison rather than as no comparison at all. Untested, this is one wrong line
    /// away from refusing EVERY folder duplicate group.
    ///
    /// The mock fixtures in this block hand-build both the group AND its recorded snapshot, in
    /// the mock walk's own convention (the injected-manager tree walk reads no sizes or dates,
    /// so entries carry size 0 / nil mtime). They pin the count/kind semantics; the real-tree
    /// section below is what holds the scan's and the re-walk's conventions to each other.
    @MainActor
    @Test func aFolderCopyIsNotRefusedForItsStatSize() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        Self.plantFolder(mockFM, at: "/a/Photos", files: 4, bytesEach: 100_000)
        Self.plantFolder(mockFM, at: "/b/Photos", files: 4, bytesEach: 100_000)
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 400_000, itemCount: 4,
                                     snapshot: Self.mockFolderSnapshot(files: 4))
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == true, "a folder group was refused because a directory stat is not its content size")
        #expect(mockFM.virtualDisk["/b/Photos"] == nil)
    }

    /// **The gap this closes, as the report described it.** Scan two 3,000-file folders as
    /// identical, move 1,200 photos out of the KEEPER, press Move to Trash — and the last intact
    /// copy of those 1,200 was destroyed, because a folder group's entire resolve-time guarantee
    /// was "a directory entry still exists at this path".
    @MainActor
    @Test func aFolderThatLostFilesSinceTheScanIsRefused() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        // The scan recorded four files each; the keeper has since lost one.
        Self.plantFolder(mockFM, at: "/a/Photos", files: 3, bytesEach: 100_000)
        Self.plantFolder(mockFM, at: "/b/Photos", files: 4, bytesEach: 100_000)
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 400_000, itemCount: 4,
                                     snapshot: Self.mockFolderSnapshot(files: 4))
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/b/Photos"] != nil,
                "the backup was trashed while the keeper was missing 1,200 photos")
        #expect(manager.banner?.severity == .warning)
    }

    /// And the other end: the REDUNDANT copy gaining content nothing else has. Trashing it then
    /// destroys the only instance of that content, under a banner calling it redundant.
    @MainActor
    @Test func aRedundantFolderThatGainedFilesIsRefused() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        Self.plantFolder(mockFM, at: "/a/Photos", files: 4, bytesEach: 100_000)
        Self.plantFolder(mockFM, at: "/b/Photos", files: 5, bytesEach: 100_000)
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 400_000, itemCount: 4,
                                     snapshot: Self.mockFolderSnapshot(files: 4))
        manager.duplicateGroups = [group]

        #expect(await manager.resolveDuplicateGroup(group) == false)
        #expect(mockFM.virtualDisk["/b/Photos"] != nil)
    }

    /// **A same-count, different-name swap is caught** — one file replaced by another under a
    /// new name leaves the entry count intact, and the per-entry baseline still sees both the
    /// missing path and the extra one. (Byte drift under an UNCHANGED name is pinned by the
    /// real-tree rewrite test below — the injected-manager walk reads no sizes, so a mock cannot
    /// express it honestly.)
    @MainActor
    @Test func aFolderWhoseFileWasSwappedForAnotherNameIsRefused() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        Self.plantFolder(mockFM, at: "/a/Photos", files: 4, bytesEach: 100_000)
        Self.plantFolder(mockFM, at: "/b/Photos", files: 4, bytesEach: 100_000)
        // Same count, different membership: p0 replaced by a newcomer after the scan.
        mockFM.virtualDisk.removeValue(forKey: "/b/Photos/p0.jpg")
        mockFM.virtualDisk["/b/Photos/new.jpg"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100_000], contents: nil)
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 400_000, itemCount: 4,
                                     snapshot: Self.mockFolderSnapshot(files: 4))
        manager.duplicateGroups = [group]

        #expect(await manager.resolveDuplicateGroup(group) == false)
        #expect(mockFM.virtualDisk["/b/Photos"] != nil)
    }

    /// A folder that cannot be listed completely counts as drifted, which refuses — a partial
    /// listing cannot prove a folder is still what it was.
    @MainActor
    @Test func anUnlistableFolderIsRefused() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        Self.plantFolder(mockFM, at: "/a/Photos", files: 4, bytesEach: 100_000)
        Self.plantFolder(mockFM, at: "/b/Photos", files: 4, bytesEach: 100_000)
        mockFM.unlistableDirectories.insert("/a/Photos")
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 400_000, itemCount: 4,
                                     snapshot: Self.mockFolderSnapshot(files: 4))
        manager.duplicateGroups = [group]

        #expect(await manager.resolveDuplicateGroup(group) == false)
        #expect(mockFM.virtualDisk["/b/Photos"] != nil)
    }

    /// A folder copy with NO baseline refuses too — but with a banner that says the scan couldn't
    /// check it, not that it changed. The scan records nil on a folder whose subtree held an
    /// unreadable descendant, a rescan of the same tree records nil again, and the old "changed
    /// since it was scanned — rescan" wording asserted a change nobody measured while pointing at
    /// a rescan that could never clear it (the banner-honesty rule: never claim what wasn't
    /// checked).
    @MainActor
    @Test func aFolderCopyWithNoBaselineRefusesWithoutClaimingChange() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        Self.plantFolder(mockFM, at: "/a/Photos", files: 4, bytesEach: 100_000)
        Self.plantFolder(mockFM, at: "/b/Photos", files: 4, bytesEach: 100_000)
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 400_000, itemCount: 4, snapshot: nil)
        manager.duplicateGroups = [group]

        #expect(await manager.resolveDuplicateGroup(group) == false)
        #expect(mockFM.virtualDisk["/b/Photos"] != nil, "the refusal itself must stand")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("couldn't be fully checked") == true)
        #expect(manager.banner?.message.contains("changed since") != true,
                "no change was measured, so none may be claimed")

        // The batch draws the same line when every refusal is a missing baseline.
        manager.banner = nil
        await manager.applyRecommendedDuplicates([group])
        #expect(mockFM.virtualDisk["/b/Photos"] != nil)
        #expect(manager.banner?.message.contains("couldn't be fully checked") == true)
        #expect(manager.banner?.message.contains("changed since") != true)
    }

    /// Nested folders are entries too — a subdirectory is present in the baseline in its own
    /// right (kind only; its files carry the sizes), so a nested tree that still matches resolves.
    @MainActor
    @Test func aFolderWithSubfoldersCountsThemAsEntries() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        for root in ["/a/Photos", "/b/Photos"] {
            mockFM.virtualDisk[root] = MockFileManager.FileStub(isDirectory: true,
                                                                attributes: [.size: 96], contents: nil)
            mockFM.virtualDisk["\(root)/2019"] = MockFileManager.FileStub(
                isDirectory: true, attributes: [.size: 96], contents: nil)
            for i in 0..<2 {
                mockFM.virtualDisk["\(root)/2019/p\(i).jpg"] = MockFileManager.FileStub(
                    isDirectory: false, attributes: [.size: 50_000], contents: nil)
            }
        }
        // 3 entries: the 2019 folder plus its two files.
        var entries: [String: FolderContentSnapshot.Entry] = ["2019": .directory]
        for i in 0..<2 { entries["2019/p\(i).jpg"] = .file(size: 0, modificationDate: nil) }
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 100_000, itemCount: 3,
                                     snapshot: FolderContentSnapshot(
                                        entries: entries,
                                        ignoredNames: DuplicateFinderOptions.defaultIgnoredNames))
        manager.duplicateGroups = [group]

        #expect(await manager.resolveDuplicateGroup(group) == true,
                "a nested folder group was refused; the entry count must include subfolders")
    }

    /// Plants a folder holding `files` regular files of `bytesEach`.
    static func plantFolder(_ fm: MockFileManager, at path: String, files: Int, bytesEach: Int) {
        fm.virtualDisk[path] = MockFileManager.FileStub(isDirectory: true,
                                                        attributes: [.size: 96], contents: nil)
        for i in 0..<files {
            fm.virtualDisk["\(path)/p\(i).jpg"] = MockFileManager.FileStub(
                isDirectory: false, attributes: [.size: bytesEach], contents: nil)
        }
    }

    /// The scan-recorded baseline for a `plantFolder` fixture, in the mock walk's own convention:
    /// the injected-manager tree walk reads no sizes or dates, so every file entry is
    /// (size 0, mtime nil) — exactly what a resolve-time re-walk of the same mock disk produces.
    static func mockFolderSnapshot(files: Int) -> FolderContentSnapshot {
        var entries: [String: FolderContentSnapshot.Entry] = [:]
        for i in 0..<files { entries["p\(i).jpg"] = .file(size: 0, modificationDate: nil) }
        return FolderContentSnapshot(entries: entries,
                                     ignoredNames: DuplicateFinderOptions.defaultIgnoredNames)
    }

    static func folderGroup(keeper: String, redundant: String,
                            size: Int, itemCount: Int,
                            snapshot: FolderContentSnapshot? = nil) -> DuplicateGroup {
        let k = DuplicateCopy(id: keeper, name: "Photos", isDirectory: true, size: size,
                              itemCount: itemCount, modificationDate: nil, uniqueItemCount: 0,
                              depth: 2, isRecommendedKeeper: true, contentSnapshot: snapshot)
        let r = DuplicateCopy(id: redundant, name: "Photos", isDirectory: true, size: size,
                              itemCount: itemCount, modificationDate: nil, uniqueItemCount: 0,
                              depth: 2, isRecommendedKeeper: false, contentSnapshot: snapshot)
        return DuplicateGroup(matchType: .identical, name: "Photos", isDirectory: true,
                              copies: [k, r], reclaimableBytes: size)
    }

    /// The drift guard must not over-refuse: a copy that simply VANISHED is not a copy that
    /// changed — there is nothing left to destroy, and the group's other copies still resolve.
    @MainActor
    @Test func resolveStillTrashesWhenAnotherCopyMerelyVanished() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        // "/c/x3" is absent from the virtual disk entirely — deleted externally after the scan.
        for p in ["/a/x", "/b/x2"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x2", "/c/x3"], reclaim: 2000)
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == true, "a vanished copy must not block the ones still there")
        #expect(mockFM.virtualDisk["/b/x2"] == nil, "the surviving redundant copy is still trashed")
        #expect(manager.duplicateGroups.isEmpty)
    }

    @MainActor
    @Test func applyRecommendedKeepsGroupsWhoseCopiesSurvivedTheDelete() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true                                // no Trash on this volume
        let manager = FileSyncManager(fileManager: mockFM)           // permanent-delete confirm declines
        let size: [FileAttributeKey: Any] = [.size: 1000]
        for p in ["/a/x", "/b/x"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        manager.duplicateGroups = [grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000)]

        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)

        #expect(mockFM.virtualDisk["/b/x"] != nil, "declined permanent delete leaves the copy on disk")
        #expect(manager.duplicateGroups.count == 1, "a group whose copies survived must stay listed")
    }

    @MainActor
    @Test func mergeRefusesWhenKeeperVanishedSinceScan() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        // Only the redundant folder is on disk — the keeper was deleted externally after the scan.
        // A merge would silently recreate the keeper from the copy being folded in, then trash
        // that copy: the last real bytes would survive only by accident of the fold order.
        mockFM.virtualDisk["/base/R"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["rfile"])
        mockFM.virtualDisk["/base/R/rfile"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)

        let k = DuplicateCopy(id: "/base/K", name: "K", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: "/base/R", name: "R", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 1, depth: 1, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "K",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 2500)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/base/K"] == nil, "the vanished keeper must not be recreated")
        #expect(mockFM.virtualDisk["/base/R"] != nil, "the last remaining copy must never be trashed")
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.duplicateGroups.count == 1, "group stays until a rescan re-establishes a keeper")
        #expect(manager.banner?.severity == .warning)
    }

    @MainActor
    @Test func resolveReportsPartialWhenOnlySomeCopiesLeftTheDisk() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)   // permanent-delete confirm declines
        let size: [FileAttributeKey: Any] = [.size: 1000]
        // Distinct copy names (identical groups match by content, not name) so the mock's
        // name-keyed trash staging can't collide and make the outcome order-dependent.
        for p in ["/a/x", "/b/x2", "/c/x3"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        // /c/x3 refuses to leave the disk (its trash's remove step fails once); /b/x2 trashes fine.
        mockFM.failRemovePathsOnce = ["/c/x3"]
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x2", "/c/x3"], reclaim: 2000)
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false, "a partial removal must not read as success")
        #expect(mockFM.virtualDisk["/b/x2"] == nil)
        #expect(mockFM.virtualDisk["/c/x3"] != nil)
        #expect(manager.duplicateGroups.count == 1, "the group stays listed until every copy is handled")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("1 of 2") == true, "the banner must claim only what landed")
    }

    /// `duplicateScanRoot` labels what's ON SCREEN, so it publishes with the results — a
    /// cancelled rescan of a different folder must not relabel the previous results.
    @MainActor
    @Test func duplicateScanRootLabelsResultsNotTheInFlightScan() async throws {
        let rootA = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: rootA) }
        try write(rootA.appendingPathComponent("A/x.bin"), bytes: 5000, fill: 0x41)
        try write(rootA.appendingPathComponent("B/x.bin"), bytes: 5000, fill: 0x41)
        let rootB = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: rootB) }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: rootA)
        #expect(manager.duplicateScanRoot == rootA.path, "a completed scan labels its results")
        let groupsBefore = manager.duplicateGroups.map(\.id)

        // A rescan of a DIFFERENT folder, cancelled before it publishes.
        manager.startFindDuplicates(root: rootB)
        manager.cancelFindDuplicates()
        await manager.duplicateScanTask?.value

        #expect(manager.duplicateScanRoot == rootA.path, "the label must still match the on-screen results")
        #expect(manager.duplicateGroups.map(\.id) == groupsBefore)
    }

    @MainActor
    @Test func keepSeparatePersistsAcrossRescans() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("A/a-only.txt"), bytes: 8, fill: 0x61)
        try write(root.appendingPathComponent("B/b-only.txt"), bytes: 12, fill: 0x62)

        let manager = FileSyncManager()
        let suite = "DuplicatesIgnoreTest-\(UUID().uuidString)"
        manager.duplicateIgnoreDefaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }

        await manager.findDuplicates(root: root)
        #expect(manager.duplicateGroups.count == 1)
        let group = try #require(manager.duplicateGroups.first)

        manager.keepDuplicateGroupSeparate(group)
        #expect(manager.duplicateGroups.isEmpty)

        // Rescan — a kept-separate cluster must not reappear.
        await manager.findDuplicates(root: root)
        #expect(manager.duplicateGroups.isEmpty)
    }

    // MARK: Cancellable scan

    @MainActor
    @Test func startFindDuplicatesRunsToCompletionViaTask() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("A/x.bin"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("B/x.bin"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("A/a.txt"), bytes: 8, fill: 0x61)
        try write(root.appendingPathComponent("B/b.txt"), bytes: 9, fill: 0x62)

        let manager = FileSyncManager()
        manager.startFindDuplicates(root: root)
        await manager.duplicateScanTask?.value

        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.count == 1)
        #expect(manager.isFindingDuplicates == false)
    }

    @MainActor
    @Test func cancelWithNoRunningScanIsSafe() {
        let manager = FileSyncManager()
        manager.cancelFindDuplicates()   // no task in flight
        #expect(manager.isFindingDuplicates == false)
        #expect(manager.hasFoundDuplicates == false)
    }

    // MARK: Numeric scan progress (drives the lens's determinate bar)

    @MainActor
    @Test func duplicateScanProgressPublishesMonotonicallyThenResets() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // 120 same-size files with pairwise-distinct content: every one is a size-collision
        // hash candidate, so the every-50 progress cadence fires mid-scan (50, 100) as well
        // as the final done == total update.
        for i in 0..<120 {
            try write(root.appendingPathComponent("f\(i).bin"), bytes: 64, fill: UInt8(i))
        }

        let manager = FileSyncManager()
        manager.duplicateScanProgress = (completed: 3, total: 9)   // stale; scan start must clear it

        var observed: [(completed: Int, total: Int)?] = []
        let sub = manager.$duplicateScanProgress.sink { observed.append($0) }
        defer { sub.cancel() }

        await manager.findDuplicates(root: root)

        // Drop the sink's initial replay (the stale value); everything after comes from the scan.
        let published = Array(observed.dropFirst())
        try #require(!published.isEmpty)
        #expect(published.first! == nil)   // reset to nil on scan start (walk phase, total unknown)

        let numeric = published.compactMap { $0 }
        try #require(!numeric.isEmpty)
        #expect(numeric.allSatisfy { $0.total == 120 })                 // total constant while hashing
        #expect(zip(numeric, numeric.dropFirst()).allSatisfy { $0.completed <= $1.completed })  // monotonic
        #expect(numeric.contains { $0.completed >= 50 })                // mid-hash updates arrived
        #expect(numeric.allSatisfy { $0.completed <= $0.total })
        // Deterministic terminal state: findDuplicates pins (total, total) synchronously
        // after hashing (the unstructured done == total hop can lose the race against the
        // scan's own resumption and be epoch-dropped), so the last numeric publish is
        // always the full bar — never stuck at the last 50-multiple.
        #expect(numeric.last! == (completed: 120, total: 120))

        // Nil after completion — and stays nil once any straggler main-actor hops drain
        // (the epoch bump in findDuplicates' defer makes them drop themselves).
        #expect(manager.duplicateScanProgress == nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.duplicateScanProgress == nil)
    }

    @MainActor
    @Test func duplicateScanProgressResetsOnCancel() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<8 {
            try write(root.appendingPathComponent("f\(i).bin"), bytes: 64, fill: UInt8(i))
        }

        let manager = FileSyncManager()
        manager.startFindDuplicates(root: root)
        manager.cancelFindDuplicates()
        await manager.duplicateScanTask?.value   // let the cancelled scan unwind

        #expect(manager.duplicateScanProgress == nil)
        #expect(manager.isFindingDuplicates == false)
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.duplicateScanProgress == nil)   // no stale republish after cancel
    }

    /// The epoch guard's actual scenario: cancellation landing MID-HASH, with numeric progress
    /// already live (the 8-file test above cancels in the walk phase and never gets there).
    /// A gating file manager freezes hashing at exactly 50 completions — files f50–f55 block
    /// in `sha256Hex`'s pre-hash stat, filling the 6-wide scheduling window so nothing past
    /// f55 is ever scheduled — making the cancel point deterministic without sleeps. After
    /// cancel + release, the drain (f50–f55) can reach neither another 50-multiple nor
    /// done == total, so ANY numeric publish after the cancel is a stale straggler that the
    /// epoch guard should have dropped.
    @MainActor
    @Test func cancelMidHashRepublishesNoNumericProgress() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // Same-size, pairwise-distinct files: every one is a hash candidate, so total == 120.
        for i in 0..<120 {
            try write(root.appendingPathComponent("f\(i).bin"), bytes: 64, fill: UInt8(i))
        }

        // Names sort Finder-style (localizedStandardCompare is numeric-aware), so hashing
        // schedules f0…f119 in order: f50–f55 are exactly the 6 in flight when the 50th
        // completion publishes its progress hop. The 6 here IS hashFiles' `maxConcurrent`
        // default — if that widens, ungated files slip past 50 and the waitUntil below times
        // out (a graceful failure, not a hang); widen this set to match.
        let gate = GatingFileManager(gatedNames: Set((50...55).map { "f\($0).bin" }))
        defer { gate.release() }   // never leave hasher tasks parked if an assertion bails early
        let manager = FileSyncManager(fileManager: gate)

        var observed: [(completed: Int, total: Int)?] = []
        let sub = manager.$duplicateScanProgress.sink { value in
            observed.append(value)
            // (0, 120) is published synchronously after the walk, right before hashing
            // starts — the race-free moment to arm the gate (the walk must never block).
            if let v = value, v == (completed: 0, total: 120) { gate.arm() }
        }
        defer { sub.cancel() }

        manager.startFindDuplicates(root: root)
        await waitUntil("mid-hash progress published") { manager.duplicateScanProgress?.completed == 50 }
        manager.cancelFindDuplicates()
        let publishCountAtCancel = observed.count

        gate.release()
        await manager.duplicateScanTask?.value   // scan unwinds; its defer bumps the epoch
        for _ in 0..<20 { await Task.yield() }   // let any straggler main-actor hops drain

        let afterCancel = observed.dropFirst(publishCountAtCancel)
        #expect(!afterCancel.isEmpty)                      // the defer's nil reset arrived…
        #expect(afterCancel.allSatisfy { $0 == nil })      // …and no stale numbers came with it
        #expect(manager.duplicateScanProgress == nil)
        #expect(manager.isFindingDuplicates == false)
        #expect(manager.hasFoundDuplicates == false)       // cancelled scan published no results
    }

    // MARK: Overlapping merge

    @Test func planMergeCopiesUniqueButNotProvablySharedFiles() async throws {
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(keeper.appendingPathComponent("keeper-only.txt"), bytes: 5000, fill: 0x4B)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)   // same content as keeper's
        try write(redundant.appendingPathComponent("sub/unique.txt"), bytes: 5000, fill: 0x52)

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        let srcNames = plan.steps.map { $0.src.lastPathComponent }

        #expect(srcNames.contains("unique.txt"))          // content the keeper lacks → copied
        #expect(!srcNames.contains("shared.txt"))         // provably already in keeper → skipped
        // Destination preserves the relative layout under the keeper.
        let uniqueStep = try #require(plan.steps.first { $0.src.lastPathComponent == "unique.txt" })
        #expect(uniqueStep.dst.path == keeper.appendingPathComponent("sub/unique.txt").path)
        // The snapshot covers the redundant copy's FULL file set (including provably-shared files
        // the steps skip) with byte sizes AND mtimes — the trash step's drift baseline.
        #expect(plan.sourceSnapshot.keys.sorted() == ["shared.txt", "sub/unique.txt"])
        #expect(plan.sourceSnapshot["shared.txt"]?.size == 5000)
        #expect(plan.sourceSnapshot["sub/unique.txt"]?.size == 5000)
        // The mtimes come from the same walk — a real fixture file always carries one.
        #expect(plan.sourceSnapshot["shared.txt"]?.modificationDate != nil)
    }

    @Test func planMergeRetrySkipsCollisionUniquifiedContentAlreadyInTheFolder() async throws {
        // Retry idempotence: run 1 hit a collision at Keeper/a.txt (different content held the
        // name), so the fold landed at the uniquified sibling "a 2.txt". A retry re-plans from
        // scratch — it must recognize the content already landed IN THAT FOLDER and skip,
        // not mint "a 3.txt" on every retry (the cancel banner promises "a retry skips what
        // landed").
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x41)     // different content holds the name
        try write(keeper.appendingPathComponent("a 2.txt"), bytes: 5000, fill: 0x59)   // run 1's uniquified landing
        try write(redundant.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x59)  // same content, still in the source

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        #expect(plan.steps.isEmpty)   // the content already landed — nothing left to copy
    }

    @Test func planMergeStillCopiesOnAFreshCollision() async throws {
        // The complement: the name is taken by different content and the source's bytes are
        // NOT yet anywhere in that folder — the fold must still copy (landing uniquified).
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x41)
        try write(redundant.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x59)

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        #expect(plan.steps.map { $0.src.lastPathComponent } == ["a.txt"])
    }

    @Test func planMergeCopiesWhenNameIsFreeEvenIfBytesExistUnderAnotherName() async throws {
        // The name-preserving principle survives the retry fix: destination name FREE, but the
        // bytes happen to live in that folder under the user's own different name — copy
        // anyway. Losing a meaningfully-named file is the worse surprise; a later duplicates scan
        // reconciles byte-duplicates. (The retry skip applies ONLY when the name is taken,
        // where the fold could never have kept the name anyway.)
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("b.txt"), bytes: 5000, fill: 0x59)     // same bytes, user's own name
        try write(redundant.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x59)  // name free in keeper

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        #expect(plan.steps.map { $0.src.lastPathComponent } == ["a.txt"])
    }

    @MainActor
    @Test func uniqueSizeHardLinksNeverEnterVersionsGroups() async throws {
        // The nlink filter must cover EVERY file the passes admit, not only size-colliding
        // hash candidates: a hard-linked file with a UNIQUE size skipped the stat entirely,
        // rode into a versions bucket as an unknown-hash member, and was recommended for
        // removal with its bytes counted reclaimable — trashing a link frees nothing (its
        // sibling entry here lies OUTSIDE the scan root, which only nlink can see).
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Root")
        try write(root.appendingPathComponent("Docs/report.pdf"), bytes: 9_000, fill: 0x41)
        try write(root.appendingPathComponent("Docs/report copy.pdf"), bytes: 9_000, fill: 0x42)
        let outside = base.appendingPathComponent("outside-v2.bin")
        try write(outside, bytes: 9_050, fill: 0x43)                      // unique size
        try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("Docs/report v2.pdf"))

        let manager = FileSyncManager()
        manager.startFindDuplicates(root: root)
        await manager.duplicateScanTask?.value

        #expect(!manager.duplicateGroups.contains { g in
            g.copies.contains { $0.path.hasSuffix("report v2.pdf") }
        })
        // The two real files keep their own versions group — the drop is surgical.
        #expect(manager.duplicateGroups.contains { g in
            g.matchType == .versions && g.copies.contains { $0.path.hasSuffix("report copy.pdf") }
        })
    }

    @Test func realHardLinksAreDetectedByLinkCountAndNeverGroup() throws {
        // End-to-end on a real volume: link(2) entries carry linkCount 2, land in
        // multiLinkPaths, and the finder drops them — no group, zero phantom reclaimable.
        // A singly-linked file is NOT flagged (the negative control).
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("Docs/a.bin")
        let b = base.appendingPathComponent("Docs/b.bin")
        let c = base.appendingPathComponent("Docs/c.bin")
        try write(a, bytes: 5000, fill: 0x41)
        try FileManager.default.linkItem(at: a, to: b)
        try write(c, bytes: 5000, fill: 0x41)

        let flagged = FileSyncManager.multiLinkPaths(among: [a.path, b.path, c.path])
        #expect(flagged == [a.path, b.path])   // both link entries; the real file stays

        let tree = [FileNode(id: base.appendingPathComponent("Docs").path, name: "Docs", isDirectory: true,
                             children: [
                                FileNode(id: a.path, name: "a.bin", isDirectory: false, children: nil,
                                         modificationDate: Date(), fileSize: 5000),
                                FileNode(id: b.path, name: "b.bin", isDirectory: false, children: nil,
                                         modificationDate: Date(), fileSize: 5000),
                                FileNode(id: c.path, name: "c.bin", isDirectory: false, children: nil,
                                         modificationDate: Date(), fileSize: 5000),
                             ], modificationDate: Date(), fileSize: nil)]
        let groups = DuplicateFinder.findGroups(
            tree: tree, fileHashes: [a.path: "H", b.path: "H", c.path: "H"], multiLinkPaths: flagged)
        #expect(!groups.contains { $0.matchType == .identical })
    }

    @Test func planMergeFoldsCaseOnInsensitiveKeeperVolumes() async throws {
        // On a case-insensitive keeper volume "A.txt" and "a.txt" are one on-disk name. With
        // exact-case keys the same-location check missed the collision: byte-identical content
        // copied anyway and uniquified to a junk "a 2.txt" on the FIRST run — and the retry
        // skip missed it too, so retries kept minting more. Folded keys treat it as the
        // same-location duplicate it is.
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("A.txt"), bytes: 5000, fill: 0x59)
        try write(redundant.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x59)

        let plan = await FileSyncManager.planMerge(
            from: redundant, into: keeper, caseSensitiveVolume: false, fileManager: FileManager.default)
        #expect(plan.steps.isEmpty)   // same location modulo case, same bytes — nothing to copy
    }

    @Test func planMergeRetrySkipHonorsCaseFoldedCollisions() async throws {
        // The retry shape of the case fold: run 1 collided "a.txt" against keeper "A.txt"
        // (different content) and landed "a 2.txt"; the retry must see the folded name as
        // taken AND the bytes as present, and plan nothing.
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("A.txt"), bytes: 5000, fill: 0x41)
        try write(keeper.appendingPathComponent("a 2.txt"), bytes: 5000, fill: 0x59)
        try write(redundant.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x59)

        let plan = await FileSyncManager.planMerge(
            from: redundant, into: keeper, caseSensitiveVolume: false, fileManager: FileManager.default)
        #expect(plan.steps.isEmpty)
    }

    @Test func planMergeFoldsUnicodeNormalizationVariants() async throws {
        // APFS/HFS+ name lookups are normalization-insensitive on EVERY volume (providers mix
        // NFC and NFD forms — the diff engine's nearNameKey precomposes for the same reason),
        // so an NFD keeper name and an NFC source rel are one on-disk name: byte-identical
        // content must hit the same-location skip, not copy-and-uniquify a junk sibling.
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("cafe\u{0301}.txt"), bytes: 5000, fill: 0x59)   // NFD é
        try write(redundant.appendingPathComponent("caf\u{E9}.txt"), bytes: 5000, fill: 0x59)   // NFC é

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        #expect(plan.steps.isEmpty)
    }

    @Test func planMergeKeepsExactCaseSemanticsOnSensitiveVolumes() async throws {
        // The default (case-sensitive) path is untouched: "A.txt" and "a.txt" are distinct
        // names there, so the byte-identical source still copies under its own name.
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("A.txt"), bytes: 5000, fill: 0x59)
        try write(redundant.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x59)

        let plan = await FileSyncManager.planMerge(
            from: redundant, into: keeper, fileManager: FileManager.default)
        #expect(plan.steps.map { $0.src.lastPathComponent } == ["a.txt"])
    }

    @MainActor
    @Test func mergeRefusesWhenAKeeperSymlinkDirWouldReceiveTheFold() async throws {
        // Pruning the linked subtree from the maps was only half the fix: the plan still AIMED
        // steps under the link and the copy loop wrote THROUGH it — into whatever it points at
        // (an external folder silently received the "folded" file and the trash then ran; a
        // link into the source minted junk per retry and the fold could never complete). Any
        // step descending through a keeper symlink dir now refuses the merge up front: nothing
        // is copied, nothing is trashed, the group stays, and the banner names the link.
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        let elsewhere = base.appendingPathComponent("Elsewhere")
        try write(keeper.appendingPathComponent("own.txt"), bytes: 5000, fill: 0x4B)
        try write(redundant.appendingPathComponent("sub/y.txt"), bytes: 5000, fill: 0x59)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: keeper.appendingPathComponent("sub"),
                                                   withDestinationURL: elsewhere)

        let manager = FileSyncManager()
        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant.path, name: "Redundant", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 5000)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("sub") == true)      // names the linked folder
        #expect(FileManager.default.fileExists(atPath: redundant.appendingPathComponent("sub/y.txt").path))
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("y.txt").path))
        #expect(manager.duplicateGroups.contains { $0.id == group.id })   // group stays listed
    }

    @Test func planMergeNeverLetsASymlinkedDirectoryVouchForContent() async throws {
        // buildTree deliberately FOLLOWS symlinked directories, so a keeper link-dir's children
        // arrive as ordinary files — and fed the maps as if the keeper owned them. With
        // Keeper/sub → Redundant/sub, the same-rel skip then saw every sub/ file as "already
        // in the keeper", planned nothing, and the trash step removed the only real copy —
        // leaving the keeper holding a dangling link. The whole linked subtree is pruned from
        // the keeper's view — and the step is returned BLOCKED, not planned: a planned copy
        // would write THROUGH the link (round 6's finding — here straight back into the
        // source, where the self-collision minted junk per retry).
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("own.txt"), bytes: 5000, fill: 0x4B)
        try write(redundant.appendingPathComponent("sub/f.txt"), bytes: 5000, fill: 0x59)  // only real copy
        try FileManager.default.createSymbolicLink(
            at: keeper.appendingPathComponent("sub"),
            withDestinationURL: redundant.appendingPathComponent("sub"))

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        #expect(plan.steps.isEmpty)                       // never aimed through the link…
        #expect(plan.blockedLinkedDirs == ["sub"])        // …surfaced for the caller's refusal
    }

    @Test func planMergeNeverLetsASymlinkVouchForContent() async throws {
        // A keeper-folder symlink hashes as its TARGET's bytes. If it fed the parent hash-set,
        // the retry skip would fire for content whose only real copy is the redundant folder —
        // the fold "completes", the trash step removes the redundant copy, and the keeper is
        // left holding a dangling link. Links must contribute to neither keeper map.
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("b.txt"), bytes: 5000, fill: 0x5A)      // name-holder, content Z
        try write(redundant.appendingPathComponent("b.txt"), bytes: 5000, fill: 0x59)   // content Y — only real copy
        try FileManager.default.createSymbolicLink(
            at: keeper.appendingPathComponent("alias.txt"),
            withDestinationURL: redundant.appendingPathComponent("b.txt"))

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        // Y must still be copied: the link's hash (Y, via the target) may not count as
        // "already in the folder".
        #expect(plan.steps.map { $0.src.lastPathComponent } == ["b.txt"])
    }

    @Test func planMergeRetrySkipSeesDirectoryAndUnhashedNameHolders() async throws {
        // The "name taken" gate must trigger on what the COPY loop's fileExists collides
        // with — any on-disk entry, including a directory (which the hash maps can never
        // hold). Run 1: source file "sub" collided with keeper DIRECTORY "sub", landed
        // uniquified as "sub 2". The retry must skip, not mint "sub 3".
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try write(keeper.appendingPathComponent("sub/inner.txt"), bytes: 5000, fill: 0x49)  // DIR holds the name
        try write(keeper.appendingPathComponent("sub 2"), bytes: 5000, fill: 0x59)          // run 1's landing
        try write(redundant.appendingPathComponent("sub"), bytes: 5000, fill: 0x59)         // same content, still in source

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        #expect(plan.steps.isEmpty)
    }

    @Test func mergeSourceDriftedFlagsNewAndChangedFilesButNotRemovals() {
        typealias Snap = FileSyncManager.MergeFileSnapshot
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 2_000_000)
        let planned = ["a.txt": Snap(size: 100, modificationDate: t1),
                       "sub/b.txt": Snap(size: 200, modificationDate: t1)]
        // Unchanged → no drift.
        #expect(!FileSyncManager.mergeSourceDrifted(planned: planned, current: planned))
        // A file REMOVED since plan time is fine — what remains was covered by the plan.
        #expect(!FileSyncManager.mergeSourceDrifted(planned: planned,
                                                    current: ["a.txt": Snap(size: 100, modificationDate: t1)]))
        #expect(!FileSyncManager.mergeSourceDrifted(planned: planned, current: [:]))
        // A NEW file is content the plan never saw → drift.
        #expect(FileSyncManager.mergeSourceDrifted(planned: planned,
                                                   current: ["a.txt": Snap(size: 100, modificationDate: t1),
                                                             "sub/b.txt": Snap(size: 200, modificationDate: t1),
                                                             "new.txt": Snap(size: 1, modificationDate: t1)]))
        // A size CHANGE is content the plan never verified → drift.
        #expect(FileSyncManager.mergeSourceDrifted(planned: planned,
                                                   current: ["a.txt": Snap(size: 100, modificationDate: t1),
                                                             "sub/b.txt": Snap(size: 999, modificationDate: t1)]))
        // A SAME-SIZE rewrite (mtime bumped, byte count unchanged) is drift too — size alone let
        // the only copy of the rewritten bytes be trashed (round-5).
        #expect(FileSyncManager.mergeSourceDrifted(planned: planned,
                                                   current: ["a.txt": Snap(size: 100, modificationDate: t2),
                                                             "sub/b.txt": Snap(size: 200, modificationDate: t1)]))
        // mtime unknown on both walks (mock FS) still compares as unchanged.
        let dateless = ["c.txt": Snap(size: 50, modificationDate: nil)]
        #expect(!FileSyncManager.mergeSourceDrifted(planned: dateless, current: dateless))
    }

    @MainActor
    @Test func mergeRefusesToTrashARedundantCopyThatChangedMidMerge() async throws {
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Changing")
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(redundant.appendingPathComponent("unique.txt"), bytes: 5000, fill: 0x52)

        // A file manager that simulates external activity: the first copy the merge performs
        // also drops a brand-new file into the redundant folder — after the plan was snapshotted,
        // before the trash step. The old code re-verified only the keeper and would trash the
        // folder, destroying surprise.txt.
        let fm = MidMergeInterferingFileManager(
            dropping: redundant.appendingPathComponent("surprise.txt"),
            bytes: Data(repeating: 0x21, count: 4096))
        let manager = FileSyncManager(fileManager: fm)

        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 10000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant.path, name: "Changing", isDirectory: true, size: 10000, itemCount: 2,
                              modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 5000)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(FileManager.default.fileExists(atPath: redundant.path), "the changed copy must NOT be trashed")
        #expect(FileManager.default.fileExists(atPath: redundant.appendingPathComponent("surprise.txt").path),
                "the file that appeared mid-merge survives")
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("unique.txt").path),
                "the planned fold-in still landed")
        #expect(manager.duplicateGroups.count == 1, "group stays listed for a rescan/retry")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("changed") == true)
    }

    @MainActor
    @Test func mergeFoldsUniqueFilesThenTrashesRedundant() async throws {
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let rName = "Folded-\(UUID().uuidString)"
        let redundant = base.appendingPathComponent(rName)
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(keeper.appendingPathComponent("keeper-only.txt"), bytes: 5000, fill: 0x4B)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(redundant.appendingPathComponent("redundant-only.txt"), bytes: 5000, fill: 0x52)
        // The redundant folder is trashed to ~/.Trash on success — clean it up.
        defer {
            let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
            try? FileManager.default.removeItem(at: trashed)
        }

        let manager = FileSyncManager()
        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 10000, itemCount: 2,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant.path, name: rName, isDirectory: true, size: 10000, itemCount: 2,
                              modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 5000)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)
        await waitUntil("redundant folder trashed") { !FileManager.default.fileExists(atPath: redundant.path) }

        #expect(ok)
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("redundant-only.txt").path))  // unique folded in
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("keeper-only.txt").path))     // keeper intact
        #expect(!FileManager.default.fileExists(atPath: redundant.path))                                            // redundant gone
        #expect(manager.duplicateGroups.isEmpty)
    }

    @MainActor
    @Test func mergeDropsASecondCallForAGroupAlreadyMerging() async throws {
        // The guard must live in the manager, not the UI: a second call for an in-flight group
        // is dropped before it can re-plan against the half-merged keeper (and mint " 2" copies).
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        mockFM.virtualDisk["/base/K"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["kfile"])
        mockFM.virtualDisk["/base/K/kfile"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)
        mockFM.virtualDisk["/base/R"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["rfile"])
        mockFM.virtualDisk["/base/R/rfile"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)

        let k = DuplicateCopy(id: "/base/K", name: "K", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: "/base/R", name: "R", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 1, depth: 1, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "K",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 2500)
        manager.duplicateGroups = [group]
        manager.mergingGroupIDs.insert(group.id)   // simulate the in-flight first merge

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(mockFM.trashedPaths.isEmpty, "the dropped call must not touch the disk")
        #expect(manager.duplicateGroups.count == 1)
        #expect(manager.mergingGroupIDs.contains(group.id),
                "the dropped call must not clear the real merge's in-flight marker")
    }

    @MainActor
    @Test func concurrentMergeOfTheSameGroupRunsExactlyOnce() async throws {
        // End-to-end double-click: two merge calls race; exactly one runs, and the keeper never
        // gains " 2" junk copies from a second plan drawn against the half-merged keeper.
        let base = try makeCanonicalTempRoot(prefix: "SyncTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let rName = "Folded-\(UUID().uuidString)"
        let redundant = base.appendingPathComponent(rName)
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(redundant.appendingPathComponent("redundant-only.txt"), bytes: 5000, fill: 0x52)
        defer {
            let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
            try? FileManager.default.removeItem(at: trashed)
        }

        let manager = FileSyncManager()
        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant.path, name: rName, isDirectory: true, size: 10000, itemCount: 2,
                              modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 5000)
        manager.duplicateGroups = [group]

        async let first = manager.mergeDuplicateGroup(group)
        async let second = manager.mergeDuplicateGroup(group)
        let (a, b) = await (first, second)

        #expect(a != b, "exactly one of the two racing calls may run (\(a), \(b))")
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("redundant-only.txt").path))
        #expect(!FileManager.default.fileExists(atPath: keeper.appendingPathComponent("redundant-only 2.txt").path),
                "the dropped call must not re-fold already-folded files as \" 2\" copies")
        #expect(manager.mergingGroupIDs.isEmpty, "the in-flight marker clears when the merge ends")
    }

    @MainActor
    @Test func mergeClearsInFlightMarkerOnEveryRefusalPath() async throws {
        // Even a merge that refuses early (vanished keeper) must not leave the group marked
        // as merging — that would permanently disable its card.
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        mockFM.virtualDisk["/base/R"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        let k = DuplicateCopy(id: "/base/K", name: "K", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: "/base/R", name: "R", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 1, depth: 1, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "K",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 2500)
        manager.duplicateGroups = [group]

        _ = await manager.mergeDuplicateGroup(group)

        #expect(manager.mergingGroupIDs.isEmpty)
    }

    @MainActor
    @Test func mergeKeepsGroupAndAvoidsFalseSuccessWhenTrashFails() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true                        // Trash-less volume
        let manager = FileSyncManager(fileManager: mockFM)   // permanentDeleteConfirmer defaults to false
        mockFM.virtualDisk["/base/K"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["kfile"])
        mockFM.virtualDisk["/base/K/kfile"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)
        mockFM.virtualDisk["/base/R"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["rfile"])
        mockFM.virtualDisk["/base/R/rfile"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)

        let k = DuplicateCopy(id: "/base/K", name: "K", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: "/base/R", name: "R", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 1, depth: 1, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "K",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 2500)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(manager.duplicateGroups.count == 1)             // group kept, not vanished
        #expect(mockFM.virtualDisk["/base/R"] != nil)           // redundant folder still on disk
        #expect(manager.banner?.severity != .success)           // no false "Merged" success
    }

    @MainActor
    @Test func mergeRefusesARedundantNestedInsideTheKeeper() async throws {
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Data")
        let nested = keeper.appendingPathComponent("old/Data")   // inside the keeper
        try write(keeper.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x41)
        try write(nested.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        let k = DuplicateCopy(id: keeper.path, name: "Data", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: nested.path, name: "Data", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 2, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 1.0), name: "Data",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 5000)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(FileManager.default.fileExists(atPath: nested.path))   // nested copy NOT trashed
        #expect(manager.duplicateGroups.count == 1)                    // group kept
    }

    @MainActor
    @Test func clearDuplicatesCancelsAnInFlightScan() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("A/x.bin"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("B/x.bin"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        manager.startFindDuplicates(root: root)
        manager.clearDuplicates()                     // simulate a provider switch mid-scan
        await manager.duplicateScanTask?.value        // let the cancelled scan unwind

        #expect(manager.duplicateGroups.isEmpty)      // the cancelled scan must not republish
        #expect(manager.hasFoundDuplicates == false)
    }

    @MainActor
    @Test func mergeIsNoOpForNonOverlappingGroup() async throws {
        let manager = FileSyncManager()
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1)
        manager.duplicateGroups = [group]
        let ok = await manager.mergeDuplicateGroup(group)
        #expect(ok == false)
        #expect(manager.duplicateGroups.count == 1)   // untouched
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

    // MARK: Folder drift, end to end on a real tree
    //
    // The mock-backed folder tests above hand-build their groups, which is exactly how the
    // scan/re-walk convention mismatch survived them: a fixture that writes down both sides of
    // the comparison can never disagree with itself. These run the REAL pipeline — scan a real
    // temp tree, then resolve — so the baseline the scan records and the walk the resolve-time
    // check performs are the production ones, and a convention drift between them fails here.

    /// Removes what a resolve trashed from the real ~/.Trash — these tests run the production
    /// delete path, so a successful resolve lands the redundant folder there (same cleanup shape
    /// as `mergeFoldsUniqueFilesThenTrashesRedundant`).
    private func removeFromTrash(_ names: [String]) {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for n in names { try? FileManager.default.removeItem(at: trash.appendingPathComponent(n)) }
    }

    /// **A `.DS_Store` is not drift.** The scan skips `options.ignoredNames` when it measures a
    /// folder, so a re-walk that counts them disagrees with the baseline by a constant offset —
    /// and every folder the user ever opened in Finder is then refused with "changed since it was
    /// scanned", permanently, because rescanning reproduces the same mismatch. The one UI built to
    /// review folder copies was unusable on exactly the folders it exists for.
    @MainActor
    @Test func aFolderPairHoldingAFinderDSStoreStillResolves() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "KeepA-\(UUID().uuidString)", bName = "CopyB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeFromTrash([aName, bName]) }
        for folder in [aName, bName] {
            try write(root.appendingPathComponent("\(folder)/f1.txt"), bytes: 5000, fill: 0x41)
            try write(root.appendingPathComponent("\(folder)/f2.txt"), bytes: 6000, fill: 0x42)
            try write(root.appendingPathComponent("\(folder)/.DS_Store"), bytes: 800, fill: 0x44)
        }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }),
                                 "two folders identical up to an ignored name must still group")
        let redundantPath = try #require(group.recommendedRemovalPaths.first)

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == true, "a folder that merely holds a .DS_Store was refused as 'changed since it was scanned'")
        #expect(!FileManager.default.fileExists(atPath: redundantPath))
        #expect(FileManager.default.fileExists(atPath: group.keeper.path))
    }

    /// **A same-length rewrite is drift.** Count and total bytes are both unchanged — `sed -i`
    /// over fixed-width text, one 5,000-byte export replaced by another — so a count+bytes
    /// equality waves it through and trashes the only instance of the new content. The file-level
    /// check compares size AND mtime for exactly this reason; the folder path owes its contents
    /// the same fidelity, per file.
    @MainActor
    @Test func aSameLengthRewriteInsideAFolderCopyIsRefused() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "KeepA-\(UUID().uuidString)", bName = "CopyB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeFromTrash([aName, bName]) }
        for folder in [aName, bName] {
            try write(root.appendingPathComponent("\(folder)/f1.txt"), bytes: 5000, fill: 0x41)
            try write(root.appendingPathComponent("\(folder)/f2.txt"), bytes: 6000, fill: 0x42)
        }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }))
        let redundantPath = try #require(group.recommendedRemovalPaths.first)

        // Rewrite one file inside the copy about to be trashed: same byte count, different
        // content. The mtime moves on its own; pinned explicitly so the drift is deterministic
        // rather than riding on filesystem timestamp granularity.
        let rewritten = (redundantPath as NSString).appendingPathComponent("f1.txt")
        try Data(repeating: 0x5A, count: 5000).write(to: URL(fileURLWithPath: rewritten))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(500)],
                                              ofItemAtPath: rewritten)

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false, "a same-length rewrite left count and bytes unchanged and the only copy of the edit was trashed")
        #expect(FileManager.default.fileExists(atPath: redundantPath),
                "the rewritten copy holds content nothing else has — it must stay on disk")
        #expect(manager.banner?.severity == .warning)
    }

    /// The KEEP side of the same gate, end to end. The test above rewrites the copy being
    /// trashed; this one rewrites a file inside the KEEPER — the folder being kept — which is the
    /// half whose loss makes a "redundant" copy the last intact instance of the scanned content.
    /// Count, membership and byte totals are all unchanged, so only the per-entry mtime half of
    /// `folderContentsMatchScan` can catch it, and only `driftedFolderInGroup`'s
    /// keeper-inclusive scope routes the keeper through it at all.
    @MainActor
    @Test func aSameLengthRewriteInsideTheKeeperFolderIsRefused() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "KeepA-\(UUID().uuidString)", bName = "CopyB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeFromTrash([aName, bName]) }
        for folder in [aName, bName] {
            try write(root.appendingPathComponent("\(folder)/f1.txt"), bytes: 5000, fill: 0x41)
            try write(root.appendingPathComponent("\(folder)/f2.txt"), bytes: 6000, fill: 0x42)
        }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }))
        let redundantPath = try #require(group.recommendedRemovalPaths.first)

        // Rewrite one file inside the KEEPER: same byte count, different content. The mtime is
        // pinned explicitly for the same reason as above — deterministic drift, not filesystem
        // timestamp granularity.
        let rewritten = (group.keeper.path as NSString).appendingPathComponent("f1.txt")
        try Data(repeating: 0x5A, count: 5000).write(to: URL(fileURLWithPath: rewritten))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(500)],
                                              ofItemAtPath: rewritten)

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false, "the keeper drifted, so its copies are no longer provably redundant")
        #expect(FileManager.default.fileExists(atPath: redundantPath),
                "the copy is the last intact instance of the scanned content — it must stay on disk")
        #expect(manager.banner?.severity == .warning)
    }

    /// **The re-walk's ignored-name skip, pinned from OUTSIDE the recording side.** The
    /// convention-true snapshot test below compares the scan's baseline against the shared
    /// re-walk, but both sides go through one builder — a mutation that changes the builder's
    /// convention moves both sides together and still compares equal. Here the baseline is
    /// recorded with NO ignored name on disk and the `.DS_Store` arrives AFTERWARDS (Finder
    /// opening the folder mid-session — the ordinary way one appears), so only the re-walk's own
    /// skip can keep the verdict true; nothing about the recording can compensate.
    @MainActor
    @Test func anIgnoredNameAddedAfterTheScanIsNotDrift() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["A", "B"] {
            try write(root.appendingPathComponent("\(folder)/f.txt"), bytes: 5000, fill: 0x41)
        }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }))
        let snapshot = try #require(group.keeper.contentSnapshot)
        #expect(snapshot.entries.keys.sorted() == ["f.txt"],
                "the baseline was recorded before any ignored name existed")

        // Finder visits the folder after the scan.
        try write(URL(fileURLWithPath: group.keeper.path).appendingPathComponent(".DS_Store"),
                  bytes: 700, fill: 0x44)

        #expect(await FileSyncManager.folderContentsMatchScan(
            path: group.keeper.path, snapshot: snapshot, fileManager: FileManager.default),
                "the re-walk must skip ignored names on its own — the baseline never saw this one")

        // Control: a NON-ignored arrival through the same re-walk still reads as drift, so the
        // pin above cannot pass by the comparison being inert.
        try write(URL(fileURLWithPath: group.keeper.path).appendingPathComponent("new.txt"),
                  bytes: 700, fill: 0x45)
        #expect(await FileSyncManager.folderContentsMatchScan(
            path: group.keeper.path, snapshot: snapshot, fileManager: FileManager.default) == false)
    }

    /// **The ignored-name offset must not MASK real drift either** — the other face of the
    /// `.DS_Store` bug. A copy loses one real file after the scan while an ignored name of the
    /// same size sits in it: raw count and raw bytes both match the scan's rollup exactly, so the
    /// count+bytes check reads a genuinely changed folder as intact.
    @MainActor
    @Test func anIgnoredNameCannotMaskALostFile() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "CleanA-\(UUID().uuidString)", bName = "MaskB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeFromTrash([aName, bName]) }
        for folder in [aName, bName] {
            for i in 1...4 {
                try write(root.appendingPathComponent("\(folder)/f\(i).txt"), bytes: 5000, fill: 0x41)
            }
        }
        // Only the B copy holds the ignored name, sized exactly like the file it will "replace".
        try write(root.appendingPathComponent("\(bName)/.DS_Store"), bytes: 5000, fill: 0x44)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }))
        let maskedPath = try #require(group.copies.first(where: { ($0.path as NSString).lastPathComponent == bName })?.path)

        // The masked copy loses a real file: raw count is back to 4 (3 files + .DS_Store) and raw
        // bytes back to 20,000 — byte-for-byte the numbers the scan recorded.
        try FileManager.default.removeItem(atPath: (maskedPath as NSString).appendingPathComponent("f1.txt"))

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false, "an ignored name's size offset masked a lost file and the group resolved anyway")
        #expect(FileManager.default.fileExists(atPath: group.keeper.path))
        #expect(group.recommendedRemovalPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) },
                "nothing may be trashed while either end of the group has drifted")
    }

    /// **The scan's symlink convention and the re-walk's must be the same convention.** The scan
    /// counts a link as one entry contributing zero bytes; a re-walk that stats the link itself
    /// adds the link's own byte count and refuses a folder that never changed — same permanent
    /// false refusal as the `.DS_Store` case, reproduced on every rescan.
    @MainActor
    @Test func aSymlinkInsideAFolderPairDoesNotFalselyDrift() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "KeepA-\(UUID().uuidString)", bName = "CopyB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeFromTrash([aName, bName]) }
        for folder in [aName, bName] {
            try write(root.appendingPathComponent("\(folder)/f.txt"), bytes: 5000, fill: 0x41)
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent("\(folder)/link.txt").path,
                withDestinationPath: "f.txt")
        }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }),
                                 "two folders identical link-for-link must group")
        let redundantPath = try #require(group.recommendedRemovalPaths.first)

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == true, "an unchanged folder was refused because the re-walk stats symlinks by a different convention than the scan")
        #expect(!FileManager.default.fileExists(atPath: redundantPath))
    }

    /// The scan records the baseline in its own conventions: ignored names are absent from the
    /// entries, symlinks are recorded as links (target-resolved size), files carry real sizes and
    /// dates — and an immediate re-walk through the shared routine reproduces it exactly, which
    /// is the property the whole gate stands on.
    @MainActor
    @Test func theScanRecordsAConventionTrueSnapshotOnFolderCopies() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["A", "B"] {
            try write(root.appendingPathComponent("\(folder)/f.txt"), bytes: 5000, fill: 0x41)
            try write(root.appendingPathComponent("\(folder)/.DS_Store"), bytes: 700, fill: 0x44)
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent("\(folder)/link.txt").path,
                withDestinationPath: "f.txt")
        }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }))
        let snapshot = try #require(group.keeper.contentSnapshot,
                                    "a scanned folder copy must carry its baseline")

        #expect(Set(snapshot.entries.keys) == ["f.txt", "link.txt"],
                "ignored names must be absent; files and links present")
        guard case .file(let size, let mtime)? = snapshot.entries["f.txt"] else {
            Issue.record("f.txt recorded as \(String(describing: snapshot.entries["f.txt"]))"); return
        }
        #expect(size == 5000)
        #expect(mtime != nil, "a real file always carries a date — nil here would blind the mtime half of the gate")
        guard case .symlink? = snapshot.entries["link.txt"] else {
            Issue.record("link.txt recorded as \(String(describing: snapshot.entries["link.txt"]))"); return
        }
        // The shared re-walk reproduces the scan's snapshot on an unchanged folder — and sees
        // through it: the redundant copy carries its own equivalent baseline.
        #expect(await FileSyncManager.folderContentsMatchScan(
            path: group.keeper.path, snapshot: snapshot, fileManager: FileManager.default))
        // No baseline, no verdict: nil refuses rather than trusting an unmeasured folder.
        #expect(await FileSyncManager.folderContentsMatchScan(
            path: group.keeper.path, snapshot: nil, fileManager: FileManager.default) == false)
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
        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.duplicateGroups.count == 1)

        // But it can be dismissed manually ("Keep separate").
        manager.dismissDuplicateGroup(group)
        #expect(manager.duplicateGroups.isEmpty)
    }
}

/// A real FileManager that simulates external activity landing mid-merge: the FIRST copy it
/// performs also writes a brand-new file into the (redundant) folder being merged — after
/// `planMerge` snapshotted that folder, before the trash step re-verifies it. Everything else
/// is stock FileManager, so the merge's real copy/trash machinery runs unmodified.
private final class MidMergeInterferingFileManager: FileManager, @unchecked Sendable {
    private let dropURL: URL
    private let dropBytes: Data
    // FileManager is (unchecked) Sendable, so a subclass may not add mutable stored state
    // directly — the one-shot flag lives in a lock-guarded box (same shape as GatingFileManager).
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        /// True exactly once.
        func trip() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let first = !fired
            fired = true
            return first
        }
    }
    private let shot = OneShot()

    init(dropping url: URL, bytes: Data) {
        self.dropURL = url
        self.dropBytes = bytes
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if shot.trip() {
            try? dropBytes.write(to: dropURL)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

/// A real FileManager that, once armed, parks callers statting one of `gatedNames` — via either
/// metadata entry point, whichever `sha256Hex` reaches first for a file it hashes — until
/// `release()`.
///
/// **Both entry points, because pinning it to one was a latent break.** This gated
/// `fileExists(atPath:isDirectory:)` alone, on the stated grounds that it was "the first call
/// `sha256Hex` makes for every file it hashes" — true when written. When the verifier collapsed its
/// three metadata reads into one `attributesOfItem`, nothing parked, the scan ran to completion,
/// and `cancelMidHashRepublishesNoNumericProgress` cancelled a scan that had already finished.
/// The gate is name-scoped, so covering both costs nothing: an ungated path is never parked
/// whichever route it arrives by. It must be a FileManager SUBCLASS, not a plain FileManaging
/// wrapper: buildTree's walk only fetches file sizes on its `fileManager is FileManager`
/// fast path (anything else is treated as a metadata-less mock), and without sizes there are
/// no hash candidates to gate. The walk itself never calls this override for regular files
/// (it stats via URL.resourceValues), so only the hash phase can block. Freezing a handful of
/// named files mid-scan lets the cancel-mid-hash test pick its cancellation point
/// deterministically (no sleeps).
private final class GatingFileManager: FileManager, @unchecked Sendable {
    /// Lock-guarded flags in a box of their own: FileManager is already (unchecked) Sendable,
    /// and a subclass may not add mutable stored state to a Sendable class directly.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var armed = false
        private var released = false

        func arm() {
            lock.lock(); armed = true; lock.unlock()
        }

        func release() {
            lock.lock(); released = true; lock.unlock()
            // Wake anything already parked; over-signaling a semaphore is harmless.
            for _ in 0..<64 { semaphore.signal() }
        }

        func waitIfArmed() {
            lock.lock()
            let mustWait = armed && !released
            lock.unlock()
            // If release() lands between the check and the wait, its banked signals make
            // the wait return immediately — no lost-wakeup hang.
            if mustWait { semaphore.wait() }
        }
    }

    private let gatedNames: Set<String>
    private let gate = Gate()

    init(gatedNames: Set<String>) {
        self.gatedNames = gatedNames
        super.init()
    }

    /// Starts gating. Called only once the walk phase is over, so tree building never blocks.
    func arm() { gate.arm() }

    /// Unblocks every parked and future gated call. Idempotent.
    func release() { gate.release() }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if gatedNames.contains((path as NSString).lastPathComponent) {
            gate.waitIfArmed()
        }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if gatedNames.contains((path as NSString).lastPathComponent) {
            gate.waitIfArmed()
        }
        return try super.attributesOfItem(atPath: path)
    }
}
