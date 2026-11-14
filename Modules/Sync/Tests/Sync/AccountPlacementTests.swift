import Testing
import Foundation
@testable import Sync

/// Placement and naming copy the account's own newest statements. Layouts are the ones the dry run
/// met: statements loose in the account folder since a year, `Statements/<year>`, `<year>`, a
/// Fidelity-style name dated a day before month end, a tax folder, and a folder whose newest files
/// are transaction histories, not statements.
@Suite struct AccountPlacementTests {

    private func file(_ name: String) -> FileNode {
        FileNode(id: "/A/" + name, name: name, isDirectory: false, fileSize: 9000)
    }
    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: "/A/" + name, name: (name as NSString).lastPathComponent, isDirectory: true, children: children)
    }
    private func ymd(_ prefix: String, _ y: Int, _ months: ClosedRange<Int>, _ suffix: String) -> [FileNode] {
        months.map { m in file(String(format: "%@%d-%02d-%02d%@", prefix, y, m, AccountPlacement.monthEnd(y, m), suffix)) }
    }

    @Test func statementsLooseInTheAccountFolderStayThereNamedLikeTheirNeighbours() {
        let account = dir("Traditional IRA 7863", ymd("Brokerage Statement_", 2025, 1...7, "_863.PDF") + [
            dir("Statements", [dir("2021", (1...9).map { file(String(format: "%d. ", $0) + ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep"][$0 - 1] + " 2021.pdf") })]),
            file("Traditional_IRA_XXX863_Transactions_20250817-013343.csv"),
        ])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 10, day: 31), taxForm: false,
                                       fileName: "10. Oct 2026.pdf")
        #expect(p.folder == "" && p.newSegments.isEmpty)
        #expect(p.name == "Brokerage Statement_2026-10-31_863.PDF", "\(String(describing: p.name))")
    }

    @Test func aStatementsYearLayoutGetsANewYearFolder() {
        let account = dir("Trust Brokerage 2 - 3494", [dir("Statements", [
            dir("2024", ymd("Brokerage Statement_", 2024, 1...12, "_494.PDF")),
            dir("2025", ymd("Brokerage Statement_", 2025, 1...12, "_494.PDF")),
        ])])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 3, day: 31), taxForm: false,
                                       fileName: "03. Mar 2026.pdf")
        #expect(p.folder == "Statements/2026" && p.newSegments == ["2026"])
        #expect(p.name == "Brokerage Statement_2026-03-31_494.PDF")
    }

    @Test func theDayTheAccountNamesItsFilesByIsKept() {
        // Named a day before each month's end: Jan 30, Feb 27, Mar 30.
        let names = ["Statement01302026.pdf", "Statement02272026.pdf", "Statement03302026.pdf"]
        let account = dir("Statements", [dir("2026", names.map(file))])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 9, day: 30), taxForm: false,
                                       fileName: "09. Sep 2026.pdf")
        #expect(p.folder == "2026" && p.newSegments.isEmpty)
        #expect(p.name == "Statement09292026.pdf", "\(String(describing: p.name))")
    }

    @Test func transactionHistoriesDontDecideWhereStatementsGo() {
        // The newest files in the account folder are reports with no monthly cadence.
        let account = dir("Trust Brokerage 1 - 2766", [
            file("META Transaction History - Jan to Jul 2026.pdf"),
            file("Balance Verification Letter - May 2026.pdf"),
            dir("2025", ymd("Brokerage Statement_", 2025, 1...12, "_766.PDF")),
            dir("2026", ymd("Brokerage Statement_", 2026, 1...2, "_766.PDF")),
        ])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 10, day: 31), taxForm: false,
                                       fileName: "10. Oct 2026.pdf")
        #expect(p.folder == "2026" && p.newSegments.isEmpty)
        #expect(p.name == "Brokerage Statement_2026-10-31_766.PDF")
    }

    @Test func noPeriodMeansNoYearFolderAndNotHigh() {
        let account = dir("Checking 6436", [dir("2023", ymd("Statement_", 2023, 1...12, ".pdf"))])
        let p = AccountPlacement.place(in: account, period: nil, taxForm: false, fileName: "statement.pdf")
        #expect(p.folder == "" && p.yearUnknown && p.name == nil, "never the newest filed year: \(p)")
    }

    @Test func aCSVExportDoesntDecideWhereAPDFGoesOrWhatItIsCalled() {
        let account = dir("Traditional IRA 7863", [
            dir("2025", ymd("Brokerage Statement_", 2025, 1...12, "_863.PDF")),
            dir("Exports", ymd("Brokerage Statement_", 2026, 1...6, "_863.csv")),
        ])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 3, day: 31), taxForm: false, fileName: "x.pdf")
        #expect(p.folder == "2026" && p.name == "Brokerage Statement_2026-03-31_863.PDF", "\(p)")
    }

    @Test func aMonthFolderIsReDated() {
        let months = ["Jan", "Feb", "Mar", "Apr"]
        let account = dir("Credit 9278", [dir("2025", (1...4).map { m in
            dir(String(format: "2025/%02d. %@ 2025", m, months[m - 1]), [file(String(format: "%02d. %@ 2025.pdf", m, months[m - 1]))]) })])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 2), taxForm: false, fileName: "x.pdf")
        #expect(p.folder == "2026/02. Feb 2026", "\(p)")
        #expect(p.newSegments == ["2026", "02. Feb 2026"], "\(p)")
    }

    @Test func taxFormsGoToTheAccountsTaxFolderOrItsRoot() {
        let withTax = dir("Roth IRA 8260", [dir("Tax", [file("5498 2024.pdf")]),
                                            dir("Statements", [dir("2021", ymd("Statement_", 2021, 1...12, ".pdf"))])])
        #expect(AccountPlacement.place(in: withTax, period: .init(year: 2025, month: 12, day: 31), taxForm: true,
                                       fileName: "Tax - 5498 2025.pdf").folder == "Tax")
        let noTax = dir("Trust Brokerage 1 - 2766", [dir("2025", ymd("Brokerage Statement_", 2025, 1...12, "_766.PDF"))])
        let p = AccountPlacement.place(in: noTax, period: .init(year: 2025, month: 12, day: 31), taxForm: true,
                                       fileName: "Tax - 1099 2025.pdf")
        #expect(p.folder == "" && p.name == nil, "the root is the tax home, and a form keeps its name")
    }

    @Test func aNameCarryingAnotherAccountsNumberIsNoTemplate() {
        let mixed = dir("Traditional IRA 7863", [
            file("BrokerageStatement 2025-10-31_260.pdf"), file("BrokerageStatement 2025-11-30_260.pdf"),
            file("BrokerageStatement 2025-12-31_260.pdf"),
        ])
        let p = AccountPlacement.place(in: mixed, period: .init(year: 2026, month: 1, day: 31), taxForm: false,
                                       fileName: "01. Jan 2026.pdf")
        #expect(p.name == nil, "a `_260` in 7863's folder is another account's file")
    }

    @Test func monthEndAndOrdinalNamesNeedOnlyTheMonth() {
        let account = dir("Credit 22002", [dir("2025", ymd("Statement_", 2025, 1...12, ".pdf"))])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 3), taxForm: false, fileName: "03. Mar 2026.pdf")
        #expect(p.name == "Statement_2026-03-31.pdf", "month-end names need only the month")
        let ordinal = dir("Credit 1768", [dir("2025", (1...6).map { file(String(format: "%02d. ", $0) + ["Jan","Feb","Mar","Apr","May","Jun"][$0 - 1] + " 2025.pdf") })])
        #expect(AccountPlacement.place(in: ordinal, period: .init(year: 2026, month: 2), taxForm: false,
                                       fileName: "x.pdf").name == "02. Feb 2026.pdf")
    }
}

