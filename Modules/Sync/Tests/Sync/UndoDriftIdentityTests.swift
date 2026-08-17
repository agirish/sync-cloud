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
    @MainActor
    private func plantLogMarker(_ label: String) async -> String {
        let marker = "undo-drift-marker \(label) \(UUID().uuidString)"
        await Logger.shared.debug(marker).value
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
        await Logger.shared.debug("flush after \(marker)").value
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
    @MainActor
    @Test func copyUndoOfAFolderRefusesOnceItsContentsChanged() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/photos/a.jpg"] = file(10)

        let node = FileNode(id: "/src/photos", name: "photos", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/photos"] != nil)

        // Finder drops two more files into the copy. Finder never touches the undo stack.
        mockFM.virtualDisk["/dst/photos/new1.jpg"] = file(20)
        mockFM.virtualDisk["/dst/photos/new2.jpg"] = file(30)
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
            $0.contains("REFUSED to remove \"photos\" at /dst/photos")
                && $0.contains("it changed since the operation")
                && $0.contains("no longer the item this undo produced")
        }, "the refusal log line is missing or reworded; lines since the marker: \(lines)")
        #expect(mockFM.virtualDisk["/dst/photos"] != nil, "the copied folder must still be on disk")
        #expect(mockFM.virtualDisk["/dst/photos/new1.jpg"] != nil, "the files added since must survive")
        #expect(mockFM.virtualDisk["/dst/photos/new2.jpg"] != nil)
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

    /// The regression this file did not cover, and `3df70dbd` introduced.
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

    // MARK: The batch-relative resolution itself

    /// `liveLocation` is what makes the snapshot above read the right path. Pinned directly as
    /// well as through the call site: the three-deep case and the cycle guard cannot be staged
    /// from `normalizeNames`, and a rule proven only end-to-end loses its edges.
    @Test func liveLocationRewritesOnlyAncestorsRenamedLaterInTheSameBatch() {
        func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

        // A flat batch (every single-item call site, and every same-directory one): untouched.
        let flat: [FileSyncManager.MoveItemState] = [
            (from: url("/root/a b.txt"), to: url("/root/a-b.txt"), overwritten: nil),
            (from: url("/root/c d.txt"), to: url("/root/c-d.txt"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/a-b.txt"), afterBatch: flat)
                == url("/root/a-b.txt"))

        // Three deep, applied deepest-first: the leaf's recorded `to` still spells BOTH old
        // ancestor names, and both have to be rewritten — resolving only the nearest one leaves a
        // path that is still wrong.
        let nested: [FileSyncManager.MoveItemState] = [
            (from: url("/root/A-BAD/B-BAD/c-BAD.txt"), to: url("/root/A-BAD/B-BAD/cOK.txt"), overwritten: nil),
            (from: url("/root/A-BAD/B-BAD"), to: url("/root/A-BAD/BOK"), overwritten: nil),
            (from: url("/root/A-BAD"), to: url("/root/AOK"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/A-BAD/B-BAD/cOK.txt"), afterBatch: nested)
                == url("/root/AOK/BOK/cOK.txt"))
        #expect(FileSyncManager.liveLocation(of: url("/root/A-BAD/BOK"), afterBatch: nested)
                == url("/root/AOK/BOK"))
        // The shallowest item was never nested under anything: it stays put.
        #expect(FileSyncManager.liveLocation(of: url("/root/AOK"), afterBatch: nested)
                == url("/root/AOK"))

        // A rename CYCLE must terminate rather than chase itself forever.
        let cycle: [FileSyncManager.MoveItemState] = [
            (from: url("/root/X"), to: url("/root/Y"), overwritten: nil),
            (from: url("/root/Y"), to: url("/root/X"), overwritten: nil)
        ]
        let resolved = FileSyncManager.liveLocation(of: url("/root/X/leaf.txt"), afterBatch: cycle)
        #expect(resolved == url("/root/X/leaf.txt") || resolved == url("/root/Y/leaf.txt"),
                "a cycle may resolve to either lap, but it must resolve")
    }
}
