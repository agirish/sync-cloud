import Testing
import Foundation
import Combine
@testable import Sync

/// Manager-level coverage for Tidy: the end-to-end scan (real files, so the SHA-256 layer runs)
/// and the resolve path (mock disk, so we can assert what gets trashed without touching ~/.Trash).
@Suite struct FileSyncManagerDuplicatesTests {


    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func findDuplicatesDetectsIdenticalFileEndToEnd() async throws {
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
        defer { try? FileManager.default.removeItem(at: root) }
        // Two byte-identical files over the (injected) hash cap: they are size-collision
        // candidates, but hashing skips both — so no group can form, and the scan must SAY so
        // instead of silently reporting "no duplicates".
        try write(root.appendingPathComponent("A/movie.mp4"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("B/movie.mp4"), bytes: 5000, fill: 0x41)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, maxBytesToHash: 1000)

        #expect(manager.hasFoundDuplicates)
        #expect(manager.duplicateGroups.isEmpty)                      // identity unknown → no claim
        #expect(manager.duplicateScanSkips.tooLarge == 2)
        #expect(manager.duplicateScanSkips.cloudOnly == 0)
        #expect(manager.duplicateScanSkips.total == 2)

        // A rescan with the real cap hashes them — and resets the skip figure with the results.
        await manager.findDuplicates(root: root)
        #expect(manager.duplicateScanSkips == FileSyncManager.DuplicateScanSkips())
        #expect(manager.duplicateGroups.count == 1)

        // clearDuplicates resets it alongside the rest of the results state.
        await manager.findDuplicates(root: root, maxBytesToHash: 1000)
        #expect(manager.duplicateScanSkips.total == 2)
        manager.clearDuplicates()
        #expect(manager.duplicateScanSkips == FileSyncManager.DuplicateScanSkips())
    }

    @MainActor
    @Test func findDuplicatesSkipsAndCountsCloudOnlyCandidatesWithoutReadingThem() async throws {
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        #expect(manager.banner == nil)                               // no false "Reclaimed" banner
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
        let rootA = try makeCanonicalTempRoot(prefix: "TidyTest")
        defer { try? FileManager.default.removeItem(at: rootA) }
        try write(rootA.appendingPathComponent("A/x.bin"), bytes: 5000, fill: 0x41)
        try write(rootA.appendingPathComponent("B/x.bin"), bytes: 5000, fill: 0x41)
        let rootB = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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

    // MARK: Cancellable scan

    @MainActor
    @Test func startFindDuplicatesRunsToCompletionViaTask() async throws {
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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

    // MARK: Numeric scan progress (drives Tidy's determinate bar)

    @MainActor
    @Test func duplicateScanProgressPublishesMonotonicallyThenResets() async throws {
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let base = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let base = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let base = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let base = try makeCanonicalTempRoot(prefix: "TidyTest")
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
        let root = try makeCanonicalTempRoot(prefix: "TidyTest")
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

/// A real FileManager that, once armed, parks callers statting one of `gatedNames` via
/// `fileExists(atPath:isDirectory:)` — the first call `sha256Hex` makes for every file it
/// hashes — until `release()`. It must be a FileManager SUBCLASS, not a plain FileManaging
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
}
