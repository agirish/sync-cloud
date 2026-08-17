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
/// **`.serialized`, and it is load-bearing rather than tidy.** Two tests here —
/// `undoOfANestedNormalizePassReversesTheChildRenameToo` and
/// `undoAfterARedoOfANestedNormalizePassStillReversesBothRenames` — assert the BYTE-IDENTICAL log
/// line `Undo (Normalize 2 Names): moved 2 of 2 item(s) back to source, 0 restore failure(s), 0
/// left in place`. No other file in the package can write it (grepped: `Normalize 2 Names` appears
/// in this file alone), so the exposure is entirely between these two siblings — and both are
/// `@MainActor` but both suspend at `waitUntil`, so run in parallel they interleave.
///
/// **Measured, three runs each way.** Remove the second test's own undo, so it produces no line at
/// all, and delay the sibling so its identical line lands inside the second test's window: the
/// presence assertion PASSED, satisfied by a line its own code never wrote. It passed just the same
/// with the window bounded strictly between this suite's own markers — bounding keeps out lines
/// from before and after, and this one is INSIDE. Serialized, the same mutation fails immediately
/// (3 issues → 4). `docs/flaky-tests.md` mechanism 11 ("A log assertion reading a window that has
/// already rolled") names both halves and this suite needs both:
/// rule 2 bounds the window, rule 4 is what stops a concurrent sibling writing into it. CI runs
/// this target WITHOUT `--no-parallel`, so parallel is the configuration that ships. The whole
/// suite costs about half a second, so serializing it is free.
@Suite(.serialized) struct UndoDriftIdentityTests {

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

