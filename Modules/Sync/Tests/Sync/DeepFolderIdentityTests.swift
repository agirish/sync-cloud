import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// The deep half of the copy-undo drift guard. The shallow `.directory` identity (own date plus
/// immediate child count) sees nothing below depth 1, so an edit deep inside a copied folder would
/// read `.unchanged` and ⌘Z would trash the only copy of it, permanently on a Trash-less volume.
///
/// `deepSnapshot` digests every descendant's relative path, kind, size and mtime as a
/// `.directoryTree`, so a deep edit refuses the undo. These tests hold its edges: a deep edit
/// refuses (by size, and by date alone); an untouched tree still undoes; an unreadable descendant
/// is `.indeterminate` and refuses; and the digest ignores enumeration order, the Unicode form of
/// names, and Finder's `.DS_Store`s. The registration walk's contract (off the main thread, undo
/// armed before it resolves) is at the bottom.
///
/// Each end-to-end test first requires the shallow `ItemIdentity.snapshot` to still read
/// `.unchanged` after the tampering, so it exercises what only the deep identity can see.
///
/// No `.serialized`: every assertion reads this suite's own banner or mock disk, and the one
/// `Logger.shared` match is keyed on a per-run UUID path.
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

    /// `<srcRoot>/project/src/deep/notes.md`: the edited file sits two levels below the copied
    /// root, so it can't move the root's date or child count. `contents` is filled in because the
    /// mock's `copyItem` deep-copies by it.
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

    /// Copies the planted tree to `dstRoot` through the real operation, which registers the undo
    /// under test, and checks the whole tree arrived.
    @MainActor
    private func copyDeepTree(manager: FileSyncManager, fm: MockFileManager,
                              from srcRoot: String, to dstRoot: String) async throws {
        try fm.createDirectory(at: URL(fileURLWithPath: dstRoot), withIntermediateDirectories: true)
        let node = FileNode(id: "\(srcRoot)/project", name: "project", isDirectory: true)
        _ = await manager.copyItems(nodes: [node], toPath: dstRoot, fileManager: fm)
        try #require(fm.virtualDisk["\(dstRoot)/project/src/deep/notes.md"] != nil,
                     "the fixture's deep tree must have been copied in full")
    }

    /// The shallow identity of the copied root, taken before the tampering. Each refusal test
    /// re-asks it afterwards and requires `.unchanged`, so it tests the deep guard and not depth 1.
    private func shallowIdentity(_ fm: MockFileManager, root: String) throws -> ItemIdentity {
        let shallow = ItemIdentity.snapshot(at: URL(fileURLWithPath: root), fileManager: fm)
        guard case .directory = shallow else {
            throw NSError(domain: "DeepFolderIdentityTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected a shallow directory identity for \(root), got \(shallow)"])
        }
        return shallow
    }

    // MARK: 1 — THE bug: an edit two levels down refuses the undo

    /// Copy a folder, edit a file two levels deep, ⌘Z: the undo refuses. The shallow identity reads
    /// `.unchanged` here and would trash the only copy of the edit. Two edits: the file grows, and
    /// the harder half, same size with only the date moved (a same-length rewrite, the deep twin of
    /// `copyUndoRefusesASameSizeEditOfTheCopy`), which only the per-file date in the deep digest
    /// can see.
    @MainActor
    @Test(arguments: [999, 4])
    func copyUndoRefusesADeepEdit(editedSize: Int) async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/deepid-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/deepid-src", to: "/deepid-dst")

        // Nothing at the copied root moves: same immediate children, same (nil) directory date.
        let shallowAtRegistration = try shallowIdentity(fm, root: "/deepid-dst/project")
        fm.virtualDisk["/deepid-dst/project/src/deep/notes.md"] =
            file(editedSize, modified: Date(timeIntervalSince1970: 9_999))
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
        let edited = fm.virtualDisk["/deepid-dst/project/src/deep/notes.md"]?.attributes
        #expect(edited?[FileAttributeKey.size] as? Int == editedSize,
                "the edited deep file must be left exactly as the user wrote it")
        #expect(edited?[FileAttributeKey.modificationDate] as? Date == Date(timeIntervalSince1970: 9_999),
                "the edited deep file must be left exactly as the user wrote it")
        #expect(fm.virtualDisk["/deepid-src/project"] != nil, "the source is untouched by an undo")
    }

    // MARK: 2 — no false refusals

    /// The other direction: an untouched deep tree still undoes. The digest is computed at
    /// registration and at verification over walks APFS may order differently, so this also shows
    /// end to end that the two agree.
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

    /// A deep subfolder of the copy becomes unlistable before ⌘Z. The re-walk comes back partial
    /// (`.listedWithUnreadableDescendants`), which proves nothing about the withheld part, so the
    /// verdict is `.indeterminate` and the undo refuses. The shallow identity never opens it.
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
        #expect(manager.banner?.message.contains("couldn’t be checked") == true,
                "an unverifiable tree reports as unverifiable, not as changed; got \(String(describing: manager.banner?.message))")
        #expect(fm.virtualDisk["/deeplock-dst/project"] != nil,
                "a tree that cannot be checked is not destroyed")
        #expect(fm.virtualDisk["/deeplock-dst/project/src/deep/notes.md"] != nil)
    }

    // MARK: 4 — the digest is a function of the tree, not of the walk

    /// Two trees with identical contents built in opposite creation orders, one snapshotted twice,
    /// produce one identity. APFS guarantees no enumeration order, so an order-dependent digest
    /// would make every folder-copy undo falsely refuse.
    ///
    /// This doesn't pin the digest's sort: the real enumerator yields a stable order, so it passes
    /// with `lines.sort` deleted. It shows two real walks agree; the sort is pinned by
    /// `theDigestDoesNotDependOnTheOrderTheWalkYieldsEntriesIn`, whose enumerator varies the order.
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

    /// The counterpart of `ItemIdentityTests.aChangeDeepInsideASubtreeIsNotNoticed`: the edit the
    /// shallow snapshot calls `.unchanged`, the deep one calls `.changed`, both asserted on one
    /// fixture so neither goes vacuous.
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

    /// One tree, walked forwards and backwards, produces one identity: the pin for
    /// `deepSnapshot`'s sort, which exists because APFS promises no enumeration order. Real and
    /// mock walks both yield a stable order, so `ReshapedWalkFileManager` hands the real tree's
    /// entries back reversed, an order APFS may produce. Deleting `lines.sort` must fail this.
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

        // `.indeterminate == .indeterminate` would pass vacuously, so require the shape first: a
        // fake that broke the walk must fail, not agree.
        guard case .directoryTree = forward else {
            Issue.record("expected a deep directory identity, got \(forward)")
            return
        }
        #expect(forward == backward,
                "one tree must serialize identically whatever order the enumerator yields it in — registration and verification are two walks, and a disagreement here falsely refuses every folder-copy undo")
    }

    // MARK: 6 — the Unicode form a name reaches the digest in is not part of the identity

    /// One relative path handed over decomposed (NFD, "é" as U+0065 U+0301) or precomposed (NFC)
    /// digests under one spelling, byte for byte. The digest hashes UTF-8 and APFS/HFS+ lookups
    /// ignore normalization, so one name hashing two ways would falsely refuse an untouched tree.
    ///
    /// Tested at the seam (`ItemIdentity.canonicalDigestSpelling`) because no end-to-end fixture
    /// reaches it: `listing(of:)` re-spells every entry through `appendingPathComponent`, which
    /// hands `deepSnapshot` the decomposed form whatever is on disk. That incidental normalization
    /// is undocumented; this test notices if it stops holding the digest up.
    ///
    /// Compared as UTF-8 bytes, since `String ==` uses canonical equivalence and would pass with
    /// the rule gone. Making `canonicalDigestSpelling` return its input must fail this.
    @Test func oneNameReportedInEitherUnicodeFormDigestsAsOneSpelling() throws {
        let nfd = "sub/deep/re\u{0065}\u{0301}sume\u{0301}.txt"   // "résumé.txt", é decomposed
        let nfc = nfd.precomposedStringWithCanonicalMapping
        try #require(Array(nfd.utf8) != Array(nfc.utf8),
                     "fixture check: the two spellings must be byte-distinct — String == cannot tell them apart")

        #expect(Array(ItemIdentity.canonicalDigestSpelling(ofRelativePath: nfd).utf8)
                == Array(ItemIdentity.canonicalDigestSpelling(ofRelativePath: nfc).utf8),
                "one name reported in either Unicode form must digest as one spelling — two spellings would falsely refuse the undo of an untouched folder walked once per form")
    }

    /// The user-level half: a decomposed non-ASCII filename deep in a real tree reads `.unchanged`
    /// on re-walk, and matches a twin whose name was stored precomposed through POSIX `open`, as an
    /// SMB or non-Foundation writer leaves it on APFS. macOS APIs may hand back either form.
    ///
    /// `listing(of:)` currently canonicalizes both spellings before the digest, so this passes even
    /// without the precomposition (the seam test above fails then). It holds the invariant end to
    /// end, whichever layer canonicalizes.
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
        // Same mtime on both leaves, or the test measures the clock, not the spelling. The lookup
        // ignores normalization, so the NFD path reaches the NFC-stored file.
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

    /// Both halves of the ignored-names rule, on a real tree. OS noise (`.DS_Store` at two depths,
    /// `Thumbs.db`) added after the recording leaves the identity alone, or ⌘Z would refuse every
    /// folder Finder opened. That is `ItemIdentity.deepIdentityIgnoredNames`, deliberately not the
    /// duplicates finder's `defaultIgnoredNames`, which also skips `.git`, `.build` and
    /// `node_modules`: fine for discovery, wrong for a guard before destruction. So an edit inside
    /// a tooling subtree the copy carried is drift, and the undo refuses.
    @Test func osNoiseDoesNotChangeTheDeepIdentityButAnEditInsideAToolingTreeDoes() throws {
        let base = try makeCanonicalTempRoot(prefix: "DeepIdentityIgnored")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        let deep = folder.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: deep.appendingPathComponent("leaf.txt"))
        // The copy carries a dependency subtree, recorded as part of the tree.
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

        // The user edits inside the tooling subtree. With the duplicates finder's set this would
        // read .unchanged, and ⌘Z would destroy the edit with the copy.
        try Data("module.exports = { edited: true }".utf8).write(to: pkg.appendingPathComponent("index.js"))
        #expect(recorded.drift(at: folder, fileManager: FileManager.default) == .changed,
                "an edit inside node_modules is the user's work like any other — .unchanged here is ⌘Z trashing the only copy of it")
    }

    /// The same rule end to end: Finder writes a `.DS_Store` deep inside the copy before ⌘Z, as
    /// it does in any folder the user looks at, and the undo still removes the untouched copy.
    @MainActor
    @Test func copyUndoStillRemovesACopyFinderScribbledADSStoreInto() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/deepds-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/deepds-src", to: "/deepds-dst")

        // Finder visits the copy: a .DS_Store lands two levels down, also listed in the parent's
        // contents so the mock's deep copy and remove match a real disk.
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

    /// The deep walk `registerCopyUndo(items:actionName:fileManager:)` takes at registration never
    /// touches the main thread. `FileSyncManager` is `@MainActor`, so inline it would freeze the UI
    /// for seconds on a big local copy and minutes on SMB or iCloud.
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
            actionName: "Copy 1 Item", fileManager: fm)
        await walk.value

        let samples = fm.mainThreadSamples
        try #require(!samples.isEmpty,
                     "vacuity guard: the identity walk must actually have listed and statted the tree")
        #expect(samples.allSatisfy { !$0 },
                "the registration walk must never run on the main thread — that is the whole point of detaching it")
    }

    /// The other half: the undo is registered before the walk resolves, so a ⌘Z racing the walk
    /// pops this undo and its handler waits for the identity instead of no-oping (or undoing the
    /// operation before it). The walk task is dropped on purpose: this is the caller that can't
    /// await. The race is held, not hoped for: `FirstStatGate` parks the walk in its first
    /// stat, so the ⌘Z lands while the identity is unresolved.
    @MainActor
    @Test(.parksAThread) func anUndoInvokedBeforeTheIdentityWalkResolvesWaitsForItInsteadOfNoOping() async throws {
        let manager = makeManager()
        let mock = MockFileManager()
        try mock.createDirectory(at: URL(fileURLWithPath: "/undowait-dst"), withIntermediateDirectories: true)
        mock.virtualDisk["/undowait-dst/project"] =
            MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["notes.md"])
        mock.virtualDisk["/undowait-dst/project/notes.md"] = file(4)
        let fm = FirstStatGate(inner: mock, gatesDirectoryProbe: false)

        _ = manager.registerCopyUndo(
            items: [(source: URL(fileURLWithPath: "/undowait-src/project"),
                     destination: URL(fileURLWithPath: "/undowait-dst/project"), overwritten: nil)],
            actionName: "Copy 1 Item", fileManager: fm)
        // The walk is mid-flight: parked in its opening stat, identity unresolved.
        await awaitSignal(fm.entered, "the identity walk never reached its first stat — the gate cannot have held the race")
        // No await between registration and ⌘Z: the racing user, ahead of the resolution.
        manager.undoManager?.undo()
        await waitUntil("the undo op is in flight") { manager.activeFileOperationsCount == 1 }
        #expect(mock.virtualDisk["/undowait-dst/project"] != nil,
                "the handler must be suspended in the resolver while the walk is held — acting here would mean comparing against a half-recorded state")

        fm.release.signal()
        await waitUntil("the undo waits for the identity and then removes the copy") {
            mock.virtualDisk["/undowait-dst/project"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        try #require(!fm.releasedByTimeout,
                     "the walk resumed by timeout, not by this test — the race was never actually held")
        #expect(mock.virtualDisk["/undowait-dst/project"] == nil,
                "an undo racing the identity walk must wait for it and then act — a silent no-op strands the copy and lies about the stack")
    }

    // MARK: 8 — the registration window is per ITEM, not per batch

    /// Each item's identity walk starts the moment its own copy lands, inside the transfer loop.
    /// The loop blocks on user prompts, so a walk after the whole batch would leave an unbounded
    /// window: copy folders A and B, and while B's collision prompt is open the user edits a file
    /// deep in A's copy; that edit becomes A's baseline, and ⌘Z reads `.unchanged` and trashes it.
    ///
    /// The fixture holds the order: before the prompt, a bounded wait lets the walk stat the deep
    /// file's pre-edit state, then the prompt applies the edit. With a post-batch walk, no walk can
    /// run while the prompt is open, so the wait times out and the `#require` names the defect.
    @MainActor
    @Test func anEditDuringALaterItemsCollisionPromptRefusesTheUndoOfTheEarlierItem() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/promptwin-src")
        // The second item: a file that collides at the destination, holding the batch at a prompt
        // after the folder's copy has landed. Its name is longer than the folder's so
        // `pruneNestedNodes`' length sort keeps the folder first.
        fm.virtualDisk["/promptwin-src/zz-collide.txt"] = file(5)
        try fm.createDirectory(at: URL(fileURLWithPath: "/promptwin-dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/promptwin-dst/zz-collide.txt"] = file(7)

        let deepCopyPath = "/promptwin-dst/project/src/deep/notes.md"
        let walkReadTheDeepFile = LockedBox(false)
        fm.onAttributesOfItem = { path in
            if path == deepCopyPath { walkReadTheDeepFile.withLock { $0 = true } }
        }
        let promptFired = LockedBox(false)
        let walkRanDuringPrompt = LockedBox(false)

        // The wait for the walk happens here, off the main thread, not in the resolver: the
        // resolver is `@MainActor` and synchronous, so spinning there blocks the main thread (for
        // the whole 5 s on failure) and stalls every main-actor test beside this one.
        // `beforeFileExists` runs on the operation's worker thread before item 2's collision stat,
        // holding no lock, so the walk (which takes the mock's lock per `attributesOfItem`) runs on.
        // **Don't park in `onFileExists`:** it holds that lock and would deadlock the walk.
        let collidingTarget = "/promptwin-dst/zz-collide.txt"
        let parkedOut = LockedBox(false)
        fm.beforeFileExists = { path in
            guard path == collidingTarget, !walkReadTheDeepFile.withLock({ $0 }) else { return }
            let deadline = Date().addingTimeInterval(5)
            while !walkReadTheDeepFile.withLock({ $0 }) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            parkedOut.withLock { $0 = !walkReadTheDeepFile.withLock { $0 } }
        }

        manager.collisionResolver = { _ in
            promptFired.withLock { $0 = true }
            // The user, mid-batch: the folder's copy has landed and its walk has read the pre-edit
            // state (waited for above), and now they edit a file deep inside it while this prompt
            // is open, so the edit postdates the recording.
            walkRanDuringPrompt.withLock { $0 = walkReadTheDeepFile.withLock { $0 } }
            // The walk may still be inside the mock, so this write takes the mock's lock, as
            // `setStub` and every `virtualDisk` access do.
            fm.setStub(MockFileManager.FileStub(
                isDirectory: false,
                attributes: [FileAttributeKey.size: 999,
                             FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 9_999)],
                contents: nil), at: deepCopyPath)
            return .replace
        }

        let nodes = [FileNode(id: "/promptwin-src/project", name: "project", isDirectory: true),
                     FileNode(id: "/promptwin-src/zz-collide.txt", name: "zz-collide.txt", isDirectory: false)]
        _ = await manager.copyItems(nodes: nodes, toPath: "/promptwin-dst", fileManager: fm)

        try #require(promptFired.withLock { $0 },
                     "fixture check: the collision prompt (and so the mid-batch edit) must have fired")
        try #require(parkedOut.withLock { $0 } == false,
                     "the park before the collision stat gave up waiting instead of being released — the walk never reached the deep file, so the ordering below was never established")
        try #require(walkRanDuringPrompt.withLock { $0 },
                     "the copy-to-recording window is per BATCH, not per item: no identity walk read the landed copy while a later item's prompt held the loop open — an edit made now becomes the recorded baseline and ⌘Z will trash it")
        try #require(fm.virtualDisk[deepCopyPath]?.attributes?[FileAttributeKey.size] as? Int == 999,
                     "fixture check: the mid-prompt edit must be on the mock disk")
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.severity == .warning,
                "the undo must refuse the edited copy; banner: \(String(describing: manager.banner?.message))")
        #expect(manager.banner?.message.contains("changed since") == true,
                "got \(String(describing: manager.banner?.message))")
        #expect(fm.virtualDisk["/promptwin-dst/project"] != nil,
                "the copy edited during the prompt must survive ⌘Z — trashing it takes the only instance of the edit")
        #expect(fm.virtualDisk[deepCopyPath]?.attributes?[FileAttributeKey.size] as? Int == 999,
                "the edited deep file must be left exactly as the user wrote it")
        #expect(fm.virtualDisk["/promptwin-dst/zz-collide.txt"]?.attributes?[FileAttributeKey.size] as? Int == 7,
                "the unedited item still undoes: its replaced original is restored")
    }

    // MARK: 9 — the redo→undo leg records at the same depth

    /// Copy, undo, redo, edit deep inside the re-copy, undo again: the second undo refuses. The
    /// redo records the next undo's identity itself, and must record it deep. Other copy-redo tests
    /// use files, where both snapshots are the same, so changing the redo's `deepSnapshot` to
    /// `snapshot` must fail this one.
    @MainActor
    @Test func aDeepEditAfterARedoRefusesTheSecondUndo() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        try plantDeepSource(on: fm, under: "/redodeep-src")
        try await copyDeepTree(manager: manager, fm: fm, from: "/redodeep-src", to: "/redodeep-dst")

        manager.undoManager?.undo()
        await waitUntil("the first undo removes the copy") { fm.virtualDisk["/redodeep-dst/project"] == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        try #require(fm.virtualDisk["/redodeep-dst/project"] == nil,
                     "fixture check: the first undo must have removed the untouched copy")

        manager.undoManager?.redo()
        await waitUntil("the redo re-copies the tree") {
            fm.virtualDisk["/redodeep-dst/project/src/deep/notes.md"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        try #require(fm.virtualDisk["/redodeep-dst/project/src/deep/notes.md"] != nil,
                     "fixture check: the redo must have re-copied the whole tree")

        // The user edits deep inside the re-copy; nothing at its root moves, so the shallow
        // identity can't see it (the same precondition as the first-leg tests).
        let shallowAfterRedo = try shallowIdentity(fm, root: "/redodeep-dst/project")
        fm.virtualDisk["/redodeep-dst/project/src/deep/notes.md"] =
            file(999, modified: Date(timeIntervalSince1970: 9_999))
        try #require(shallowAfterRedo.drift(at: URL(fileURLWithPath: "/redodeep-dst/project"),
                                            fileManager: fm) == .unchanged,
                     "fixture check: this edit must be exactly the one the shallow identity cannot see")
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("second undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.severity == .warning,
                "the second undo must refuse, not proceed; banner: \(String(describing: manager.banner?.message))")
        #expect(manager.banner?.message.contains("changed since") == true,
                "got \(String(describing: manager.banner?.message))")
        #expect(fm.virtualDisk["/redodeep-dst/project"] != nil,
                "the re-copy must still be on disk — the redo leg recorded shallow and the deep edit slipped through")
        #expect(fm.virtualDisk["/redodeep-dst/project/src/deep/notes.md"]?.attributes?[FileAttributeKey.size] as? Int == 999,
                "the edited deep file must be left exactly as the user wrote it")
    }

    // MARK: 10 — a registration-time .indeterminate says why, when it is knowable

    /// An unreadable descendant at registration means a permanent refusal for that item, and the
    /// ⌘Z banner hours later can't say why. So registration logs one warning naming the item and
    /// the failing descendant the listing reports.
    ///
    /// The paths carry a per-run UUID so no parallel neighbour can satisfy or pollute the match,
    /// as in `LoggingGapTests`.
    @MainActor
    @Test func anUnreadableDescendantAtRegistrationLogsWhyTheEventualUndoWillRefuse() async throws {
        let manager = makeManager()
        let fm = MockFileManager()
        let root = "/logind-\(UUID().uuidString)"
        // See the batch test below: opened before the call, so eviction cannot empty it.
        let log = LogCapture()
        try plantDeepSource(on: fm, under: root)
        fm.unlistableDirectories = ["\(root)/project/src/deep"]

        let walk = manager.registerCopyUndo(
            items: [(source: URL(fileURLWithPath: "\(root)-src/project"),
                     destination: URL(fileURLWithPath: "\(root)/project"), overwritten: nil)],
            actionName: "Copy 1 Item", fileManager: fm)
        await walk.value

        // `LogCapture`, not `Logger.shared.entries`, whose newest-1000 buffer other suites can
        // evict this warning from (`docs/flaky-tests.md`, "A log assertion reading a window that
        // has already rolled"). A capture keeps what it saw, and awaits the FIFO flush.
        let entry = await log.entries.last {
            $0.message.contains("\(root)/project") && $0.level == .warning
        }
        try #require(entry != nil,
                     "a registration-time .indeterminate must log a warning naming the item — the ⌘Z refusal hours later is otherwise undiagnosable")
        #expect(entry?.message.contains("\(root)/project/src/deep") == true,
                "the failing descendant is known (the listing reports it) and must be named; got \(String(describing: entry?.message))")
    }

    /// …and a batch of them says it once. One cause (a permissions problem, an unmounted volume, a
    /// provider that stopped answering) would otherwise log a warning per item and push the context
    /// explaining it out of the 1000-entry buffer. Same shape as `SyncHistoryStore.appendBatch`'s
    /// dropped records: count them, name the first. The per-run UUID means only this batch matches.
    @MainActor
    @Test func aBatchOfUnreadableRegistrationsLogsOneLineNamingTheFirstAndTheCount() async throws {
        // Opened before the call under test: it is a window, not a query. A capture keeps what it
        // sees, which `Logger.shared`'s shared newest-1000 buffer doesn't (`docs/flaky-tests.md`,
        // "A log assertion reading a window that has already rolled").
        let log = LogCapture()
        let manager = makeManager()
        let fm = MockFileManager()
        let root = "/logbatch-\(UUID().uuidString)"
        var items: [(source: URL, destination: URL, overwritten: URL?)] = []
        for i in 0..<6 {
            try plantDeepSource(on: fm, under: "\(root)/item\(i)")
            fm.unlistableDirectories.insert("\(root)/item\(i)/project/src/deep")
            items.append((source: URL(fileURLWithPath: "\(root)/item\(i)-src/project"),
                          destination: URL(fileURLWithPath: "\(root)/item\(i)/project"),
                          overwritten: nil))
        }

        await manager.registerCopyUndo(items: items, actionName: "Copy 6 Items", fileManager: fm).value

        // See the sibling test: read the capture, not the evictable process-wide buffer.
        let mine = await log.entries.filter {
            $0.level == .warning && $0.message.contains(root)
        }
        #expect(mine.count == 1,
                "6 unreadable registrations left \(mine.count) warning(s) — one per item crowds the 1000-entry buffer that holds the context explaining WHY they were unreadable: \(mine.map(\.message))")
        let line = mine.first?.message ?? ""
        #expect(line.contains("6 of 6"),
                "the one line must say how many of how many: “\(line)”")
        #expect(line.contains("\(root)/item0/project"),
                "the one line must name the first offender: “\(line)”")
        #expect(line.contains("\(root)/item0/project/src/deep"),
                "the one line must still name the failing descendant — that is the whole diagnostic value: “\(line)”")
    }
}