/// The phase in a scan: a statement whose page prints its account's number leads with that account,
/// at High, never in the unseen batch, and the model isn't asked about it.
@MainActor
@Suite struct FilingAccountScanTests {
    @Test func aStatementGoesToItsAccountAtHighAndTheModelIsNotAsked() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAccountScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("Docs/Bank Accounts/Bank of America/Checking 5696")
        for m in 1...6 {
            try writeBytes(account.appendingPathComponent(String(format: "2025/eStmt_2025-%02d-28.pdf", m)), Data(repeating: 0x41, count: 64))
        }
        try writeBytes(root.appendingPathComponent("Docs/Vehicles/Tesla/.keep"), Data(repeating: 0x41, count: 1))
        let inbox = root.appendingPathComponent("Inbox")
        let statement = inbox.appendingPathComponent("03. Mar 2026.pdf")
        try writeBytes(statement, Data(repeating: 0x41, count: 64))
        // A letter: the model is still asked about this one, so the check below means something.
        let letter = inbox.appendingPathComponent("Note from the school.pdf")
        try writeBytes(letter, Data(repeating: 0x41, count: 64))

        let m = FileSyncManager(defaults: ScratchDefaults("AccountPlacementTests.1"))
        let page = """
        Bank of America Advantage Banking
        for February 26, 2026 to March 27, 2026
        Account number: 2370 2420 5696
        """
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { $0 == statement.path ? page : nil }
        m.filingTokensFromText = { _ in [] }
        var asked: [String] = []
        m.filingClassifier = { _, files, _ in
            await MainActor.run { asked += files.map(\.filePath) }
            return [:]
        }
        await m.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Docs"))

        let card = try #require(m.filingSuggestions.first { $0.filePath == statement.path })
        let best = try #require(card.best)
        #expect(best.path == account.path + "/2026", "\(best.path)")
        #expect(best.newSegments == ["2026"])
        #expect(best.confidence == .high)
        #expect(best.account?.ending == "5696" && best.account?.institution == "bank of america")
        #expect(best.proposedName == "eStmt_2026-03-27.pdf" && best.nameOrigin == .template,
                "named like its neighbours, dated from the page: \(String(describing: best.proposedName))")
        #expect(!card.isBatchEligible, "an account match is read from the page, so it needs a click")
        #expect(!asked.contains(statement.path), "the model isn't asked where a statement goes")
        #expect(asked.contains(letter.path), "a page with no account is still the model's to place")
    }
}
