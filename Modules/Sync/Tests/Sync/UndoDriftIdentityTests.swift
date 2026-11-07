import Testing
import Foundation
import Events
@testable import Sync

/// Undo and redo destroy only what they recorded: drift is checked by `ItemIdentity`, not size.
/// A copied folder is guarded (a folder's stat size is not its content size), a same-length
/// rewrite of a file counts as an edit, the move-undo checks what sits at the destination, and
/// an item that can't be read is refused. Each test drives the real undo through
/// `FileSyncManager`: a rule proven only where it is defined is one revert from being unused.
///
/// `.serialized` stays. The two undo legs of `undoOfANestedNormalizePassReversesTheChildRenameToo`
/// assert the byte-identical line `Undo (Normalize 2 Names): moved 2 of 2 item(s) back to source,
/// 0 restore failure(s), 0 left in place`; as two tests suspended at `waitUntil`, either could pass
/// on the other's line. Markers bound the window in time; only serializing keeps a sibling from
/// writing inside it (`docs/flaky-tests.md`, "A log assertion reading a window that has already
/// rolled"). CI runs this target in parallel, and serializing costs about half a second.
@Suite(.serialized) struct UndoDriftIdentityTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests(collision: .replace, bulk: (.replace, false))
    }

    private func file(_ size: Int, modified: Date = Date(timeIntervalSince1970: 1_000)) -> MockFileManager.FileStub {
        .file(size, modified: modified)
    }

    // MARK: Reading the refusal LOG, not just the banner

    /// The tests read the log, not just the banner: the banner is one sentence shared by both undo
    /// paths, and the log line carries the path-specific wording. A marker planted before the
    /// operation lets `logLines(since:)` tell a line that was never written from a window that
    /// lost its front, and reports the latter as inconclusive.
    ///
    /// Planted at `.info`, the level of the lines asserted on, not `.debug`: `Logger.log` drops
    /// anything below `minimumLevel`, and a dropped marker would read as a rolled window.
    @MainActor
    private func plantLogMarker(_ label: String) async -> String {
        let marker = "undo-drift-marker \(label) \(UUID().uuidString)"
        await Logger.shared.info(marker).value
        return marker
    }

    /// The lines logged strictly between `marker` and a closing marker written here
    /// (`docs/flaky-tests.md`, "A log assertion reading a window that has already rolled"). A
    /// missing opening marker means the window lost its front, so nothing can be concluded; the
    /// closing one keeps out lines logged after the operation.
    ///
    /// The window still holds lines from suites running alongside on the shared `Logger`, so an
    /// absence assertion must first filter to lines naming the test's own paths.
    ///
    /// Both indices are guarded before anything is sliced, and `start` is searched only in
    /// `lines[..<end]`: slicing reversed bounds traps and takes the whole test host down.
    @MainActor
    private func logLines(since marker: String,
                          sourceLocation: SourceLocation = #_sourceLocation) async -> [String] {
        let closing = "undo-drift-close \(marker)"
        await Logger.shared.info(closing).value
        // The log file, not `Logger.shared.entries`: the entries are a 1000-line window every
        // suite shares, and a slow test under load can see its marker rolled out. The file rolls
        // far later, but `LogFileWriter.trimMidSessionIfOversized` halves it past about 5 MB, so
        // the guard below names that rather than blaming the undo. `flushToDisk` drains it first.
        Logger.shared.flushToDisk()
        let text = (try? String(contentsOf: Logger.shared.logFileURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let end = lines.lastIndex(where: { $0.hasSuffix(closing) }) else {
            Issue.record("""
                this test's own CLOSING marker is not in the log at all — the window cannot be \
                bounded, so nothing can be concluded about the refusal line
                """, sourceLocation: sourceLocation)
            return []
        }
        guard let start = lines[..<end].lastIndex(where: { $0.hasSuffix(marker) }) else {
            Issue.record("""
                this test's own opening marker is not in the log file — it never reached it, or the \
                writer trimmed it away past its size cap (about 5 MB) during a long run — so nothing \
                can be concluded about the refusal line
                """, sourceLocation: sourceLocation)
            return []
        }
        return Array(lines[start..<end])
    }

    // MARK: 1 — a copied folder is now guarded

    /// Copy a folder, let files land in it, press ⌘Z: the undo refuses rather than trash the folder
    /// with everything in it. Named `photos-drifted` so no neighbour's log line can match it: the
    /// window is shared with every suite running alongside.
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
        // The copy path's sentence: this undo would have removed the item the copy produced.
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

    /// An untouched copied folder still undoes cleanly: a guard that refuses everything is not a
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

    /// `2025` → `2026`: identical length, different content. A size-only check would trash it as
    /// the copy it produced.
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

    /// The move-undo checks the destination, not only that the source path is free. Without that,
    /// a different file dropped at the destination would be moved to the source on ⌘Z and the older
    /// version restored over it, as a clean success.
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
        // A move-undo moves the item back: it removes nothing, and the original move, not the
        // undo, put it there.
        #expect(lines.contains {
            $0.contains("REFUSED to move \"ledger.txt\" at /dst/ledger.txt back to its original location")
                && $0.contains("no longer the item that was moved here")
        }, "the move refusal still describes a removal; lines since the marker: \(lines)")
        #expect(lines.allSatisfy { !$0.contains("REFUSED to remove \"ledger.txt\"") },
                "no move refusal may say it was going to REMOVE the item")
        // A refusal is not a failure: the undo chose not to attempt anything, so it is tallied as
        // left in place, not as a restore failure.
        #expect(lines.contains {
            $0.contains("moved 0 of 1 item(s) back to source, 0 restore failure(s), 1 left in place")
        }, "a deliberate refusal is still being tallied as a failure; lines since the marker: \(lines)")
    }

    /// The moved item is gone: the user deleted it between the move and the ⌘Z. That is not drift
    /// (nothing at the destination can be a stranger), as for the copy-undo and the move-redo, so
    /// it must not be reported as changed. And the original the move displaced comes back from the
    /// Trash: the destination is empty, so restoring it can clobber nothing.
    @MainActor
    @Test func moveUndoOfAnItemTheUserDeletedRestoresWhatTheMoveDisplaced() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/report.txt"] = file(100, modified: Date(timeIntervalSince1970: 1_000))
        // An older file already at the destination: the move displaces it to the Trash, and the
        // undo should bring it back.
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
        // Not reported as a change: nothing changed, the item is gone. Narrowed to this item's
        // lines, because a window bounds time, not authorship, and other suites log refusals of
        // their own. Still not vacuous: `reportUndoRefusedChangedItem` embeds
        // `\(destination.path)`, so a real refusal would name `/dst/report.txt`.
        let mine = lines.filter { $0.contains("/dst/report.txt") }
        #expect(mine.allSatisfy { !$0.contains("REFUSED") },
                "a vanished item is not a refusal; lines naming this item: \(mine)")
        #expect(manager.banner?.message.contains("changed since") != true,
                "the banner still claims the deleted item changed: \(String(describing: manager.banner))")
        #expect(lines.contains { $0.contains("report.txt is no longer on disk") },
                "the vanished item is not named in the log; lines since the marker: \(lines)")
        // The displaced original comes back, the one thing left for this undo to do.
        #expect(mockFM.virtualDisk["/dst/report.txt"]?.attributes?[FileAttributeKey.size] as? Int == 42,
                "the file the move displaced is still stranded in the Trash")
        // And nothing is invented at the source: the item the user deleted stays deleted.
        #expect(mockFM.virtualDisk["/src/report.txt"] == nil)
    }

    // MARK: The third verdict

    /// An item whose state can't be read is refused, not destroyed, and reported as unverifiable
    /// rather than changed.
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

        // The copy is still there but can no longer be listed (permissions, volume trouble), so
        // nothing can be concluded about whether it is still the copy.
        mockFM.unlistableDirectories = ["/dst/locked"]
        manager.banner = nil
        let marker = await plantLogMarker("copy-unreadable")

        manager.undoManager?.undo()
        await waitUntil("the unreadable copy is refused") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("couldn’t be checked") == true,
                "an unverifiable item reports as unverifiable, not as changed")
        #expect(mockFM.virtualDisk["/dst/locked"] != nil, "an item that cannot be checked is not destroyed")
        // The log keeps the two refusals apart too: "could not be read" is no evidence of an edit,
        // and a reader acts differently on each.
        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to remove \"locked\" at /dst/locked")
                && $0.contains("its current state could not be read")
        }, "the indeterminate refusal log line is missing or reworded; lines since the marker: \(lines)")
        // Scoped to this fixture's path: the window carries other suites' lines too.
        #expect(lines.filter { $0.contains("/dst/locked") }
                     .allSatisfy { !$0.contains("it changed since the operation") },
                "an unreadable item must not be logged as a demonstrated change")
    }

    // MARK: 4 — a NESTED batch, where `to` is not where the item is

    /// `normalizeNames` applies renames deepest-first and registers the undo shallowest-first: the
    /// child renames inside its still-named parent, then the parent around it. So at registration
    /// the child's recorded `to` (`<root>/Photos␣/a.txt`, under the old parent name) no longer
    /// exists. Snapshotted there, it reads `.absent`, and once the undo restores the parent the
    /// child reads as changed and is left half-undone under a false drift banner.
    ///
    /// Then ⌘⇧Z puts the normalized names back. The undo's params are shallowest-first, the wrong
    /// order for re-applying: renaming the parent first leaves the child's recorded `from`
    /// (`Photos␣/a␣.txt`) under a parent that has just vanished, and recreating it would leave an
    /// empty folder carrying the very risky name the pass removed. The tree must end exactly
    /// `["Photos", "Photos/a.txt"]`.
    ///
    /// The undo after that redo reverses both renames again. A stray `Photos␣` left by a
    /// wrong-order redo would occupy the child's source, so this undo would reverse nothing. This
    /// leg proves the redo's own snapshot reads a live path: each re-applied item is snapshotted
    /// as it lands, before shallower moves rename its ancestors. `liveLocation` buys the same
    /// guarantee for `registerMoveUndo(items:)`, which snapshots after the whole batch.
    ///
    /// Real filesystem, not `MockFileManager`: the mock's `moveItem` of a directory drops keys not
    /// in its `contents` list, so a nested fixture would measure the double.
    @MainActor
    @Test func undoOfANestedNormalizePassReversesTheChildRenameToo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "NestedNormalizeUndo")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await stageNestedNormalizePass(root: root)
        let reversed = ["Photos<ZWSP>", "Photos<ZWSP>/a<ZWSP>.txt"]

        // 1. Undo: every one of the three paths is back, and nothing of the normalized pass survives.
        f.manager.banner = nil
        let undoMarker = await plantLogMarker("nested-normalize-undo")
        f.manager.undoManager?.undo()
        await waitUntil("the nested undo puts the risky child back") {
            FileManager.default.fileExists(atPath: f.riskyChild.path)
        }
        await waitUntil("undo op drains") { f.manager.activeFileOperationsCount == 0 }

        #expect(treeUnder(root) == reversed, "the undo must reverse the whole pass; tree is \(treeUnder(root))")
        // `try?`: a throwing read would abort at the first missing file and skip the banner and
        // log assertions below, the evidence a regression needs to report.
        #expect((try? Data(contentsOf: f.riskyChild)) == Data("child payload".utf8),
                "the child must be the same file moved back, not a fresh one")
        #expect(f.manager.banner == nil,
                "a fully reversed pass raises no banner; got \(String(describing: f.manager.banner?.message))")
        let undoLines = await logLines(since: undoMarker)
        #expect(undoLines.contains {
            $0.contains("Undo (Normalize 2 Names): moved 2 of 2 item(s) back to source, 0 restore failure(s), 0 left in place")
        }, "the undo did not reverse both renames; lines since the marker: \(undoLines)")
        // Scoped to this fixture's temp root: a neighbour's refusal in the window isn't ours.
        #expect(undoLines.filter { $0.contains(root.path) }.allSatisfy { !$0.contains("REFUSED") },
                "nothing drifted, so nothing may be refused; lines since the marker: \(undoLines)")

        // 2. Redo: the pass lands exactly again.
        let redoMarker = await plantLogMarker("nested-normalize-redo")
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
        let redoLines = await logLines(since: redoMarker)
        #expect(redoLines.contains {
            $0.contains("Redo (Normalize 2 Names): moved 2 of 2 item(s), 0 redo failure(s)")
        }, "the redo did not re-apply both renames; lines since the marker: \(redoLines)")
        #expect(redoLines.filter { $0.contains(root.path) }.allSatisfy { !$0.contains("FAILED to redo") },
                "nothing was missing, so nothing may fail to redo; lines since the marker: \(redoLines)")

        // 3. The undo after the redo reverses the whole pass again.
        f.manager.banner = nil
        let againMarker = await plantLogMarker("nested-normalize-redo-undo")
        f.manager.undoManager?.undo()
        await waitUntil("the second undo puts the risky child back again") {
            FileManager.default.fileExists(atPath: f.riskyChild.path)
        }
        await waitUntil("second undo op drains") { f.manager.activeFileOperationsCount == 0 }

        #expect(treeUnder(root) == reversed,
                "the second undo must reverse the whole pass again; tree is \(treeUnder(root))")
        #expect((try? Data(contentsOf: f.riskyChild)) == Data("child payload".utf8))
        #expect(f.manager.banner == nil,
                "a fully reversed pass raises no banner; got \(String(describing: f.manager.banner?.message))")
        let againLines = await logLines(since: againMarker)
        #expect(againLines.contains {
            $0.contains("Undo (Normalize 2 Names): moved 2 of 2 item(s) back to source, 0 restore failure(s), 0 left in place")
        }, "the undo after the redo did not reverse both renames; lines since the marker: \(againLines)")
        #expect(againLines.filter { $0.contains(root.path) }.allSatisfy { !$0.contains("REFUSED") },
                "nothing drifted, so nothing may be refused; lines since the marker: \(againLines)")
    }

    /// A refused nested undo builds nothing. When the shallow item has drifted, the deeper item's
    /// `from` spells the old ancestor name, so recreating its parent before deciding would
    /// manufacture `Photos␣`, the name the pass removed. A refused item leaves the disk exactly as
    /// it found it.
    @MainActor
    @Test func aRefusedNestedUndoManufacturesNoDirectory() async throws {
        let root = try makeCanonicalTempRoot(prefix: "NestedNormalizeRefused")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await stageNestedNormalizePass(root: root)

        // Something lands in the normalized folder before the ⌘Z, so the folder's restore is
        // refused. The child's recorded destination is under the folder's old name, which now
        // stays unrestored.
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

    /// The redo's half of the same rule: a re-apply that can't happen builds nothing, not even the
    /// destination's parent. Staged flat on the mock, because with the ordering right the nested
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

        // Between ⌘Z and ⌘⇧Z the user deletes the file and the folder it had been moved into.
        // Neither is the redo's to recreate.
        mockFM.virtualDisk["/src/report.txt"] = nil
        mockFM.virtualDisk["/dst"] = nil
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the redo reports it cannot re-apply") { manager.banner?.severity == .warning }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("Redo couldn’t re-apply “report.txt”") == true,
                "got \(String(describing: manager.banner?.message))")
        #expect(mockFM.virtualDisk["/dst"] == nil,
                "the redo must not rebuild a destination folder for a move that cannot happen")
        #expect(mockFM.virtualDisk["/dst/report.txt"] == nil)
    }

    // MARK: 5 — an occupied recorded path is not proof of identity

    /// An occupied recorded path is not proof of identity: `fileExists` can't tell our item from
    /// any item. After a pass turns `<root>/P␣/a␣.txt` into `<root>/P/a.txt`, the user recreates
    /// `<root>/P␣` with an unrelated `a.txt`. Snapshotting the recorded path would record that
    /// stranger, compare it with itself and move it, planting the risky name on the user's file.
    /// `liveLocation` reads the rewritten path instead, so the undo refuses.
    ///
    /// Calls `registerMoveUndo(items:)` with `normalizeNames`' shallowest-first batch directly: the
    /// snapshot is taken at registration, so the stranger must already be on disk then, as it can
    /// be at any call site that registers after applying. Real filesystem, as for the nested tests.
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
        // ...and the user has since recreated the risky folder with an unrelated file in it, named
        // as the pass named ours.
        try FileManager.default.createDirectory(at: riskyFolder, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4242).write(to: strangerChild)

        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }

        // `normalizeNames`' batch, shallowest-first, as it registers it: the child was renamed
        // inside its still-risky parent, so its recorded `to` is where the stranger now sits.
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

        // The stranger keeps its own name; renamed, it would be `a␣.txt`.
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
        // recreated directory holds), and nothing moved.
        #expect(lines.contains {
            $0.contains("Undo (Normalize 2 Names): moved 0 of 2 item(s) back to source, 1 restore failure(s), 1 left in place")
        }, "the undo moved something it should have refused; lines since the marker: \(lines)")
    }

    // MARK: 6 — the redo checks identity too

    /// The redo checks identity, not just that the source path exists. After ⌘Z, the user writes a
    /// different file at the source and an unrelated one at the destination; a path-only redo
    /// would move the first over the second and report nothing. It refuses, as the undo does.
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

        // Between ⌘Z and ⌘⇧Z the user writes a different file at the source and an unrelated one
        // at the destination. Neither is the redo's to touch.
        mockFM.virtualDisk["/redo-src/stranger.txt"] = file(999, modified: Date(timeIntervalSince1970: 9_999))
        mockFM.virtualDisk["/redo-dst/stranger.txt"] = file(555, modified: Date(timeIntervalSince1970: 8_888))
        manager.banner = nil
        let marker = await plantLogMarker("redo-source-replaced")

        manager.undoManager?.redo()
        await waitUntil("the redo refuses the replaced source") { manager.banner?.severity == .warning }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message == "Redo left “stranger.txt” in place — it changed since",
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
            $0.contains("Redo (Move 1 Item): moved 0 of 1 item(s), 0 redo failure(s), 1 left in place")
        }, "a redo refusal is not being tallied; lines since the marker: \(lines)")
    }

    /// An untouched source still redoes, or the guard is an outage. Same steps with nothing edited
    /// and the opposite answer, so neither test can pass on the fallback.
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

        // An untouched move still undoes, or the guard is just an outage.
        manager.undoManager?.undo()
        await waitUntil("the move is reversed") { mockFM.virtualDisk["/redo-ok-src/kept.txt"] != nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/redo-ok-dst/kept.txt"] == nil)
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

    /// The redo checks each source at its own move, not in an up-front pass: anything that changed
    /// between the pass and the move would go unchecked. With one item the two shapes look the
    /// same, so this batch has two. For item k of N the gap spans the earlier items' real moves,
    /// seconds on a large batch, and cloud providers materialise files at any time. Here a
    /// stranger lands at `/tsrc/aa.txt` while `b.txt` moves, after an up-front check would pass.
    @MainActor
    @Test func redoRefusesASourceReplacedWhileAnEarlierItemOfTheSameBatchMoved() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/tsrc"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: url("/tdst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/tsrc/aa.txt"] = file(10)
        mockFM.virtualDisk["/tsrc/b.txt"] = file(20)

        // Different lengths on purpose: `pruneNestedNodes` orders by path length with
        // `sorted(by:)`, which isn't stable, and which item moves first is the whole fixture. The
        // batch is [b, aa], and a multi-select move replays in the order it was applied.
        let nodes = [FileNode(id: "/tsrc/aa.txt", name: "aa.txt", isDirectory: false),
                     FileNode(id: "/tsrc/b.txt", name: "b.txt", isDirectory: false)]
        await manager.moveItems(nodes: nodes, toPath: "/tdst", fileManager: mockFM)
        try #require(mockFM.virtualDisk["/tdst/aa.txt"] != nil)
        try #require(mockFM.virtualDisk["/tdst/b.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("both moves are reversed") {
            mockFM.virtualDisk["/tsrc/aa.txt"] != nil && mockFM.virtualDisk["/tsrc/b.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        let afterUndo = probe(mockFM, ["/tsrc/aa.txt", "/tsrc/b.txt", "/tdst/aa.txt", "/tdst/b.txt"])
        #expect(afterUndo == "/tsrc/aa.txt=10  /tsrc/b.txt=20",
                "the undo leg must put both files back before the redo is measured; got \(afterUndo)")

        // A stranger takes `aa.txt`'s place while `b.txt` is moving, before `aa.txt`'s own move.
        // One-shot (the hook nils itself), so the redo's bookkeeping moves can't re-arm it.
        mockFM.beforeCopyItem = { src in
            guard src == "/tsrc/b.txt" else { return }
            mockFM.beforeCopyItem = nil
            mockFM.virtualDisk["/tsrc/aa.txt"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [FileAttributeKey.size: 8888,
                             FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 8_888)],
                contents: nil)
        }
        manager.banner = nil
        let marker = await plantLogMarker("redo-source-replaced-mid-batch")

        manager.undoManager?.redo()
        await waitUntil("the redo re-applies the item that did not drift") {
            mockFM.virtualDisk["/tdst/b.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        let afterRedo = probe(mockFM, ["/tsrc/aa.txt", "/tsrc/b.txt", "/tdst/aa.txt", "/tdst/b.txt"])
        #expect(afterRedo == "/tsrc/aa.txt=8888  /tdst/b.txt=20",
                "the stranger must stay where the user put it and only bb.txt may be re-applied; got \(afterRedo)")
        #expect(manager.banner?.message == "Redo left “aa.txt” in place — it changed since",
                "got \(String(describing: manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to re-apply \"aa.txt\" from /tsrc/aa.txt")
                && $0.contains("it changed since the undo put it back")
        }, "the mid-batch replacement was not refused; lines since the marker: \(lines)")
        #expect(lines.contains {
            $0.contains("Redo (Move 2 Items): moved 1 of 2 item(s), 0 redo failure(s), 1 left in place")
        }, "the tally does not report one refusal and one re-apply; lines since the marker: \(lines)")
    }

    /// A source found absent is still checked at its move. "Nothing there to be a stranger" holds
    /// only if re-confirmed where the move happens. Here the user deletes `yy.txt` after the undo,
    /// then writes an unrelated `yy.txt` while `x.txt` moves; the redo must refuse it.
    @MainActor
    @Test func redoRefusesASourceFilledAfterItWasFoundAbsent() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: url("/dsrc"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: url("/ddst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dsrc/yy.txt"] = file(20)
        mockFM.virtualDisk["/dsrc/x.txt"] = file(10)

        // Lengths pin the order again, with the longer name the absent one: the batch is [x, yy],
        // replayed in that order, so `x.txt` moves first and `yy.txt` last.
        let nodes = [FileNode(id: "/dsrc/yy.txt", name: "yy.txt", isDirectory: false),
                     FileNode(id: "/dsrc/x.txt", name: "x.txt", isDirectory: false)]
        await manager.moveItems(nodes: nodes, toPath: "/ddst", fileManager: mockFM)
        try #require(mockFM.virtualDisk["/ddst/yy.txt"] != nil)
        try #require(mockFM.virtualDisk["/ddst/x.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("both moves are reversed") {
            mockFM.virtualDisk["/dsrc/yy.txt"] != nil && mockFM.virtualDisk["/dsrc/x.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // The user deletes the restored yy.txt, so its source is absent when the redo starts...
        mockFM.virtualDisk["/dsrc/yy.txt"] = nil
        let afterUndo = probe(mockFM, ["/dsrc/x.txt", "/dsrc/yy.txt", "/ddst/x.txt", "/ddst/yy.txt"])
        #expect(afterUndo == "/dsrc/x.txt=10",
                "only the surviving source may be on disk when the redo starts; got \(afterUndo)")

        // ...and then writes a new, unrelated yy.txt while x.txt is moving.
        mockFM.beforeCopyItem = { src in
            guard src == "/dsrc/x.txt" else { return }
            mockFM.beforeCopyItem = nil
            mockFM.virtualDisk["/dsrc/yy.txt"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [FileAttributeKey.size: 7777,
                             FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 7_777)],
                contents: nil)
        }
        manager.banner = nil
        let marker = await plantLogMarker("redo-absent-source-refilled")

        manager.undoManager?.redo()
        await waitUntil("the redo re-applies the item whose source survived") {
            mockFM.virtualDisk["/ddst/x.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        let afterRedo = probe(mockFM, ["/dsrc/x.txt", "/dsrc/yy.txt", "/ddst/x.txt", "/ddst/yy.txt"])
        #expect(afterRedo == "/dsrc/yy.txt=7777  /ddst/x.txt=10",
                "the file the user had just created must not be relocated by a redo; got \(afterRedo)")
        #expect(manager.banner?.message == "Redo left “yy.txt” in place — it changed since",
                "got \(String(describing: manager.banner?.message))")

        let lines = await logLines(since: marker)
        #expect(lines.contains {
            $0.contains("REFUSED to re-apply \"yy.txt\" from /dsrc/yy.txt")
                && $0.contains("it changed since the undo put it back")
        }, "the refilled source was not refused; lines since the marker: \(lines)")
        #expect(lines.contains {
            $0.contains("Redo (Move 2 Items): moved 1 of 2 item(s), 0 redo failure(s), 1 left in place")
        }, "the tally does not report one refusal and one re-apply; lines since the marker: \(lines)")
    }

    // MARK: 8 — a recorded `.absent` is not an identity

    /// A recorded `.absent` is not an identity: `compare(.absent, .absent)` answers `.unchanged`,
    /// which must not read as "still my item". With the destination and its parent both missing,
    /// the `vanished` branch can't fire, and taking the move branch would recreate `item.from`'s
    /// parent (`P␣`) before failing. The undo refuses and builds nothing. Registered directly,
    /// since a destination missing at registration is what records `.absent`.
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

        // Nothing under `root`, not even the destination's parent, so the `vanished` branch can't
        // fire.
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
        #expect(manager.banner?.message == "Undo left “a.txt” in place — there was nothing to move back",
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

    /// The same refusal with the destination's parent on disk, the shape a normalize batch
    /// produces. The `vanished` branch must not claim it: "no longer on disk" says the user removed
    /// it, a recorded `.absent` says it was never there, and `vanished` only logs, so the refusal
    /// banner would be lost. This is about what the user is told and the counters staying apart.
    @MainActor
    @Test func anUnrecordedItemIsRefusedAsSuchEvenWhenItsParentExists() async throws {
        let root = try makeCanonicalTempRoot(prefix: "AbsentRecordedParentExists")
        defer { try? FileManager.default.removeItem(at: root) }

        // The parent is on disk: the one difference from the test above.
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

        #expect(manager.banner?.message == "Undo left “a.txt” in place — there was nothing to move back",
                "got \(String(describing: manager.banner?.message))")
        let lines = await logLines(since: marker)
        #expect(!lines.contains { $0.contains("a.txt is no longer on disk") },
                "reported as removed by the user an item that was never recorded on disk")
        #expect(lines.contains {
            $0.contains("Undo (Normalize 1 Name): moved 0 of 1 item(s) back to source, 0 restore failure(s), 0 left in place")
                && $0.contains("1 with nothing recorded to move back")
        }, "the tally counted this as vanished rather than unrecorded; lines: \(lines)")
    }

    /// `path=size` for each of `paths` on the virtual disk, in the order given, so a failure prints
    /// one table rather than four separate expectations.
    private func probe(_ fm: MockFileManager, _ paths: [String]) -> String {
        paths.compactMap { path in
            (fm.virtualDisk[path]?.attributes?[FileAttributeKey.size] as? Int).map { "\(path)=\($0)" }
        }.joined(separator: "  ")
    }

    /// Runs the risky-name pass the nested redo and refusal tests share, checks it landed, and
    /// hands back the manager and the four paths.
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

    /// Every path under `root`, relative and sorted, with zero-width spaces spelled `<ZWSP>` so a
    /// failure doesn't print strings that look identical to the normalized ones.
    private func treeUnder(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
            .map { $0.replacingOccurrences(of: "\u{200B}", with: "<ZWSP>") }
            .sorted()
    }

    // MARK: The batch-relative resolution itself

    /// `liveLocation` makes the snapshots above read the right path. Pinned directly too: the
    /// three-deep case and the cycle guard can't be staged from `normalizeNames`.
    @Test func liveLocationRewritesOnlyAncestorsRenamedLaterInTheSameBatch() {
        // An empty disk, so the "still there?" check never short-circuits the resolution;
        // `liveLocationLeavesAnItemThatIsStillAtItsRecordedPath` covers that check.
        let empty = MockFileManager()

        // Three deep, applied deepest-first: the leaf's recorded `to` spells both old ancestor
        // names, and both must be rewritten.
        let nested: [FileSyncManager.MoveItemState] = [
            (from: url("/root/A-BAD/B-BAD/c-BAD.txt"), to: url("/root/A-BAD/B-BAD/cOK.txt"), overwritten: nil),
            (from: url("/root/A-BAD/B-BAD"), to: url("/root/A-BAD/BOK"), overwritten: nil),
            (from: url("/root/A-BAD"), to: url("/root/AOK"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/A-BAD/B-BAD/cOK.txt"), afterBatch: nested, fileManager: empty)
                == url("/root/AOK/BOK/cOK.txt"))
        #expect(FileSyncManager.liveLocation(of: url("/root/A-BAD/BOK"), afterBatch: nested, fileManager: empty)
                == url("/root/AOK/BOK"))

        // A flat batch (every single-item or same-directory call site) is untouched. Staged as a
        // renumbering cascade, where `02 - x.pdf` is one move's destination and another's source,
        // so the leaf rule has something to disprove: resolving the whole path instead of only the
        // parent must fail here, answering `/root/03 - x.pdf`.
        let cascade: [FileSyncManager.MoveItemState] = [
            (from: url("/root/01 - x.pdf"), to: url("/root/02 - x.pdf"), overwritten: nil),
            (from: url("/root/02 - x.pdf"), to: url("/root/03 - x.pdf"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/02 - x.pdf"), afterBatch: cascade, fileManager: empty)
                == url("/root/02 - x.pdf"),
                "the LEAF must never be rewritten — an item is renamed once per batch, so its own name is final")

        // The same rule one level up: the shallowest item's destination is another move's source,
        // so a leaf-rewriting implementation would answer `/root/B`.
        let chain: [FileSyncManager.MoveItemState] = [
            (from: url("/root/A"), to: url("/root/B"), overwritten: nil),
            (from: url("/root/C"), to: url("/root/A"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/A"), afterBatch: chain, fileManager: empty)
                == url("/root/A"))
    }

    /// The cycle guard, pinned to the one path it produces. Resolution is deterministic (keyed by
    /// exact path), so the exact answer can be named: returning `renames[path]` instead of `path`
    /// on the second visit must fail this.
    @Test func liveLocationStopsAtOneLapOfACycle() {
        let cycle: [FileSyncManager.MoveItemState] = [
            (from: url("/root/X"), to: url("/root/Y"), overwritten: nil),
            (from: url("/root/Y"), to: url("/root/X"), overwritten: nil)
        ]
        #expect(FileSyncManager.liveLocation(of: url("/root/X/leaf.txt"), afterBatch: cycle,
                                            fileManager: MockFileManager())
                == url("/root/X/leaf.txt"),
                "X→Y→X closes the lap at X, so the parent resolves back to itself and the path is left alone")

        // The same guard where the expected value is not the fallback: above, a cycle closes at
        // its entry, so `return destination` alone would pass. Here the cycle sits above a parent
        // that really is renamed. Deleting `seen` must fail this line: the depth cap stops the
        // recursion, resolution answers nil, and `liveLocation` falls back to the recorded path.
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

    /// An occupied recorded path is not proof the occupant is ours, pinned in isolation
    /// (`undoRefusesAStrangerSittingOnTheRecordedDestination` drives the whole undo). One batch,
    /// three disks: only the rewrite occupied → the rewrite; only the recorded path occupied → the
    /// recorded path (a nested provider root); both occupied → the rewrite, so the undo refuses
    /// rather than move a stranger.
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

        // Our item still at the recorded path and nothing at the rewritten one: a nested provider
        // root, where the item really did land at its recorded `to`.
        let stayedPut = MockFileManager()
        try stayedPut.createDirectory(at: url("/root/P-BAD"), withIntermediateDirectories: true)
        stayedPut.virtualDisk["/root/P-BAD/a.txt"] = file(13)
        #expect(FileSyncManager.liveLocation(of: url("/root/P-BAD/a.txt"), afterBatch: batch,
                                            fileManager: stayedPut)
                == url("/root/P-BAD/a.txt"))

        // Both occupied: a stranger at the recorded path, our item at the rewritten one. Trusting
        // the recorded path would snapshot the stranger and the undo would move it; the rewrite
        // makes the snapshot disagree with what sits at `item.to`, so the undo refuses.
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

    /// Keeps a nested provider root from being falsely refused. `/P` and `/P/Backup` can both be
    /// roots (`SettingsManager.existingSource` refuses only the same folder). A multi-select move
    /// orders by `id.count`, so the folder `/P/Backup/D` moves first and the file landing second
    /// recreates `/P/Backup/D`: the item arrives after its ancestor moved. Rewriting would read it
    /// at a path where it isn't, and the undo would refuse an item that never drifted. An item
    /// still at its recorded destination didn't go anywhere.
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

        // Not a blanket "never rewrite": with the destination gone (the nested-rename case) the
        // ancestor rewrite still runs. Same query, opposite answer, so neither is the fallback.
        #expect(FileSyncManager.liveLocation(of: url("/P/Backup/D/file.txt"), afterBatch: batch,
                                            fileManager: MockFileManager())
                == url("/P/Backup/moved-D/file.txt"))
    }

    /// Registering the undo for a large batch must not go quadratic. `registerMoveUndo(items:)`
    /// runs on the main actor right after a bulk move and calls `liveLocation` per item; rebuilding
    /// the rename map per item costs about 15 s of frozen UI at 3,000 items, and a multi-select move
    /// or a "Fix all" pass can hand over thousands.
    ///
    /// One point against a loose ceiling: linear registration takes tens of milliseconds here, and
    /// 3 s is over 100× that yet far below the quadratic cost. It can't see a linear slowdown, and
    /// a ratio test would be noise on CI (`docs/flaky-tests.md`, "Load-scaled benchmarks").
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