/// A `FileManaging` that walks the real filesystem but hands each enumeration back reordered.
/// The real enumerator yields a stable order, so only a double like this can make deleting
/// `deepSnapshot`'s sort fail.
///
/// It doesn't vary the Unicode spelling: `listing(of:)` re-spells every entry through
/// `appendingPathComponent`, which decomposes, so a respelling never reaches the digest. That rule
/// is pinned at its seam (`oneNameReportedInEitherUnicodeFormDigestsAsOneSpelling`).
private final class ReshapedWalkFileManager: ForwardingFileManaging<FileManager>, @unchecked Sendable {
    let reorder: @Sendable ([URL]) -> [URL]

    init(reorder: @escaping @Sendable ([URL]) -> [URL] = { $0 }) {
        self.reorder = reorder
        super.init(inner: .default)
    }

    override func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                             options mask: FileManager.DirectoryEnumerationOptions,
                             errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        // `.producesRelativePathURLs` is forced so every entry carries the relative path this
        // reshapes; `listing(of:)`, the only consumer under test, always asks for it anyway.
        guard let real = inner.enumerator(at: url, includingPropertiesForKeys: keys,
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

/// Forwards to the real `FileManager` and records, per enumeration and stat, whether it ran on the
/// main thread, for `theRegistrationIdentityWalkNeverTouchesTheMainThread`. Zero recordings is a
/// broken fixture, not a pass, so the test requires some.
private final class WalkThreadRecordingFileManager: ForwardingFileManaging<FileManager>, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Bool] = []

    init() { super.init(inner: .default) }

    var mainThreadSamples: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func record() {
        lock.lock(); samples.append(Thread.isMainThread); lock.unlock()
    }

    override func fileExists(atPath path: String) -> Bool { record(); return inner.fileExists(atPath: path) }
    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        record(); return inner.fileExists(atPath: path, isDirectory: isDirectory)
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        record(); return try inner.attributesOfItem(atPath: path)
    }
    override func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                             options mask: FileManager.DirectoryEnumerationOptions,
                             errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        record()
        return inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
    }
}
