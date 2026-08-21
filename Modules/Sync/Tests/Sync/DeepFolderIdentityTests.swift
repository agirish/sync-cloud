import Events
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
/// identity and the undo REFUSES. The tests below hold the edges of that: the deep edit refuses
/// (by size, and by date alone), the untouched tree still undoes (a guard that refuses
/// everything is not a guard), an unreadable descendant is `.indeterminate` and refuses rather
/// than guesses, and the digest is a function of the tree — not of the enumeration order, not
/// of the Unicode form the walk spells names in, and not of the `.DS_Store`s Finder scribbles
/// into every folder it opens. The registration walk's own contract — off the main thread, undo
/// armed before it resolves — is held at the bottom.
///
/// Each end-to-end test plants a SHALLOW-blindness precondition — `ItemIdentity.snapshot` of the
/// copied root still answers `.unchanged` after the tampering — so the fixture provably exercises
/// the gap the shallow identity cannot see, not a shape the old guard already caught.
///
/// No `.serialized`: every assertion here reads this suite's own manager's banner or its own mock
/// disk — except the one registration-warning test, whose `Logger.shared` match is keyed on a
/// per-run UUID path — so there is nothing a parallel neighbour could satisfy.
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
    /// snapshotted twice — produce one identity. APFS guarantees no enumeration order, so if the
    /// digest ever came to depend on the order entries are yielded or created, registration and
    /// verification would disagree about an untouched tree and every folder-copy undo would
    /// falsely refuse.
    ///
    /// What this does NOT pin, proven by mutation (2026-08-21): the digest's sort line. The real
    /// enumerator happens to yield a stable order whatever the creation order, so this passed
    /// with `lines.sort` deleted — the very hazard its comment warned about for the mock's sorted
    /// enumeration was true of the real one too. It stays as the end-to-end proof that two real
    /// walks of one tree agree; the sort itself is pinned by
    /// `theDigestDoesNotDependOnTheOrderTheWalkYieldsEntriesIn`, whose enumerator can actually
    /// vary the order.
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

    // MARK: 5 — the canonical serialization, pinned through a walk that can actually vary

    /// One tree, walked forwards and walked BACKWARDS, produces one identity. This is the test
    /// the sort line answers to: `deepSnapshot`'s digest sorts its lines precisely because APFS
    /// promises no enumeration order, but no real walk will demonstrate the hazard on demand —
    /// the real enumerator yields a stable order, and so does the mock. `ReshapedWalkFileManager`
    /// hands the REAL tree's entries back reversed, which is an order APFS is entitled to produce
    /// tomorrow.
    ///
    /// Mutation-checked (2026-08-21): with `lines.sort` deleted from `deepSnapshot`, this fails
    /// (`forward != backward`) while the creation-order test above still passes. Restore the sort
    /// and it is green again — this test, not that one, is the sort's pin.
    @Test func theDigestDoesNotDependOnTheOrderTheWalkYieldsEntriesIn() throws {
        let base = try makeCanonicalTempRoot(prefix: "DeepIdentityWalkOrder")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/deep"),
                                                withIntermediateDirectories: true)
        for rel in ["alpha.txt", "sub/beta.txt", "sub/deep/gamma.txt", "sub/deep/delta.txt"] {
            try Data("payload".utf8).write(to: root.appendingPathComponent(rel))
        }

        let forward = ItemIdentity.deepSnapshot(at: root, fileManager: ReshapedWalkFileManager())
        let backward = ItemIdentity.deepSnapshot(
            at: root, fileManager: ReshapedWalkFileManager(reorder: { $0.reversed() }))

        // `.indeterminate == .indeterminate` would pass the equality below vacuously, so the
        // shape is required first: a fake that broke the walk must fail loudly, not agree quietly.
        guard case .directoryTree = forward else {
            Issue.record("expected a deep directory identity, got \(forward)")
            return
        }
        #expect(forward == backward,
                "one tree must serialize identically whatever order the enumerator yields it in — registration and verification are two walks, and a disagreement here falsely refuses every folder-copy undo")
    }

    // MARK: 6 — the Unicode form a name reaches the digest in is not part of the identity

    /// The rule at its seam: one relative path handed over decomposed (NFD, "é" as U+0065 U+0301)
    /// and handed over precomposed (NFC) must digest under ONE spelling, byte for byte — the
    /// digest hashes UTF-8 bytes, and APFS/HFS+ lookups are normalization-insensitive, so one
    /// on-disk name hashing two ways would make registration and verification disagree about an
    /// untouched tree.
    ///
    /// At the SEAM (`ItemIdentity.canonicalDigestSpelling`), because no end-to-end fixture can
    /// reach the rule: `listing(of:)` re-spells every entry through `appendingPathComponent`,
    /// which converts through the file-system representation and hands `deepSnapshot` the
    /// decomposed form whatever is on disk — measured, and exactly why deleting the
    /// precomposition passed every pre-existing test (this suite's end-to-end twin below
    /// included). That pipeline normalization is incidental and undocumented; this test is what
    /// notices the day it stops holding the digest up.
    ///
    /// Compared as UTF-8 byte arrays throughout: Swift `String ==` is itself
    /// canonical-equivalence-based, so a String comparison here would pass with the rule deleted
    /// — the vacuity this test exists to end. Mutation-checked (2026-08-21): with
    /// `canonicalDigestSpelling` returning its input unchanged, this fails; restored, green.
    @Test func oneNameReportedInEitherUnicodeFormDigestsAsOneSpelling() throws {
        let nfd = "sub/deep/re\u{0065}\u{0301}sume\u{0301}.txt"   // "résumé.txt", é decomposed
        let nfc = nfd.precomposedStringWithCanonicalMapping
        try #require(Array(nfd.utf8) != Array(nfc.utf8),
                     "fixture check: the two spellings must be byte-distinct — String == cannot tell them apart")

        #expect(Array(ItemIdentity.canonicalDigestSpelling(ofRelativePath: nfd).utf8)
                == Array(ItemIdentity.canonicalDigestSpelling(ofRelativePath: nfc).utf8),
                "one name reported in either Unicode form must digest as one spelling — two spellings would falsely refuse the undo of an untouched folder walked once per form")
    }

    /// The user-level half: a decomposed non-ASCII filename deep in a REAL tree answers
    /// `.unchanged` on re-walk, and is one identity with a twin tree whose same name was stored
    /// PRECOMPOSED — written with raw NFC bytes through POSIX `open`, bypassing Foundation's
    /// path decomposition, which is the shape an SMB or non-Foundation writer leaves on APFS
    /// (normalization-preserving storage, normalization-insensitive lookup). macOS file APIs may
    /// hand back either form; that variability is exactly what this pins against.
    ///
    /// Known limit, stated: today `listing(of:)` happens to canonicalize both trees' spellings
    /// before the digest sees them, so this passes even with the precomposition deleted — the
    /// seam test above is the one that fails then. This one holds the invariant end-to-end
    /// against whichever layer does the canonicalizing.
    @Test func aDecomposedDeepFilenameIsOneIdentityWithItsPrecomposedTwin() throws {
        let nfdName = "re\u{0065}\u{0301}sume\u{0301}.txt"
        let nfcName = nfdName.precomposedStringWithCanonicalMapping
        try #require(Array(nfdName.utf8) != Array(nfcName.utf8),
                     "fixture check: the two spellings must be byte-distinct")

        let base = try makeCanonicalTempRoot(prefix: "DeepIdentityNFD")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let stamp = Date(timeIntervalSince1970: 1_000)

        let a = base.appendingPathComponent("a")   // name written through Foundation (decomposes)
        let b = base.appendingPathComponent("b")   // name written as raw NFC bytes through POSIX
        for root in [a, b] {
            try fm.createDirectory(at: root.appendingPathComponent("sub/deep"),
                                   withIntermediateDirectories: true)
        }
        try Data("payload".utf8).write(to: a.appendingPathComponent("sub/deep/\(nfdName)"))
        let rawNFCPath = Array((b.appendingPathComponent("sub/deep").path + "/").utf8) + Array(nfcName.utf8) + [0]
        let fd = rawNFCPath.withUnsafeBufferPointer {
            open(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self),
                 O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        }
        try #require(fd >= 0, "fixture check: the POSIX create of the NFC-spelled twin must succeed")
        _ = Array("payload".utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        // Same mtime on both leaves, or the digests differ for the honest reason and the test
        // measures the clock instead of the spelling. The lookup is normalization-insensitive,
        // so the NFD-spelled path reaches the NFC-stored file.
        for root in [a, b] {
            try fm.setAttributes([.modificationDate: stamp],
                                 ofItemAtPath: root.appendingPathComponent("sub/deep/\(nfdName)").path)
        }

        let recorded = ItemIdentity.deepSnapshot(at: a, fileManager: fm)
        guard case .directoryTree = recorded else {
            Issue.record("expected a deep directory identity, got \(recorded)")
            return
        }
        #expect(recorded.drift(at: a, fileManager: fm) == .unchanged,
                "an untouched tree with a decomposed deep filename must not read as drift")
        #expect(recorded == ItemIdentity.deepSnapshot(at: b, fileManager: fm),
                "one logical name stored NFD by Foundation and NFC by a POSIX writer must be one identity")
    }

    // MARK: 7 — OS noise is not part of the identity; tooling trees ARE

    /// The seam, on a real tree, holding both halves of the ignored-names rule.
    ///
    /// OS noise — `.DS_Store` at two depths, `Thumbs.db` — appearing after the recording leaves
    /// the identity untouched: digesting Finder's droppings refused ⌘Z for every folder the user
    /// so much as opened, forever. That is `ItemIdentity.deepIdentityIgnoredNames`, and it is
    /// deliberately NOT the duplicates finder's `defaultIgnoredNames`: that set also skips
    /// `.git`, `.build` and `node_modules`, which is right for a DISCOVERY filter (a false skip
    /// costs a missed duplicate) and wrong for this DESTRUCTION guard — a `node_modules` skip
    /// meant an edit the user made inside the copy's `node_modules` was trashed by ⌘Z under an
    /// `.unchanged` verdict, taking the only instance of the edit. So the second half: an edit
    /// INSIDE a tooling subtree the copy carried is drift, and the undo refuses.
    @Test func osNoiseDoesNotChangeTheDeepIdentityButAnEditInsideAToolingTreeDoes() throws {
        let base = try makeCanonicalTempRoot(prefix: "DeepIdentityIgnored")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        let deep = folder.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: deep.appendingPathComponent("leaf.txt"))
        // The copy CARRIES a dependency subtree — recorded as part of the tree it lands as.
        let pkg = folder.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("module.exports = {}".utf8).write(to: pkg.appendingPathComponent("index.js"))

        let recorded = ItemIdentity.deepSnapshot(at: folder, fileManager: FileManager.default)
        guard case .directoryTree = recorded else {
            Issue.record("expected a deep directory identity, got \(recorded)")
            return
        }
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .unchanged,
                "an untouched tree — tooling subtree included — must not read as drift")

        // Finder opens the copy (and a subfolder); a Windows client scribbles its thumbnail db.
        try Data("finder".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        try Data("finder".utf8).write(to: deep.appendingPathComponent(".DS_Store"))
        try Data("windows".utf8).write(to: folder.appendingPathComponent("Thumbs.db"))

        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .unchanged,
                "OS noise must not shift the identity: digesting it refuses ⌘Z for every folder Finder ever opened")

        // The user edits INSIDE the tooling subtree. Under the old rule (the duplicates finder's
        // set) this was invisible — .unchanged — and ⌘Z destroyed the edit with the copy.
        try Data("module.exports = { edited: true }".utf8).write(to: pkg.appendingPathComponent("index.js"))
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .changed,
                "an edit inside node_modules is the user's work like any other — .unchanged here is ⌘Z trashing the only copy of it")
    }

    /// The same convention end-to-end: Finder writes a `.DS_Store` deep inside the copy between
    /// the copy and the ⌘Z — which is what Finder does to every folder the user so much as looks
    /// at — and the undo still removes the untouched copy instead of refusing it forever.
    @MainActor
    @Test func copyUndoStillRemovesACopyFinderScribbledADSStoreInto() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/deepds-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/deepds-src", to: "/deepds-dst")

        // Finder visits the copy: a .DS_Store lands two levels down. Registered in the parent's
        // contents too, so the mock's deep copy/remove stay faithful to a real disk.
        fm.virtualDisk["/deepds-dst/project/src/deep/.DS_Store"] = file(6148)
        if var deepStub = fm.virtualDisk["/deepds-dst/project/src/deep"] {
            deepStub.contents?.append(".DS_Store")
            fm.virtualDisk["/deepds-dst/project/src/deep"] = deepStub
        }
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the copy is removed despite the .DS_Store") { fm.virtualDisk["/deepds-dst/project"] == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(fm.virtualDisk["/deepds-dst/project"] == nil,
                "a Finder-written .DS_Store is not an edit — refusing here refuses every folder ever opened in Finder, forever")
        #expect(manager.banner?.severity != .warning,
                "no refusal banner for Finder metadata; got \(String(describing: manager.banner?.message))")
        #expect(fm.virtualDisk["/deepds-src/project/src/deep/notes.md"] != nil,
                "the source is untouched by an undo")
    }

    // MARK: The registration walk's own contract

    /// The deep walk `registerCopyUndo(items:)` takes at registration never touches the main
    /// thread. Inline it was the one main-actor stall in the chain — `FileSyncManager` is
    /// `@MainActor`, so a 40,200-node copy froze the UI for the ~1.8 s its recursive
    /// listing+stat costs on this machine (measured 2026-08-21), and SMB/iCloud for minutes.
    @MainActor
    @Test func theRegistrationIdentityWalkNeverTouchesTheMainThread() async throws {
        let base = try makeCanonicalTempRoot(prefix: "DeepIdentityOffMain")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a/b"),
                                                withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: folder.appendingPathComponent("a/b/leaf.txt"))

        let manager = makeManager()
        let fm = WalkThreadRecordingFileManager()
        let walk = manager.registerCopyUndo(
            items: [(source: base.appendingPathComponent("src"), destination: folder, overwritten: nil)],
            actionName: "Copy 1 Items", fileManager: fm)
        await walk.value

        let samples = fm.mainThreadSamples
        try #require(!samples.isEmpty,
                     "vacuity guard: the identity walk must actually have listed and statted the tree")
        #expect(samples.allSatisfy { !$0 },
                "the registration walk must never run on the main thread — that is the whole point of detaching it")
    }

    /// The other half of the off-main contract: the undo is registered BEFORE the walk resolves,
    /// so a ⌘Z racing the walk pops this undo and its handler waits for the identity instead of
    /// no-oping (or worse, undoing the operation before it). The returned walk task is
    /// deliberately dropped here — this test is the caller that cannot await.
    @MainActor
    @Test func anUndoInvokedBeforeTheIdentityWalkResolvesWaitsForItInsteadOfNoOping() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/undowait-dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/undowait-dst/project"] =
            MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["notes.md"])
        fm.virtualDisk["/undowait-dst/project/notes.md"] = file(4)

        _ = manager.registerCopyUndo(
            items: [(source: URL(fileURLWithPath: "/undowait-src/project"),
                     destination: URL(fileURLWithPath: "/undowait-dst/project"), overwritten: nil)],
            actionName: "Copy 1 Items", fileManager: fm)
        // No await between registration and ⌘Z: this is the racing user.
        manager.undoManager?.undo()
        await waitUntil("the undo waits for the identity and then removes the copy") {
            fm.virtualDisk["/undowait-dst/project"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(fm.virtualDisk["/undowait-dst/project"] == nil,
                "an undo racing the identity walk must wait for it and then act — a silent no-op strands the copy and lies about the stack")
    }
    // MARK: 10 — a registration-time .indeterminate says why, when it is knowable

    /// An unreadable descendant at REGISTRATION time is a permanent refusal for that item: hours
    /// later ⌘Z shows a banner that cannot say why, and until this the log's only line was the
    /// refusal itself. The registration must leave one warning naming the item — and the failing
    /// descendant, which the listing reports and the walk used to discard.
    ///
    /// This is the suite's one assertion against `Logger.shared` (a process-global): the paths
    /// carry a per-run UUID so no parallel neighbour can satisfy or pollute the match, per the
    /// `LoggingGapTests` discipline.
    @MainActor
    @Test func anUnreadableDescendantAtRegistrationLogsWhyTheEventualUndoWillRefuse() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        let root = "/logind-\(UUID().uuidString)"
        try plantDeepSource(on: fm, under: root)
        fm.unlistableDirectories = ["\(root)/project/src/deep"]

        let walk = manager.registerCopyUndo(
            items: [(source: URL(fileURLWithPath: "\(root)-src/project"),
                     destination: URL(fileURLWithPath: "\(root)/project"), overwritten: nil)],
            actionName: "Copy 1 Items", fileManager: fm)
        await walk.value
        // The warning rides the logger's FIFO; awaiting a later marker proves it has landed.
        await Logger.shared.debug("deep-identity log flush \(root)").value

        let entry = Logger.shared.entries.last {
            $0.message.contains("\(root)/project") && $0.level == .warning
        }
        try #require(entry != nil,
                     "a registration-time .indeterminate must log a warning naming the item — the ⌘Z refusal hours later is otherwise undiagnosable")
        #expect(entry?.message.contains("\(root)/project/src/deep") == true,
                "the failing descendant is known (the listing reports it) and must be named; got \(String(describing: entry?.message))")
    }
}

