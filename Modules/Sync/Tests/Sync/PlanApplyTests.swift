import Foundation
import Testing
import Events
@testable import Sync

/// A card of changes applied as one undo step, on a real folder. Its Trash is a `ScratchTrash`
/// inside that folder: an Apply's trash and an undone New Folder would otherwise land in the
/// Trash of whoever runs it.
@MainActor
@Suite(.serialized) struct PlanApplyTests {

    private let dir: String
    private let manager: FileSyncManager
    private let store: SyncHistoryStore
    private let trash: ScratchTrash

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)").resolvingSymlinksInPath().path
        trash = ScratchTrash(folder: URL(fileURLWithPath: dir + "-trash", isDirectory: true))
        manager = FileSyncManager(fileManager: trash)
        manager.undoManager = UndoManager()
        store = makeTempHistoryStore(prefix: "PlanApply")
        manager.syncHistoryStore = store
        for path in ["Downloads/JAL Ticket.pdf", "Downloads/Ticket.pdf", "Downloads/old.txt", "Downloads/Trip/plan.pdf",
                     "Downloads/Notes.rtfd/TXT.rtf", "Documents/Travel/Trips/Ticket.pdf", "Documents/Taxes/w2.pdf"] {
            try write(path)
        }
    }

    private func write(_ rel: String, _ text: String? = nil) throws {
        let full = dir + "/" + rel
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data((text ?? rel).utf8).write(to: URL(fileURLWithPath: full))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(at: trash.folder)
        removeHistoryStoreFiles(store)
    }

    /// Every file and folder under `dir`, with its bytes, so a restore can be compared exactly.
    private func tree() -> [String: Data?] {
        var out: [String: Data?] = [:]
        let e = FileManager.default.enumerator(atPath: dir)
        while let rel = e?.nextObject() as? String {
            guard !rel.hasSuffix(".DS_Store") else { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: dir + "/" + rel, isDirectory: &isDirectory)
            out[rel] = isDirectory.boolValue ? nil : FileManager.default.contents(atPath: dir + "/" + rel)
        }
        return out
    }

    private func apply(_ changes: [AskClaudePlan.Change], hidden: Set<String> = []) async -> AskClaudePlanOutcome {
        await manager.applyPlan(Array(changes.enumerated()).map { (id: $0.offset, change: $0.element) },
                                actionName: "File \(changes.count) Items", isHidden: { hidden.contains($0) },
                                protected: [dir + "/Documents"])
    }

    /// A move with a new name (TE328) lands under it, a taken one numbered, never over the other
    /// file; one Undo brings both back under their old names.
    @Test func aMoveWithANewNameLandsUnderItAndUndoesToTheOldName() async throws {
        defer { cleanUp() }
        try write("Downloads/Scan 0042.pdf", "ally")
        try write("Downloads/Scan 0043.pdf", "pge")
        try write("Documents/Taxes/2025 Ally 1099-INT.pdf", "the filed one")
        let before = tree()
        let out = await manager.applyPlan([(id: 0, change: .move(from: dir + "/Downloads/Scan 0042.pdf", toFolder: dir + "/Documents/Taxes")),
                                           (id: 1, change: .move(from: dir + "/Downloads/Scan 0043.pdf", toFolder: dir + "/Documents/Taxes")),
                                           (id: 2, change: .move(from: dir + "/Downloads/JAL Ticket.pdf", toFolder: dir + "/Documents/Taxes"))],
                                          names: [0: "2025 Ally 1099-INT.pdf", 1: "10. Oct 2025.pdf"], actionName: "Move",
                                          isHidden: { _ in false }, protected: [])
        #expect(out.rows[0] == .done("Renamed and moved, as 2025 Ally 1099-INT 2.pdf"))
        #expect(out.rows[1] == .done("Renamed and moved") && out.rows[2] == .done("Moved"))
        #expect(FileManager.default.contents(atPath: dir + "/Documents/Taxes/2025 Ally 1099-INT.pdf") == Data("the filed one".utf8))
        #expect(FileManager.default.contents(atPath: dir + "/Documents/Taxes/2025 Ally 1099-INT 2.pdf") == Data("ally".utf8))
        #expect(FileManager.default.contents(atPath: dir + "/Documents/Taxes/10. Oct 2025.pdf") == Data("pge".utf8))
        #expect(out.landed[1] == dir + "/Documents/Taxes/10. Oct 2025.pdf")
        manager.undoManager?.undo()
        await waitUntil("one undo restores both old names", timeout: 20) { self.tree() == before }
        #expect(tree() == before)
    }

    /// A new name is checked as a name: one that would hide the file or address another folder.
    @Test func aNewNameIsCheckedBeforeAnythingRuns() {
        defer { cleanUp() }
        let move = AskClaudePlan.Change.move(from: dir + "/Downloads/Ticket.pdf", toFolder: dir + "/Documents/Taxes")
        #expect(manager.planRefusal(move, newName: ".Ticket.pdf", isHidden: { _ in false }, protected: []) == "A name starting with “.” would hide the file")
        #expect(manager.planRefusal(move, newName: "a/b.pdf", isHidden: { _ in false }, protected: []) == "Names can’t contain “/”.")
        #expect(manager.planRefusal(move, newName: "2025 Ally.pdf", isHidden: { _ in false }, protected: []) == nil)
    }

    /// The whole card applies, and one Undo puts the tree back exactly as it was.
    @Test func aCardAppliesAllItsRowsAndOneUndoRestoresTheTree() async throws {
        defer { cleanUp() }
        let before = tree()
        let out = await apply([
            .newFolder(in: dir + "/Documents/Travel/Trips", name: "Japan 2026"),
            .move(from: dir + "/Downloads/JAL Ticket.pdf", toFolder: dir + "/Documents/Travel/Trips/Japan 2026"),
            .move(from: dir + "/Downloads/Ticket.pdf", toFolder: dir + "/Documents/Travel/Trips"),
            .move(from: dir + "/Downloads/Trip/plan.pdf", toFolder: dir + "/Documents/Travel/Trips"),
            .rename(path: dir + "/Documents/Taxes/w2.pdf", to: "W-2 2025.pdf"),
            .trash(path: dir + "/Downloads/old.txt"),
            .trashIfEmptied(folders: [dir + "/Downloads/Trip"]),
        ])
        #expect(out.doneCount == 7, "\(out.rows)")
        #expect(out.rows[2] == .done("Moved, as Ticket 2.pdf"), "a taken name keeps both")
        #expect(out.landed[2] == dir + "/Documents/Travel/Trips/Ticket 2.pdf", "where a move landed, for a rule its pick teaches")
        #expect(out.landed[1] == dir + "/Documents/Travel/Trips/Japan 2026/JAL Ticket.pdf" && out.landed[4] == nil)
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Travel/Trips/Japan 2026/JAL Ticket.pdf"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Travel/Trips/Ticket 2.pdf"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Taxes/W-2 2025.pdf"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/Downloads/old.txt"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/Downloads/Trip"))
        #expect(out.undoName == "File 7 Items" && manager.undoManager?.undoActionName == "File 7 Items")

        manager.undoManager?.undo()
        await waitUntil("one undo restores the tree", timeout: 20) { self.tree() == before }
        #expect(tree() == before)
        #expect(manager.undoManager?.canUndo == false, "the card was one step")
        #expect(trash.names.contains("Japan 2026"), "the undone folder went to \(trash.names), not this suite's Trash")
    }

    /// Each refusal is found at the click, and the rest of the card still runs.
    @Test func eachRefusalAtTheClickSkipsItsRowAndTheRestRun() async throws {
        defer { cleanUp() }
        try FileManager.default.removeItem(atPath: dir + "/Downloads/old.txt")
        let long = String(repeating: "e\u{301}", count: 128) + ".pdf"   // 132 characters, 261 units decomposed
        let out = await apply([
            .move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents"),
            .move(from: dir + "/Downloads/JAL Ticket.pdf", toFolder: dir + "/Documents/Private"),
            .rename(path: dir + "/Downloads/Ticket.pdf", to: "JAL Ticket.pdf"),
            .rename(path: dir + "/Downloads/Ticket.pdf", to: long),
            .move(from: dir + "/Downloads/Trip/plan.pdf", toFolder: dir + "/Downloads/Notes.rtfd"),
            .move(from: dir + "/Downloads/Trip/plan.pdf", toFolder: dir + "/Downloads/Trip"),
            .trash(path: dir + "/Documents"),
            .trash(path: dir + "/Downloads/Notes.rtfd/TXT.rtf"),
            .move(from: dir + "/Downloads/Trip", toFolder: dir + "/Downloads/Trip"),
            .move(from: dir + "/Downloads/Ticket.pdf", toFolder: dir + "/Documents/Travel"),
        ], hidden: [dir + "/Documents/Private"])
        #expect(out.rows[0] == .refused("It isn’t there any more"))
        #expect(out.rows[1] == .refused("Private is hidden from Claude"))
        #expect(out.rows[2] == .refused("JAL Ticket.pdf is taken there"))
        #expect(out.rows[3] == .refused("Names can’t be longer than 255 characters."))
        #expect(out.rows[4] == .refused("Notes.rtfd is a document, not a folder"))
        #expect(out.rows[5] == .refused("It’s already there"))
        #expect(out.rows[6] == .refused("It’s a source’s own folder"))
        #expect(out.rows[7] == .refused("It’s inside a document"))
        #expect(out.rows[8] == .refused("A folder can’t go inside itself"))
        #expect(out.rows[9] == .done("Moved"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Travel/Ticket.pdf"))
    }

    /// Into its own subfolder, however the folder's name is cased on a disk that folds case.
    @Test func aFolderCantGoIntoItsOwnSubfolder() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(atPath: dir + "/Downloads/Trip/Sub", withIntermediateDirectories: true)
        #expect(!FileSyncManager.volumeSupportsCaseSensitiveNames(for: URL(fileURLWithPath: dir)), "needs a disk that folds case")
        let out = await apply([.move(from: dir + "/Downloads/Trip", toFolder: dir + "/Downloads/Trip/Sub"),
                               .move(from: dir + "/Downloads/Trip", toFolder: dir + "/Downloads/trip/Sub")])
        #expect(out.rows[0] == .refused("A folder can’t go inside itself"))
        #expect(out.rows[1] == .refused("A folder can’t go inside itself"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Downloads/Trip/plan.pdf"))
    }

    /// Renames run first, so a later row's item is found under its new name: a renamed file is
    /// filed, and files move out of a folder the same card renames.
    @Test func aMoveFindsItsItemUnderTheCardsRename() async throws {
        defer { cleanUp() }
        let before = tree()
        let out = await apply([
            .move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents/Taxes"),
            .rename(path: dir + "/Downloads/old.txt", to: "W-2 2025.txt"),
            .move(from: dir + "/Downloads/Trip/plan.pdf", toFolder: dir + "/Documents/Travel"),
            .rename(path: dir + "/Downloads/Trip", to: "Japan"),
        ])
        #expect(out.doneCount == 4, "\(out.rows)")
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Taxes/W-2 2025.txt"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Travel/plan.pdf"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Downloads/Japan"))
        manager.undoManager?.undo()
        await waitUntil("one undo restores the tree", timeout: 20) { self.tree() == before }
        #expect(tree() == before)
    }

    /// A folder whose files all left goes with its emptied subfolders; one holding a file at any
    /// depth stays.
    @Test func anEmptiedFolderGoesWithItsEmptySubfolders() async throws {
        defer { cleanUp() }
        try write("Downloads/Trip/Inner/b.pdf")
        try write("Downloads/Keep/Inner/.env")
        try FileManager.default.createDirectory(atPath: dir + "/Downloads/Trip/Empty", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: dir + "/Downloads/Trip/Inner/.DS_Store"))
        let before = tree()
        let out = await apply([
            .move(from: dir + "/Downloads/Trip/plan.pdf", toFolder: dir + "/Documents/Travel"),
            .move(from: dir + "/Downloads/Trip/Inner/b.pdf", toFolder: dir + "/Documents/Travel"),
            .trashIfEmptied(folders: [dir + "/Downloads/Trip", dir + "/Downloads/Keep"]),
        ])
        #expect(out.rows[2] == .done("Moved 1 of 2 to Trash; the rest still hold files"), "\(out.rows)")
        #expect(!FileManager.default.fileExists(atPath: dir + "/Downloads/Trip"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Downloads/Keep/Inner/.env"), "a hidden file is a file")
        manager.undoManager?.undo()
        await waitUntil("one undo restores the tree", timeout: 20) { self.tree() == before }
        #expect(tree() == before)
    }

    /// Checked at the click: a copy goes only while its twin is another file with its bytes.
    @Test func aCopyIsTrashedOnlyWhileItsTwinStillHoldsItsBytes() async throws {
        defer { cleanUp() }
        try write("Downloads/a.pdf", "same")
        try write("Documents/Travel/a copy.pdf", "same")
        try write("Downloads/b.pdf", "same")
        try write("Documents/Travel/b copy.pdf", "SAME")
        try FileManager.default.createSymbolicLink(atPath: dir + "/Link", withDestinationPath: dir + "/Downloads")
        let out = await apply([
            .trash(path: dir + "/Downloads/a.pdf", copyOf: dir + "/Documents/Travel/a copy.pdf"),
            .trash(path: dir + "/Downloads/b.pdf", copyOf: dir + "/Documents/Travel/b copy.pdf"),
            .trash(path: dir + "/Downloads/old.txt", copyOf: dir + "/Link/old.txt"),
            .trash(path: dir + "/Downloads/Ticket.pdf", copyOf: dir + "/Documents/Gone.pdf"),
        ])
        #expect(out.rows[0] == .done("Moved to Trash"))
        #expect(out.rows[1] == .refused("b copy.pdf isn’t the same file any more"))
        #expect(out.rows[2] == .refused("old.txt is this same file, not a copy"))
        #expect(out.rows[3] == .refused("The copy, Gone.pdf, isn’t there any more"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Downloads/old.txt"), "the only copy was kept")
        #expect(trash.names == ["a.pdf"], "the copy went to \(trash.names), not this suite's Trash")
    }

    /// Two cards share a name; a card's Undo acts only on its own Apply, and never after an
    /// outside undo.
    @Test func aCardsUndoActsOnlyOnItsOwnApply() async throws {
        defer { cleanUp() }
        let first = await apply([.move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents")])
        let second = await apply([.move(from: dir + "/Downloads/Ticket.pdf", toFolder: dir + "/Documents")])
        #expect(first.undoName == second.undoName, "the same name: File 1 Items")
        let applied = [(id: 0, change: AskClaudePlan.Change.move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents"))]
        let firstToken = try #require(first.undoToken), secondToken = try #require(second.undoToken)
        #expect(manager.undoPlan(firstToken, named: "File 1 Items", applied: applied) == nil,
                "the first card's Undo would take back the second")
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Ticket.pdf"))
        // ⌘Z takes the second back; the first is on top again, but nothing can say it is.
        manager.undoManager?.undo()
        await waitUntil("the second card is undone", timeout: 20) { FileManager.default.fileExists(atPath: self.dir + "/Downloads/Ticket.pdf") }
        #expect(manager.undoPlan(secondToken, named: "File 1 Items", applied: []) == nil)
        #expect(manager.undoPlan(firstToken, named: "File 1 Items", applied: applied) == nil)
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/old.txt"))
    }

    /// Undo says what it did once it has run: a file taken from where the card put it stays out.
    @Test func aCardsUndoReportsWhatDidntGoBack() async throws {
        defer { cleanUp() }
        let changes: [AskClaudePlan.Change] = [.move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents"),
                                               .move(from: dir + "/Downloads/Ticket.pdf", toFolder: dir + "/Documents")]
        let out = await apply(changes)
        try FileManager.default.removeItem(atPath: dir + "/Documents/Ticket.pdf")
        let token = try #require(out.undoToken)
        let undoing = try #require(manager.undoPlan(token, named: "File 2 Items",
                                                    applied: Array(changes.enumerated()).map { (id: $0.offset, change: $0.element) }))
        let notBack = await undoing.value
        #expect(notBack == [1])
        #expect(FileManager.default.fileExists(atPath: dir + "/Downloads/old.txt"), "the undo had run when it answered")
        var plan = AskClaudePlan(title: "File 2 Items", subtitle: "", rows: [
            .init(id: 0, name: "old.txt", change: changes[0], ticked: true), .init(id: 1, name: "Ticket.pdf", change: changes[1], ticked: true)])
        plan.recordUndo(notBack: [1])
        #expect(plan.state == .undone && plan.summary == "Undone, except 1: Ticket.pdf didn’t go back.")
        plan.recordUndo(notBack: [])
        #expect(plan.summary == "Undone: everything is back where it was.")
    }

    @Test func aOneWaySyncedFileIsRefused() async throws {
        defer { cleanUp() }
        manager.oneWaySyncRefusal = { paths in paths.contains { $0.hasSuffix("/Taxes") } ? "Taxes is synced one way" : nil }
        let out = await apply([.move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents/Taxes")])
        #expect(out.rows[0] == .refused("Taxes is synced one way") && out.undoName == nil)
        #expect(manager.undoManager?.canUndo == false)
    }

    /// A run going or Verify All: nothing runs, and the button waits rather than starting later.
    @Test func aRunInProgressRefusesTheWholeCard() async throws {
        defer { cleanUp() }
        manager.isVerifyAllRunning = true
        let out = await apply([.move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents")])
        #expect(out.rows[0] == .refused("Waiting: Verify All is running"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Downloads/old.txt"))
        manager.isVerifyAllRunning = false
        manager.activeProgress = Progress(totalUnitCount: 1)
        let busy = await apply([.move(from: dir + "/Downloads/old.txt", toFolder: dir + "/Documents")])
        if case .refused(let why) = busy.rows[0] { #expect(why.hasPrefix("Waiting: ")) } else { Issue.record("ran during a run") }
        manager.activeProgress = nil
    }

    /// History hears every move, rename and trash, under one run.
    @Test func historyRecordsEveryChange() async throws {
        defer { cleanUp() }
        _ = await apply([.rename(path: dir + "/Documents/Taxes/w2.pdf", to: "W2.pdf"),
                         .move(from: dir + "/Downloads/JAL Ticket.pdf", toFolder: dir + "/Documents/Travel"),
                         .trash(path: dir + "/Downloads/old.txt"),
                         .newFolder(in: dir + "/Documents", name: "Japan")])
        let records = store.lastRunId.map(store.recordsForRun) ?? []
        #expect(records.map(\.action).sorted { $0.rawValue < $1.rawValue } == [.delete, .move, .move, .newFolder])
        #expect(records.contains { $0.action == .newFolder && $0.sourcePath == dir + "/Documents/Japan" })
        #expect(Set(records.map(\.runId)).count == 1)
        #expect(records.contains { $0.action == .move && $0.destPath == dir + "/Documents/Taxes/W2.pdf" })
        manager.undoManager?.undo()
        await waitUntil("undo brings the trashed file back", timeout: 20) {
            FileManager.default.fileExists(atPath: self.dir + "/Downloads/old.txt")
        }
    }

    /// Only an emptied folder goes: one that still holds a file stays, and says so.
    @Test func aFolderStillHoldingFilesIsNotTrashed() async throws {
        defer { cleanUp() }
        let out = await apply([.trashIfEmptied(folders: [dir + "/Downloads/Trip"])])
        #expect(out.rows[0] == .refused("Not empty, so left in place"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Downloads/Trip/plan.pdf"))
    }
}

/// The pane's own Rename and New Folder: the disk's name-length limit, waiting for Verify All, and
/// a rename in History.
@MainActor
@Suite struct RenameAndNewFolderGapTests {

    @Test func aNameOverTheDisksLimitIsRefusedCountedDecomposed() {
        #expect(FileSyncManager.validateItemName(String(repeating: "a", count: 255)) == nil)
        #expect(FileSyncManager.validateItemName(String(repeating: "a", count: 256)) == "Names can’t be longer than 255 characters.")
        // 128 é: 128 characters typed, 256 units as the disk stores them.
        #expect(FileSyncManager.validateItemName(String(repeating: "\u{E9}", count: 128)) == "Names can’t be longer than 255 characters.")
    }

    @Test func renameAndNewFolderWaitForVerifyAllAndARenameIsInHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gaps-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/a.txt"))
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let store = makeTempHistoryStore(prefix: "RenameGap")
        manager.syncHistoryStore = store
        defer { try? FileManager.default.removeItem(atPath: dir); removeHistoryStoreFiles(store) }

        manager.isVerifyAllRunning = true
        await manager.renameItem(at: dir + "/a.txt", to: "b.txt")
        await manager.createFolder(named: "New", in: dir)
        #expect(FileManager.default.fileExists(atPath: dir + "/a.txt") && !FileManager.default.fileExists(atPath: dir + "/New"))
        #expect(store.records.isEmpty)

        manager.isVerifyAllRunning = false
        await manager.renameItem(at: dir + "/a.txt", to: "b.txt")
        #expect(FileManager.default.fileExists(atPath: dir + "/b.txt"))
        #expect(store.records.map(\.action) == [.move])
        #expect(store.records.first?.sourcePath == dir + "/a.txt" && store.records.first?.destPath == dir + "/b.txt")
        await manager.createFolder(named: "New", in: dir)
        #expect(store.records.map(\.action) == [.move, .newFolder])
        #expect(store.records.last?.sourcePath == dir + "/New")
    }
}
