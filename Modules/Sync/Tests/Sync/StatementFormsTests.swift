import Foundation
import Testing
@testable import Sync

/// A year-end summary is `0. Summary YYYY` in its year's folder; a trade confirmation is
/// `Trade Confirms/<year>/DD Mon YYYY` (``StatementForms``).
@Suite struct StatementFormsTests {
    typealias P = DocumentFacts.Period

    @Test func pageOneSaysWhichFormItIs() {
        func form(_ page: String) -> StatementForms.Form? { StatementForms.form(of: DocumentFacts(page: page)) }
        #expect(form("Bank of America 2016 Year End Summary Prepared for: SHWETA DANI") == .yearEndSummary(year: 2016))
        #expect(form("Page 1 of 2 2022 Year-End Summary Includes charges from January 1 through December 31, 2022") == .yearEndSummary(year: 2022))
        #expect(form("2025 YEAR-END INVESTMENT REPORT January 1, 2025 - December 31, 2025") == .yearEndSummary(year: 2025))
        #expect(form("Your Account Summary Statement Period: 01/01/2020 to 12/31/2020") == .yearEndSummary(year: 2020),
                "a whole year's period is the year's summary")
        #expect(form("Account summary Statement Period: 01/01/2020 to 03/31/2020") == nil, "a quarter is a statement")
        #expect(form("Account Number 9465-8260 Trade Confirmation 12/30/2020 Bought 10 shares")
                == .tradeConfirm(date: P(year: 2020, month: 12, day: 30)))
        #expect(form("BROKERAGE NO. Z26 TRANSACTION CONFIRMATION TYPE TRADE DATE SETTLEMENT DATE TRANS NO. 1 04-28-23 05-04-23")
                == .tradeConfirm(date: P(year: 2023, month: 4, day: 28)), "the trade date, under its column heading")
        #expect(form("Account summary for February 26, 2026 to March 27, 2026") == nil)
    }

    @Test func theNamesAreHis() {
        #expect(StatementForms.summaryName(year: 2025, ext: "pdf") == "0. Summary 2025.pdf")
        #expect(StatementForms.confirmName(P(year: 2023, month: 5, day: 4), ext: "pdf") == "04 May 2023.pdf")
    }

    private func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
    private func dir(_ p: String, _ c: [FileNode]) -> FileNode {
        FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c)
    }

    @Test func eachFormIsPlacedInsideItsAccount() {
        let a = "Credit 6397"
        let card = dir(a, [dir(a + "/2025", (1...12).map { file(a + String(format: "/2025/%02d. ", $0) + StatementForms.monthNames[$0 - 1] + " 2025.pdf") })])
        let summary = DocumentFacts(page: "Bank of America 2025 Year End Summary Prepared for: ABHISHEK")
        let s = FileSyncManager.placement(in: card, facts: summary, period: summary.period, monthFromName: false,
                                          fileName: "YES_2025.pdf", bank: nil)
        #expect(s.folder == "2025" && s.name == "0. Summary 2025.pdf", "\(s)")

        let b = "Roth IRA 8260"
        let ira = dir(b, [dir(b + "/Trade Confirms", [dir(b + "/Trade Confirms/2025", [file(b + "/Trade Confirms/2025/02 Jan 2025.pdf")])]),
                          dir(b + "/Statements", [])])
        let confirm = DocumentFacts(page: "Account Number 9465-8260 Trade Confirmation 03/14/2026 Bought")
        let c = FileSyncManager.placement(in: ira, facts: confirm, period: confirm.period, monthFromName: false,
                                          fileName: "Trade_Confirm.PDF", bank: nil)
        #expect(c.folder == "Trade Confirms/2026" && c.newSegments == ["2026"] && c.name == "14 Mar 2026.pdf", "\(c)")

        // An account with no `Trade Confirms` folder places a confirm as before.
        let plain = FileSyncManager.placement(in: card, facts: confirm, period: confirm.period, monthFromName: false,
                                              fileName: "Trade_Confirm.pdf", bank: nil)
        #expect(plain.folder != "Trade Confirms/2026")
    }
}
