import Testing
import Foundation
import Combine
@testable import Sync

/// Manager-level coverage for the duplicate finder: the end-to-end scan (real files, so the SHA-256 layer runs)
/// and the resolve path (mock disk, so we can assert what gets trashed without touching ~/.Trash).
@Suite struct FileSyncManagerDuplicatesTests {

    /// Plants a file of `size` bytes at each path.
    private func plant(_ fm: MockFileManager, _ paths: [String], size: Int) {
        for p in paths { fm.virtualDisk[p] = .file(size) }
    }

    @MainActor
    @Test func findDuplicatesDetectsIdenticalFileEndToEnd() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }

        // Two identical report.pdf files under different folders; distinct siblings keep the two
        // folders from themselves being reported as identical.
        try writeBytes(root.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("A/a-only.txt"), bytes: 8, fill: 0x61)
        try writeBytes(root.appendingPathComponent("B/b-only.txt"), bytes: 12, fill: 0x62)

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
        try writeBytes(root.appendingPathComponent("one.bin"), bytes: 5000, fill: 0x01)
        try writeBytes(root.appendingPathComponent("two.bin"), bytes: 5000, fill: 0x02)  // same size, different bytes

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)

        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.isEmpty)
    }

    @MainActor
    @Test func resolveTrashesRedundantCopyAndDropsGroup() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        plant(mockFM, ["/root/A/report.pdf", "/root/B/report.pdf"], size: 8192)

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
    @Test func aRescanAndClearDuplicatesResetTheSkipFigure() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // Two byte-identical files flagged cloud-only: they are size-collision candidates, but
        // hashing skips both — so no group can form, and the scan must SAY so instead of silently
        // reporting "no duplicates".
        try writeBytes(root.appendingPathComponent("A/movie.mp4"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("B/movie.mp4"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        // `cache: nil` throughout: this scans the same files with two cloud-only answers, and a
        // cache hit bypasses that answer, so a shared cache would let the local run answer for the
        // cloud-only one. What is under test is the skip classification.
        await manager.findDuplicates(root: root, isCloudOnly: { _ in true }, cache: nil)

        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.isEmpty)                      // identity unknown → no claim
        #expect(manager.duplicateScanSkips.cloudOnly == 2)
        #expect(manager.duplicateScanSkips.total == 2)

        // A rescan with the files local hashes them — and resets the skip figure with the results.
        await manager.findDuplicates(root: root, isCloudOnly: { _ in false }, cache: nil)
        #expect(manager.duplicateScanSkips == FileSyncManager.DuplicateScanSkips())
        #expect(manager.duplicateGroups.count == 1)
        // clearDuplicates resets the results state: groups, root and the has-found flag.
        manager.clearDuplicates()
        #expect(manager.duplicateGroups.isEmpty)
        #expect(manager.duplicateScanRoot == nil)
        #expect(manager.hasFoundDuplicates == false)

        // clearDuplicates resets it alongside the rest of the results state.
        await manager.findDuplicates(root: root, isCloudOnly: { _ in true }, cache: nil)
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
        try writeBytes(root.appendingPathComponent("A/cloud.mov"), bytes: 6000, fill: 0x43)
        try writeBytes(root.appendingPathComponent("B/cloud.mov"), bytes: 6000, fill: 0x43)
        try writeBytes(root.appendingPathComponent("A/local.pdf"), bytes: 5000, fill: 0x4C)
        try writeBytes(root.appendingPathComponent("B/local.pdf"), bytes: 5000, fill: 0x4C)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, isCloudOnly: { $0.hasSuffix("cloud.mov") })

        #expect(manager.duplicateScanSkips.cloudOnly == 2)
        #expect(manager.duplicateScanSkips.unverifiable == 0)
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
    /// An overlapping folder group of keeper `k` and redundant `r`, each named for its last path
    /// component, as the merge tests build them.
    private func overlap(_ k: String, _ r: String, sizes: (Int, Int) = (5000, 5000), items: (Int, Int) = (1, 1),
                         rUnique: Int = 1, depths: (Int, Int) = (1, 1), shared: Double = 0.5,
                         reclaim: Int = 2500) -> DuplicateGroup {
        let kName = (k as NSString).lastPathComponent
        let keeper = DuplicateCopy(id: k, name: kName, isDirectory: true, size: sizes.0, itemCount: items.0,
                                   modificationDate: nil, uniqueItemCount: 0, depth: depths.0, isRecommendedKeeper: true)
        let redundant = DuplicateCopy(id: r, name: (r as NSString).lastPathComponent, isDirectory: true, size: sizes.1,
                                      itemCount: items.1, modificationDate: nil, uniqueItemCount: rUnique,
                                      depth: depths.1, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: .overlapping(sharedFraction: shared), name: kName,
                              isDirectory: true, copies: [keeper, redundant], reclaimableBytes: reclaim)
    }

    @MainActor
    @Test func summaryCountsOnlyBatchEligibleGroups() {
        let manager = FileSyncManager()
        manager.duplicateGroups = [
            grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 100),
            grp(.versions, keeper: "/a/r (1).doc", redundant: ["/a/r.doc"], reclaim: 50),
            grp(.overlapping(sharedFraction: 0.9), keeper: "/a/Inv", redundant: ["/b/Inv"], reclaim: 40),
            grp(.sameText, keeper: "/a/S", redundant: ["/b/S"], reclaim: 0),
        ]
        let s = manager.duplicateSummary
        #expect(s.groupCount == 4)
        #expect(s.reclaimableBytes == 100)   // identical only — versions/overlapping don't inflate it
        #expect(s.redundantCopyCount == 1)   // only the identical group's redundant copy
        #expect(s.needsReviewCount == 1)     // the same-text group
    }

    @MainActor
    @Test func applyRecommendedTrashesIdenticalButNotVersionsOrOverlapping() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        // Keepers must exist on disk too — resolve re-verifies them before trashing copies.
        plant(mockFM, ["/b/x", "/a/r.doc", "/b/Inv", "/a/x", "/a/r (1).doc", "/a/Inv"], size: 1000)
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
        plant(mockFM, ["/b/x", "/a/x"], size: 1000)
        let group = grp(.identical, keeper: "/a/x", redundant: ["/b/x"], reclaim: 1000)
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false)                                         // nothing removed
        #expect(mockFM.virtualDisk["/b/x"] != nil)                   // file still there
        #expect(manager.duplicateGroups.count == 1)                  // group NOT dropped
        // No false "Reclaimed" banner: a warning says the copy couldn't be trashed and the
        // permanent delete was declined, so the file is still there. Silence would read as the
        // click doing nothing.
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
        // Group 1 intact (keeper + copy); group 2's keeper is gone from disk.
        plant(mockFM, ["/a/x", "/b/x", "/b/y"], size: 1000)
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
        plant(mockFM, ["/a/x", "/b/x", "/a/y"], size: 1000)
        // Group 2's redundant copy was rewritten after the scan.
        plant(mockFM, ["/b/y"], size: 77)
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

    /// A folder group against the scan's recorded four files each, as the disk stands at resolve:
    /// - a folder's stat size is not its recursive content size, so the drift check compares
    ///   content and never the two sizes; one wrong line would refuse every folder group;
    /// - a keeper that lost files since the scan refuses the group: trashing the backup would
    ///   destroy the last intact copy of what left the keeper. A directory still existing at the
    ///   path proves nothing about its contents;
    /// - and the other end: the REDUNDANT copy gaining content nothing else has. Trashing it then
    ///   destroys the only instance of that content, under a banner calling it redundant;
    /// - a same-count swap under a new name is caught: the entry count is intact, but the
    ///   per-entry baseline sees both the missing path and the extra one. Byte drift under an
    ///   unchanged name is pinned by the real-tree rewrite test below, since the mock walk reads
    ///   no sizes;
    /// - a folder that cannot be listed completely counts as drifted, which refuses: a partial
    ///   listing cannot prove a folder is still what it was.
    ///
    /// The mock fixtures here hand-build both the group and its recorded snapshot in the mock
    /// walk's convention (it reads no sizes or dates, so entries carry size 0 / nil mtime). They
    /// pin the count/kind semantics; the real-tree section below holds the scan's and the
    /// re-walk's conventions to each other.
    @MainActor
    @Test(arguments: [
        (4, 4, false, false, true, false),    // untouched: resolves
        (3, 4, false, false, false, true),    // the keeper lost a file
        (4, 5, false, false, false, false),   // the redundant copy gained one
        (4, 4, true, false, false, false),    // the copy's p0 swapped for a newcomer
        (4, 4, false, true, false, false),    // the keeper can't be listed
    ])
    func aFolderGroupResolvesOnlyWhileItsContentsMatchTheScan(keeperFiles: Int, redundantFiles: Int, swap: Bool,
                                                               unlistable: Bool, resolves: Bool, warns: Bool) async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        Self.plantFolder(mockFM, at: "/a/Photos", files: keeperFiles, bytesEach: 100_000)
        Self.plantFolder(mockFM, at: "/b/Photos", files: redundantFiles, bytesEach: 100_000)
        if swap {
            // Same count, different membership: p0 replaced by a newcomer after the scan.
            mockFM.virtualDisk.removeValue(forKey: "/b/Photos/p0.jpg")
            mockFM.virtualDisk["/b/Photos/new.jpg"] = .file(100_000)
        }
        if unlistable { mockFM.unlistableDirectories.insert("/a/Photos") }
        let group = Self.folderGroup(keeper: "/a/Photos", redundant: "/b/Photos",
                                     size: 400_000, itemCount: 4,
                                     snapshot: Self.mockFolderSnapshot(files: 4))
        manager.duplicateGroups = [group]

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == resolves, resolves ? "a folder group was refused because a directory stat is not its content size" : "")
        #expect((mockFM.virtualDisk["/b/Photos"] == nil) == resolves,
                "the backup was trashed while the keeper or the copy had drifted from the scan")
        if warns { #expect(manager.banner?.severity == .warning) }
    }

    /// A folder copy with no baseline refuses too, with a banner saying the scan couldn't check
    /// it, not that it changed. The scan records nil for a folder with an unreadable descendant and
    /// a rescan records nil again, so "changed since it was scanned" would claim an unmeasured
    /// change and point at a rescan that can't clear it.
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
        #expect(manager.banner?.message.contains("couldn’t be fully checked") == true)
        #expect(manager.banner?.message.contains("changed since") != true,
                "no change was measured, so none may be claimed")
        // Nothing was removed, so Activity keeps it for this session only.
        #expect(manager.banner?.isRefusal == true)

        // The batch draws the same line when every refusal is a missing baseline.
        manager.banner = nil
        await manager.applyRecommendedDuplicates([group])
        #expect(mockFM.virtualDisk["/b/Photos"] != nil)
        #expect(manager.banner?.message.contains("couldn’t be fully checked") == true)
        #expect(manager.banner?.message.contains("changed since") != true)
        #expect(manager.banner?.isRefusal == true)
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
        // "/c/x3" is absent from the virtual disk entirely — deleted externally after the scan.
        plant(mockFM, ["/a/x", "/b/x2"], size: 1000)
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
        plant(mockFM, ["/a/x", "/b/x"], size: 1000)
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

        let group = overlap("/base/K", "/base/R")
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/base/K"] == nil, "the vanished keeper must not be recreated")
        #expect(mockFM.virtualDisk["/base/R"] != nil, "the last remaining copy must never be trashed")
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.duplicateGroups.count == 1, "group stays until a rescan re-establishes a keeper")
        #expect(manager.banner?.severity == .warning)
        // Even a merge that refuses early must not leave the group marked as merging: that would
        // permanently disable its card.
        #expect(manager.mergingGroupIDs.isEmpty)
    }

    /// The copy being folded away holds a folder its walk can't read. A flatten would read it as
    /// empty and the merge would trash the copy with the unread folder inside, so nothing is
    /// copied or trashed, and the banner says why.
    @MainActor
    @Test func mergeRefusesACopyHoldingAFolderItCouldNotRead() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        for dir in ["/base", "/base/K", "/base/R", "/base/R/Locked"] {
            mockFM.virtualDisk[dir] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        }
        for file in ["/base/K/shared", "/base/R/shared", "/base/R/Locked/only-copy"] {
            mockFM.virtualDisk[file] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)
        }
        mockFM.unlistableDirectories = ["/base/R/Locked"]

        let group = overlap("/base/K", "/base/R", sizes: (5000, 10000), items: (1, 2), reclaim: 5000)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(mockFM.trashedPaths.isEmpty, "trashed: \(mockFM.trashedPaths)")
        #expect(mockFM.virtualDisk["/base/R/Locked/only-copy"] != nil)
        #expect(manager.banner?.message.contains("couldn’t be read") == true,
                "refused for another reason: \(manager.banner?.message ?? "no banner")")
    }

    @MainActor
    @Test func resolveReportsPartialWhenOnlySomeCopiesLeftTheDisk() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)   // permanent-delete confirm declines
        // Distinct copy names (identical groups match by content, not name) so the mock's
        // name-keyed trash staging can't collide and make the outcome order-dependent.
        plant(mockFM, ["/a/x", "/b/x2", "/c/x3"], size: 1000)
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
        try writeBytes(rootA.appendingPathComponent("A/x.bin"), bytes: 5000, fill: 0x41)
        try writeBytes(rootA.appendingPathComponent("B/x.bin"), bytes: 5000, fill: 0x41)
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

    /// Keep separate can be taken back: one ⌘Z step and an undoable banner. Undo puts the card
    /// back and forgets the key; redo hides it again.
    @MainActor
    @Test func keepSeparateCanBeUndoneAndRedone() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        manager.duplicateIgnoreDefaults = ScratchDefaults("DuplicatesIgnoreTest")
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo

        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first)

        undo.beginUndoGrouping()
        manager.keepDuplicateGroupSeparate(group)
        undo.endUndoGrouping()
        #expect(manager.duplicateGroups.isEmpty)
        #expect(manager.banner?.isUndoable == true, "the banner offered no Undo")
        #expect(undo.undoActionName == "Keep Separate")

        undo.undo()
        #expect(manager.banner?.isUndoable != true,
                "Edit ▸ Undo left the “Kept … separate [Undo]” banner up; its Undo now pops the redo")
        #expect(manager.duplicateGroups.map(\.id) == [group.id], "undo did not put the card back")
        #expect(manager.ignoredDuplicateKeys.isEmpty, "undo left the group hidden from future scans")

        undo.redo()
        #expect(manager.duplicateGroups.isEmpty)
        #expect(manager.ignoredDuplicateKeys == [group.ignoreKey])
    }

    /// Undo puts the card back only where it came from. Ids are per scan, so after a rescan of the
    /// same folder (the group back under a new id) it must not add a second card, and after a scan
    /// of another folder it must not drop this folder's group into those results.
    @MainActor
    @Test func undoingKeepSeparatePutsTheCardBackOnlyWhereItCameFrom() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)
        let other = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: other) }
        try writeBytes(other.appendingPathComponent("A/photo.jpg"), bytes: 6000, fill: 0x42)
        try writeBytes(other.appendingPathComponent("B/photo.jpg"), bytes: 6000, fill: 0x42)

        let manager = FileSyncManager()
        manager.duplicateIgnoreDefaults = ScratchDefaults("DuplicatesIgnoreTest")
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManager = undo

        // Same folder, rescanned after the key was forgotten: the group is back under a new id.
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first)
        undo.beginUndoGrouping()
        manager.keepDuplicateGroupSeparate(group)
        undo.endUndoGrouping()
        manager.forgetKeptSeparateGroups(under: root.path)
        await manager.findDuplicates(root: root)
        #expect(manager.duplicateGroups.count == 1, "premise: the rescan shows the group again")
        undo.undo()
        #expect(manager.duplicateGroups.count == 1, "undo added a second card for one cluster")

        // Another folder scanned since: undo forgets the key but adds nothing to those results.
        undo.redo()
        await manager.findDuplicates(root: other)
        let otherIds = manager.duplicateGroups.map(\.id)
        #expect(otherIds.count == 1, "premise: the other folder has its own group")
        undo.undo()
        #expect(manager.duplicateGroups.map(\.id) == otherIds,
                "undo dropped another folder's group into these results")
        #expect(!manager.ignoredDuplicateKeys.contains(group.ignoreKey),
                "the key stays hidden from the next scan of its own folder")
    }

    /// Show them again: groups kept in an earlier session come back with the next scan.
    @MainActor
    @Test func forgettingKeptSeparateGroupsFlagsThemAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        manager.duplicateIgnoreDefaults = ScratchDefaults("DuplicatesIgnoreTest")

        await manager.findDuplicates(root: root)
        manager.keepDuplicateGroupSeparate(try #require(manager.duplicateGroups.first))
        // Not "won't be flagged again" outright: the key is these exact copies.
        #expect(manager.banner?.message.hasSuffix("it won’t be flagged again while its copies stay put.") == true,
                "\(manager.banner?.message ?? "nil")")
        await manager.findDuplicates(root: root)
        #expect(manager.duplicateGroups.isEmpty, "premise: the group stays hidden across a rescan")

        #expect(manager.forgetKeptSeparateGroups(under: root.path) == 1)
        await manager.findDuplicates(root: root)
        #expect(manager.duplicateGroups.count == 1)

        // A file group (distinct siblings keep the two folders from grouping) kept separate stays
        // hidden across a rescan too.
        let fileRoot = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: fileRoot) }
        try writeBytes(fileRoot.appendingPathComponent("A/report.pdf"), bytes: 5000, fill: 0x41)
        try writeBytes(fileRoot.appendingPathComponent("B/report.pdf"), bytes: 5000, fill: 0x41)
        try writeBytes(fileRoot.appendingPathComponent("A/a-only.txt"), bytes: 8, fill: 0x61)
        try writeBytes(fileRoot.appendingPathComponent("B/b-only.txt"), bytes: 12, fill: 0x62)
        await manager.findDuplicates(root: fileRoot)
        #expect(manager.duplicateGroups.count == 1)
        let fileGroup = try #require(manager.duplicateGroups.first)
        #expect(fileGroup.isDirectory == false, "premise: the siblings make this a file group")
        manager.keepDuplicateGroupSeparate(fileGroup)
        #expect(manager.duplicateGroups.isEmpty)
        await manager.findDuplicates(root: fileRoot)
        #expect(manager.duplicateGroups.isEmpty)
    }

    /// Show them again counts and forgets only this folder's keys. The set holds every folder and
    /// provider at once; only the keys a scan of this folder could flag are this lens's, and the
    /// forgetting says how many.
    @MainActor
    @Test func showingKeptGroupsAgainTouchesOnlyThisFolder() throws {
        // On disk, every copy: a key whose copies are gone is not counted (below).
        let base = try makeCanonicalTempRoot(prefix: "KeptSeparateFolders")
        defer { try? FileManager.default.removeItem(at: base) }
        let x = base.path
        let all = ["Documents/a.pdf", "Documents/b/a.pdf", "Documents/c/n.txt", "Documents/d/n.txt",
                   "Pictures/p.jpg", "Pictures/q/p.jpg", "Documents/s.pdf", "Desktop/s.pdf",
                   "DocumentsOld/a.pdf", "DocumentsOld/b/a.pdf"]
        for path in all { try writeBytes(base.appendingPathComponent(path), bytes: 10, fill: 0x41) }
        let manager = FileSyncManager()
        manager.duplicateIgnoreDefaults = ScratchDefaults("DuplicatesIgnoreTest")
        let here = "\(x)/Documents/a.pdf\n\(x)/Documents/b/a.pdf"
        let alsoHere = "\(x)/Documents/c/n.txt\n\(x)/Documents/d/n.txt"
        let elsewhere = "\(x)/Pictures/p.jpg\n\(x)/Pictures/q/p.jpg"
        let straddling = "\(x)/Documents/s.pdf\n\(x)/Desktop/s.pdf"
        let prefixSibling = "\(x)/DocumentsOld/a.pdf\n\(x)/DocumentsOld/b/a.pdf"
        manager.ignoredDuplicateKeys = [here, alsoHere, elsewhere, straddling, prefixSibling]

        #expect(manager.keptSeparateKeys(under: "\(x)/Documents") == [here, alsoHere])
        #expect(manager.keptSeparateKeys(under: nil).isEmpty)

        #expect(manager.forgetKeptSeparateGroups(under: "\(x)/Documents") == 2)
        #expect(manager.ignoredDuplicateKeys == [elsewhere, straddling, prefixSibling],
                "Show them again forgot groups another folder's scan had kept separate")
        #expect(manager.banner?.message == "Forgot 2 groups kept separate — this scan flags any that are still duplicates.")
        #expect(manager.banner?.isUndoable != true)
        #expect(FileSyncManager.keptSeparateForgottenSentence(1)
                == "Forgot 1 group kept separate — this scan flags it again if it’s still a duplicate.")
    }

    /// A kept group whose copy is gone is neither counted nor promised back: its key is the exact
    /// copy paths, so no scan can match it again. It is forgotten all the same, so the store
    /// doesn't keep it forever.
    ///
    /// Gone is known from the scan's own tree, not a stat per copy, since the lens counts these on
    /// every redraw. So nothing is known gone until a scan has looked: the control below.
    @MainActor
    @Test func aKeptGroupWithACopyGoneIsNeitherCountedNorPromisedBack() async throws {
        let base = try makeCanonicalTempRoot(prefix: "KeptSeparateGone")
        defer { try? FileManager.default.removeItem(at: base) }
        let x = base.path
        for path in ["a/report.pdf", "b/report.pdf", "c/n.txt"] {
            try writeBytes(base.appendingPathComponent(path), bytes: 5000, fill: 0x41)
        }
        let manager = FileSyncManager()
        manager.duplicateIgnoreDefaults = ScratchDefaults("DuplicatesIgnoreTest")
        let live = "\(x)/a/report.pdf\n\(x)/b/report.pdf"
        let oneGone = "\(x)/c/n.txt\n\(x)/d/n.txt"   // d/n.txt was never written
        let allGone = "\(x)/e/m.txt\n\(x)/f/m.txt"
        manager.ignoredDuplicateKeys = [oneGone, allGone, live]
        // The control: before any scan has looked, nothing is known gone.
        #expect(manager.keptSeparateKeys(under: x) == [oneGone, allGone, live])

        await manager.findDuplicates(root: base)
        #expect(!manager.duplicateGroups.contains { $0.ignoreKey == live },
                "premise: the live group stays kept separate")
        #expect(manager.keptSeparateKeys(under: x) == [live],
                "the lens counts a kept group whose copies the scan did not find")
        #expect(manager.forgetKeptSeparateGroups(under: x) == 1)
        #expect(manager.banner?.message == "Forgot 1 group kept separate — this scan flags it again if it’s still a duplicate.")
        #expect(manager.ignoredDuplicateKeys.isEmpty, "a dead key was left in the store")

        // Nothing left that could come back: forgotten, but no banner promising anything.
        manager.ignoredDuplicateKeys = [allGone]
        manager.banner = nil
        #expect(manager.forgetKeptSeparateGroups(under: x) == 0)
        #expect(manager.ignoredDuplicateKeys.isEmpty)
        #expect(manager.banner == nil, "a banner promised back groups whose copies are gone")
    }

    /// Show them again works under the deeper of the scan root and the scope. Under the scan root
    /// of a scoped list it would forget keys the list never showed, and the scoped rescan would
    /// bring none of them back.
    @MainActor
    @Test func showingKeptGroupsAgainUsesTheDeeperOfScanAndScope() throws {
        let root = "/Users/x/Documents"
        let legal = try #require(OrganizeScope(path: root + "/Legal", providerRoot: root))
        let deep = root + "/Legal/2024"
        // Scanned wide, scoped narrow: the scope. Scanned deeper than the scope: the scan root.
        #expect(OrganizeAim.keptSeparateFolder(scannedRoot: root, scope: legal) == legal.path)
        #expect(OrganizeAim.keptSeparateFolder(scannedRoot: deep, scope: legal) == deep)
        #expect(OrganizeAim.keptSeparateFolder(scannedRoot: legal.path, scope: legal) == legal.path)
        // Unrelated folders: the scope. One side missing: the other.
        #expect(OrganizeAim.keptSeparateFolder(scannedRoot: root + "/Taxes", scope: legal)
                == legal.path)
        #expect(OrganizeAim.keptSeparateFolder(scannedRoot: root, scope: nil) == root)
        #expect(OrganizeAim.keptSeparateFolder(scannedRoot: nil, scope: legal) == legal.path)
        #expect(OrganizeAim.keptSeparateFolder(scannedRoot: "", scope: nil) == nil)

        // The keys' copies on disk, since a key with a copy gone is not counted.
        let base = try makeCanonicalTempRoot(prefix: "KeptSeparateScope")
        defer { try? FileManager.default.removeItem(at: base) }
        let disk = base.path + "/Documents"
        for path in ["Legal/a.pdf", "Legal/b/a.pdf", "Taxes/t.pdf", "Taxes/u/t.pdf"] {
            try writeBytes(URL(fileURLWithPath: disk + "/" + path), bytes: 10, fill: 0x41)
        }
        let diskLegal = try #require(OrganizeScope(path: disk + "/Legal", providerRoot: disk))
        let manager = FileSyncManager()
        manager.duplicateIgnoreDefaults = ScratchDefaults("DuplicatesIgnoreTest")
        let inScope = "\(disk)/Legal/a.pdf\n\(disk)/Legal/b/a.pdf"
        let outsideScope = "\(disk)/Taxes/t.pdf\n\(disk)/Taxes/u/t.pdf"
        manager.ignoredDuplicateKeys = [inScope, outsideScope]
        let folder = OrganizeAim.keptSeparateFolder(scannedRoot: disk, scope: diskLegal)
        #expect(manager.keptSeparateKeys(under: folder) == [inScope])
        #expect(manager.forgetKeptSeparateGroups(under: folder) == 1)
        #expect(manager.ignoredDuplicateKeys == [outsideScope],
                "Show them again forgot a group the scoped list never showed")
    }

    // MARK: Cancellable scan

    @MainActor
    @Test func startFindDuplicatesRunsToCompletionViaTask() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("A/x.bin"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("B/x.bin"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("A/a.txt"), bytes: 8, fill: 0x61)
        try writeBytes(root.appendingPathComponent("B/b.txt"), bytes: 9, fill: 0x62)

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
            try writeBytes(root.appendingPathComponent("f\(i).bin"), bytes: 64, fill: UInt8(i))
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
            try writeBytes(root.appendingPathComponent("f\(i).bin"), bytes: 64, fill: UInt8(i))
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

    /// The epoch guard's real case: a cancel landing mid-hash, with numeric progress live (the
    /// 8-file test above cancels in the walk phase). A gating file manager freezes hashing at 50
    /// completions: f50–f55 block in `sha256Hex`'s pre-hash stat and fill the 6-wide window, so
    /// the cancel point is deterministic without sleeps. The drain can reach neither another
    /// 50-multiple nor done == total, so any numeric publish after the cancel is a straggler the
    /// epoch guard should have dropped.
    @MainActor
    @Test(.parksThreads(6)) func cancelMidHashRepublishesNoNumericProgress() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // Same-size, pairwise-distinct files: every one is a hash candidate, so total == 120.
        for i in 0..<120 {
            try writeBytes(root.appendingPathComponent("f\(i).bin"), bytes: 64, fill: UInt8(i))
        }

        // Names sort Finder-style (numeric-aware), so hashing schedules f0…f119 in order and
        // f50–f55 are the 6 in flight when the 50th completion publishes. 6 is hashFiles'
        // `maxConcurrent` default: if that widens, the waitUntil below times out (a failure, not
        // a hang); widen this set to match.
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
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try writeBytes(keeper.appendingPathComponent("keeper-only.txt"), bytes: 5000, fill: 0x4B)
        try writeBytes(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)   // same content as keeper's
        try writeBytes(redundant.appendingPathComponent("sub/unique.txt"), bytes: 5000, fill: 0x52)

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

    /// Where a source file's name is taken, and whether its bytes already sit in the keeper folder,
    /// decides whether the fold copies it (all files 5,000 bytes; a fill byte stands for content):
    /// - retry idempotence: run 1 collided at Keeper/a.txt (different content held the name) and
    ///   landed at "a 2.txt". A retry re-plans from scratch and must see the content already in
    ///   that folder and skip, not mint "a 3.txt" each time (the cancel banner promises "a retry
    ///   skips what landed");
    /// - the complement: the name is taken by different content and the source's bytes are NOT
    ///   yet anywhere in that folder, so the fold must still copy (landing uniquified);
    /// - name-preserving: the destination name is free but the bytes already live in that folder
    ///   under the user's own name, so copy anyway. Losing a meaningfully named file is the worse
    ///   surprise; a later duplicates scan reconciles the bytes. The retry skip applies only when
    ///   the name is taken, where the fold could never have kept it;
    /// - on a case-insensitive keeper volume "A.txt" and "a.txt" are one on-disk name. Exact-case
    ///   keys would miss the collision, copy byte-identical content to a junk "a 2.txt", and mint
    ///   more on each retry. Folded keys treat it as the same-location duplicate it is;
    /// - the retry shape of the case fold: run 1 collided "a.txt" against keeper "A.txt"
    ///   (different content) and landed "a 2.txt"; the retry must see the folded name as taken
    ///   AND the bytes as present, and plan nothing;
    /// - APFS/HFS+ name lookups are normalization-insensitive on EVERY volume (providers mix NFC
    ///   and NFD forms — the diff engine's nearNameKey precomposes for the same reason), so an NFD
    ///   keeper name and an NFC source rel are one on-disk name: byte-identical content must hit
    ///   the same-location skip, not copy-and-uniquify a junk sibling;
    /// - the default (case-sensitive) path is untouched: "A.txt" and "a.txt" are distinct names
    ///   there, so the byte-identical source still copies under its own name;
    /// - the "name taken" gate must trigger on what the COPY loop's fileExists collides with: any
    ///   on-disk entry, including a directory (which the hash maps can never hold). Run 1: source
    ///   file "sub" collided with keeper DIRECTORY "sub", landed uniquified as "sub 2". The retry
    ///   must skip, not mint "sub 3".
    @Test(arguments: Self.planMergeCases)
    func planMergeCopiesOnlyWhatTheKeeperFolderLacks(_ c: PlanMergeCase) async throws {
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        for (name, fill) in c.keeper { try writeBytes(keeper.appendingPathComponent(name), bytes: 5000, fill: fill) }
        for (name, fill) in c.source { try writeBytes(redundant.appendingPathComponent(name), bytes: 5000, fill: fill) }

        let plan = await FileSyncManager.planMerge(
            from: redundant, into: keeper, caseSensitiveVolume: c.caseSensitive, fileManager: FileManager.default)
        #expect(plan.steps.map { $0.src.lastPathComponent } == c.expected)
    }

    /// Files planted in the keeper and the source (name, fill byte), the volume's case rule, and
    /// the source names the plan must copy.
    struct PlanMergeCase: Sendable {
        let keeper: [(String, UInt8)]
        let source: [(String, UInt8)]
        let caseSensitive: Bool
        let expected: [String]
    }

    static let planMergeCases: [PlanMergeCase] = [
        PlanMergeCase(keeper: [("a.txt", 0x41), ("a 2.txt", 0x59)], source: [("a.txt", 0x59)], caseSensitive: true, expected: []),
        PlanMergeCase(keeper: [("a.txt", 0x41)], source: [("a.txt", 0x59)], caseSensitive: true, expected: ["a.txt"]),
        PlanMergeCase(keeper: [("b.txt", 0x59)], source: [("a.txt", 0x59)], caseSensitive: true, expected: ["a.txt"]),
        PlanMergeCase(keeper: [("A.txt", 0x59)], source: [("a.txt", 0x59)], caseSensitive: false, expected: []),
        PlanMergeCase(keeper: [("A.txt", 0x41), ("a 2.txt", 0x59)], source: [("a.txt", 0x59)], caseSensitive: false, expected: []),
        // NFD keeper name, NFC source name.
        PlanMergeCase(keeper: [("cafe\u{0301}.txt", 0x59)], source: [("caf\u{E9}.txt", 0x59)], caseSensitive: true, expected: []),
        PlanMergeCase(keeper: [("A.txt", 0x59)], source: [("a.txt", 0x59)], caseSensitive: true, expected: ["a.txt"]),
        // A DIRECTORY holds the name.
        PlanMergeCase(keeper: [("sub/inner.txt", 0x49), ("sub 2", 0x59)], source: [("sub", 0x59)], caseSensitive: true, expected: []),
    ]

    @MainActor
    @Test func uniqueSizeHardLinksNeverEnterVersionsGroups() async throws {
        // The nlink filter must cover every file the passes admit, not only size-colliding hash
        // candidates. A hard link with a unique size would otherwise ride into a versions group as
        // an unknown-hash member, recommended for removal with its bytes counted reclaimable,
        // though trashing a link frees nothing (its sibling here is outside the scan root, which
        // only nlink can see).
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Root")
        try writeBytes(root.appendingPathComponent("Docs/report.pdf"), bytes: 9_000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("Docs/report copy.pdf"), bytes: 9_000, fill: 0x42)
        let outside = base.appendingPathComponent("outside-v2.bin")
        try writeBytes(outside, bytes: 9_050, fill: 0x43)                      // unique size
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
        // End-to-end on a real volume: link(2) entries carry linkCount 2 and land in
        // multiLinkPaths (the finder's drop of them is
        // `DuplicateFinderTests.hardLinkedEntriesLeaveDuplicateCandidacyEntirely`).
        // A singly-linked file is NOT flagged (the negative control).
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("Docs/a.bin")
        let b = base.appendingPathComponent("Docs/b.bin")
        let c = base.appendingPathComponent("Docs/c.bin")
        try writeBytes(a, bytes: 5000, fill: 0x41)
        try FileManager.default.linkItem(at: a, to: b)
        try writeBytes(c, bytes: 5000, fill: 0x41)

        let flagged = FileSyncManager.multiLinkPaths(among: [a.path, b.path, c.path])
        #expect(flagged == [a.path, b.path])   // both link entries; the real file stays
    }

    @MainActor
    @Test func mergeRefusesWhenAKeeperSymlinkDirWouldReceiveTheFold() async throws {
        // A step aimed under a keeper symlink dir would copy through the link into whatever it
        // points at (an external folder gets the "folded" file and the trash runs; a link into
        // the source mints junk per retry). So any such step refuses the merge up front: nothing
        // copied or trashed, the group stays, and the banner names the link.
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        let elsewhere = base.appendingPathComponent("Elsewhere")
        try writeBytes(keeper.appendingPathComponent("own.txt"), bytes: 5000, fill: 0x4B)
        try writeBytes(redundant.appendingPathComponent("sub/y.txt"), bytes: 5000, fill: 0x59)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: keeper.appendingPathComponent("sub"),
                                                   withDestinationURL: elsewhere)

        let manager = FileSyncManager()
        let group = overlap(keeper.path, redundant.path, depths: (0, 0), reclaim: 5000)
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
        // buildTree follows symlinked directories, so a keeper link-dir's children arrive as
        // ordinary files. With Keeper/sub → Redundant/sub they'd read as "already in the keeper",
        // nothing would be planned, and the trash step would remove the only real copy, leaving a
        // dangling link. So the linked subtree is pruned from the keeper's view and the step comes
        // back blocked, not planned: a planned copy would write through the link (here back into
        // the source).
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent("Redundant")
        try writeBytes(keeper.appendingPathComponent("own.txt"), bytes: 5000, fill: 0x4B)
        try writeBytes(redundant.appendingPathComponent("sub/f.txt"), bytes: 5000, fill: 0x59)  // only real copy
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
        try writeBytes(keeper.appendingPathComponent("b.txt"), bytes: 5000, fill: 0x5A)      // name-holder, content Z
        try writeBytes(redundant.appendingPathComponent("b.txt"), bytes: 5000, fill: 0x59)   // content Y — only real copy
        try FileManager.default.createSymbolicLink(
            at: keeper.appendingPathComponent("alias.txt"),
            withDestinationURL: redundant.appendingPathComponent("b.txt"))

        let plan = await FileSyncManager.planMerge(from: redundant, into: keeper, fileManager: FileManager.default)
        // Y must still be copied: the link's hash (Y, via the target) may not count as
        // "already in the folder".
        #expect(plan.steps.map { $0.src.lastPathComponent } == ["b.txt"])
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
        // A same-size rewrite (mtime bumped) is drift too: size alone would let the only copy of
        // the rewritten bytes be trashed.
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
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("unique.txt"), bytes: 5000, fill: 0x52)

        // Simulates external activity: the merge's first copy also drops a new file into the
        // redundant folder, after the plan's snapshot and before the trash step. Re-verifying only
        // the keeper would trash the folder and destroy surprise.txt.
        let fm = MidMergeInterferingFileManager(
            dropping: redundant.appendingPathComponent("surprise.txt"),
            bytes: Data(repeating: 0x21, count: 4096))
        let manager = FileSyncManager(fileManager: fm)

        let group = overlap(keeper.path, redundant.path, sizes: (10000, 10000), items: (1, 2), depths: (0, 0), reclaim: 5000)
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
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try writeBytes(keeper.appendingPathComponent("keeper-only.txt"), bytes: 5000, fill: 0x4B)
        try writeBytes(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("redundant-only.txt"), bytes: 5000, fill: 0x52)
        let trash = ScratchTrash(in: base)
        let manager = FileSyncManager(fileManager: trash)
        let group = overlap(keeper.path, redundant.path, sizes: (10000, 10000), items: (2, 2), depths: (0, 0), reclaim: 5000)
        manager.duplicateGroups = [group]

        let ok = await manager.mergeDuplicateGroup(group)
        await waitUntil("redundant folder trashed") { !FileManager.default.fileExists(atPath: redundant.path) }

        #expect(ok)
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("redundant-only.txt").path))  // unique folded in
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("keeper-only.txt").path))     // keeper intact
        #expect(!FileManager.default.fileExists(atPath: redundant.path))                                            // redundant gone
        #expect(manager.duplicateGroups.isEmpty)
        #expect(trash.names == [rName], "the redundant folder never reached the test's own Trash")
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

        let group = overlap("/base/K", "/base/R")
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
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("redundant-only.txt"), bytes: 5000, fill: 0x52)
        let trash = ScratchTrash(in: base)
        let manager = FileSyncManager(fileManager: trash)
        let group = overlap(keeper.path, redundant.path, sizes: (5000, 10000), items: (1, 2), depths: (0, 0), reclaim: 5000)
        manager.duplicateGroups = [group]

        async let first = manager.mergeDuplicateGroup(group)
        async let second = manager.mergeDuplicateGroup(group)
        let (a, b) = await (first, second)

        #expect(a != b, "exactly one of the two racing calls may run (\(a), \(b))")
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("redundant-only.txt").path))
        #expect(!FileManager.default.fileExists(atPath: keeper.appendingPathComponent("redundant-only 2.txt").path),
                "the dropped call must not re-fold already-folded files as \" 2\" copies")
        #expect(manager.mergingGroupIDs.isEmpty, "the in-flight marker clears when the merge ends")
        #expect(trash.names == [rName], "the redundant folder never reached the test's own Trash")
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

        let group = overlap("/base/K", "/base/R")
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
        try writeBytes(keeper.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x41)
        try writeBytes(nested.appendingPathComponent("a.txt"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        let group = overlap(keeper.path, nested.path, rUnique: 0, depths: (0, 2), shared: 1.0, reclaim: 5000)
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
        try writeBytes(root.appendingPathComponent("A/x.bin"), bytes: 5000, fill: 0x41)
        try writeBytes(root.appendingPathComponent("B/x.bin"), bytes: 5000, fill: 0x41)

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

    // MARK: Folder drift, end to end on a real tree
    //
    // The mock-backed tests above write down both sides of the comparison, so they can never
    // disagree with themselves. These run the real pipeline (scan a real temp tree, then
    // resolve), so a convention drift between the scan's baseline and the resolve-time walk
    // fails here.

    /// A `.DS_Store` is not drift. The scan skips `options.ignoredNames` when measuring a folder,
    /// so a re-walk that counted them would disagree by a constant offset and refuse every folder
    /// ever opened in Finder, permanently, since a rescan reproduces the mismatch.
    @MainActor
    @Test func aFolderPairHoldingAFinderDSStoreStillResolves() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "KeepA-\(UUID().uuidString)", bName = "CopyB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        for folder in [aName, bName] {
            try writeBytes(root.appendingPathComponent("\(folder)/f1.txt"), bytes: 5000, fill: 0x41)
            try writeBytes(root.appendingPathComponent("\(folder)/f2.txt"), bytes: 6000, fill: 0x42)
            try writeBytes(root.appendingPathComponent("\(folder)/.DS_Store"), bytes: 800, fill: 0x44)
        }

        let manager = FileSyncManager(fileManager: trash)
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }),
                                 "two folders identical up to an ignored name must still group")
        let redundantPath = try #require(group.recommendedRemovalPaths.first)

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == true, "a folder that merely holds a .DS_Store was refused as 'changed since it was scanned'")
        #expect(!FileManager.default.fileExists(atPath: redundantPath))
        #expect(trash.names == [(redundantPath as NSString).lastPathComponent],
                "the redundant folder never reached the test's own Trash")
        #expect(FileManager.default.fileExists(atPath: group.keeper.path))
    }

    /// A same-length rewrite is drift. Count and total bytes are unchanged (`sed -i` over
    /// fixed-width text, one 5,000-byte export replaced by another), so a count+bytes check would
    /// trash the only copy of the new content. Like the file-level check, the folder check
    /// compares size and mtime, per file.
    ///
    /// The keeper side of the same gate (`rewriteKeeper`): a rewrite inside the folder being kept
    /// makes the "redundant" copy the last intact instance of the scanned content. Count,
    /// membership and byte totals are unchanged, so only the per-entry mtime half of
    /// `folderContentsMatchScan` catches it, and only because `driftedFolderInGroup` checks the
    /// keeper too.
    @MainActor
    @Test(arguments: [false, true])
    func aSameLengthRewriteInsideAFolderOfTheGroupIsRefused(rewriteKeeper: Bool) async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "KeepA-\(UUID().uuidString)", bName = "CopyB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        for folder in [aName, bName] {
            try writeBytes(root.appendingPathComponent("\(folder)/f1.txt"), bytes: 5000, fill: 0x41)
            try writeBytes(root.appendingPathComponent("\(folder)/f2.txt"), bytes: 6000, fill: 0x42)
        }

        let manager = FileSyncManager(fileManager: trash)
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }))
        let redundantPath = try #require(group.recommendedRemovalPaths.first)

        // Rewrite one file inside the copy about to be trashed, or inside the keeper: same byte
        // count, different content. The mtime moves on its own; pinned explicitly so the drift is
        // deterministic rather than riding on filesystem timestamp granularity.
        let rewritten = ((rewriteKeeper ? group.keeper.path : redundantPath) as NSString).appendingPathComponent("f1.txt")
        try Data(repeating: 0x5A, count: 5000).write(to: URL(fileURLWithPath: rewritten))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(500)],
                                              ofItemAtPath: rewritten)

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == false, "a same-length rewrite left count and bytes unchanged, yet the group resolved")
        #expect(FileManager.default.fileExists(atPath: redundantPath),
                "the copy holds content nothing else has — it must stay on disk")
        #expect(manager.banner?.severity == .warning)
    }

    /// The re-walk's ignored-name skip, pinned from outside the recording side. The snapshot test
    /// below runs both sides through one builder, so a change to its convention moves both and
    /// still compares equal. Here the baseline has no ignored name and the `.DS_Store` arrives
    /// afterwards (Finder opening the folder), so only the re-walk's own skip keeps the verdict
    /// true.
    @MainActor
    @Test func anIgnoredNameAddedAfterTheScanIsNotDrift() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["A", "B"] {
            try writeBytes(root.appendingPathComponent("\(folder)/f.txt"), bytes: 5000, fill: 0x41)
        }

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }))
        let snapshot = try #require(group.keeper.contentSnapshot)
        #expect(snapshot.entries.keys.sorted() == ["f.txt"],
                "the baseline was recorded before any ignored name existed")

        // Finder visits the folder after the scan.
        try writeBytes(URL(fileURLWithPath: group.keeper.path).appendingPathComponent(".DS_Store"),
                  bytes: 700, fill: 0x44)

        #expect(await FileSyncManager.folderContentsMatchScan(
            path: group.keeper.path, snapshot: snapshot, fileManager: FileManager.default),
                "the re-walk must skip ignored names on its own — the baseline never saw this one")

        // Control: a NON-ignored arrival through the same re-walk still reads as drift, so the
        // pin above cannot pass by the comparison being inert.
        try writeBytes(URL(fileURLWithPath: group.keeper.path).appendingPathComponent("new.txt"),
                  bytes: 700, fill: 0x45)
        #expect(await FileSyncManager.folderContentsMatchScan(
            path: group.keeper.path, snapshot: snapshot, fileManager: FileManager.default) == false)
    }

    /// The ignored-name offset must not mask real drift either. A copy loses one real file while
    /// an ignored name of the same size sits in it: raw count and bytes match the scan's rollup
    /// exactly, so a count+bytes check would read a changed folder as intact.
    @MainActor
    @Test func anIgnoredNameCannotMaskALostFile() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "CleanA-\(UUID().uuidString)", bName = "MaskB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        for folder in [aName, bName] {
            for i in 1...4 {
                try writeBytes(root.appendingPathComponent("\(folder)/f\(i).txt"), bytes: 5000, fill: 0x41)
            }
        }
        // Only the B copy holds the ignored name, sized exactly like the file it will "replace".
        try writeBytes(root.appendingPathComponent("\(bName)/.DS_Store"), bytes: 5000, fill: 0x44)

        let manager = FileSyncManager(fileManager: trash)
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

    /// The scan's symlink convention and the re-walk's must match. The scan records a link with
    /// the size and mtime resolved from its target; a re-walk that read the link itself would
    /// refuse a folder that never changed, on every rescan, as in the `.DS_Store` case.
    @MainActor
    @Test func aSymlinkInsideAFolderPairDoesNotFalselyDrift() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicatesTest")
        let aName = "KeepA-\(UUID().uuidString)", bName = "CopyB-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        for folder in [aName, bName] {
            try writeBytes(root.appendingPathComponent("\(folder)/f.txt"), bytes: 5000, fill: 0x41)
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent("\(folder)/link.txt").path,
                withDestinationPath: "f.txt")
        }

        let manager = FileSyncManager(fileManager: trash)
        await manager.findDuplicates(root: root)
        let group = try #require(manager.duplicateGroups.first(where: { $0.isDirectory && $0.matchType == .identical }),
                                 "two folders identical link-for-link must group")
        let redundantPath = try #require(group.recommendedRemovalPaths.first)

        let ok = await manager.resolveDuplicateGroup(group)

        #expect(ok == true, "an unchanged folder was refused because the re-walk stats symlinks by a different convention than the scan")
        #expect(!FileManager.default.fileExists(atPath: redundantPath))
        #expect(trash.names == [(redundantPath as NSString).lastPathComponent],
                "the redundant folder never reached the test's own Trash")
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
            try writeBytes(root.appendingPathComponent("\(folder)/f.txt"), bytes: 5000, fill: 0x41)
            try writeBytes(root.appendingPathComponent("\(folder)/.DS_Store"), bytes: 700, fill: 0x44)
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
    @Test func aGroupWithNoRemovalStaysUntilDismissed() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        let a = DuplicateCopy(id: "/root/Screenshots", name: "Screenshots", isDirectory: true,
                              size: 100, itemCount: 2, modificationDate: nil, uniqueItemCount: 0,
                              depth: 0, isRecommendedKeeper: true)
        let b = DuplicateCopy(id: "/root/Work/Screenshots", name: "Screenshots", isDirectory: true,
                              size: 100, itemCount: 2, modificationDate: nil, uniqueItemCount: 2,
                              depth: 1, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.3), name: "Screenshots", isDirectory: true,
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

/// A real FileManager that, once armed, parks callers statting one of `gatedNames` until
/// `release()`, so the cancel-mid-hash test can pick its cancellation point without sleeps.
///
/// It gates both `fileExists(atPath:isDirectory:)` and `attributesOfItem`, whichever `sha256Hex`
/// reaches first: gating one alone stops parking if the verifier changes its read, and the test
/// then cancels a finished scan. The gate is name-scoped, so covering both costs nothing. It must
/// be a FileManager subclass: buildTree reads file sizes only on its `fileManager is FileManager`
/// fast path, and without sizes there are no hash candidates. The walk stats regular files via
/// URL.resourceValues, so only the hash phase can block.
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
