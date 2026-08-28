import Testing
import Foundation
@testable import Sync

/// The manifest's laws, and the scaffold that first exercises them (ROADMAP_V5 §5.4, §5.2).
@Suite struct RestructureManifestTests {

    private static func backlogFinding(scaffold: [String]) -> StructureFinding {
        StructureFinding(kind: .backlog, family: "Health/Dental",
                         subject: "Health/Dental/2025",
                         detail: .backlog(scaffold: scaffold, looseFiles: 2))
    }

    @Test func theScaffoldManifestIsCreateDirsAndNothingElse() throws {
        let manifest = try #require(RestructureScaffold.manifest(
            for: Self.backlogFinding(scaffold: ["Claims", "Statements"]),
            profileId: "p", manifestId: "m1", createdAt: "2026-08-28T00:00:00"))
        #expect(manifest.schemaVersion == RestructureManifest.currentSchema)
        #expect(manifest.kind == .backlog)
        #expect(manifest.actions.map(\.action) == [.createDir, .createDir])
        #expect(manifest.actions.map(\.dst) == ["Health/Dental/2025/Claims",
                                                "Health/Dental/2025/Statements"])
        #expect(manifest.actions.allSatisfy { $0.src == nil })
        #expect(manifest.actions.allSatisfy { $0.evidence?.isEmpty == false },
                "every operation carries its written justification — the 6 Aug log's rule")
    }

    @Test func anEmptyScaffoldAndAWrongKindBuildNothing() {
        #expect(RestructureScaffold.manifest(for: Self.backlogFinding(scaffold: []),
                                             profileId: "p", manifestId: "m",
                                             createdAt: "t") == nil)
        #expect(RestructureScaffold.manifest(
            for: StructureFinding(family: "F", schemes: []),
            profileId: "p", manifestId: "m", createdAt: "t") == nil)
    }

    /// §5.4's inverse rules, as laws: reversed order, swapped ends, `create-dir` ↔
    /// `remove-empty-dir` — and the inverse of the inverse is the original, exactly.
    @Test func theInverseIsMechanicalAndInvolutive() {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m1", createdAt: "t", family: "F", kind: .shape,
            actions: [
                .init(action: .createDir, dst: "F/New"),
                .init(action: .renameDir, src: "F/Old", dst: "F/Newer", filesCarried: 12),
                .init(action: .moveFile, src: "F/a.pdf", dst: "F/Newer/a.pdf"),
                .init(action: .keep, src: "F/Kept"),
            ])
        let inverse = manifest.inverse
        #expect(inverse.actions.map(\.action) == [.keep, .moveFile, .renameDir, .removeEmptyDir])
        #expect(inverse.actions[1].src == "F/Newer/a.pdf")
        #expect(inverse.actions[1].dst == "F/a.pdf")
        #expect(inverse.actions[2].src == "F/Newer")
        #expect(inverse.actions[2].dst == "F/Old")
        #expect(inverse.actions[3].src == "F/New")
        #expect(inverse.manifestId == "m1-inverse")
        #expect(inverse.inverse == manifest)
    }

    @Test func theManifestRoundTripsThroughItsCodable() throws {
        let manifest = try #require(RestructureScaffold.manifest(
            for: Self.backlogFinding(scaffold: ["Claims"]),
            profileId: "p", manifestId: "m1", createdAt: "2026-08-28T00:00:00"))
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(RestructureManifest.self, from: data)
        #expect(decoded == manifest)
        // The wire format is the log's vocabulary, not the enum's case names.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("create-dir"))
    }
}

/// One scaffold landing against a real temporary tree — the first proof of the guards, the
/// ledger and the re-probe on disk rather than in a model.
@MainActor
@Suite struct RestructureScaffoldApplyTests {

