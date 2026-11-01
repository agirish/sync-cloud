import Foundation
import Testing
import Events
@testable import Sync

/// A card of changes applied as one undo step (TE262), on a real folder.
@MainActor
@Suite(.serialized) struct PlanApplyTests {

    private let dir: String
    private let manager: FileSyncManager
    private let store: SyncHistoryStore

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)").resolvingSymlinksInPath().path
        manager = FileSyncManager()
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
        #expect(out.rows[8] == .refused("It’s already there") || out.rows[8] == .refused("A folder can’t go inside itself"))
        #expect(out.rows[9] == .done("Moved"))
        #expect(FileManager.default.fileExists(atPath: dir + "/Documents/Travel/Ticket.pdf"))
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
                         .trash(path: dir + "/Downloads/old.txt")])
        let records = store.lastRunId.map(store.recordsForRun) ?? []
        #expect(records.map(\.action).sorted { $0.rawValue < $1.rawValue } == [.delete, .move, .move])
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

/// The pane's own Rename and New Folder, closing the gaps TE262's plan found.
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
    }
}