    /// The messages logged strictly BETWEEN `marker` and a closing marker written here — rule 2 of
    /// `docs/flaky-tests.md` mechanism 11 ("A log assertion reading a window that has already
    /// rolled"), both halves of it.
    ///
    /// The opening marker is the eviction guard: if the 1000-entry cap rolled past it, the window
    /// this would return is a fiction, and saying so is the whole point of planting it.
    ///
    /// **The closing marker is the half this was missing, and it was silently costing coverage.**
    /// This used to slice `entries[start...]` — open-ended, all the way to whatever had been logged
    /// by the time the assertion ran — on the stated ground that every assertion here matches a
    /// string unique to its own fixture. That is not true of this file: the nested-normalize undo
    /// test and its undo-after-redo sibling assert the BYTE-IDENTICAL line `Undo (Normalize 2
    /// Names): moved 2 of 2 item(s) back to source, 0 restore failure(s), 0 left in place`, both
    /// are `@MainActor` but both suspend at `waitUntil`, so they interleave, and either could
    /// satisfy the other's presence assertion while its own code did nothing. CI runs this target
    /// WITHOUT `--no-parallel`, so that is the configuration it ships under. Bounding the top costs
    /// one line and closes it.
    ///
    /// The window is still a SUPERSET of this test's own lines — suites in this target run in
    /// parallel against one shared `Logger`, so a neighbour's lines land inside it — which is why
    /// absence assertions filter it down to lines naming this test's own paths first. An unfiltered
    /// `allSatisfy` over the window asserts something about whatever else happened to be running,
    /// which is how the first draft of this suite failed.
    ///
    /// Both indices are resolved and guarded BEFORE anything is sliced, and `start` is searched for
    /// only in `entries[..<end]`, so the bounds cannot be reversed: `entries[a..<b]` on reversed
    /// bounds TRAPS, and a trap here takes the whole test host down and loses every other verdict
    /// in the run.
    @MainActor
    private func logLines(since marker: String,
                          sourceLocation: SourceLocation = #_sourceLocation) async -> [String] {
        let closing = "undo-drift-close \(marker)"
        await Logger.shared.info(closing).value
        let entries = Logger.shared.entries
        guard let end = entries.lastIndex(where: { $0.message == closing }) else {
            Issue.record("""
                this test's own CLOSING marker is not in the log at all — the window cannot be \
                bounded, so nothing can be concluded about the refusal line
                """, sourceLocation: sourceLocation)
            return []
        }
        guard let start = entries[..<end].lastIndex(where: { $0.message == marker }) else {
            Issue.record("""
                the log window rolled past this test's own marker — the 1000-entry cap evicted it, \
                so nothing can be concluded about the refusal line
                """, sourceLocation: sourceLocation)
            return []
        }
        return entries[start..<end].map(\.message)
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

    /// The moved item is GONE — the user deleted it themselves between the move and the ⌘Z.
    ///
    /// Not drift: there is nothing at the destination to be a stranger. The copy-undo has said so
    /// explicitly since before the drift guard existed ("a copy the user already deleted
    /// themselves: nothing to trash"), and the move-REDO says it too ("a source that is simply
    /// GONE is not drift"). Only the move-UNDO fell through to the drift comparison, where
    /// `.absent` differs from the recorded identity and so reported the item as *changed*.
    ///
    /// Two things are wrong with that, and the second is the one that costs the user something:
    /// the sentence is false, and the ORIGINAL this move displaced stays stranded in the Trash —
    /// where the vanished branch is exactly the place to bring it back, because the destination is
    /// now empty and nothing can be clobbered by restoring it.
    @MainActor
    @Test func moveUndoOfAnItemTheUserDeletedRestoresWhatTheMoveDisplaced() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/report.txt"] = file(100, modified: Date(timeIntervalSince1970: 1_000))
        // An older file already at the destination: the move displaces it to the Trash, and undo
        // is what is supposed to bring it back.
        mockFM.virtualDisk["/dst/report.txt"] = file(42, modified: Date(timeIntervalSince1970: 500))

        let node = FileNode(id: "/src/report.txt", name: "report.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/report.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(mockFM.virtualDisk["/src/report.txt"] == nil)

        // The user deletes the moved file in Finder before pressing ⌘Z.
        mockFM.virtualDisk["/dst/report.txt"] = nil
        manager.banner = nil
        let marker = await plantLogMarker("move-destination-vanished")

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        let lines = await logLines(since: marker)
        // It must not be reported as a change: nothing changed, the item is gone.
        #expect(lines.allSatisfy { !$0.contains("REFUSED") },
                "a vanished item is not a refusal; lines since the marker: \(lines)")
        #expect(manager.banner?.message.contains("changed since") != true,
                "the banner still claims the deleted item changed: \(String(describing: manager.banner))")
        #expect(lines.contains { $0.contains("report.txt is no longer on disk") },
                "the vanished item is not named in the log; lines since the marker: \(lines)")
        // The displaced original comes back, which is the whole remaining point of this undo.
        #expect(mockFM.virtualDisk["/dst/report.txt"]?.attributes?[FileAttributeKey.size] as? Int == 42,
                "the file the move displaced is still stranded in the Trash")
        // And nothing is invented at the source: the item the user deleted stays deleted.
        #expect(mockFM.virtualDisk["/src/report.txt"] == nil)
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

    // MARK: 5 — an occupied recorded path is not proof of identity

    /// The regression the previous round introduced, and the reason `liveLocation` now asks the
    /// disk about the REWRITTEN path instead of the recorded one.
    ///
    /// `fileExists(destination)` cannot tell OUR item from ANY item. Let a normalize pass turn
    /// `<root>/P␣/a␣.txt` into `<root>/P/a.txt`, then let the user recreate `<root>/P␣` with an
    /// unrelated `a.txt` in it, and the recorded destination is occupied again — by a stranger. The
    /// "if it is still there it did not go anywhere" short-circuit then snapshotted the STRANGER,
    /// the undo's drift guard compared the stranger against itself, answered `.unchanged`, and
    /// moved it.
    ///
    /// Measured on this exact fixture before the fix — our child 13 bytes, the stranger 4242:
    ///
    /// ```
    /// <root>/P/a.txt              <- OUR file. NEVER REVERSED.
    /// <root>/P␣/a␣.txt            <- the STRANGER's file, RENAMED to the risky name
    /// banner = Undo couldn't restore the original of "P␣" — it may have been removed from the Trash
    /// ```
    ///
    /// So the undo planted a zero-width space in an unrelated user file's name — the exact hazard
    /// the feature exists to remove — left the real item un-undone, and the only banner named a
    /// different item and blamed the Trash, which nothing went near. Under the design this replaced
    /// (rewrite unconditionally) the same situation was a safe REFUSAL, so the change converted a
    /// false refusal into a wrong-item move.
    ///
    /// Driven by calling `registerMoveUndo(items:)` with `normalizeNames`' exact shallowest-first
    /// batch, rather than through `normalizeNames` itself: the snapshot is taken at REGISTRATION
    /// time, so the stranger has to already be on disk when registration runs. That is the shape of
    /// every call site — the batch is applied asynchronously and registered afterwards, and the
    /// disk can move underneath it — and it is what the original probe drove. Real filesystem, for
    /// the same reason the nested tests use one: `MockFileManager.moveItem` of a DIRECTORY would
    /// measure the double.
    @MainActor
    @Test func undoRefusesAStrangerSittingOnTheRecordedDestination() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StrangerAtRecordedPath")
        defer { try? FileManager.default.removeItem(at: root) }

        let riskyFolder = root.appendingPathComponent("P\u{200B}")
        let riskyChild = riskyFolder.appendingPathComponent("a\u{200B}.txt")
        let safeFolder = root.appendingPathComponent("P")
        let safeChild = safeFolder.appendingPathComponent("a.txt")
        let strangerChild = riskyFolder.appendingPathComponent("a.txt")

        // The state the pass leaves behind: our item normalized...
        try FileManager.default.createDirectory(at: safeFolder, withIntermediateDirectories: true)
        try Data("child payload".utf8).write(to: safeChild)          // 13 bytes, ours
        // ...and the user has since recreated the risky folder with an unrelated file in it, whose
        // name happens to be the one the pass gave ours.
        try FileManager.default.createDirectory(at: riskyFolder, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4242).write(to: strangerChild)

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }

        // `normalizeNames`' batch, shallowest-first, exactly as it registers it: the child was
        // renamed inside its still-risky parent, so its recorded `to` is `<root>/P␣/a.txt` — the
        // very path the stranger now occupies.
        let batch: [FileSyncManager.MoveItemState] = [
            (from: riskyFolder, to: safeFolder, overwritten: nil),
            (from: riskyChild, to: strangerChild, overwritten: nil)
        ]
        manager.registerMoveUndo(items: batch, actionName: "Normalize 2 Names",
                                 fileManager: FileManager.default)

        manager.banner = nil
        let marker = await plantLogMarker("stranger-at-recorded-path")
        manager.undoManager?.undo()
        await waitUntil("the undo refuses something") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // The stranger keeps its OWN name. This is the assertion the bug fails: it used to become
        // `a␣.txt`.
        #expect(treeUnder(root) == ["P", "P/a.txt", "P<ZWSP>", "P<ZWSP>/a.txt"],
                "an undo may not rename an unrelated file; tree is \(treeUnder(root))")
        #expect(!FileManager.default.fileExists(atPath: riskyChild.path),
                "the risky name must not be planted on a file that was never part of the pass")
        #expect((try? Data(contentsOf: strangerChild))?.count == 4242,
                "the stranger's contents must be untouched")
        #expect((try? Data(contentsOf: safeChild)) == Data("child payload".utf8),
                "our own item must be left exactly where the pass put it")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to move \"a.txt\" at \(strangerChild.path) back to its original location")
                && $0.contains("no longer the item that was moved here")
        }, "the stranger was not refused; lines since the marker: \(lines)")
        // One refusal (the child) and one occupied source (the folder, whose original location the
        // recreated directory holds) — and nothing moved at all.
        #expect(lines.contains {
            $0.contains("Undo (Normalize 2 Names): moved 0 of 2 item(s) back to source, 1 restore failure(s), 1 left in place")
        }, "the undo moved something it should have refused; lines since the marker: \(lines)")
    }

    // MARK: 6 — the redo checks identity too

    /// The redo gated on the SOURCE PATH existing and moved whatever was there.
    ///
    /// Measured before the fix — move `/redo-src/stranger.txt` → `/redo-dst/stranger.txt`, ⌘Z, then
    /// the user creates a DIFFERENT `/redo-src/stranger.txt` (999 bytes) and an unrelated
    /// `/redo-dst/stranger.txt` (555 bytes), then ⌘⇧Z:
    ///
    /// ```
    /// after the redo: /redo-dst/stranger.txt size = 999, /redo-src/stranger.txt = gone, banner = nil
    /// ```
    ///
    /// The redo relocated a file the user had just created, replaced an unrelated file at the
    /// destination, and reported NOTHING — no log line and no banner. The undo path has refused
    /// this exact situation since `ItemIdentity` landed; the redo had no equivalent at all.
    @MainActor
    @Test func redoRefusesASourceTheUserReplacedAfterTheUndo() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/redo-src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: url("/redo-dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/redo-src/stranger.txt"] = file(64, modified: Date(timeIntervalSince1970: 1_000))

        let node = FileNode(id: "/redo-src/stranger.txt", name: "stranger.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/redo-dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/redo-dst/stranger.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("the move is reversed") { mockFM.virtualDisk["/redo-src/stranger.txt"] != nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // Between the ⌘Z and the ⌘⇧Z the user writes a DIFFERENT file at the source path, and an
        // unrelated one at the destination. Neither is the redo's to touch.
        mockFM.virtualDisk["/redo-src/stranger.txt"] = file(999, modified: Date(timeIntervalSince1970: 9_999))
        mockFM.virtualDisk["/redo-dst/stranger.txt"] = file(555, modified: Date(timeIntervalSince1970: 8_888))
        manager.banner = nil
        let marker = await plantLogMarker("redo-source-replaced")

        manager.undoManager?.redo()
        await waitUntil("the redo refuses the replaced source") { manager.banner?.severity == .warning }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message == "Redo left \"stranger.txt\" in place — it changed since",
                "got \(String(describing: manager.banner?.message))")
        #expect(mockFM.virtualDisk["/redo-src/stranger.txt"]?.attributes?[FileAttributeKey.size] as? Int == 999,
                "the file the user had just created must not be relocated by a redo")
        #expect(mockFM.virtualDisk["/redo-dst/stranger.txt"]?.attributes?[FileAttributeKey.size] as? Int == 555,
                "the unrelated file at the destination must not be replaced by a redo")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to re-apply \"stranger.txt\" from /redo-src/stranger.txt")
                && $0.contains("it changed since the undo put it back")
        }, "the redo refusal log line is missing or reworded; lines since the marker: \(lines)")
        #expect(lines.contains {
            $0.contains("Redo (Move 1 Items): moved 0 of 1 item(s), 0 redo failure(s), 1 left in place")
        }, "a redo refusal is not being tallied; lines since the marker: \(lines)")
    }

    /// The other half of the redo guard: an untouched source must still redo, or the guard is an
    /// outage. Same fixture, same steps, nothing edited in between — and the opposite answer, so
    /// neither test can be passing on the fallback.
    @MainActor
    @Test func redoOfAnUntouchedSourceStillReAppliesTheMove() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/redo-ok-src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: url("/redo-ok-dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/redo-ok-src/kept.txt"] = file(64, modified: Date(timeIntervalSince1970: 1_000))

        let node = FileNode(id: "/redo-ok-src/kept.txt", name: "kept.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/redo-ok-dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/redo-ok-dst/kept.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("the move is reversed") { mockFM.virtualDisk["/redo-ok-src/kept.txt"] != nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the move is re-applied") { mockFM.virtualDisk["/redo-ok-dst/kept.txt"] != nil }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/redo-ok-src/kept.txt"] == nil, "the redo must move it, not copy it")
        #expect(mockFM.virtualDisk["/redo-ok-dst/kept.txt"]?.attributes?[FileAttributeKey.size] as? Int == 64)
        #expect(manager.banner == nil,
                "an unedited source raises no banner; got \(String(describing: manager.banner?.message))")
    }

    // MARK: 7 — WHEN the redo checks, not just whether

    /// The gate the round above added verified every source in an up-front pass and then moved
    /// every source, so anything that changed **in between** was moved unchecked — which is
    /// verbatim the bug that pass was added to fix, moved one step later in the same function.
    ///
    /// **Both existing redo tests are single-item, and that is exactly why this shipped**: with one
    /// param the pre-pass and an in-loop check are indistinguishable, so neither of them can tell
    /// the two shapes apart. The window for item *k* of *N* is (N−k stats) plus (k−1 real
    /// filesystem moves — the previous items of the batch), and this file's own registration
    /// benchmark uses 3,000-item batches, so on the sizes it designs for the window is seconds
    /// wide. The app's subject matter is cloud-synced folders, where a provider daemon
    /// materialises files asynchronously.
    ///
    /// Measured on this fixture before the fix — a stranger written at `/tsrc/a.txt` while
    /// `bb.txt` was moving, i.e. after `a.txt`'s up-front check had already passed:
    ///
    /// ```
    /// afterUndo:  /tsrc/a.txt=10    /tsrc/bb.txt=20
    /// afterRedo:  /tdst/a.txt=8888  /tdst/bb.txt=20   banner=nil
    /// ```
    ///
    /// 8888 is the stranger, relocated with no guard and no report.
    @MainActor
    @Test func redoRefusesASourceReplacedWhileAnEarlierItemOfTheSameBatchMoved() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/tsrc"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: url("/tdst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/tsrc/a.txt"] = file(10)
        mockFM.virtualDisk["/tsrc/bb.txt"] = file(20)

        // The two names are DIFFERENT LENGTHS on purpose. `pruneNestedNodes` orders the selection
        // by path length with `sorted(by:)`, which Swift does not promise is stable, so two
        // equal-length names would hand the batch over in an order that can differ between runs —
        // and which item moves first is the whole fixture. `a.txt` shorter than `bb.txt` pins the
        // batch as [a, bb], hence redo params [a, bb], hence a replay of [bb, a].
        let nodes = [FileNode(id: "/tsrc/a.txt", name: "a.txt", isDirectory: false),
                     FileNode(id: "/tsrc/bb.txt", name: "bb.txt", isDirectory: false)]
        await manager.moveItems(nodes: nodes, toPath: "/tdst", fileManager: mockFM)
        try #require(mockFM.virtualDisk["/tdst/a.txt"] != nil)
        try #require(mockFM.virtualDisk["/tdst/bb.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("both moves are reversed") {
            mockFM.virtualDisk["/tsrc/a.txt"] != nil && mockFM.virtualDisk["/tsrc/bb.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        let afterUndo = probe(mockFM, ["/tsrc/a.txt", "/tsrc/bb.txt", "/tdst/a.txt", "/tdst/bb.txt"])
        #expect(afterUndo == "/tsrc/a.txt=10  /tsrc/bb.txt=20",
                "the undo leg must put both files back before the redo is measured; got \(afterUndo)")

        // A stranger takes `a.txt`'s place WHILE `bb.txt` is moving — after `a.txt`'s up-front
        // check has passed and before its own move runs. One-shot, by nilling the hook, so the
        // redo's own bookkeeping moves cannot re-arm it.
        mockFM.beforeCopyItem = { src in
            guard src == "/tsrc/bb.txt" else { return }
            mockFM.beforeCopyItem = nil
            mockFM.virtualDisk["/tsrc/a.txt"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [FileAttributeKey.size: 8888,
                             FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 8_888)],
                contents: nil)
        }
        manager.banner = nil
        let marker = await plantLogMarker("redo-source-replaced-mid-batch")

        manager.undoManager?.redo()
        await waitUntil("the redo re-applies the item that did not drift") {
            mockFM.virtualDisk["/tdst/bb.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        let afterRedo = probe(mockFM, ["/tsrc/a.txt", "/tsrc/bb.txt", "/tdst/a.txt", "/tdst/bb.txt"])
        #expect(afterRedo == "/tsrc/a.txt=8888  /tdst/bb.txt=20",
                "the stranger must stay where the user put it and only bb.txt may be re-applied; got \(afterRedo)")
        #expect(manager.banner?.message == "Redo left \"a.txt\" in place — it changed since",
                "got \(String(describing: manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to re-apply \"a.txt\" from /tsrc/a.txt")
                && $0.contains("it changed since the undo put it back")
        }, "the mid-batch replacement was not refused; lines since the marker: \(lines)")
        #expect(lines.contains {
            $0.contains("Redo (Move 2 Items): moved 1 of 2 item(s), 0 redo failure(s), 1 left in place")
        }, "the tally does not report one refusal and one re-apply; lines since the marker: \(lines)")
    }

    /// The other half of the same hole: an `.absent` source skipped the identity check ENTIRELY.
    ///
    /// The pre-pass short-circuited on `.absent` — "nothing is there to be a stranger" — and for
    /// those params the recorded identity was then never consulted at any point. The replay's own
    /// `fileExists` re-test let whatever had appeared in the meantime be moved. The reasoning is
    /// true at the stat and false at the move: absence is a licence to skip the check only if it
    /// is re-confirmed where the destruction happens.
    ///
    /// Measured on this fixture before the fix — the user deletes `y.txt` after the undo, then
    /// writes an unrelated `y.txt` while `xx.txt` is moving:
    ///
    /// ```
    /// afterUndo:  /dsrc/xx.txt=10
    /// afterRedo:  /ddst/xx.txt=10  /ddst/y.txt=7777   banner=nil
    /// ```
    ///
    /// 7777 is the user's brand-new file, relocated with no guard and no report.
    @MainActor
    @Test func redoRefusesASourceFilledAfterItWasFoundAbsent() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/dsrc"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: url("/ddst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dsrc/y.txt"] = file(20)
        mockFM.virtualDisk["/dsrc/xx.txt"] = file(10)

        // Lengths pin the order again, and this time the SHORTER name has to be the absent one:
        // the batch is registered [y, xx], so the redo params are [y, xx] and the replay is
        // [xx, y] — `xx.txt` moves first and `y.txt`, the absent source, moves last.
        let nodes = [FileNode(id: "/dsrc/y.txt", name: "y.txt", isDirectory: false),
                     FileNode(id: "/dsrc/xx.txt", name: "xx.txt", isDirectory: false)]
        await manager.moveItems(nodes: nodes, toPath: "/ddst", fileManager: mockFM)
        try #require(mockFM.virtualDisk["/ddst/y.txt"] != nil)
        try #require(mockFM.virtualDisk["/ddst/xx.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("both moves are reversed") {
            mockFM.virtualDisk["/dsrc/y.txt"] != nil && mockFM.virtualDisk["/dsrc/xx.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // The user deletes the restored y.txt themselves, so its source is genuinely ABSENT when
        // the redo's up-front pass looks at it...
        mockFM.virtualDisk["/dsrc/y.txt"] = nil
        let afterUndo = probe(mockFM, ["/dsrc/xx.txt", "/dsrc/y.txt", "/ddst/xx.txt", "/ddst/y.txt"])
        #expect(afterUndo == "/dsrc/xx.txt=10",
                "only the surviving source may be on disk when the redo starts; got \(afterUndo)")

        // ...and then writes a NEW, unrelated y.txt while xx.txt is moving.
        mockFM.beforeCopyItem = { src in
            guard src == "/dsrc/xx.txt" else { return }
            mockFM.beforeCopyItem = nil
            mockFM.virtualDisk["/dsrc/y.txt"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [FileAttributeKey.size: 7777,
                             FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 7_777)],
                contents: nil)
        }
        manager.banner = nil
        let marker = await plantLogMarker("redo-absent-source-refilled")

        manager.undoManager?.redo()
        await waitUntil("the redo re-applies the item whose source survived") {
            mockFM.virtualDisk["/ddst/xx.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        let afterRedo = probe(mockFM, ["/dsrc/xx.txt", "/dsrc/y.txt", "/ddst/xx.txt", "/ddst/y.txt"])
        #expect(afterRedo == "/dsrc/y.txt=7777  /ddst/xx.txt=10",
                "the file the user had just created must not be relocated by a redo; got \(afterRedo)")
        #expect(manager.banner?.message == "Redo left \"y.txt\" in place — it changed since",
                "got \(String(describing: manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to re-apply \"y.txt\" from /dsrc/y.txt")
                && $0.contains("it changed since the undo put it back")
        }, "the refilled source was not refused; lines since the marker: \(lines)")
        #expect(lines.contains {
            $0.contains("Redo (Move 2 Items): moved 1 of 2 item(s), 0 redo failure(s), 1 left in place")
        }, "the tally does not report one refusal and one re-apply; lines since the marker: \(lines)")
    }

    // MARK: 8 — a recorded `.absent` is not an identity

    /// `compare(.absent, .absent)` answers `.unchanged`, which is true and useless: it says nothing
    /// changed, and the move-undo read it as "this is still my item, go ahead".
    ///
    /// The `vanished` branch above needs the destination's PARENT to exist, so an item whose
    /// recorded destination AND its parent are both missing falls through to the drift guard —
    /// where a recorded `.absent` meets a live `.absent`, votes `.unchanged`, and selects the MOVE
    /// branch. Its first act is `createDirectory(item.from's parent)`, and only then does
    /// `safeMoveItem` throw. So an undo that could never do anything still manufactured a folder,
    /// carrying the very zero-width-space name the normalize pass exists to remove — contradicting
    /// the invariant stated four lines above the `createDirectory` call, that "a refused item must
    /// leave the disk exactly as it found it".
    ///
    /// Measured on this fixture before the fix:
    ///
    /// ```
    /// disk before ⌘Z:  ["/root"]
    /// disk after  ⌘Z:  ["/root", "/root/P<ZWSP>"]
    /// ```
    ///
    /// Driven by registering the batch directly, because that is what produces a recorded
    /// `.absent`: `registerMoveUndo(items:)` snapshots at registration time, so a destination that
    /// is not on disk when registration runs records the absence itself.
    @MainActor
    @Test func undoOfAnItemNeverRecordedOnDiskManufacturesNoDirectory() async throws {
        let root = try makeCanonicalTempRoot(prefix: "AbsentRecordedIdentity")
        defer { try? FileManager.default.removeItem(at: root) }

        let riskyChild = root.appendingPathComponent("P\u{200B}").appendingPathComponent("a\u{200B}.txt")
        let safeChild = root.appendingPathComponent("P").appendingPathComponent("a.txt")

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }

        // Nothing under `root` at all — neither the recorded destination nor its parent, which is
        // what keeps the `vanished` branch from firing and sends this down the drift guard.
        try #require(treeUnder(root) == [])

        manager.registerMoveUndo(items: [(from: riskyChild, to: safeChild, overwritten: nil)],
                                 actionName: "Normalize 1 Name", fileManager: FileManager.default)

        manager.banner = nil
        let marker = await plantLogMarker("absent-recorded-identity")
        manager.undoManager?.undo()
        await waitUntil("the undo reports that it could not act") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(treeUnder(root) == [],
                "an undo with nothing to move back may build nothing; tree is \(treeUnder(root))")
        #expect(manager.banner?.message == "Undo left \"a.txt\" in place — there was nothing to move back",
                "got \(String(describing: manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to move \"a.txt\" back to its original location")
                && $0.contains("nothing was recorded at \(safeChild.path)")
        }, "the refusal line is missing or reworded; lines since the marker: \(lines)")
        #expect(lines.contains {
            $0.contains("Undo (Normalize 1 Name): moved 0 of 1 item(s) back to source, 0 restore failure(s), 0 left in place")
                && $0.contains("1 with nothing recorded to move back")
        }, "the tally does not separate 'nothing recorded' from a genuine failure; lines since the marker: \(lines)")
    }

    /// **The same refusal, with the destination's parent on disk — which is the ordinary shape.**
    ///
    /// The test above deliberately empties the root so the `vanished` branch cannot fire, and that
    /// makes it blind to the case a normalize batch actually produces: a child renamed inside a
    /// folder that exists, whose destination was not on disk when the undo was registered. There,
    /// `parentExists` is true and `item.to` is missing, so the `vanished` branch claimed the item
    /// first and reported "no longer on disk" — which says the user removed it, and a recorded
    /// `.absent` says the opposite. The banner that tells them the undo refused was lost with it:
    /// `vanished` only logs.
    ///
    /// Both branches decline to act, so nothing was manufactured either way — this is about what
    /// the user is told, and about the two counters staying separate.
    @MainActor
    @Test func anUnrecordedItemIsRefusedAsSuchEvenWhenItsParentExists() async throws {
        let root = try makeCanonicalTempRoot(prefix: "AbsentRecordedParentExists")
        defer { try? FileManager.default.removeItem(at: root) }

        // The parent IS on disk — the whole difference from the test above.
        let parent = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let riskyChild = parent.appendingPathComponent("a\u{200B}.txt")
        let safeChild = parent.appendingPathComponent("a.txt")

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }

        try #require(!FileManager.default.fileExists(atPath: safeChild.path))
        try #require(FileManager.default.fileExists(atPath: parent.path),
                     "the fixture stopped exercising the shadowed branch")

        manager.registerMoveUndo(items: [(from: riskyChild, to: safeChild, overwritten: nil)],
                                 actionName: "Normalize 1 Name", fileManager: FileManager.default)

        manager.banner = nil
        let marker = await plantLogMarker("absent-recorded-parent-exists")
        manager.undoManager?.undo()
        await waitUntil("the undo reports that it could not act") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message == "Undo left \"a.txt\" in place — there was nothing to move back",
                "got \(String(describing: manager.banner?.message))")
        let lines = await logLines(since: marker)
        #expect(!lines.contains { $0.contains("a.txt is no longer on disk") },
                "reported as removed by the user an item that was never recorded on disk")
        #expect(lines.contains {
            $0.contains("Undo (Normalize 1 Name): moved 0 of 1 item(s) back to source, 0 restore failure(s), 0 left in place")
                && $0.contains("1 with nothing recorded to move back")
        }, "the tally counted this as vanished rather than unrecorded; lines: \(lines)")
    }

    /// `path=size` for each of `paths` that is on the virtual disk, in the order given — the shape
    /// the probes in the three doc comments above are written in, so a failure prints the same
    /// table the defect was measured with rather than four separate expectations.
    private func probe(_ fm: MockFileManager, _ paths: [String]) -> String {
        paths.compactMap { path in
            (fm.virtualDisk[path]?.attributes?[FileAttributeKey.size] as? Int).map { "\(path)=\($0)" }
        }.joined(separator: "  ")
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

        // **The same guard, where the expected value is NOT the fallback.** The assertion above
        // cannot be that: a cycle always closes back at its own entry point, so the parent resolves
        // to itself, `liveLocation` returns `destination`, and an implementation consisting of
        // nothing but `return destination` passes it. Here the cycle sits one level ABOVE a parent
        // that really is renamed, so the correct answer names a different directory than the
        // recorded path does and the fallback is disprovable.
        //
        // This is also what makes the `seen` guard's ABSENCE report as a test failure rather than
        // as broken infrastructure. Deleting `seen` used to recurse forever and kill the host with
        // `unexpected signal code 10`, taking every other verdict in the run with it; with the
        // depth cap, the same deletion runs out of frames, resolution answers nil, `liveLocation`
        // falls back to `/root/A/deep/leaf.txt`, and this line goes red like any other.
        let cycleAboveARename: [FileSyncManager.MoveItemState] = [
            (from: url("/root/A"), to: url("/root/B"), overwritten: nil),
            (from: url("/root/B"), to: url("/root/A"), overwritten: nil),
            (from: url("/root/A/deep"), to: url("/root/A/deepOK"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/A/deep/leaf.txt"),
                                            afterBatch: cycleAboveARename,
                                            fileManager: MockFileManager())
                == url("/root/A/deepOK/leaf.txt"),
                "the cycle above must close at A and leave the /deep → /deepOK rename to apply")
    }

    /// **An occupied recorded path is not proof that the occupant is ours**, and this is where that
    /// is pinned in isolation. `undoRefusesAStrangerSittingOnTheRecordedDestination` drives the
    /// whole undo over a real filesystem; this names the one decision that test rests on.
    ///
    /// Three inputs, one batch, three different answers, so no branch here can be the fallback:
    /// only the rewrite occupied → the recorded path (the nested-provider-root narrowing); only the
    /// recorded path occupied → the recorded path; BOTH occupied → the rewrite, which is what makes
    /// the undo refuse rather than move a stranger.
    @Test func liveLocationPrefersTheRecordedPathOnlyWhenTheRewrittenOneIsFree() throws {
        // `normalizeNames`' shape: the child was renamed inside its still-risky parent, then the
        // parent was renamed around it.
        let batch: [FileSyncManager.MoveItemState] = [
            (from: url("/root/P-BAD/a-BAD.txt"), to: url("/root/P-BAD/a.txt"), overwritten: nil),
            (from: url("/root/P-BAD"), to: url("/root/P"), overwritten: nil)
        ]

        // Nothing at the recorded path, our item at the rewritten one: the ordinary nested case.
        let renamed = MockFileManager()
        try renamed.createDirectory(at: url("/root/P"), withIntermediateDirectories: true)
        renamed.virtualDisk["/root/P/a.txt"] = file(13)
        #expect(FileSyncManager.liveLocation(of: url("/root/P-BAD/a.txt"), afterBatch: batch,
                                            fileManager: renamed)
                == url("/root/P/a.txt"))

        // Our item still at the recorded path and nothing at the rewritten one — the nested
        // provider root, where the item really did land at its recorded `to`.
        let stayedPut = MockFileManager()
        try stayedPut.createDirectory(at: url("/root/P-BAD"), withIntermediateDirectories: true)
        stayedPut.virtualDisk["/root/P-BAD/a.txt"] = file(13)
        #expect(FileSyncManager.liveLocation(of: url("/root/P-BAD/a.txt"), afterBatch: batch,
                                            fileManager: stayedPut)
                == url("/root/P-BAD/a.txt"))

        // BOTH occupied. The recorded path holds a STRANGER — a recreated `/root/P-BAD` with an
        // unrelated 4242-byte `a.txt` — and our 13-byte item is at the rewritten path. Trusting the
        // recorded path here snapshots the stranger, and the undo then moves it: measured, ⌘Z
        // renamed the user's unrelated file to `a␣.txt`. Answering with the rewrite makes the
        // snapshot disagree with whatever sits at `item.to`, so the undo refuses.
        let ambiguous = MockFileManager()
        try ambiguous.createDirectory(at: url("/root/P-BAD"), withIntermediateDirectories: true)
        try ambiguous.createDirectory(at: url("/root/P"), withIntermediateDirectories: true)
        ambiguous.virtualDisk["/root/P-BAD/a.txt"] = file(4242)
        ambiguous.virtualDisk["/root/P/a.txt"] = file(13)
        #expect(FileSyncManager.liveLocation(of: url("/root/P-BAD/a.txt"), afterBatch: batch,
                                            fileManager: ambiguous)
                == url("/root/P/a.txt"),
                "an ambiguous path must resolve to the REWRITE — a wrong answer here has to cost a refusal, never a move of the wrong item")
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
    ///
    /// **It is named for what it measures, which is ONE point.** It used to be called
    /// `theUndoRegistrationOfALargeBatchStaysLinear`, and it cannot see linearity: a single
    /// (n, seconds) pair against a fixed ceiling passes just as happily for a 10× or 50× LINEAR
    /// regression as for the current cost. What it does see is the quadratic blow-up it was written
    /// for, because that one is three orders of magnitude, not one. The scaling itself was measured
    /// out of band on this machine — n=1500 → 0.0254 s, n=3000 → 0.0344 s, n=6000 → 0.0594 s, so
    /// t(2n)/t(n) is 1.35 and 1.73 — and deliberately NOT turned into a ratio assertion: at tens of
    /// milliseconds the measurement noise on a shared, Rosetta-hosted CI runner is the same order
    /// as the signal, which is `docs/flaky-tests.md` mechanism 6 exactly. An honest name plus a
    /// recorded measurement beats a ratio test that fails for the machine's reasons.
    @MainActor
    @Test func theUndoRegistrationOfThreeThousandItemsStaysUnderThreeSeconds() async throws {
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