/// A `FileManaging` that walks the REAL filesystem but hands each enumeration back REORDERED.
/// `deepSnapshot`'s digest claims independence from enumeration order, and no walk of the real
/// filesystem can vary the order on demand — the real enumerator yields a stable order whatever
/// the creation order, so tests driving `FileManager.default` alone passed with the sort line
/// deleted. This double is what makes that deletion fail.
///
/// It deliberately does NOT try to vary the Unicode SPELLING of what it yields: `listing(of:)`
/// re-spells every entry through `appendingPathComponent`, which decomposes, so a respelling
/// here never survives to the digest — that rule is pinned at its seam instead
/// (`oneNameReportedInEitherUnicodeFormDigestsAsOneSpelling`).
private struct ReshapedWalkFileManager: FileManaging {
    let reorder: @Sendable ([URL]) -> [URL]

    init(reorder: @escaping @Sendable ([URL]) -> [URL] = { $0 }) {
        self.reorder = reorder
    }

    private var base: FileManager { FileManager.default }

    func fileExists(atPath path: String) -> Bool { base.fileExists(atPath: path) }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        base.fileExists(atPath: path, isDirectory: isDirectory)
    }
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try base.attributesOfItem(atPath: path)
    }
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try base.setAttributes(attributes, ofItemAtPath: path)
    }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    func copyItem(at srcURL: URL, to dstURL: URL) throws { try base.copyItem(at: srcURL, to: dstURL) }
    func moveItem(at srcURL: URL, to dstURL: URL) throws { try base.moveItem(at: srcURL, to: dstURL) }
    func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try base.trashItem(at: url, resultingItemURL: outResultingURL)
    }
    func removeItem(at URL: URL) throws { try base.removeItem(at: URL) }
    func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try base.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
    }

    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                    options mask: FileManager.DirectoryEnumerationOptions,
                    errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        // `.producesRelativePathURLs` is forced so every entry carries the relative path this
        // reshapes; `listing(of:)` — the only consumer under test — always asks for it anyway.
        guard let real = base.enumerator(at: url, includingPropertiesForKeys: keys,
                                         options: mask.union(.producesRelativePathURLs),
                                         errorHandler: handler) else { return nil }
        let entries = real.compactMap { $0 as? URL }
        let rebase = URL(fileURLWithPath: url.path, isDirectory: true)
        let reshaped = reorder(entries).map { entry in
            URL(fileURLWithPath: entry.relativePath,
                isDirectory: entry.hasDirectoryPath, relativeTo: rebase)
        }
        return MockEnumerator(urls: reshaped)
    }
}

