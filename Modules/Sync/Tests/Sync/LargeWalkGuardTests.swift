import Foundation
import Testing
@testable import Sync

/// The size guard on the passes that can't be budgeted. Storage, Find Duplicates and the other
/// whole-tree passes must read everything, since a total or a duplicate group from part of a tree is
/// a wrong answer, not a partial view. So they run a budgeted walk as a probe and stop to ask, which
/// these pin. The probe budget is an instance property so tests can drive the confirm and decline
/// paths without building a 400,000-entry tree.
@Suite struct LargeWalkGuardTests {

    private func fixture(files: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("largewalk-\(UUID().uuidString)")
        for i in 0..<files {
            try writeBytes(root.appendingPathComponent("d\(i)/f\(i).txt"), bytes: 8)
        }
        return root
    }

    // MARK: - The seam's default

    /// Unwired, the guard refuses. The harm it guards is a pass that never finishes, and an unwired
    /// manager that proceeded would allow it where nobody is watching. The same fail-safe as
    /// `permanentDeleteConfirmer`, for a weaker harm.
    @MainActor
    @Test func anUnwiredManagerRefusesALargeWalk() async throws {
        let root = try fixture(files: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        manager.wholeTreeProbeBudget = 4
        await manager.buildStorageLens(root: root)
        #expect(manager.storageLensReport == nil,
                "an unwired manager analysed a tree past its probe budget — the default is supposed to refuse")
        #expect(manager.storageLensLifecycle.hasCompleted == false)
    }

    // MARK: - Storage

