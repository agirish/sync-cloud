import Testing
import Foundation
@testable import Sync

/// File All's sheet (decision OQ): which cards it may file, and that what it files is one ⌘Z.
@Suite struct FilingMatchedTests {
    private func card(confidence: FilingConfidence = .high, account: Bool = false, fromContent: Bool = false,
                      fromAI: Bool = false, to path: String = "/D/Receipts") -> FilingSuggestion {
        let acct = account ? FilingAccount(root: "/D/IRA 7863", ending: "7863", institution: "x", archived: false, kind: .statement) : nil
        let dest = FilingDestination(path: path, confidence: confidence, reasons: ["r"], newSegments: [],
                                     fromContent: fromContent, fromAI: fromAI, account: acct)
        return FilingSuggestion(filePath: "/In/a.pdf", fileName: "a.pdf", size: 1, modificationDate: nil, candidates: [dest])
    }

    @Test func anAccountNumberOrANameMatchesAndNothingWeakerDoes() {
        #expect(card(account: true, fromContent: true).isMatched, "the account number on page 1")
        #expect(card().isMatched, "the file's name")
        #expect(!card(fromContent: true).isMatched, "a word read from the page needs its own click")
        #expect(!card(fromAI: true).isMatched, "a model's High needs its own click")
        #expect(!card(confidence: .medium, account: true, fromContent: true).isMatched, "Medium is Check first")
        #expect(!card(to: "/Elsewhere/Receipts").preferring("/D").isMatched, "a name High outside File Into")
        #expect(!card(account: true, fromContent: true, to: "/Elsewhere/IRA").preferring("/D").isMatched,
                "an account outside File Into needs its own click too")
        #expect(card(account: true, fromContent: true, to: "/D/IRA").preferring("/D").isMatched)
    }
}

@MainActor
@Suite struct FilingBatchApplyTests {

    private func statement(_ root: URL, _ name: String, into folder: URL, account: URL, proposed: String,
                           confidence: FilingConfidence = .high, newSegments: [String] = []) throws -> FilingSuggestion {
        let f = root.appendingPathComponent("In/\(name)")
        try writeBytes(f, Data(name.utf8))
        let dest = FilingDestination(path: folder.path, confidence: confidence, reasons: ["r"], newSegments: newSegments,
                                     fromContent: true, proposedName: proposed,
                                     account: FilingAccount(root: account.path, ending: "7863", institution: "x",
                                                            archived: false, kind: .statement),
                                     nameOrigin: .template)
        return FilingSuggestion(filePath: f.path, fileName: name, size: 1, modificationDate: nil, candidates: [dest])
    }

    /// Two account cards, one making its year folder, and a card placed by its name: one ⌘Z puts all
    /// five files back and takes the year folder away. A Medium card handed in is not filed.
    @Test func everyTickedCardFilesAsOneUndo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingBatchApply")
        defer { try? FileManager.default.removeItem(at: root) }
        let ira = root.appendingPathComponent("Docs/IRA 7863")
        let card = root.appendingPathComponent("Docs/Credit 2002")
        let receipts = root.appendingPathComponent("Docs/Receipts")
        for d in [ira, card, receipts] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let year = card.appendingPathComponent("2026")
        let iraCards = [try statement(root, "01.pdf", into: ira, account: ira, proposed: "IRA_01.pdf"),
                        try statement(root, "02.pdf", into: ira, account: ira, proposed: "IRA_02.pdf")]
        let cardCards = [try statement(root, "c1.pdf", into: year, account: card, proposed: "2026-01-29.pdf", newSegments: ["2026"]),
                         try statement(root, "c2.pdf", into: year, account: card, proposed: "2026-02-28.pdf", newSegments: ["2026"])]
        let receiptFile = root.appendingPathComponent("In/Receipt 2026.pdf")
        try writeBytes(receiptFile, Data("r".utf8))
        let byName = FilingSuggestion(filePath: receiptFile.path, fileName: "Receipt 2026.pdf", size: 1, modificationDate: nil,
                                      candidates: [FilingDestination(path: receipts.path, confidence: .high, reasons: ["r"], newSegments: [])])
        let medium = try statement(root, "m.pdf", into: ira, account: ira, proposed: "IRA_m.pdf", confidence: .medium)
        let items = FilingCardGrouping.items(iraCards + cardCards + [byName, medium])
        #expect(items.count == 4, "two groups, the receipt and the Medium card: \(items.map(\.id))")

        let m = FileSyncManager(defaults: ScratchDefaults("FilingBatchApplyTests.1"))
        m.filingSuggestions = iraCards + cardCards + [byName, medium]
        let undo = UndoManager()
        m.undoManager = undo
        let filed = await m.applyFilingBatch(items)
        #expect(filed == 5)
        for p in [ira.path + "/IRA_01.pdf", ira.path + "/IRA_02.pdf", year.path + "/2026-01-29.pdf",
                  year.path + "/2026-02-28.pdf", receipts.path + "/Receipt 2026.pdf"] {
            #expect(FileManager.default.fileExists(atPath: p), "\(p) landed")
        }
        #expect(FileManager.default.fileExists(atPath: root.path + "/In/m.pdf"), "the Medium card stays for a look")

