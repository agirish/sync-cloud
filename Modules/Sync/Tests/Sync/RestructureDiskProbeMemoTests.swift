import Foundation
import Testing
@testable import Sync

/// **The two Restructure probes a view body runs, and the cache in front of them.**
///
/// `scaffoldedSubjects` and `emptiedFoldersStillStanding` both ask the DISK, deliberately: a ⌘Z or
/// a hand-tidy removes folders without touching the ledger, so a manifest-only answer would leave
/// the Scaffolded card and the removal button claiming things that stopped being true. And both
/// are read from `body`, which re-runs on every publish the manager makes — the lens asked once,
/// the overview asked again, the ledger cards asked once per applied record.
///
/// So the answers are remembered, and these pin what the remembering is allowed to do: serve the
/// same tree, drop the moment the ledger changes, and never outlive its window.
@MainActor
@Suite final class RestructureDiskProbeMemoTests {

    private var scratch: [URL] = []
    deinit { for dir in scratch { try? FileManager.default.removeItem(at: dir) } }

    /// Every test starts from a cold cache — the memo is process-wide by construction (an
    /// extension cannot add a stored property to `FileSyncManager`), so leaving one test's entry
    /// standing would let the next one pass on the wrong evidence.
    init() {
        RestructureDiskProbeMemo.scaffolded.clear()
        RestructureDiskProbeMemo.standingEmpties.clear()
    }

