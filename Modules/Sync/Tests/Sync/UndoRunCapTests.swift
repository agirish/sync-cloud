import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// One ⌘Z or ⇧⌘Z writes its first 20 items' lines, then one line per kind naming every item past
/// them (`UndoRunLog`). Its banners don't copy into the log; the summary names the last one shown.
/// A second ⌘Z counts afresh.
@Suite struct UndoRunCapTests {

    @Test func theFirstTwentyGetLinesAndTheRestAreNamedByKind() {
        let run = UndoRunLog("Undo", "Move 25 Items")
        let admitted = (1...25).filter { n in
            run.admit(.warning, kind: n.isMultiple(of: 2) ? "left in place, changed since" : "left in place, locked",
                      name: String(format: "/d/f%02d", n), banner: "shown \(n)")
        }
        #expect(admitted == Array(1...20))
        let closing = run.closingLines()
        #expect(closing.map(\.text) == [
            "Undo (Move 25 Items): 2 more item(s) left in place, changed since, past the first 20 logged above: /d/f22, /d/f24",
            "Undo (Move 25 Items): 3 more item(s) left in place, locked, past the first 20 logged above: /d/f21, /d/f23, /d/f25",
        ])
        #expect(closing.allSatisfy { $0.level == .warning })
        #expect(run.summaryNote == "; last message shown: “shown 25”")
    }

    /// Past the cap, every name is kept, in lines of at most 200, each kind at its own level.
    @Test func fiveHundredPastTheCapAreThreeLinesAndKeepEveryName() throws {
        let run = UndoRunLog("Redo", "Move to Trash")
        let names = (1...500).map { String(format: "/d/f%03d", $0) }
        for name in names.reversed() { _ = run.admit(.error, kind: "couldn’t be moved to the Trash", name: name) }
        let closing = run.closingLines()
        try #require(closing.count == 3)
        #expect(closing.allSatisfy { $0.level == .error })
        #expect(closing[0].text.hasPrefix("Redo (Move to Trash): 480 more item(s) couldn’t be moved to the Trash, past the first 20 logged above 1–200 of 480: "))
        let named = closing.map(\.text).joined(separator: ", ")
        #expect(names.dropLast(20).allSatisfy { named.contains($0) }, "a name past the cap was dropped")
    }

    @Test func aRunThatShowedNothingAddsNothing() {
        let run = UndoRunLog("Undo", "Copy 1 Item")
        #expect(run.admit(.info, kind: "no longer on disk", name: "/d/a"))
        #expect(run.closingLines().isEmpty)
        #expect(run.summaryNote == "")
    }

    /// Through the real undo: two moves of 25 files each, every file changed since. Each ⌘Z is its
    /// own run: 20 refusal lines, one line naming the other 5, a summary naming the last banner,
    /// and no `[banner]` copy of any of them.
    @MainActor
    @Test func eachUndoOfTwentyFiveChangedItemsWritesTwentyLinesAndNamesTheRest() async throws {
        let manager = FileSyncManager.forTests(collision: .replace, bulk: (.replace, false))
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        let tag = "cap-\(UUID().uuidString.prefix(8))"
        func batch(_ b: String) -> [String] { (1...25).map { String(format: "\(tag)-\(b)%02d.txt", $0) } }
        for name in batch("a") + batch("b") {
            mockFM.virtualDisk["/src/\(name)"] = .file(100, modified: Date(timeIntervalSince1970: 1_000))
        }
        for b in ["a", "b"] {
            await manager.moveItems(nodes: batch(b).map { FileNode(id: "/src/\($0)", name: $0, isDirectory: false) },
                                    toPath: "/dst", fileManager: mockFM)
        }
        // Every moved file is replaced by a newer one, so each undo refuses every item.
        for name in batch("a") + batch("b") {
            mockFM.virtualDisk["/dst/\(name)"] = .file(555, modified: Date(timeIntervalSince1970: 9_999))
        }

        for b in ["b", "a"] {
            let log = LogCapture()
            manager.undoManager?.undo()
            await waitUntil("the undo of batch \(b) drains") { manager.activeFileOperationsCount == 0 }
            let lines = await log.entries.map(\.message).filter { $0.contains("\(tag)-\(b)") }
            #expect(lines.filter { $0.contains("REFUSED to move") }.count == UndoRunLog.itemsLogged, "\(lines)")
            let closing = lines.filter { $0.contains("5 more item(s) left in place, changed since, past the first 20 logged above: ") }
            #expect(closing.count == 1, "\(lines)")
            #expect(batch(b).filter { name in closing.first?.contains(name) == true }.count == 5)
            #expect(!lines.contains { $0.hasPrefix("[banner] ") }, "a capped banner was copied into the log")
            let summary = await log.line(containing: "moved 0 of 25 item(s) back to source")
            #expect(summary?.contains("25 left in place") == true)
            #expect(summary?.contains("; last message shown: “Undo left “\(tag)-\(b)") == true, "\(summary ?? "no summary")")
        }
    }
}
