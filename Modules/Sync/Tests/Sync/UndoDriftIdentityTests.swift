import Testing
import Foundation
import Events
@testable import Sync

/// The three drift gaps the size-based snapshot could not close.
///
/// `fileSizeSnapshot` answered `Int?`, and the guards read `if let expected = …`, so the two
/// states it could not express both took the destroy path:
///
/// 1. **A copied FOLDER had no drift guard at all.** Directories return nil by design — a folder's
///    stat size is not its content size — and nil skipped the check rather than falling back to
///    another one.
/// 2. **A file was compared by size alone**, so a same-length rewrite (2025→2026) read as
///    untouched and was trashed.
/// 3. **The move-undo never checked the destination**, only that the source path was free. The
///    doc comment claiming a "still the same item?" guard described the occupancy check, which
///    answers a different question.
///
/// Each test below drives the real undo through `FileSyncManager` rather than asserting on
/// `ItemIdentity` in isolation: the seam already has its own tests, and a rule that is only proven
/// where it is defined is one revert away from being unused.
@Suite struct UndoDriftIdentityTests {

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

    // MARK: Reading the refusal LOG, not just the banner

    /// Every test here used to assert `manager.banner?.message` alone. The banner is one short
    /// sentence shared by both undo paths; the LOG line is where the path-specific wording lives,
    /// and it is precisely because nothing read it that the move-undo shipped logging `REFUSED to
    /// remove "doc.txt" … it is no longer the item this undo produced` — a sentence in which both
    /// claims are false.
    ///
    /// `Logger.shared.entries` is capped at 1000 and every suite in this target writes to the same
    /// logger, so a refusal line can be EVICTED between the decision and the assertion — which
    /// reads exactly like a line that was never written. Planting a marker BEFORE the operation
    /// tells the two apart: if the marker is gone, the window rolled and the run is reported as
    /// inconclusive rather than as a missing log line.
    ///
    /// Planted at `.info`, not `.debug`. `Logger.log` drops anything below `minimumLevel`, and
    /// `.debug` is the one level it can drop, while every line these tests assert on is `.error`
    /// or `.info`. Nothing in this target raises `minimumLevel` today, so the marker is not
    /// currently at risk — but if anything ever did, the marker would vanish while the asserted
    /// lines stayed, and the helper would report "the log window rolled": a red run blaming the
    /// 1000-entry cap for something that has nothing to do with it. Matching the level of the
    /// lines being measured costs nothing and removes the trap.
    @MainActor
    private func plantLogMarker(_ label: String) async -> String {
        let marker = "undo-drift-marker \(label) \(UUID().uuidString)"
        await Logger.shared.info(marker).value
        return marker
    }

    /// The messages logged since `marker` was planted, flushed first so the report is complete.
    ///
    /// The window is a SUPERSET of this test's own lines: suites in this target run in parallel
    /// against one shared `Logger`, so a neighbour's lines land inside it. Positive assertions are
    /// therefore written against strings unique to the test's own fixture, and absence assertions
    /// filter the window down to lines naming this test's paths first — an unfiltered
    /// `allSatisfy` over the window asserts something about whatever else happened to be running,
    /// which is how the first draft of this suite failed.
    @MainActor
    private func logLines(since marker: String,
                          sourceLocation: SourceLocation = #_sourceLocation) async -> [String] {
        await Logger.shared.info("flush after \(marker)").value
        let entries = Logger.shared.entries
        guard let start = entries.lastIndex(where: { $0.message == marker }) else {
            Issue.record("""
                the log window rolled past this test's own marker — the 1000-entry cap evicted it, \
                so nothing can be concluded about the refusal line
                """, sourceLocation: sourceLocation)
            return []
        }
        return entries[start...].map(\.message)
    }

    // MARK: 1 — a copied folder is now guarded

