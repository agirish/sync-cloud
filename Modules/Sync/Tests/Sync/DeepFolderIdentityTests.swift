import Foundation
import Testing
@testable import Sync

/// The deep half of the copy-undo drift guard.
///
/// The shallow `.directory` identity — own modification date plus immediate child count — catches
/// a child added, removed or replaced at depth 1 and NOTHING below that. Its own doc admitted it:
/// an edit "deep inside an untouched subtree … leaves both values identical", so the guard
/// answered `.unchanged` for a case it did not really check. Concretely: copy `Project/`
/// elsewhere, edit `Project copy/src/deep/notes.md`, press ⌘Z hours later — the copy is trashed
/// as `.unchanged`, taking the only instance of the edit with it, permanently (after a confirm)
/// on a Trash-less volume.
///
/// `deepSnapshot` closes it for the copy-undo: a `.directoryTree` identity digests every
/// descendant's (relative path, kind, size, mtime), so the deep edit changes the recorded
/// identity and the undo REFUSES. The tests below hold all four edges of that: the deep edit
/// refuses (by size, and by date alone), the untouched tree still undoes (a guard that refuses
/// everything is not a guard), an unreadable descendant is `.indeterminate` and refuses rather
/// than guesses, and the digest is a function of the tree rather than of the enumeration order.
///
/// Each end-to-end test plants a SHALLOW-blindness precondition — `ItemIdentity.snapshot` of the
/// copied root still answers `.unchanged` after the tampering — so the fixture provably exercises
/// the gap the shallow identity cannot see, not a shape the old guard already caught.
///
/// No `.serialized` and no log-window assertions: every assertion here reads this suite's own
/// manager's banner or its own mock disk, so there is nothing a parallel neighbour could satisfy.
@Suite struct DeepFolderIdentityTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    private func file(_ size: Int, modified: Date = Date(timeIntervalSince1970: 1_000)) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false,
                                 attributes: [FileAttributeKey.size: size,
                                              FileAttributeKey.modificationDate: modified],
                                 contents: nil)
    }

    /// `<srcRoot>/project/src/deep/notes.md` — three directory levels, so the edited file sits
    /// two levels below the copied root and cannot move the root's own date or child count.
    /// `contents` chains are populated because the mock's `copyItem` deep-copies by them.
    private func plantDeepSource(on fm: MockFileManager, under srcRoot: String) throws {
        try fm.createDirectory(at: URL(fileURLWithPath: srcRoot), withIntermediateDirectories: true)
        fm.virtualDisk["\(srcRoot)/project"] =
            MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["src"])
        fm.virtualDisk["\(srcRoot)/project/src"] =
            MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["deep"])
        fm.virtualDisk["\(srcRoot)/project/src/deep"] =
            MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["notes.md"])
        fm.virtualDisk["\(srcRoot)/project/src/deep/notes.md"] = file(4)
    }

    /// Copies the planted tree to `dstRoot` through the real operation (which registers the undo
    /// under test) and proves the whole tree arrived.
    @MainActor
    private func copyDeepTree(manager: FileSyncManager, fm: MockFileManager,
                              from srcRoot: String, to dstRoot: String) async throws {
        try fm.createDirectory(at: URL(fileURLWithPath: dstRoot), withIntermediateDirectories: true)
        let node = FileNode(id: "\(srcRoot)/project", name: "project", isDirectory: true)
        _ = await manager.copyItems(nodes: [node], toPath: dstRoot, fileManager: fm)
        try #require(fm.virtualDisk["\(dstRoot)/project/src/deep/notes.md"] != nil,
                     "the fixture's deep tree must have been copied in full")
    }

    /// The SHALLOW identity of the copied root, taken before the tampering — what the old guard
    /// would have recorded at registration. Each refusal test re-asks it AFTER the tampering and
    /// requires `.unchanged`: that is what makes the test a test of the deep guard rather than a
    /// second copy of the depth-1 tests that already pass.
    private func shallowIdentity(_ fm: MockFileManager, root: String) throws -> ItemIdentity {
        let shallow = ItemIdentity.snapshot(at: URL(fileURLWithPath: root), fileManager: fm)
        guard case .directory = shallow else {
            throw NSError(domain: "DeepFolderIdentityTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected a shallow directory identity for \(root), got \(shallow)"])
        }
        return shallow
    }

    // MARK: 1 — THE bug: an edit two levels down refuses the undo

    /// Copy a folder, edit a file two levels deep so its SIZE changes, ⌘Z: the shallow identity
    /// (top-level date and child count both untouched) answered `.unchanged` and the copy was
    /// trashed — with the only instance of the edit inside it.
    @MainActor
    @Test func copyUndoRefusesADeepEditThatChangedAFilesSize() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/deepid-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/deepid-src", to: "/deepid-dst")

        // The user edits the deep file inside the COPY; the edit grows it. Nothing at the copied
        // root moves: same immediate children, same (nil) directory date.
        let shallowAtRegistration = try shallowIdentity(fm, root: "/deepid-dst/project")
        fm.virtualDisk["/deepid-dst/project/src/deep/notes.md"] =
            file(999, modified: Date(timeIntervalSince1970: 9_999))
        try #require(shallowAtRegistration.drift(at: URL(fileURLWithPath: "/deepid-dst/project"),
                                                 fileManager: fm) == .unchanged,
                     "fixture check: this edit must be exactly the one the shallow identity cannot see")
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.severity == .warning,
                "the undo must refuse, not proceed; banner: \(String(describing: manager.banner?.message))")
        #expect(manager.banner?.message.contains("changed since") == true,
                "got \(String(describing: manager.banner?.message))")
        #expect(fm.virtualDisk["/deepid-dst/project"] != nil,
                "the copy must still be on disk — trashing it takes the only instance of the edit")
        #expect(fm.virtualDisk["/deepid-dst/project/src/deep/notes.md"]?.attributes?[FileAttributeKey.size] as? Int == 999,
                "the edited deep file must be left exactly as the user wrote it")
        #expect(fm.virtualDisk["/deepid-src/project"] != nil, "the source is untouched by an undo")
    }

    /// The harder half of the same edit: SAME size, only the modification date moved — a
    /// same-length rewrite two levels down. Size-blind AND count-blind; only the per-file date in
    /// the deep digest can see it.
    @MainActor
    @Test func copyUndoRefusesADeepEditThatChangedOnlyAFilesDate() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/deepdate-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/deepdate-src", to: "/deepdate-dst")

        // Same 4 bytes, later timestamp — the deep twin of `copyUndoRefusesASameSizeEditOfTheCopy`.
        let shallowAtRegistration = try shallowIdentity(fm, root: "/deepdate-dst/project")
        fm.virtualDisk["/deepdate-dst/project/src/deep/notes.md"] =
            file(4, modified: Date(timeIntervalSince1970: 9_999))
        try #require(shallowAtRegistration.drift(at: URL(fileURLWithPath: "/deepdate-dst/project"),
                                                 fileManager: fm) == .unchanged,
                     "fixture check: this edit must be exactly the one the shallow identity cannot see")
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.severity == .warning,
                "the undo must refuse, not proceed; banner: \(String(describing: manager.banner?.message))")
        #expect(manager.banner?.message.contains("changed since") == true,
                "got \(String(describing: manager.banner?.message))")
        #expect(fm.virtualDisk["/deepdate-dst/project"] != nil,
                "the copy must still be on disk")
        #expect(fm.virtualDisk["/deepdate-dst/project/src/deep/notes.md"]?.attributes?[FileAttributeKey.modificationDate] as? Date
                == Date(timeIntervalSince1970: 9_999),
                "the rewritten deep file must be left exactly as the user wrote it")
    }

    // MARK: 2 — no false refusals

    /// The other direction, or the fix is an outage: an untouched deep tree must still undo. The
    /// digest is computed twice — registration and verification — over a walk APFS orders
    /// however it likes, so this is also the end-to-end proof the two computations agree.
    @MainActor
    @Test func copyUndoOfAnUntouchedDeepTreeStillRemovesIt() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/deepok-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/deepok-src", to: "/deepok-dst")
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the untouched deep copy is removed") { fm.virtualDisk["/deepok-dst/project"] == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(fm.virtualDisk["/deepok-dst/project"] == nil)
        #expect(fm.virtualDisk["/deepok-dst/project/src/deep/notes.md"] == nil)
        #expect(fm.virtualDisk["/deepok-src/project/src/deep/notes.md"] != nil,
                "the source is untouched by an undo")
        #expect(manager.banner?.severity != .warning,
                "an untouched tree raises no refusal; got \(String(describing: manager.banner?.message))")
    }

    // MARK: 3 — a tree that cannot be re-walked refuses, it does not guess

    /// A DEEP subdirectory of the copy becomes unlistable between the copy and the ⌘Z. The
    /// recursive re-walk comes back partial (`.listedWithUnreadableDescendants`), partial proves
    /// nothing about the withheld part, and the verdict is `.indeterminate` — which REFUSES. The
    /// shallow identity never opened that subdirectory, so before the deep guard this shape was
    /// waved straight through to the trash.
    @MainActor
    @Test func copyUndoRefusesWhenADeepDescendantCannotBeReRead() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/deeplock-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/deeplock-src", to: "/deeplock-dst")

        let shallowAtRegistration = try shallowIdentity(fm, root: "/deeplock-dst/project")
        fm.unlistableDirectories = ["/deeplock-dst/project/src/deep"]
        try #require(shallowAtRegistration.drift(at: URL(fileURLWithPath: "/deeplock-dst/project"),
                                                 fileManager: fm) == .unchanged,
                     "fixture check: the shallow identity never opens the locked subdirectory")
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.severity == .warning,
                "the undo must refuse, not proceed; banner: \(String(describing: manager.banner?.message))")
        #expect(manager.banner?.message.contains("couldn't be checked") == true,
                "an unverifiable tree reports as unverifiable, not as changed; got \(String(describing: manager.banner?.message))")
        #expect(fm.virtualDisk["/deeplock-dst/project"] != nil,
                "a tree that cannot be checked is not destroyed")
        #expect(fm.virtualDisk["/deeplock-dst/project/src/deep/notes.md"] != nil)
    }

    // MARK: 4 — the digest is a function of the tree, not of the walk

    /// Two trees with identical contents built in OPPOSITE creation orders — and one of them
    /// snapshotted twice — produce one identity. APFS guarantees no enumeration order, so the
    /// digest's sort (UTF-8 byte order of the precomposed relative path) is what this pins: if it
    /// ever came to depend on the order entries are yielded or created, registration and
    /// verification would disagree about an untouched tree and every folder-copy undo would
    /// falsely refuse. Real filesystem, because the mock sorts its own enumeration and could pass
    /// this vacuously.
    @Test func deepIdentityIsStableAcrossCreationOrderAndRepeatedWalks() throws {
        let base = try makeCanonicalTempRoot(prefix: "DeepIdentityStable")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let stamp = Date(timeIntervalSince1970: 1_000)

        // Same shape, built leaf-first in one root and root-first (with reversed sibling order)
        // in the other.
        let a = base.appendingPathComponent("a")
        let b = base.appendingPathComponent("b")
        for (root, order) in [(a, ["one.txt", "two.txt"]), (b, ["two.txt", "one.txt"])] {
            try fm.createDirectory(at: root.appendingPathComponent("sub/deep"),
                                   withIntermediateDirectories: true)
            for name in order {
                try Data("same-bytes".utf8).write(to: root.appendingPathComponent("sub/deep/\(name)"))
            }
            for rel in ["sub/deep/one.txt", "sub/deep/two.txt"] {
                try fm.setAttributes([.modificationDate: stamp],
                                     ofItemAtPath: root.appendingPathComponent(rel).path)
            }
        }

        let first = ItemIdentity.deepSnapshot(at: a, fileManager: fm)
        let again = ItemIdentity.deepSnapshot(at: a, fileManager: fm)
        let other = ItemIdentity.deepSnapshot(at: b, fileManager: fm)

        guard case .directoryTree = first else {
            Issue.record("expected a deep directory identity, got \(first)")
            return
        }
        #expect(first == again, "one tree walked twice must produce one identity")
        #expect(first == other, "identical contents built in a different order must produce the same identity")
    }

    // MARK: The seam itself, on a real tree

    /// The direct counterpart of `ItemIdentityTests.aChangeDeepInsideASubtreeIsNotNoticed`, which
    /// pins the shallow identity's documented limit: the very edit the shallow snapshot answers
    /// `.unchanged` for, the deep one answers `.changed` for — on the same fixture, both halves
    /// asserted side by side so neither can drift into vacuity.
    @Test func aDeepEditIsNoticedByTheDeepIdentityWhereTheShallowOneIsBlind() throws {
        let base = try makeCanonicalTempRoot(prefix: "DeepIdentityEdit")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        let deep = folder.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: deep.appendingPathComponent("leaf.txt"))

        let shallow = ItemIdentity.snapshot(at: folder, fileManager: FileManager.default)
        let recorded = ItemIdentity.deepSnapshot(at: folder, fileManager: FileManager.default)
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .unchanged,
                "an untouched tree must not read as drift")

        try Data("after-and-longer".utf8).write(to: deep.appendingPathComponent("leaf.txt"))

        #expect(shallow.drift(at: folder, fileManager: FileManager.default) == .unchanged,
                "fixture check: this edit must be exactly the one the shallow identity cannot see")
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .changed,
                "the deep identity exists to notice exactly this")
    }
}
