import Testing
import Foundation
@testable import Sync

/// Round one of the second review of statement filing: page shapes other banks print, a flat tree,
/// copies that survive every rebuild of a home, and what ⌘Z and ⇧⌘Z do to a lesson.
@Suite struct FilingRoundOnePageTests {
    private func endings(_ page: String) -> [String] { DocumentFacts(page: page).matchingNumbers.map(\.ending) }
    private let period = "\nStatement Period: March 1, 2026 to March 31, 2026"

    @Test func labelsOtherBanksPrint() {
        #expect(endings("Credit Union\nMember # 1234567" + period) == ["4567"])
        #expect(endings("Bank\nAcct: 12345678" + period) == ["5678"])
        #expect(endings("Bank\nAccount Number (1234-5678)" + period) == ["5678"])
        #expect(endings("Bank\nAccount\nNumber 3841-7863" + period) == ["7863"])
    }

    @Test func aNumberIsNotWhatFollowsIt() {
        #expect(endings("Bank\nAccount # 5678 1,234.56" + period) == ["5678"])
        #expect(endings("Bank\nAccount Number 3841-7863 2 of 6" + period) == ["7863"])
        #expect(endings("Bank\nAccount # 1234-5678 2026-03-31" + period) == ["5678"])
        #expect(!endings("Bank\nAccount Number:\n73210 VIA VICENZA" + period).contains("3210"), "an address on the next line")
        #expect(endings("Bank\nAccount ending in 1768, thank you" + period) == ["1768"])
    }

    @Test func paymentPhrasesNotABareFrom() {
        #expect(!endings("Bank\nAutoPay from account ending in ****4121\nAccount Number 0001768" + period).contains("4121"))
        #expect(endings("HDFC Bank\nStatement From : 01/03/2026 To : 31/03/2026 Account No : 50100012345678") == ["5678"])
        #expect(!DocumentFacts(page: "XXX XX 7396 Bank" + period).ownNumbers.contains { $0.ending == "7396" }, "a spaced taxpayer mask")
    }

    @Test func datesOtherBanksPrint() {
        func p(_ page: String) -> String { DocumentFacts(page: page).period.map { "\($0.year)-\($0.month)" } ?? "nil" }
        #expect(p("Bank\nStatement Period 2026-03-01 to 2026-03-31") == "2026-3")
        #expect(p("Bank\nStatement Period 03/01/2026 thru 03/31/2026") == "2026-3")
        #expect(p("Bank\nStatement Period: Beginning 01/01/2026 Ending 01/31/2026") == "2026-1")
        #expect(p("HDFC Bank\nStatement Period 01/03/2026 to 31/03/2026") == "2026-3", "day first when only that reads")
        #expect(p("Bank\nStatement Date 31 March 2026") == "2026-3")
        #expect(p("Bank\nStatement Date 31-Mar-2026") == "2026-3")
        #expect(p("Card\nClosing Date 12/27/2025\n0% APR 01/15/2025 through 01/15/2027") == "2025-12", "a labelled date beats a printed range")
    }

    @Test func aNoticeOfATaxFormIsNotOne() {
        #expect(DocumentFacts(page: "Fidelity\nYour 2025 Form 1099 is now available\nStatement Period: January 1, 2026 to January 31, 2026").kind == .statement)
    }

    @Test func aFlatTreeNamesTheBankInTheAccountFolder() {
        func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        let acct = "Finance/Chase Checking 1234"
        let tree = [dir("Finance", [dir(acct, (1...6).map { file(acct + String(format: "/eStmt_2025-%02d-28.pdf", $0)) })])]
        let a = AccountIndex.build(tree: tree).accounts.first
        #expect(a?.institution.contains("chase") == true, "\(String(describing: a))")
    }

    @Test func noPeriodMeansNoYearFolderFromAName() {
        func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        let node = dir("A", [dir("A/Statements 2025", (1...6).map { file(String(format: "A/Statements 2025/eStmt_2025-%02d-28.pdf", $0)) })])
        let p = AccountPlacement.place(in: node, period: nil, taxForm: false, fileName: "x.pdf")
        #expect(p.yearUnknown && p.folder.isEmpty, "\(p)")
        let taxes = dir("B", [dir("B/Taxes", [])])
        #expect(AccountPlacement.place(in: taxes, period: nil, taxForm: true, fileName: "x.pdf").folder == "Taxes")
    }

