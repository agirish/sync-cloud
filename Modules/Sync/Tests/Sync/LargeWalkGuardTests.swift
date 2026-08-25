import Foundation
import Testing
@testable import Sync

/// **The size guard on the passes that cannot be budgeted.**
///
/// Storage and Find Duplicates walk whole trees by necessity — a storage total or a duplicate group
/// computed from part of a tree is a wrong ANSWER, not a partial view — so the budget that fixed the
/// pane is the wrong instrument here. What they can do is run a budgeted walk as a PROBE and stop to
/// ask, which is what these pin.
///
/// The probe budget is an instance property precisely so these can run: driving the confirm and
/// decline paths against a real 400,000-entry tree would mean building one.
@Suite struct LargeWalkGuardTests {

    private func write(_ url: URL, bytes: Int = 8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func fixture(files: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("largewalk-\(UUID().uuidString)")
        for i in 0..<files {
            try write(root.appendingPathComponent("d\(i)/f\(i).txt"))
        }
        return root
    }

    // MARK: - The seam's default

    /// **Refuse, unwired.** The failure this guards is a pass that never finishes, and an unwired
    /// manager that proceeded would reintroduce exactly that in the configuration where nobody is
    /// watching. Same fail-safe principle as `permanentDeleteConfirmer`, for a weaker harm.
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

    /// **No prompt at all when the tree fits**, which is every ordinary source. If this fired
    /// routinely the guard would be worse than the hang it prevents.
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

    /// **The boundary, at the call site.** A tree that exactly spends the probe budget is complete,
    /// so the pass must run without asking.
    ///
    /// This exists because the unit-level version below did not catch the mutation it was written
    /// for: swapping the lens's `didStopADescent` for `isExhausted` left all nine other tests green,
    /// since none of them put a tree *at* the budget through the lens. Testing a distinction on the
    /// helper proves the helper draws it; only the call site proves anyone uses it.
    ///
    /// 3, not 6, for three directories of one file each — the root's own listing is never charged.
    /// See `aTreeExactlyAtTheBudgetIsNotTruncated`.
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

    /// **The prompt names a folder the way the rest of the app names it**, through
    /// `FolderSource.defaultDisplayName` rather than a second rule of its own.
    ///
    /// The two roots this guard exists for are the two that rule was written for. Its own
    /// last-component answer called the home folder “abhishek” — a person, in a sentence about a
    /// folder — and the startup disk “/”, which is a path separator, not a name. Both are the
    /// prompt's most likely subjects: they are the trees big enough to trip the probe.
    @Test func theHomeFolderIsNamedAsAPlaceNotAsAnAccount() {
        let p = LargeWalkPreflight(pass: .storageLens, rootPath: NSHomeDirectory(), probeLimit: 1)
        #expect(p.rootName == "Home folder")
    }

    /// The startup disk answers with the volume's name, read from the real disk — this is the one
    /// assertion here that the delegation actually happened rather than being reasoned about.
    ///
    /// Compared against the lookup rather than against “Macintosh HD”, which would be a test of
    /// whoever is running it. `FolderSourceTests` covers the rule itself, injected and offline,
    /// including the fallback for a volume that declines to name itself.
    @Test func theStartupDiskTakesTheVolumesName() throws {
        let volume = try #require(FolderSource.volumeName(of: "/"),
                                  "the startup disk did not name itself — a mounted volume always does; if this is ever legitimate the rule falls back to “/” and there is nothing here to compare")
        let p = LargeWalkPreflight(pass: .storageLens, rootPath: "/", probeLimit: 1)
        #expect(p.rootName == volume, "the prompt says “/” where the sidebar says “\(volume)”")
    }

    /// An ordinary folder still answers with its own last component — the rule change must not have
    /// reached the common case.
    @Test func anOrdinaryFolderKeepsItsOwnName() {
        let p = LargeWalkPreflight(pass: .duplicates, rootPath: "/Volumes/Backup/Photos",
                                   probeLimit: 1)
        #expect(p.rootName == "Photos")
    }

    @Test func eachPassNamesItselfInTheUsersVocabulary() {
        #expect(LargeWalkPreflight.Pass.storageLens.title == "Storage")
        #expect(LargeWalkPreflight.Pass.duplicates.title == "Find Duplicates")
        #expect(LargeWalkPreflight.Pass.rename.title == "Rename")
        #expect(LargeWalkPreflight.Pass.filing.title == "Filing")
    }

    /// **Every whole-tree pass Organize and Storage can start is guarded.**
    ///
    /// The first version of this guard covered two of four. Storage and Find Duplicates were
    /// named and fixed; Rename and Filing walk whole trees from the same workspace, are reached by
    /// the same sidebar click, and were left unbounded — so "the guard is done" was true of the
    /// two I had thought about and false of the feature.
    ///
    /// Asserted as a count against `allCases` rather than by listing, so a fifth pass added later
    /// has to be considered rather than inheriting silence.
    @Test func everyPassThatWalksAWholeTreeHasACase() {
        #expect(LargeWalkPreflight.Pass.allCases.count == 4,
                "a pass was added or removed — check that every whole-tree walk still asks before it runs")
        for pass in LargeWalkPreflight.Pass.allCases {
            #expect(!pass.title.isEmpty, "\(pass) has no name for the prompt")
        }
    }

    /// **Which passes read file contents is a property, not a special case.** The prompt tested
    /// `pass == .duplicates`, so Filing — which reads the first page of documents it cannot place
    /// by name — silently got the cheaper sentence the moment it was added.
    @Test func thePassesThatReadContentsSayTheyDo() {
        #expect(LargeWalkPreflight.Pass.duplicates.readsFileContents)
        #expect(LargeWalkPreflight.Pass.filing.readsFileContents)
        #expect(!LargeWalkPreflight.Pass.storageLens.readsFileContents)
        #expect(!LargeWalkPreflight.Pass.rename.readsFileContents)
    }

    // MARK: - The probe's own question

    /// **`didStopADescent` is not `isExhausted`**, and the difference is the boundary case — which
    /// is exactly where anyone tuning the number will land. A tree holding precisely the budget
    /// spends it to zero and is nonetheless complete: there was no next directory for the
    /// exhaustion to refuse.
    ///
    /// The budget is **3, not 6**, for a fixture of 3 directories holding 1 file each — and the
    /// premise guard below is what taught me that. Charging is per *listing*, and the root's own
    /// listing happens in `buildTree` before the walk begins, so it is never charged: only the
    /// three subdirectories are, one entry each. Worth knowing beyond this test, because it means
    /// a root with an enormous number of DIRECT children is not bounded by this at all. That is one
    /// directory enumeration, so it is not a hole worth plugging — but it is not what the constant's
    /// name suggests either.
    @Test func aTreeExactlyAtTheBudgetIsNotTruncated() async throws {
        let root = try fixture(files: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = FileSyncManager.NodeBudget(3)
        _ = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: nil, budget: budget)
        #expect(budget.isExhausted, "the fixture did not spend the budget — this measures nothing")
        #expect(!budget.didStopADescent,
                "a complete tree that exactly spent its budget reported itself truncated")
    }

    @Test func aTreeOverTheBudgetIsTruncated() async throws {
        let root = try fixture(files: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = FileSyncManager.NodeBudget(4)
        _ = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: nil, budget: budget)
        #expect(budget.didStopADescent)
    }
}