    private func makeWorld() throws -> (manager: FileSyncManager, root: URL, profilesDir: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scaffold-\(UUID().uuidString)")
        let root = base.appendingPathComponent("tree")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/Dental/2025"),
            withIntermediateDirectories: true)
        let profiles = base.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager()
        manager.filingFolderProfile = FolderProfile(
            profileId: "t", root: root.path,
            folders: ["Health/Dental/2025": FolderProfileEntry(
                path: "Health/Dental/2025", role: nil, naming: nil, anchors: [],
                acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0, axes: [:])],
            personTokens: [])
        manager.filingProfileDirectoryId = "t"
        manager.restructureStore = RestructureStore(directory: profiles, profileId: "t")
        return (manager, root, profiles)
    }

    private static func finding(scaffold: [String] = ["Claims", "Statements"]) -> StructureFinding {
        StructureFinding(kind: .backlog, family: "Health/Dental",
                         subject: "Health/Dental/2025",
                         detail: .backlog(scaffold: scaffold, looseFiles: 2))
    }

    @Test func aLandingCreatesTheScaffoldSkipsWhatExistsAndWritesTheLedger() async throws {
        let (manager, root, _) = try makeWorld()
        // One target appears on disk between plan and apply — the re-probe must skip it and
        // report it, and the rest of the landing still runs (invariants 2 and 5).
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/Dental/2025/Claims"),
            withIntermediateDirectories: false)

        let outcome = await manager.applyScaffold(for: Self.finding(),
                                                  now: Date(timeIntervalSince1970: 1_000_000))
        #expect(outcome.refusal == nil)
        #expect(outcome.created == ["Health/Dental/2025/Statements"])
        #expect(outcome.skipped == ["Health/Dental/2025/Claims"])
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Health/Dental/2025/Statements").path,
            isDirectory: &isDir) && isDir.boolValue)

        // The ledger: one record, finalised counts, and the inverse ON DISK — reread from the
        // file, not from memory, because §5.5's whole point is surviving a quit.
        let store = try #require(manager.restructureStore)
        let record = try #require(store.applied.first)
        #expect(record.created == 1)
        #expect(record.skipped == 1)
        #expect(record.inverse.actions.map(\.action) == [.removeEmptyDir, .removeEmptyDir])
        let reread = RestructureStore(directory: store.directory, profileId: "t")
        #expect(reread.applied == store.applied)
    }

    @Test func everyGuardRefusesWithASentenceAndTouchesNothing() async throws {
        let (manager, root, _) = try makeWorld()
        manager.isVerifyAllRunning = true
        let refused = await manager.applyScaffold(for: Self.finding())
        #expect(refused.refusal?.contains("Verify All") == true)
        manager.isVerifyAllRunning = false

        manager.filingScanLifecycle.isRunning = true
        let refusedForScan = await manager.applyScaffold(for: Self.finding())
        #expect(refusedForScan.refusal?.contains("filing scan") == true)
        manager.filingScanLifecycle.isRunning = false

        // Nothing landed and nothing was recorded while the guards were up.
        #expect(manager.restructureStore?.applied.isEmpty == true)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Health/Dental/2025/Claims").path))
    }

    @Test func anUnreadableLedgerRefusesTheLandingBeforeItTouchesDisk() async throws {
        let (manager, root, profiles) = try makeWorld()
        // The store must be reloaded over the broken file — the world's store read a clean one.
        try Data("{ not json".utf8).write(
            to: profiles.appendingPathComponent("t/restructure.json"))
        manager.restructureStore = RestructureStore(directory: profiles, profileId: "t")

        let outcome = await manager.applyScaffold(for: Self.finding())
        #expect(outcome.refusal?.contains("could not be read") == true)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Health/Dental/2025/Claims").path),
            "a landing that cannot be recorded must not land")
    }

    @Test func anAllDriftFamilyRefusesWithTheHonestSentence() async throws {
        let (manager, _, _) = try makeWorld()
        let outcome = await manager.applyScaffold(for: Self.finding(scaffold: []))
        #expect(outcome.refusal?.contains("nothing to scaffold") == true)
        #expect(manager.restructureStore?.applied.isEmpty == true)
    }

    @Test func oneGroupedUndoRemovesEverythingTheLandingCreated() async throws {
        let (manager, root, _) = try makeWorld()
        // Event-grouping ON, as the app's window undo manager has it: with it off, the redo
        // registration inside the undo closure fires "must begin a group before registering
        // undo" — the scaffold's explicit begin/end pair NESTS inside the event group, exactly
        // as BulkSync's does.
        let undo = UndoManager()
        manager.undoManager = undo
        // The temp volume may have no Trash, in which case the undo escalates to the
        // permanent-delete confirmation — which a headless test answers yes, or the folder
        // stays and this test measures the prompt instead of the undo.
        manager.permanentDeleteConfirmer = { _ in true }

        let outcome = await manager.applyScaffold(for: Self.finding())
        #expect(outcome.created.count == 2)
        #expect(undo.canUndo)

        undo.undo()
        // The redo registration happens inside the undo closures, so this is the discriminator:
        // false here means the closures never ran and the drain below would measure nothing.
        #expect(undo.canRedo, "the undo closures never ran")
        // The closures spawn Tasks that enqueue file operations; suspending this test task lets
        // the main actor run them. Bounded (≤ 2s) so a hang is a red test, not a stuck suite.
        for _ in 0..<400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            if manager.activeFileOperationsCount == 0,
               !FileManager.default.fileExists(
                   atPath: root.appendingPathComponent("Health/Dental/2025/Claims").path),
               !FileManager.default.fileExists(
                   atPath: root.appendingPathComponent("Health/Dental/2025/Statements").path) {
                break
            }
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Health/Dental/2025/Claims").path),
            "one ⌘Z must take back the whole landing")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Health/Dental/2025/Statements").path))
    }
}