    /// The sharpest of the three. Copy a folder, let files land in it, press ⌘Z: before this, the
    /// nil size snapshot skipped the guard and the folder was trashed with everything in it.
    ///
    /// The fixture folder is `photos-drifted`, not `photos`, for the same reason `locked` and
    /// `ledger.txt` are named as they are: the log window this asserts against is shared with
    /// every suite running alongside, so a path a NEIGHBOUR could also log is not a scope. Its
    /// untouched-folder twin below still uses plain `photos` and can keep it — it reads no log at
    /// all — but the two sharing a name was one log assertion away from measuring each other.
    @MainActor
    @Test func copyUndoOfAFolderRefusesOnceItsContentsChanged() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos-drifted"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/photos-drifted/a.jpg"] = file(10)

        let node = FileNode(id: "/src/photos-drifted", name: "photos-drifted", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/photos-drifted"] != nil)

        // Finder drops two more files into the copy. Finder never touches the undo stack.
        mockFM.virtualDisk["/dst/photos-drifted/new1.jpg"] = file(20)
        mockFM.virtualDisk["/dst/photos-drifted/new2.jpg"] = file(30)
        manager.banner = nil
        let marker = await plantLogMarker("copy-folder-changed")

        manager.undoManager?.undo()
        await waitUntil("the folder undo refuses") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("changed since") == true)
        // The copy path's sentence: this undo really would have REMOVED the item, and that item
        // really is the one the copy produced.
        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to remove \"photos-drifted\" at /dst/photos-drifted")
                && $0.contains("it changed since the operation")
                && $0.contains("no longer the item this undo produced")
        }, "the refusal log line is missing or reworded; lines since the marker: \(lines)")
        #expect(mockFM.virtualDisk["/dst/photos-drifted"] != nil, "the copied folder must still be on disk")
        #expect(mockFM.virtualDisk["/dst/photos-drifted/new1.jpg"] != nil, "the files added since must survive")
        #expect(mockFM.virtualDisk["/dst/photos-drifted/new2.jpg"] != nil)
    }

    /// The other half of the same guard: an untouched copied folder must still undo cleanly, or
    /// the fix would simply have broken folder undo. A guard that refuses everything is not a
    /// guard.
    @MainActor
    @Test func copyUndoOfAnUntouchedFolderStillRemovesIt() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/photos/a.jpg"] = file(10)

        let node = FileNode(id: "/src/photos", name: "photos", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/photos"] != nil)

        manager.undoManager?.undo()
        await waitUntil("the untouched folder is removed") { mockFM.virtualDisk["/dst/photos"] == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/src/photos"] != nil, "the source is untouched by an undo")
    }

    // MARK: 2 — a same-size edit is drift

    /// `2025` → `2026`: identical length, different content. The size-only comparison read this as
    /// the copy it produced and trashed it.
    @MainActor
    @Test func copyUndoRefusesASameSizeEditOfTheCopy() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/bill.txt"] = file(4, modified: Date(timeIntervalSince1970: 1_000))

        let node = FileNode(id: "/src/bill.txt", name: "bill.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/bill.txt"] != nil)

        // Edited in place: same four bytes, later timestamp. Size alone cannot see this.
        mockFM.virtualDisk["/dst/bill.txt"] = file(4, modified: Date(timeIntervalSince1970: 9_999))
        manager.banner = nil
        let marker = await plantLogMarker("copy-same-size-edit")

        manager.undoManager?.undo()
        await waitUntil("the same-size edit is refused") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("changed since") == true)
        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to remove \"bill.txt\" at /dst/bill.txt")
                && $0.contains("it changed since the operation")
        }, "the refusal log line is missing or reworded; lines since the marker: \(lines)")
        #expect(mockFM.virtualDisk["/dst/bill.txt"]?.attributes?[FileAttributeKey.modificationDate] as? Date
                == Date(timeIntervalSince1970: 9_999), "the edited copy must be left exactly as it is")
    }

    // MARK: 3 — the move-undo checks the destination

    /// The move-undo's only guard was that the SOURCE path is free. Drop a different file at the
    /// destination and press ⌘Z: that file was moved away to the source path and the older version
    /// restored over it, reported as a clean success.
    @MainActor
    @Test func moveUndoRefusesWhenTheDestinationIsNoLongerWhatItMoved() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/ledger.txt"] = file(100, modified: Date(timeIntervalSince1970: 1_000))

        let node = FileNode(id: "/src/ledger.txt", name: "ledger.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/ledger.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/ledger.txt"] == nil)

        // A newer v2 replaces the moved file at the destination.
        mockFM.virtualDisk["/dst/ledger.txt"] = file(555, modified: Date(timeIntervalSince1970: 9_999))
        manager.banner = nil
        let marker = await plantLogMarker("move-destination-replaced")

        manager.undoManager?.undo()
        await waitUntil("the move undo refuses the replaced destination") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("changed since") == true)
        #expect(mockFM.virtualDisk["/dst/ledger.txt"]?.attributes?[FileAttributeKey.size] as? Int == 555,
                "v2 must still be at the destination, not dragged back to the source")
        #expect(mockFM.virtualDisk["/src/ledger.txt"] == nil,
                "nothing may be restored to the source while the destination is unverified")

        let lines = await logLines(since: marker)
        // A move-undo moves the item BACK; it removes nothing, and it did not produce the item —
        // the original move put it there. The old sentence claimed both.
        #expect(lines.contains {
            $0.contains("REFUSED to move \"ledger.txt\" at /dst/ledger.txt back to its original location")
                && $0.contains("no longer the item that was moved here")
        }, "the move refusal still describes a removal; lines since the marker: \(lines)")
        #expect(lines.allSatisfy { !$0.contains("REFUSED to remove \"ledger.txt\"") },
                "no move refusal may say it was going to REMOVE the item")
        // And the refusal is not a failure: nothing the undo attempted went wrong, it chose not to
        // attempt anything. Counted as a restore failure, this run reported "1 restore failure(s)".
        #expect(lines.contains {
            $0.contains("moved 0 of 1 item(s) back to source, 0 restore failure(s), 1 left in place")
        }, "a deliberate refusal is still being tallied as a failure; lines since the marker: \(lines)")
    }

    /// Both directions again: an untouched move must still undo, or the guard is just an outage.
    @MainActor
    @Test func moveUndoOfAnUntouchedItemStillMovesItBack() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/doc.txt"] = file(100)

        let node = FileNode(id: "/src/doc.txt", name: "doc.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/doc.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("the move is reversed") { mockFM.virtualDisk["/src/doc.txt"] != nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/dst/doc.txt"] == nil)
    }

    // MARK: The third verdict

    /// An item whose state cannot be read is refused, not destroyed. This is the state the old
    /// `Int?` could not express at all: nil meant "no guard", so an unreadable item took the same
    /// path as a verified one.
    @MainActor
    @Test func copyUndoRefusesWhenTheDestinationCannotBeRead() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/locked"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/locked/a.png"] = file(10)

        let node = FileNode(id: "/src/locked", name: "locked", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/locked"] != nil)

        // The copy is still there but can no longer be listed — permissions changed, volume
        // trouble. Nothing can be concluded about whether it is still the copy.
        mockFM.unlistableDirectories = ["/dst/locked"]
        manager.banner = nil
        let marker = await plantLogMarker("copy-unreadable")

        manager.undoManager?.undo()
        await waitUntil("the unreadable copy is refused") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("couldn't be checked") == true,
                "an unverifiable item reports as unverifiable, not as changed")
        #expect(mockFM.virtualDisk["/dst/locked"] != nil, "an item that cannot be checked is not destroyed")
        // The log has to keep the two refusals apart too: "could not be read" is not evidence that
        // anything was edited, and a person reading the log acts differently on each.
        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to remove \"locked\" at /dst/locked")
                && $0.contains("its current state could not be read")
        }, "the indeterminate refusal log line is missing or reworded; lines since the marker: \(lines)")
        // Scoped to this fixture's own path — the window carries whatever the suites running
        // alongside logged, and "locked" is used by no other test here.
        #expect(lines.filter { $0.contains("/dst/locked") }
                     .allSatisfy { !$0.contains("it changed since the operation") },
                "an unreadable item must not be logged as a demonstrated change")
    }

    // MARK: 4 — a NESTED batch, where `to` is not where the item is

    /// The regression this file did not cover, and `f16aa66a` introduced.
    ///
    /// `normalizeNames` applies renames DEEPEST-first and registers the undo SHALLOWEST-first,
    /// both deliberately: the child renames inside its still-named parent, then the parent is
    /// renamed around it; the undo then restores the parent before the children inside it. So by
    /// the time registration runs, the child's recorded `to` — `<root>/Photos␣/a.txt`, spelling
    /// the OLD parent name — is a path that no longer exists.
    ///
    /// Measured on this exact fixture before the fix: the child snapshotted `.absent`; the undo
    /// restored the parent, making that path real again; `compare(.absent, .file)` answered
    /// `.changed`; and the child's rename was refused and never reversed. Disk was left at
    /// `<root>/Photos␣/a.txt` — parent name back, child name not — under the banner
    /// `Undo left "a.txt" in place — it changed since`: a half-undone pass, reported to the user
    /// as drift that never happened.
    ///
    /// Driven through the real filesystem rather than `MockFileManager`, whose `moveItem` of a
    /// DIRECTORY does not carry keys that were not in its `contents` list — a nested fixture would
    /// measure the double, not the code.
    @MainActor
    @Test func undoOfANestedNormalizePassReversesTheChildRenameToo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "NestedNormalizeUndo")
        defer { try? FileManager.default.removeItem(at: root) }

        // Zero-width spaces: risky to every provider, and robust on APFS (distinct entries, not
        // trimmed by URL handling) — unlike trailing-space or trailing-dot names.
        let riskyFolder = root.appendingPathComponent("Photos\u{200B}")
        let riskyChild = riskyFolder.appendingPathComponent("a\u{200B}.txt")
        try FileManager.default.createDirectory(at: riskyFolder, withIntermediateDirectories: true)
        try Data("child payload".utf8).write(to: riskyChild)

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        await manager.scanNames(root: root, provider: .iCloud)
        // The folder AND the file — a nested batch is the whole point of the fixture.
        #expect(manager.riskyNames.count == 2,
                "expected both the folder and the file to be flagged, got \(manager.riskyNames.map(\.currentName))")

        await manager.normalizeNames(manager.riskyNames)

        let safeFolder = root.appendingPathComponent("Photos")
        let safeChild = safeFolder.appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: safeChild.path), "the pass itself must land")
        #expect(!FileManager.default.fileExists(atPath: riskyFolder.path))

        manager.banner = nil
        let marker = await plantLogMarker("nested-normalize-undo")

        manager.undoManager?.undo()
        await waitUntil("the nested undo puts the risky child back") {
            FileManager.default.fileExists(atPath: riskyChild.path)
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // Every one of the three paths is back, and nothing of the normalized pass survives.
        #expect(FileManager.default.fileExists(atPath: riskyFolder.path))
        #expect(FileManager.default.fileExists(atPath: riskyChild.path))
        // `try?`, deliberately: a throwing read here would abort the test at the first missing
        // file and take the banner and log assertions below with it — exactly the evidence a
        // future regression needs to report.
        #expect((try? Data(contentsOf: riskyChild)) == Data("child payload".utf8),
                "the child must be the same file moved back, not a fresh one")
        #expect(!FileManager.default.fileExists(atPath: safeFolder.path),
                "the normalized folder name must be gone")
        #expect(!FileManager.default.fileExists(atPath: safeChild.path))
        #expect(manager.banner == nil,
                "a fully reversed pass raises no banner; got \(String(describing: manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("Undo (Normalize 2 Names): moved 2 of 2 item(s) back to source, 0 restore failure(s), 0 left in place")
        }, "the undo did not reverse both renames; lines since the marker: \(lines)")
        // Scoped to this fixture's unique temp root: the window also holds the lines of whatever
        // suites ran alongside, and a neighbour's legitimate refusal is not this test's business.
        #expect(lines.filter { $0.contains(root.path) }.allSatisfy { !$0.contains("REFUSED") },
                "nothing drifted, so nothing may be refused; lines since the marker: \(lines)")
    }

    /// The other half of the nested pass: ⌘⇧Z has to put the normalized names BACK.
    ///
    /// `normalizeNames` is careful about order in both directions — apply deepest-first, register
    /// the undo shallowest-first — and the redo was not. The undo appends its reversed params in
    /// `items` order (shallowest-first) and the redo replayed them in that same order, which is
    /// the wrong order for re-APPLYING: the parent is renamed back to `Photos` first, and the
    /// child's recorded `from` — `Photos␣/a␣.txt` — then names a path whose parent has just
    /// vanished. `createDirectory` manufactured that parent rather than letting the move fail, so
    /// a redo produced a brand-new EMPTY folder carrying exactly the risky name this feature
    /// exists to remove.
    ///
    /// Measured on this fixture before the fix:
    /// after ⌘⇧Z the tree was `["Photos", "Photos/a␣.txt", "Photos␣"]` under the banner
    /// `Redo couldn't re-apply "a.txt" — its source may no longer exist`.
    @MainActor
    @Test func redoOfANestedNormalizePassReAppliesBothRenames() async throws {
        let root = try makeCanonicalTempRoot(prefix: "NestedNormalizeRedo")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await stageNestedNormalizePass(root: root)

        f.manager.banner = nil
        let marker = await plantLogMarker("nested-normalize-redo")
        f.manager.undoManager?.undo()
        await waitUntil("the nested undo puts the risky child back") {
            FileManager.default.fileExists(atPath: f.riskyChild.path)
        }
        await waitUntil("undo op drains") { f.manager.activeFileOperationsCount == 0 }
        #expect(f.manager.banner == nil,
                "the undo leg must stay clean; got \(String(describing: f.manager.banner?.message))")

        f.manager.undoManager?.redo()
        await waitUntil("the nested redo re-applies the child rename") {
            FileManager.default.fileExists(atPath: f.safeChild.path)
        }
        await waitUntil("redo op drains") { f.manager.activeFileOperationsCount == 0 }

        #expect(treeUnder(root) == ["Photos", "Photos/a.txt"],
                "the redo must land exactly the pass it re-applies; tree is \(treeUnder(root))")
        #expect((try? Data(contentsOf: f.safeChild)) == Data("child payload".utf8),
                "the child must be the same file moved back, not a fresh one")
        #expect(f.manager.banner == nil,
                "a fully re-applied pass raises no banner; got \(String(describing: f.manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("Redo (Normalize 2 Names): moved 2 of 2 item(s), 0 redo failure(s)")
        }, "the redo did not re-apply both renames; lines since the marker: \(lines)")
        #expect(lines.filter { $0.contains(root.path) }.allSatisfy { !$0.contains("FAILED to redo") },
                "nothing was missing, so nothing may fail to redo; lines since the marker: \(lines)")
    }

    /// And the leg after that. A redo that re-applies in the wrong order also leaves the next
    /// UNDO unable to fix it: the stray `Photos␣` directory occupies the child's source, so the
    /// undo hits `restoreTargetOccupiedError`, reverses nothing, and the stack is dead — measured
    /// as "after ⌘Z again: unchanged" under `Undo couldn't restore the original of "Photos␣" —
    /// it may have been removed from the Trash`, which is also untrue (nothing was in the Trash).
    ///
    /// This leg is what proves the redo's own snapshot reads a LIVE path. Each re-applied item is
    /// snapshotted the moment it lands, before the shallower moves rename its ancestors, so the
    /// recorded `to` is where the item actually is — the guarantee `liveLocation` has to buy for
    /// `registerMoveUndo(items:)`, which snapshots after the whole batch instead.
    @MainActor
    @Test func undoAfterARedoOfANestedNormalizePassStillReversesBothRenames() async throws {
        let root = try makeCanonicalTempRoot(prefix: "NestedNormalizeRedoUndo")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await stageNestedNormalizePass(root: root)

        f.manager.undoManager?.undo()
        await waitUntil("the nested undo puts the risky child back") {
            FileManager.default.fileExists(atPath: f.riskyChild.path)
        }
        await waitUntil("undo op drains") { f.manager.activeFileOperationsCount == 0 }

        f.manager.undoManager?.redo()
        await waitUntil("the nested redo re-applies the child rename") {
            FileManager.default.fileExists(atPath: f.safeChild.path)
        }
        await waitUntil("redo op drains") { f.manager.activeFileOperationsCount == 0 }

        f.manager.banner = nil
        let marker = await plantLogMarker("nested-normalize-redo-undo")
        f.manager.undoManager?.undo()
        await waitUntil("the second undo puts the risky child back again") {
            FileManager.default.fileExists(atPath: f.riskyChild.path)
        }
        await waitUntil("second undo op drains") { f.manager.activeFileOperationsCount == 0 }

        #expect(treeUnder(root) == ["Photos<ZWSP>", "Photos<ZWSP>/a<ZWSP>.txt"],
                "the second undo must reverse the whole pass again; tree is \(treeUnder(root))")
        #expect((try? Data(contentsOf: f.riskyChild)) == Data("child payload".utf8))
        #expect(f.manager.banner == nil,
                "a fully reversed pass raises no banner; got \(String(describing: f.manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("Undo (Normalize 2 Names): moved 2 of 2 item(s) back to source, 0 restore failure(s), 0 left in place")
        }, "the undo after the redo did not reverse both renames; lines since the marker: \(lines)")
        #expect(lines.filter { $0.contains(root.path) }.allSatisfy { !$0.contains("REFUSED") },
                "nothing drifted, so nothing may be refused; lines since the marker: \(lines)")
    }

    /// A REFUSED nested undo must build nothing.
    ///
    /// The undo recreated `item.from`'s parent at the top of its loop, before deciding anything.
    /// For a nested batch whose shallow item has drifted, the deeper item's `from` spells the old
    /// ancestor name — so the loop manufactured `Photos␣`, the very name the pass had just
    /// removed, and only then refused the item it had built it for. An undo that declines to touch
    /// an item has to leave the disk exactly as it found it; a stray empty folder carrying a risky
    /// name is not "left in place".
    @MainActor
    @Test func aRefusedNestedUndoManufacturesNoDirectory() async throws {
        let root = try makeCanonicalTempRoot(prefix: "NestedNormalizeRefused")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await stageNestedNormalizePass(root: root)

        // Something lands in the normalized folder between the pass and the ⌘Z, so the folder is
        // no longer the item the rename produced and its restore is refused. The child's own
        // recorded destination is inside the folder's OLD name, which now stays unrestored.
        try Data("dropped in later".utf8).write(to: f.safeFolder.appendingPathComponent("extra.txt"))
        f.manager.banner = nil
        let marker = await plantLogMarker("nested-normalize-refused")

        f.manager.undoManager?.undo()
        await waitUntil("the drifted folder undo refuses") { f.manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { f.manager.activeFileOperationsCount == 0 }

        #expect(treeUnder(root) == ["Photos", "Photos/a.txt", "Photos/extra.txt"],
                "a refused undo may add nothing to the tree; tree is \(treeUnder(root))")
        #expect(!FileManager.default.fileExists(atPath: f.riskyFolder.path),
                "the risky folder name must not be manufactured by an undo that refused to restore it")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("Undo (Normalize 2 Names): moved 0 of 2 item(s) back to source, 0 restore failure(s), 2 left in place")
        }, "both items should have been refused, and neither counted as a failure; lines since the marker: \(lines)")
    }

    /// The redo's half of the same rule: a re-apply that cannot happen must build nothing for it.
    ///
    /// `createDirectory` ran unconditionally, so a redo whose source had gone still created the
    /// destination's parent and only then reported the failure — leaving an empty directory the
    /// user never asked for, at a path the undo had emptied. Staged flat and on the mock, because
    /// this is about the gate rather than about ordering: with the ordering fixed, the nested
    /// batch never reaches a missing source, so nothing else here can see this.
    @MainActor
    @Test func aRedoThatCannotReApplyBuildsNoDestinationForIt() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: url("/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/report.txt"] = file(64)

        let node = FileNode(id: "/src/report.txt", name: "report.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/report.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("the move is reversed") { mockFM.virtualDisk["/src/report.txt"] != nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // Between the ⌘Z and the ⌘⇧Z the user deletes both the file and the folder it had been
        // moved into. Neither is the redo's to recreate.
        mockFM.virtualDisk["/src/report.txt"] = nil
        mockFM.virtualDisk["/dst"] = nil
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the redo reports it cannot re-apply") { manager.banner?.severity == .warning }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("Redo couldn't re-apply \"report.txt\"") == true,
                "got \(String(describing: manager.banner?.message))")
        #expect(mockFM.virtualDisk["/dst"] == nil,
                "the redo must not rebuild a destination folder for a move that cannot happen")
        #expect(mockFM.virtualDisk["/dst/report.txt"] == nil)
    }

    /// Runs the risky-name pass the two redo tests share and hands back the manager and the four
    /// paths, having checked the pass itself landed.
    @MainActor
    private func stageNestedNormalizePass(
        root: URL, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (manager: FileSyncManager, riskyFolder: URL, riskyChild: URL, safeFolder: URL, safeChild: URL) {
        let riskyFolder = root.appendingPathComponent("Photos\u{200B}")
        let riskyChild = riskyFolder.appendingPathComponent("a\u{200B}.txt")
        try FileManager.default.createDirectory(at: riskyFolder, withIntermediateDirectories: true)
        try Data("child payload".utf8).write(to: riskyChild)

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        await manager.scanNames(root: root, provider: .iCloud)
        #expect(manager.riskyNames.count == 2,
                "expected both the folder and the file to be flagged, got \(manager.riskyNames.map(\.currentName))",
                sourceLocation: sourceLocation)
        await manager.normalizeNames(manager.riskyNames)

        let safeFolder = root.appendingPathComponent("Photos")
        let safeChild = safeFolder.appendingPathComponent("a.txt")
        #expect(treeUnder(root) == ["Photos", "Photos/a.txt"],
                "the pass itself must land; tree is \(treeUnder(root))", sourceLocation: sourceLocation)
        return (manager, riskyFolder, riskyChild, safeFolder, safeChild)
    }

    /// Every path under `root`, relative and sorted, with zero-width spaces spelled out so a
    /// failure message is readable — `["Photos<ZWSP>", "Photos<ZWSP>/a<ZWSP>.txt"]` rather than
    /// two strings that look identical to the normalized ones.
    private func treeUnder(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
            .map { $0.replacingOccurrences(of: "\u{200B}", with: "<ZWSP>") }
            .sorted()
    }

    // MARK: The batch-relative resolution itself

    /// `liveLocation` is what makes the snapshot above read the right path. Pinned directly as
    /// well as through the call site: the three-deep case and the cycle guard cannot be staged
    /// from `normalizeNames`, and a rule proven only end-to-end loses its edges.
    @Test func liveLocationRewritesOnlyAncestorsRenamedLaterInTheSameBatch() {
        // An empty disk, so the "still there?" confirmation never short-circuits a case that is
        // about the resolution itself. `liveLocationLeavesAnItemThatIsStillAtItsRecordedPath`
        // below is where that confirmation is measured.
        let empty = MockFileManager()

        // Three deep, applied deepest-first: the leaf's recorded `to` still spells BOTH old
        // ancestor names, and both have to be rewritten — resolving only the nearest one leaves a
        // path that is still wrong.
        let nested: [FileSyncManager.MoveItemState] = [
            (from: url("/root/A-BAD/B-BAD/c-BAD.txt"), to: url("/root/A-BAD/B-BAD/cOK.txt"), overwritten: nil),
            (from: url("/root/A-BAD/B-BAD"), to: url("/root/A-BAD/BOK"), overwritten: nil),
            (from: url("/root/A-BAD"), to: url("/root/AOK"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/A-BAD/B-BAD/cOK.txt"), afterBatch: nested, fileManager: empty)
                == url("/root/AOK/BOK/cOK.txt"))
        #expect(FileSyncManager.liveLocation(of: url("/root/A-BAD/BOK"), afterBatch: nested, fileManager: empty)
                == url("/root/AOK/BOK"))

        // A flat batch — every single-item call site, and every same-directory one — is untouched.
        //
        // Staged as a RENUMBERING CASCADE rather than two unrelated renames, so the assertion has
        // something to disprove: `02 - x.pdf` is one move's destination AND another move's source,
        // exactly the collision the "leaf is never rewritten" rule exists for. Written as two
        // unrelated renames (`a b.txt`→`a-b.txt` beside `c d.txt`→`c-d.txt`), the expected value
        // is the fallback, and an implementation that was nothing but `return destination` passed
        // it — as did one that resolved the WHOLE path instead of only the parent, which is the
        // mutation this now catches: it would answer `/root/03 - x.pdf` and snapshot the wrong
        // file entirely.
        let cascade: [FileSyncManager.MoveItemState] = [
            (from: url("/root/01 - x.pdf"), to: url("/root/02 - x.pdf"), overwritten: nil),
            (from: url("/root/02 - x.pdf"), to: url("/root/03 - x.pdf"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/02 - x.pdf"), afterBatch: cascade, fileManager: empty)
                == url("/root/02 - x.pdf"),
                "the LEAF must never be rewritten — an item is renamed once per batch, so its own name is final")

        // The same rule one level up, and the case the old "the shallowest item stays put"
        // assertion could not see: here the shallowest item's destination IS another move's
        // source, so a leaf-rewriting implementation answers `/root/B` instead of leaving it.
        let chain: [FileSyncManager.MoveItemState] = [
            (from: url("/root/A"), to: url("/root/B"), overwritten: nil),
            (from: url("/root/C"), to: url("/root/A"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/A"), afterBatch: chain, fileManager: empty)
                == url("/root/A"))
    }

    /// The cycle guard, pinned to the ONE path it produces rather than to "either lap".
    ///
    /// The previous assertion accepted both, which made it unfailable — and removing the `seen`
    /// guard it was meant to justify did not fail it either: the recursion never returns, and the
    /// test host dies with `unexpected signal code 10` and no `Test run with N tests` line at all,
    /// taking the rest of the run with it. Resolution is fully deterministic (the map is keyed by
    /// exact path, so dictionary ordering cannot reach it), so the exact answer can be named, and
    /// a mutation that keeps the recursion bounded but drops the guard's ANSWER — returning
    /// `renames[path]` instead of `path` on the second visit — fails it cleanly.
    @Test func liveLocationStopsAtOneLapOfACycle() {
        let cycle: [FileSyncManager.MoveItemState] = [
            (from: url("/root/X"), to: url("/root/Y"), overwritten: nil),
            (from: url("/root/Y"), to: url("/root/X"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/X/leaf.txt"), afterBatch: cycle,
                                            fileManager: MockFileManager())
                == url("/root/X/leaf.txt"),
                "X→Y→X closes the lap at X, so the parent resolves back to itself and the path is left alone")
    }

    /// The narrowing that keeps a NESTED PROVIDER ROOT from being falsely refused.
    ///
    /// `SettingsManager.existingSource` refuses only the SAME folder, so `/P` and `/P/Backup` can
    /// both be roots. A multi-select move across them orders by `id.count`, so the FOLDER
    /// `/P/Backup/D` moves first and `ensureParentDirectoryExists` then recreates `/P/Backup/D`
    /// under the file that lands second — the item arrives AFTER its ancestor moved, the inverse
    /// of the order the ancestor rewrite assumes. Resolving anyway walked the file off into
    /// `/P/Backup/Backup/D/file.txt`, snapshotted `.absent`, and the undo refused an item that had
    /// never drifted. The blast radius was only ever a bad READ — `item.to` still drives the move
    /// itself — but a false refusal is the thing `liveLocation` exists to prevent.
    ///
    /// The disk settles it: an item still sitting at its recorded destination did not go anywhere.
    @Test func liveLocationLeavesAnItemThatIsStillAtItsRecordedPath() throws {
        let batch: [FileSyncManager.MoveItemState] = [
            (from: url("/P/Backup/D"), to: url("/P/Backup/moved-D"), overwritten: nil),
            (from: url("/P/D/file.txt"), to: url("/P/Backup/D/file.txt"), overwritten: nil)
        ]

        // The file really is at its recorded `to`: the recreated `/P/Backup/D` holds it.
        let present = MockFileManager()
        try present.createDirectory(at: url("/P/Backup/D"), withIntermediateDirectories: true)
        present.virtualDisk["/P/Backup/D/file.txt"] = file(12)
        #expect(FileSyncManager.liveLocation(of: url("/P/Backup/D/file.txt"), afterBatch: batch, fileManager: present)
                == url("/P/Backup/D/file.txt"),
                "an item still at its recorded destination must be read there, not chased through the batch")

        // And the narrowing is not a blanket "never rewrite": with the destination genuinely gone
        // — the nested-rename case this whole seam exists for — the ancestor rewrite still runs.
        // Same batch, same query, opposite answer, so neither branch can be the fallback.
        #expect(FileSyncManager.liveLocation(of: url("/P/Backup/D/file.txt"), afterBatch: batch,
                                            fileManager: MockFileManager())
                == url("/P/Backup/moved-D/file.txt"))
    }

    /// Registering the undo for a large batch must stay LINEAR in the batch size.
    ///
    /// `registerMoveUndo(items:)` runs on the MAIN ACTOR, immediately after a bulk move, and calls
    /// `liveLocation` once per item. With the rename map built inside `liveLocation` it rebuilt
    /// the whole table from the whole batch every time — measured on this machine, debug build:
    /// n=100 → 0.015 s, n=1000 → 1.70 s, n=3000 → **14.6 s**, n=6000 → 52.1 s of frozen UI, and a
    /// multi-select move (`FileOperations.swift`) or a "Fix all" normalize pass can hand over
    /// thousands of items.
    ///
    /// **What this costs and why the ceiling is loose.** A timing assertion is a machine
    /// measurement, so it is written to separate two shapes rather than to police a budget: with
    /// the map hoisted this fixture takes tens of milliseconds here, and the ceiling is 3 s — over
    /// 100× the expected cost, and still under a FIFTH of the 14.6 s the quadratic form spent. A
    /// runner slow enough to fail this honestly would have to be ~100× this machine, and the same
    /// runner would take ~24 minutes to do it quadratically. The batch is flat (no nesting
    /// needed): the table was rebuilt per item regardless of shape.
    @MainActor
    @Test func theUndoRegistrationOfALargeBatchStaysLinear() async throws {
        let n = 3000
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/root"), withIntermediateDirectories: true)
        var items: [FileSyncManager.MoveItemState] = []
        items.reserveCapacity(n)
        for i in 0..<n {
            let to = "/root/renamed-\(i).txt"
            mockFM.virtualDisk[to] = file(i + 1)
            items.append((from: url("/root/original-\(i).txt"), to: url(to), overwritten: nil))
        }

        let manager = makeManager()
        let started = ContinuousClock.now
        manager.registerMoveUndo(items: items, actionName: "Move \(n) Items", fileManager: mockFM)
        let elapsed = started.duration(to: ContinuousClock.now)

        #expect(elapsed < .seconds(3),
                "registering \(n) items took \(elapsed) — quadratic registration is back (it cost 14.6 s at this size)")
        #expect(manager.undoManager?.canUndo == true, "the batch must actually have registered an undo")
    }

    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }
}