/// Forwards everything to the real `FileManager` and records, for each enumeration and each
/// stat, whether it ran on the main thread — the seam
/// `theRegistrationIdentityWalkNeverTouchesTheMainThread` reads. A count of zero recordings is a
/// broken fixture, not a pass; the test `#require`s it non-empty.
private final class WalkThreadRecordingFileManager: FileManaging, @unchecked Sendable {
    private let base = FileManager.default
    private let lock = NSLock()
    private var samples: [Bool] = []

    var mainThreadSamples: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func record() {
        lock.lock(); samples.append(Thread.isMainThread); lock.unlock()
    }

    func fileExists(atPath path: String) -> Bool { record(); return base.fileExists(atPath: path) }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        record(); return base.fileExists(atPath: path, isDirectory: isDirectory)
    }
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        record(); return try base.attributesOfItem(atPath: path)
    }
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try base.setAttributes(attributes, ofItemAtPath: path)
    }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    func copyItem(at srcURL: URL, to dstURL: URL) throws { try base.copyItem(at: srcURL, to: dstURL) }
    func moveItem(at srcURL: URL, to dstURL: URL) throws { try base.moveItem(at: srcURL, to: dstURL) }
    func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try base.trashItem(at: url, resultingItemURL: outResultingURL)
    }
    func removeItem(at URL: URL) throws { try base.removeItem(at: URL) }
    func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try base.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
    }
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                    options mask: FileManager.DirectoryEnumerationOptions,
                    errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        record()
        return base.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
    }
}