    @MainActor
    @Test func decliningLeavesThePreviousReadingAlone() async throws {
        let small = try fixture(files: 2)
        let big = try fixture(files: 12)
        defer {
            try? FileManager.default.removeItem(at: small)
            try? FileManager.default.removeItem(at: big)
        }
        let manager = FileSyncManager()
        manager.largeWalkConfirmer = { _ in true }
        await manager.buildStorageLens(root: small)
        let first = try #require(manager.storageLensReport)

        manager.wholeTreeProbeBudget = 4
        manager.largeWalkConfirmer = { _ in false }
        await manager.buildStorageLens(root: big)
        #expect(manager.storageLensReport == first,
                "a declined build replaced the reading that was on screen — a decline must change nothing")
        #expect(manager.storageLensRoot == small, "the declined root relabelled the previous report")
    }

    @MainActor
    @Test func confirmingRunsTheRealPass() async throws {
        let root = try fixture(files: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        manager.wholeTreeProbeBudget = 4
        manager.largeWalkConfirmer = { _ in true }
        await manager.buildStorageLens(root: root)
        let report = try #require(manager.storageLensReport)
        #expect(report.totalBytes == 12 * 8,
                "the confirmed pass reported \(report.totalBytes) bytes for 12 files of 8 — it published the PROBE's truncated tree rather than re-walking")
    }

    /// No prompt at all when the tree fits, as every ordinary source does. A guard that asked
    /// routinely would be worse than the hang it prevents.
    @MainActor
    @Test func aTreeUnderTheBudgetNeverAsks() async throws {
        let root = try fixture(files: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        var asked = 0
        manager.largeWalkConfirmer = { _ in asked += 1; return true }
        await manager.buildStorageLens(root: root)
        #expect(asked == 0, "the guard asked about a tree well under its budget")
        #expect(manager.storageLensReport != nil)
    }

    /// The boundary, at the call site: a tree that exactly spends the probe budget is complete, so
    /// the pass runs without asking. Swapping the lens's `didStopADescent` for `isExhausted` must
    /// fail this; the helper's own test below proves only that the helper draws the distinction.
    /// The budget is 3, not 6, for three directories of one file each: the root's own listing is
    /// never charged (see `aTreeExactlyAtTheBudgetIsNotTruncated`).
    @MainActor
    @Test func aTreeExactlyAtTheBudgetRunsWithoutAsking() async throws {
        let root = try fixture(files: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        manager.wholeTreeProbeBudget = 3
        var asked = 0
        manager.largeWalkConfirmer = { _ in asked += 1; return false }
        await manager.buildStorageLens(root: root)
        #expect(asked == 0,
                "the guard asked about a COMPLETE tree that merely spent its budget exactly — it is testing exhaustion rather than truncation")
        let report = try #require(manager.storageLensReport,
                                  "a complete tree at the budget was refused")
        #expect(report.totalBytes == 3 * 8)
    }

    // MARK: - The other call sites' declines
    //
    // The storage lens's decline proves only that the seam declines; each pass's own call site
    // proves that pass consults it. Each test's premise is the recorded preflight: a pass that
    // never asked either never probed or ran unbounded.

    /// Find Duplicates, declined, publishes no groups. The fixture holds a real identical pair, so
    /// an empty result is the decline working, not a tree with nothing to find.
    @MainActor
    @Test func decliningTheDuplicatesWalkPublishesNoGroups() async throws {
        let root = try fixture(files: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("A/report.pdf"), bytes: 64)
        try writeBytes(root.appendingPathComponent("B/report.pdf"), bytes: 64)

        let manager = FileSyncManager()
        manager.wholeTreeProbeBudget = 4
        var seen: LargeWalkPreflight?
        manager.largeWalkConfirmer = { seen = $0; return false }
        await manager.findDuplicates(root: root)

        let p = try #require(seen, "the duplicates pass never asked — its walk ran unbounded, or unprobed")
        #expect(p.pass == .duplicates)
        #expect(p.rootPath == root.path)
        #expect(manager.duplicateGroups.isEmpty,
                "a declined scan published groups — computed from the probe's truncated tree, so a duplicate group here is a duplicate MISSED elsewhere")
        #expect(!manager.hasFoundDuplicates,
                "a declined scan reported completion — an empty 'no duplicates' over a tree it refused to read")
    }

    /// Rename, declined, reports no risky names. The fixture plants a name the detector flags
    /// (`NameNormalizerTests` pins the zero-width space for iCloud), so an empty list is the
    /// decline, not a clean tree.
    @MainActor
    @Test func decliningTheRenameWalkReportsNoRiskyNames() async throws {
        let root = try fixture(files: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("photo\u{200B}.jpg"), bytes: 8)

        let manager = FileSyncManager()
        manager.wholeTreeProbeBudget = 4
        var seen: LargeWalkPreflight?
        manager.largeWalkConfirmer = { seen = $0; return false }
        await manager.scanNames(root: root, provider: .iCloud)

        let p = try #require(seen, "the rename pass never asked — its walk ran unbounded, or unprobed")
        #expect(p.pass == .rename)
        #expect(manager.riskyNames.isEmpty,
                "a declined scan reported risky names — found in the probe's partial tree, which reads as 'these are all of them'")
        #expect(!manager.nameScanLifecycle.hasCompleted,
                "a declined scan reported completion, which is indistinguishable from a clean tree")
    }

    /// Filing, declined, publishes nothing: no suggestions, and no risky names either, since
    /// `detectRiskyNames` runs on the taxonomy the gate protects.
    @MainActor
    @Test func decliningTheFilingWalkPublishesNothing() async throws {
        let root = try fixture(files: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("photo\u{200B}.jpg"), bytes: 8)

        let manager = FileSyncManager()
        manager.wholeTreeProbeBudget = 4
        var seen: LargeWalkPreflight?
        manager.largeWalkConfirmer = { seen = $0; return false }
        await manager.findFilingSuggestions(folder: root, providerRoot: root, nameProvider: .iCloud)

        let p = try #require(seen, "the filing pass never asked — its taxonomy walk ran unbounded, or unprobed")
        #expect(p.pass == .filing)
        #expect(p.rootPath == root.path)
        #expect(manager.filingSuggestions.isEmpty,
                "a declined scan published suggestions — routed against a taxonomy missing the folders the probe never reached")
        #expect(manager.riskyNames.isEmpty,
                "the decline let the risky-name detection run on the probe's truncated taxonomy")
        #expect(!manager.filingScanLifecycle.hasCompleted)
    }

    /// The folder-memory re-survey is the pass that writes. Declined, it opens no document and
    /// writes nothing: run on the probe's truncated tree, it would merge what it happened to read
    /// over the corpus. Reuses `FilingResurveyTests.makeTree`, which sets up the survey's
    /// preconditions; its recording extractor proves the pass read nothing, not just reported
    /// nothing.
    @MainActor
    @Test func decliningTheResurveyWalkWritesNothingAndReadsNothing() async throws {
        let (manager, docs, profiles, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: profiles.deletingLastPathComponent()) }
        manager.wholeTreeProbeBudget = 2
        var seen: LargeWalkPreflight?
        manager.largeWalkConfirmer = { seen = $0; return false }

        let report = await manager.resurveyFilingMemory(root: docs)

        let p = try #require(seen, "the re-survey never asked — the one Organize-reachable whole-tree walk is unbounded again")
        #expect(p.pass == .filing, "the prompt should name the feature the memory belongs to")
        #expect(p.rootPath == docs.path)
        #expect(report == .none, "a declined re-survey reported work: \(report.summary)")
        #expect(reads.paths.isEmpty,
                "the declined pass opened \(reads.paths.count) document(s) — the cost the guard exists to ask about first")
        #expect(!FileManager.default.fileExists(atPath: profiles.appendingPathComponent("t/filing-corpus.json").path),
                "a declined re-survey wrote a corpus")
        #expect(!FileManager.default.fileExists(atPath: profiles.appendingPathComponent("t/filing-memory.json").path),
                "a declined re-survey wrote a memory")
        #expect(manager.filingMemory == nil, "a declined re-survey published a memory")
    }

    // MARK: - What the prompt is told

    @MainActor
    @Test func thePreflightNamesThePassAndTheFolder() async throws {
        let root = try fixture(files: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager()
        manager.wholeTreeProbeBudget = 4
        var seen: LargeWalkPreflight?
        manager.largeWalkConfirmer = { seen = $0; return false }
        await manager.buildStorageLens(root: root)
        let p = try #require(seen)
        #expect(p.pass == .storageLens)
        #expect(p.probeLimit == 4)
        #expect(p.rootPath == root.path)
        #expect(p.rootName == root.lastPathComponent, "the prompt would print a whole path")
    }

    /// The prompt names a folder as the rest of the app does, through
    /// `FolderSource.defaultDisplayName`. The home folder and the startup disk are its likeliest
    /// subjects, being big enough to trip the probe, and their last path components would read as
    /// an account name and “/”.
    @Test func theHomeFolderIsNamedAsAPlaceNotAsAnAccount() {
        let p = LargeWalkPreflight(pass: .storageLens, rootPath: NSHomeDirectory(), probeLimit: 1)
        #expect(p.rootName == "Home folder")
    }

    /// The startup disk answers with the volume's name, read from the real disk, which proves the
    /// delegation happens. Compared against the lookup, not “Macintosh HD”, which would depend on
    /// the machine. `FolderSourceTests` covers the rule itself offline, including the fallback for
    /// a volume with no name.
    @Test func theStartupDiskTakesTheVolumesName() throws {
        let volume = try #require(FolderSource.volumeName(of: "/"),
                                  "the startup disk did not name itself — a mounted volume always does; if this is ever legitimate the rule falls back to “/” and there is nothing here to compare")
        let p = LargeWalkPreflight(pass: .storageLens, rootPath: "/", probeLimit: 1)
        #expect(p.rootName == volume, "the prompt says “/” where the sidebar says “\(volume)”")
    }

    /// Every whole-tree pass Organize and Storage can start is guarded, and names itself in the
    /// user's vocabulary. The count of `allCases` makes a pass added later be checked rather than
    /// silently left unbounded.
    @Test func eachPassNamesItselfInTheUsersVocabulary() {
        #expect(LargeWalkPreflight.Pass.storageLens.title == "Storage")
        #expect(LargeWalkPreflight.Pass.duplicates.title == "Find Duplicates")
        #expect(LargeWalkPreflight.Pass.rename.title == "Rename")
        #expect(LargeWalkPreflight.Pass.filing.title == "Filing")
        #expect(LargeWalkPreflight.Pass.allCases.count == 4,
                "a pass was added or removed — check that every whole-tree walk still asks before it runs")
    }

    /// Which passes read file contents is a property, not a special case, so a new pass that reads
    /// them (as Filing reads the first page of documents it can't place by name) can't silently get
    /// the cheaper sentence.
    @Test func thePassesThatReadContentsSayTheyDo() {
        #expect(LargeWalkPreflight.Pass.duplicates.readsFileContents)
        #expect(LargeWalkPreflight.Pass.filing.readsFileContents)
        #expect(!LargeWalkPreflight.Pass.storageLens.readsFileContents)
        #expect(!LargeWalkPreflight.Pass.rename.readsFileContents)
    }

    // MARK: - The probe's own question

    /// `didStopADescent` is not `isExhausted`, and they differ at the boundary, where anyone tuning
    /// the number lands. A tree holding exactly the budget spends it to zero yet is complete: there
    /// was no next directory to refuse. The budget is 3, not 6, for 3 directories of 1 file each:
    /// charging is per listing, and the root's own listing happens before the walk, so it is never
    /// charged. So a root's direct children are not bounded by the budget at all; that is one
    /// directory listing, not worth bounding.
    @Test func aTreeExactlyAtTheBudgetIsNotTruncated() async throws {
        let root = try fixture(files: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = FileSyncManager.NodeBudget(3)
        _ = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: nil, budget: budget)
        #expect(budget.isExhausted, "the fixture did not spend the budget — this measures nothing")
        #expect(!budget.didStopADescent,
                "a complete tree that exactly spent its budget reported itself truncated")
    }
}