        undo.undo()
        let back = ["01.pdf", "02.pdf", "c1.pdf", "c2.pdf", "Receipt 2026.pdf"].map { root.path + "/In/" + $0 }
        await waitUntil("every file is back and the year folder gone", timeout: 10) {
            back.allSatisfy { FileManager.default.fileExists(atPath: $0) } && !FileManager.default.fileExists(atPath: year.path)
        }
        #expect(back.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "one ⌘Z puts all five back")
        #expect(!FileManager.default.fileExists(atPath: year.path), "and removes the 2026 folder it made")
        #expect(!undo.canUndo, "the whole batch was one step")
    }

    /// A file gone since the scan stays listed as a card of its own; the rest still file.
    @Test func aFileThatFailsStaysAsItsOwnCard() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingBatchFail")
        defer { try? FileManager.default.removeItem(at: root) }
        let ira = root.appendingPathComponent("Docs/IRA 7863")
        try FileManager.default.createDirectory(at: ira, withIntermediateDirectories: true)
        let cards = [try statement(root, "01.pdf", into: ira, account: ira, proposed: "IRA_01.pdf"),
                     try statement(root, "02.pdf", into: ira, account: ira, proposed: "IRA_02.pdf")]
        try FileManager.default.removeItem(atPath: cards[1].filePath)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingBatchApplyTests.2"))
        m.filingSuggestions = cards
        let filed = await m.applyFilingBatch(FilingCardGrouping.items(cards))
        #expect(filed == 1)
        #expect(m.filingGroupFailures == [cards[1].id])
    }

    /// The sheet's lines are taken when it opens. A card filed from its own button meanwhile is no
    /// longer listed: the batch skips it, and nothing is reported as failed.
    @Test func aCardFiledWhileTheSheetWasOpenIsSkippedNotFailed() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingBatchStale")
        defer { try? FileManager.default.removeItem(at: root) }
        let ira = root.appendingPathComponent("Docs/IRA 7863")
        try FileManager.default.createDirectory(at: ira, withIntermediateDirectories: true)
        let cards = [try statement(root, "01.pdf", into: ira, account: ira, proposed: "IRA_01.pdf"),
                     try statement(root, "02.pdf", into: ira, account: ira, proposed: "IRA_02.pdf")]
        let sheet = FilingCardGrouping.items(cards)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingBatchApplyTests.3"))
        m.filingSuggestions = cards
        guard case .group(let group) = sheet[0] else { Issue.record("expected a group"); return }
        #expect(await m.applyFilingGroup(group) == 2, "filed from its own card first")
        #expect(await m.applyFilingBatch(sheet) == 0)
        #expect(m.filingGroupFailures.isEmpty, "nothing that was filed is called a failure")
        #expect(m.banner?.message.hasPrefix("Nothing left to file") == true)
    }

    /// A new folder's name typed on its card is the name the batch makes.
    @Test func aTypedFolderNameIsKept() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingBatchTyped")
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("Docs/Receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        let f = root.appendingPathComponent("In/Receipt.pdf")
        try writeBytes(f, Data("r".utf8))
        let best = FilingDestination(path: receipts.path + "/Hardware", confidence: .high, reasons: ["r"], newSegments: ["Hardware"])
        let s = FilingSuggestion(filePath: f.path, fileName: "Receipt.pdf", size: 1, modificationDate: nil, candidates: [best])
        let m = FileSyncManager(defaults: ScratchDefaults("FilingBatchApplyTests.4"))
        m.filingSuggestions = [s]
        let typed = best.renamingNewFolder(to: "Tools")
        #expect(await m.applyFilingBatch([.single(s)], destinations: [s.id: typed]) == 1)
        #expect(FileManager.default.fileExists(atPath: receipts.path + "/Tools/Receipt.pdf"))
        #expect(!FileManager.default.fileExists(atPath: receipts.path + "/Hardware"))
    }
}

@Suite struct DocumentFirstLineTests {
    @Test func theFirstLineWithWordsAsPrintedCutAtAWord() {
        #expect(DocumentFacts(page: "  \n12/01\nImmunization   Record\nName: A").firstLine == "Immunization Record")
        let long = String(repeating: "word ", count: 30)
        let line = DocumentFacts(page: long).firstLine ?? ""
        #expect(line.hasSuffix("…") && line.count <= 81 && !line.contains("  "))
        #expect(DocumentFacts(page: "123 456\n").firstLine == nil)
    }
}