    private func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-memo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("profiles"),
                                                withIntermediateDirectories: true)
        scratch.append(base)
        return base
    }

    /// A manager pointed at a real tree, with a real ledger store.
    private func makeManager(_ base: URL) throws -> FileSyncManager {
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profiles = base.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager()
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: root.path,
                                                    folders: [:], personTokens: [])
        manager.filingProfilesDirectory = profiles
        manager.filingProfileDirectoryId = "t"
        manager.restructureStore = RestructureStore(directory: profiles, profileId: "t")
        return manager
    }

    private func scaffoldRecord(_ subject: String, _ children: [String])
        -> RestructureStore.AppliedRecord {
        let manifest = RestructureManifest(
            profileId: "t", manifestId: "scaffold-\(subject)", createdAt: "t",
            family: (subject as NSString).deletingLastPathComponent, kind: .backlog,
            actions: children.map { .init(action: .createDir, dst: "\(subject)/\($0)") })
        return RestructureStore.AppliedRecord(manifest: manifest, inverse: manifest.inverse,
                                              at: "t", created: children.count, skipped: 0)
    }

    private func mergeManifest(id: String, drains: [String]) -> RestructureManifest {
        RestructureManifest(
            profileId: "t", manifestId: id, createdAt: "t", family: "F", kind: .shape,
            actions: drains.map {
                .init(action: .moveFile, src: "\($0)/f.pdf", dst: "F/Keeper/f.pdf")
            })
    }

    // MARK: scaffoldedSubjects

    /// **The disk decides, and it is asked again once the window is out.** A ⌘Z takes the
    /// scaffolded folders away without touching the ledger; the subject must drop back to
    /// offering the scaffold, which is the whole reason this probes rather than reads.
    @Test func aScaffoldedSubjectDropsOnceItsFoldersGoAndTheWindowPasses() throws {
        let base = try makeRoot()
        let manager = try makeManager(base)
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/Dental/2025/Claims"),
            withIntermediateDirectories: true)
        manager.restructureStore?.recordApplied(
            scaffoldRecord("Health/Dental/2025", ["Claims"]))

        let t0 = Date()
        #expect(manager.scaffoldedSubjects(now: t0) == ["Health/Dental/2025"])

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Health/Dental/2025/Claims"))
        // Inside the window the remembered answer is served — the deliberate trade.
        #expect(manager.scaffoldedSubjects(now: t0.addingTimeInterval(0.1))
                    == ["Health/Dental/2025"])
        // Past it, the disk is asked again and the claim is withdrawn.
        #expect(manager.scaffoldedSubjects(
            now: t0.addingTimeInterval(RestructureDiskProbeMemo.window + 0.01)).isEmpty,
                "past the window the probe must read the disk, not its own memory")
    }

    /// A new ledger record drops the entry AT ONCE — no window to wait out. Landing a scaffold
    /// and then rendering must not show the state from before it.
    @Test func aNewLedgerRecordInvalidatesImmediately() throws {
        let base = try makeRoot()
        let manager = try makeManager(base)
        let root = base.appendingPathComponent("Documents")
        let t0 = Date()
        #expect(manager.scaffoldedSubjects(now: t0).isEmpty)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Work/Benefits/2026/Claims"),
            withIntermediateDirectories: true)
        manager.restructureStore?.recordApplied(
            scaffoldRecord("Work/Benefits/2026", ["Claims"]))

        #expect(manager.scaffoldedSubjects(now: t0) == ["Work/Benefits/2026"],
                "the ledger changed, so the remembered answer is about a different question")
    }

    /// **Two managers never share an answer, and the key carries the object's identity to make
    /// sure of it.**
    ///
    /// The memo lives outside `FileSyncManager` — an extension cannot add a stored property — so
    /// it is process-wide, and a key of root-plus-ledger alone is not enough: the probe reads the
    /// manager's OWN `fileManager`, which is a seam every test in this repo uses. Two managers on
    /// the same root with the same ledger and different file managers genuinely have different
    /// answers, and this is the shape that proves the identity term is load-bearing rather than
    /// decorative.
    @Test func twoManagersDoNotShareOneAnswer() throws {
        let base = try makeRoot()
        let real = try makeManager(base)
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/Dental/2025/Claims"),
            withIntermediateDirectories: true)
        real.restructureStore?.recordApplied(scaffoldRecord("Health/Dental/2025", ["Claims"]))

        // Same root, same ledger, a file manager that can see nothing.
        let blind = FileSyncManager(fileManager: MockFileManager())
        blind.filingFolderProfile = real.filingFolderProfile
        blind.filingProfilesDirectory = real.filingProfilesDirectory
        blind.filingProfileDirectoryId = real.filingProfileDirectoryId
        blind.restructureStore = real.restructureStore

        let t0 = Date()
        #expect(real.scaffoldedSubjects(now: t0) == ["Health/Dental/2025"])
        #expect(blind.scaffoldedSubjects(now: t0).isEmpty,
                "a manager that cannot see the folders must not be served another's answer")
        // And the other way round, so this is not just about which one asked first.
        RestructureDiskProbeMemo.scaffolded.clear()
        #expect(blind.scaffoldedSubjects(now: t0).isEmpty)
        #expect(real.scaffoldedSubjects(now: t0) == ["Health/Dental/2025"])
    }

    /// A partially standing scaffold keeps the claim — re-offering would re-create the
    /// survivors' siblings around folders that still exist.
    @Test func aPartiallyStandingScaffoldKeepsItsClaim() throws {
        let base = try makeRoot()
        let manager = try makeManager(base)
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/Dental/2025/Claims"),
            withIntermediateDirectories: true)
        manager.restructureStore?.recordApplied(
            scaffoldRecord("Health/Dental/2025", ["Claims", "Statements"]))
        #expect(manager.scaffoldedSubjects() == ["Health/Dental/2025"])
    }

    // MARK: emptiedFoldersStillStanding

    /// **Many manifests under one key.** The ledger cards ask once per applied record inside a
    /// single render, so a one-slot cache would be evicted by the next record and never hit —
    /// and, worse, would answer about the wrong manifest if it were not keyed by id.
    @Test func eachManifestKeepsItsOwnAnswerWithinOneWindow() throws {
        let base = try makeRoot()
        let manager = try makeManager(base)
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("F/Standing"),
                                                withIntermediateDirectories: true)

        let standing = mergeManifest(id: "m-standing", drains: ["F/Standing"])
        let gone = mergeManifest(id: "m-gone", drains: ["F/Gone"])
        let t0 = Date()
        #expect(manager.emptiedFoldersStillStanding(of: standing, now: t0))
        #expect(!manager.emptiedFoldersStillStanding(of: gone, now: t0))

        // **The disk is changed under both, and neither may notice inside the window.** That is
        // what makes this an assertion about the CACHE rather than about the probe: a one-slot
        // box would have been evicted by `gone` above and would re-read the tree here, and a box
        // that dropped its map on every store would do the same — both show up as `false`.
        try FileManager.default.removeItem(at: root.appendingPathComponent("F/Standing"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("F/Gone"),
                                                withIntermediateDirectories: true)
        #expect(manager.emptiedFoldersStillStanding(of: standing, now: t0),
                "the second ask in one window must be served, not re-probed")
        #expect(!manager.emptiedFoldersStillStanding(of: gone, now: t0),
                "and each manifest must be served its OWN answer, not the other's")
    }

    /// The disk still decides, once the window is out.
    @Test func aRemovedEmptyFolderStopsStandingPastTheWindow() throws {
        let base = try makeRoot()
        let manager = try makeManager(base)
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("F/Drained"),
                                                withIntermediateDirectories: true)
        let manifest = mergeManifest(id: "m1", drains: ["F/Drained"])

        let t0 = Date()
        #expect(manager.emptiedFoldersStillStanding(of: manifest, now: t0))
        try FileManager.default.removeItem(at: root.appendingPathComponent("F/Drained"))
        #expect(manager.emptiedFoldersStillStanding(of: manifest, now: t0.addingTimeInterval(0.1)))
        #expect(!manager.emptiedFoldersStillStanding(
            of: manifest, now: t0.addingTimeInterval(RestructureDiskProbeMemo.window + 0.01)))
    }

    /// A clock that goes BACKWARDS invalidates rather than pinning an answer forever.
    @Test func aBackwardsClockInvalidatesRatherThanFreezing() throws {
        let base = try makeRoot()
        let manager = try makeManager(base)
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("F/Drained"),
                                                withIntermediateDirectories: true)
        let manifest = mergeManifest(id: "m1", drains: ["F/Drained"])
        let t0 = Date()
        #expect(manager.emptiedFoldersStillStanding(of: manifest, now: t0))
        try FileManager.default.removeItem(at: root.appendingPathComponent("F/Drained"))
        #expect(!manager.emptiedFoldersStillStanding(of: manifest,
                                                     now: t0.addingTimeInterval(-60)))
    }

    /// No profile means no root to probe against, and no claim either way.
    @Test func noProfileMeansNoClaim() throws {
        let base = try makeRoot()
        let manager = try makeManager(base)
        manager.filingFolderProfile = nil
        #expect(manager.scaffoldedSubjects().isEmpty)
        #expect(!manager.emptiedFoldersStillStanding(of: mergeManifest(id: "m1",
                                                                      drains: ["F/A"])))
    }
}