    @Test func copiesTravelWithEveryRebuildOfAHome() {
        let acct = FilingAccount(root: "/D/Fidelity/Checking 0779", ending: "0779", institution: "fidelity", archived: false, kind: .statement)
        var d = FilingDestination(path: "/D/Fidelity/Checking 0779", confidence: .medium, reasons: ["r"], newSegments: ["Checking 0779"],
                                  account: acct)
        d.alsoCopiesTo = [FilingCopy(path: "/D/Fidelity/Roth", proposedName: nil,
                                     account: FilingAccount(root: "/D/Fidelity/Roth", ending: "4657", institution: "fidelity", archived: false, kind: .statement))]
        #expect(d.naming(nil).alsoCopiesTo.count == 1)
        #expect(d.naming("x.pdf", origin: .template).alsoCopiesTo.count == 1)
        #expect(d.withConfidence(.low).alsoCopiesTo.count == 1)
        let renamed = d.renamingNewFolder(to: "Chase Checking")
        #expect(renamed.alsoCopiesTo.count == 1)
        #expect(renamed.account?.root == "/D/Fidelity/Chase Checking", "the account follows its renamed folder")
    }

    @Test func aTaxFormLeadsItsCard() {
        let rule = FilingDestination(path: "/D/Rule", confidence: .high, reasons: ["r"], newSegments: [], remembered: true)
        let guess = FilingDestination(path: "/D/Home/Mortgage/Tax", confidence: .high, reasons: ["word"], newSegments: [])
        let tax = FilingDestination(path: "/D/Schwab/Brokerage 2766/Tax", confidence: .medium, reasons: ["Account ••2766"], newSegments: [])
        #expect(FileSyncManager.leading(tax, in: [rule, guess]).map(\.path) == ["/D/Rule", "/D/Schwab/Brokerage 2766/Tax", "/D/Home/Mortgage/Tax"])
    }
}

@MainActor
@Suite struct FilingRoundOneUndoTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// ⌘Z of the filing that taught a lesson forgets it; ⇧⌘Z teaches it again.
    @Test func redoTeachesTheLessonAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingR1Redo")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        for (i, month) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun"].enumerated() {
            try writeBytes(docs.appendingPathComponent(String(format: "Credit/Chase/Credit 1768/2025/%02d. %@ 2025.pdf", i + 1, month)),
                           Data(repeating: UInt8(i), count: 40))
        }
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Bank/Chase/Joint"), withIntermediateDirectories: true)
        let inbox = root.appendingPathComponent("Inbox")
        let file = inbox.appendingPathComponent("Chase/03. Mar 2026.pdf")
        try writeBytes(file, Data(repeating: 9, count: 41))
        let m = FileSyncManager(defaults: ScratchDefaults("FilingRoundOneUndoTests.redo"))
        let undo = UndoManager()
        m.undoManager = undo
        m.filingContentExtractor = { _ in [] }
        m.filingTokensFromText = { _ in [] }
        m.filingSnippetExtractor = { $0 == file.path ? "JPMorgan Chase Bank\nStatement Period: March 1, 2026 through March 28, 2026\nAccount Number: 000012344139" : nil }
        m.setFilingScansSubfolders(true, for: inbox.path)
        await m.findFilingSuggestions(folder: inbox, providerRoot: docs)
        let card = try #require(m.filingSuggestions.first { $0.filePath == file.path })
        #expect(await m.applyFilingSuggestion(card, to: FilingDestination(path: docs.path + "/Bank/Chase/Joint", confidence: .high,
                                                                          reasons: ["r"], newSegments: []), teachAccount: true) == .moved)
        #expect(m.filingLearnedAccounts.count == 1)
        undo.undo()
        try await waitUntil { m.filingLearnedAccounts.isEmpty }
        #expect(m.filingLearnedAccounts.isEmpty, "⌘Z forgets it")
        undo.redo()
        try await waitUntil { m.filingLearnedAccounts.count == 1 }
        #expect(m.filingLearnedAccounts.first?.folder == "Bank/Chase/Joint", "⇧⌘Z teaches it again")
    }
}
