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
    private static func monthEnd(_ y: Int, _ m: Int) -> Int {
        Calendar(identifier: .gregorian).range(of: .day, in: .month,
            for: DateComponents(calendar: Calendar(identifier: .gregorian), year: y, month: m, day: 1).date!)!.count
    }
    private func ymd(_ prefix: String, _ y: Int, _ months: ClosedRange<Int>, _ suffix: String) -> [FileNode] {
        months.map { m in file(String(format: "%@%d-%02d-%02d%@", prefix, y, m, Self.monthEnd(y, m), suffix)) }
    }

    @Test func statementsLooseInTheAccountFolderStayThereInHisName() {
        let account = dir("Traditional IRA 7863", ymd("Brokerage Statement_", 2025, 1...7, "_863.PDF") + [
            dir("Statements", [dir("2021", (1...9).map { file(String(format: "%d. ", $0) + ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep"][$0 - 1] + " 2021.pdf") })]),
            file("Traditional_IRA_XXX863_Transactions_20250817-013343.csv"),
        ])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 10, day: 31), taxForm: false,
                                       fileName: "10. Oct 2026.pdf")
        #expect(p.folder == "" && p.newSegments.isEmpty)
        // His `NN. Mon YYYY` name, not the bank's, with the extension as the account spells it.
        #expect(p.name == "10. Oct 2026.PDF", "\(String(describing: p.name))")
    }

    @Test func aStatementsYearLayoutGetsANewYearFolder() {
        let account = dir("Trust Brokerage 2 - 3494", [dir("Statements", [
            dir("2024", ymd("Brokerage Statement_", 2024, 1...12, "_494.PDF")),
            dir("2025", ymd("Brokerage Statement_", 2025, 1...12, "_494.PDF")),
        ])])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 3, day: 31), taxForm: false,
                                       fileName: "03. Mar 2026.pdf")
        #expect(p.folder == "Statements/2026" && p.newSegments == ["2026"])
        #expect(p.name == "03. Mar 2026.PDF")
    }

    @Test func aBankNamedAccountStillGetsHisName() {
        // Amex Credit 22002 as he keeps it: bank-named, with months missing (Aug, Oct, Dec 2022;
        // Jan, Jun, Jul, Dec 2023; Apr, Jun–Sep 2024). Decision OR names the new statement `01. Jan 2026.pdf`: his
        // name, and two digits, since a gap of a month or two is a monthly card he skipped.
        let account = dir("Credit 22002", [
            dir("2022", ["2022-08-29", "2022-10-28", "2022-12-29"].map { file($0 + ".pdf") }),
            dir("2023", ["2023-01-29", "2023-06-28", "2023-07-28", "2023-12-29"].map { file($0 + ".pdf") }),
            dir("2024", ["2024-04-28", "2024-06-28", "2024-07-29", "2024-08-29", "2024-09-27"].map { file($0 + ".pdf") }),
        ])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 1, day: 28), taxForm: false,
                                       fileName: "statement.pdf")
        #expect(p.folder == "2026" && p.name == "01. Jan 2026.pdf", "\(p)")
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
        #expect(p.name == "10. Oct 2026.PDF")
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
        #expect(p.folder == "2026" && p.name == "03. Mar 2026.PDF", "\(p)")
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

    @Test func hisNameNeedsOnlyTheMonth() {
        let account = dir("Credit 22002", [dir("2025", ymd("Statement_", 2025, 1...12, ".pdf"))])
        let p = AccountPlacement.place(in: account, period: .init(year: 2026, month: 3), taxForm: false, fileName: "x.pdf")
        #expect(p.name == "03. Mar 2026.pdf", "a period with no day still names the statement")
        let ordinal = dir("Credit 1768", [dir("2025", (1...6).map { file(String(format: "%02d. ", $0) + ["Jan","Feb","Mar","Apr","May","Jun"][$0 - 1] + " 2025.pdf") })])
        #expect(AccountPlacement.place(in: ordinal, period: .init(year: 2026, month: 2), taxForm: false,
                                       fileName: "x.pdf").name == "02. Feb 2026.pdf")
    }

    @Test func theOrdinalIsPaddedByCadenceNotCopied() {
        let mon = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        // BofA Credit 6397: a monthly account whose newest name slipped to one digit. February is
        // `02.`, not a copy of January's `1.`.
        let monthly = dir("Credit 6397", [
            dir("2025", (1...12).map { file(String(format: "%02d. ", $0) + mon[$0 - 1] + " 2025.pdf") }),
            dir("2026", [file("1. Jan 2026.pdf")])])
        #expect(AccountPlacement.place(in: monthly, period: .init(year: 2026, month: 2), taxForm: false,
                                       fileName: "x.pdf").name == "02. Feb 2026.pdf")
        // A quarterly account written one-digit stays one-digit.
        let quarterly = dir("Brokerage 4410", [dir("2025", [3, 6, 9, 12].map { file("\($0). \(mon[$0 - 1]) 2025.pdf") })])
        #expect(AccountPlacement.place(in: quarterly, period: .init(year: 2026, month: 3), taxForm: false,
                                       fileName: "x.pdf").name == "3. Mar 2026.pdf")
    }
}

/// A statement covering two months or more is named for them: `3. Jan-Mar 2026`.
@Suite struct StatementRangeNameTests {
    typealias P = DocumentFacts.Period
    @Test func theMonthsAStatementCovers() {
        func covered(_ s: P, _ e: P) -> String? {
            AccountPlacement.coveredMonths(start: s, end: e).map { "\($0.first)-\($0.last)" }
        }
        #expect(covered(P(year: 2026, month: 1, day: 1), P(year: 2026, month: 3, day: 31)) == "1-3")
        #expect(covered(P(year: 2026, month: 2, day: 26), P(year: 2026, month: 3, day: 27)) == nil, "a monthly cycle stays one month")
        #expect(covered(P(year: 2025, month: 12, day: 21), P(year: 2026, month: 3, day: 20)) == "1-3", "a start on the 20th counts from the next month")
        #expect(covered(P(year: 2026, month: 4, day: 1), P(year: 2026, month: 6, day: 3)) == "4-5", "an end by the 5th counts as the month before")
        #expect(covered(P(year: 2025, month: 11, day: 1), P(year: 2026, month: 1, day: 31)) == nil, "across a new year: the end alone")
    }

    @Test func aQuarterlyIsNamedForItsMonths() {
        let members = [3, 6, 9, 12].map { StatementFamily.Member(name: "\($0). x 2025.pdf", folder: "", period: P(year: 2025, month: $0)) }
        #expect(AccountPlacement.houseName(P(year: 2026, month: 3, day: 31), start: P(year: 2026, month: 1, day: 1),
                                           members: members, ext: "pdf") == "3. Jan-Mar 2026.pdf")
        #expect(AccountPlacement.houseName(P(year: 2026, month: 3, day: 31), members: members, ext: "pdf") == "3. Mar 2026.pdf",
                "without a start, as before")
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
        let statement = inbox.appendingPathComponent("eStmt_2026-03-27.pdf")
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
        #expect(best.proposedName == "03. Mar 2026.pdf" && best.nameOrigin == .template,
                "his name, dated from the page, not the bank's `eStmt_`: \(String(describing: best.proposedName))")
        #expect(!card.isBatchEligible, "an account match is read from the page, so it needs a click")
        #expect(!asked.contains(statement.path), "the model isn't asked where a statement goes")
        #expect(asked.contains(letter.path), "a page with no account is still the model's to place")
    }

    /// A page with no period leaves the month to the file name, which is when the statement was
    /// fetched, not the period it holds. It still places the file, at Medium, and says so.
    @Test func aMonthFromTheFileNameIsNeverHigh() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAccountNameMonth")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("Docs/Bank Accounts/Bank of America/Checking 5696")
        for m in 1...6 {
            try writeBytes(account.appendingPathComponent(String(format: "2025/eStmt_2025-%02d-28.pdf", m)), Data(repeating: 0x41, count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        let statement = inbox.appendingPathComponent("eStmt_2026-03-27.pdf")
        try writeBytes(statement, Data(repeating: 0x41, count: 64))
        let m = FileSyncManager(defaults: ScratchDefaults("AccountPlacementTests.2"))
        let page = """
        Bank of America Advantage Banking
        Account summary
        Account number: 2370 2420 5696
        """
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { $0 == statement.path ? page : nil }
        m.filingTokensFromText = { _ in [] }
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Docs"))

        let card = try #require(m.filingSuggestions.first { $0.filePath == statement.path })
        let best = try #require(card.best)
        #expect(best.path == account.path + "/2026", "the name's month still places it: \(best.path)")
        #expect(best.account?.ending == "5696")
        #expect(best.confidence == .medium)
        #expect(best.reasons.contains { $0.contains("month from the file name") }, "\(best.reasons)")
    }

    /// A tax form leads into its tax year's folder for its kind, after every other lane (``TaxLane``).
    @Test func aW2GoesToItsTaxYear() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTaxLane")
        defer { try? FileManager.default.removeItem(at: root) }
        let tax = root.appendingPathComponent("Docs/Finance/US/Income Tax")
        try writeBytes(tax.appendingPathComponent("2024/Income/Form W-2/W-2 2024.pdf"), Data(repeating: 0x41, count: 64))
        let account = root.appendingPathComponent("Docs/Bank Accounts/Bank of America/Checking 5696")
        for m in 1...6 {
            try writeBytes(account.appendingPathComponent(String(format: "2025/eStmt_2025-%02d-28.pdf", m)), Data(repeating: 0x41, count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        let w2 = inbox.appendingPathComponent("W2_2025.pdf")
        try writeBytes(w2, Data(repeating: 0x41, count: 64))
        let m = FileSyncManager(defaults: ScratchDefaults("AccountPlacementTests.5"))
        let page = "Form W-2 Wage and Tax Statement 2025\nEmployer identification number 12-3456789"
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { $0 == w2.path ? page : nil }
        m.filingTokensFromText = { _ in [] }
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Docs"))
        let best = try #require(m.filingSuggestions.first { $0.filePath == w2.path }?.best)
        #expect(best.path == tax.path + "/2025/Income/Form W-2", "\(best.path)")
        #expect(best.newSegments == ["2025", "Income", "Form W-2"])
    }

    /// A quarterly statement's card names the months it covers, from the range page 1 prints.
    @Test func aQuarterlyCardIsNamedForItsMonths() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAccountQuarter")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("Docs/Bank Accounts/Bank of America/Savings 5582")
        for (m, mon) in [(3, "Mar"), (6, "Jun"), (9, "Sep"), (12, "Dec")] {
            try writeBytes(account.appendingPathComponent("2025/\(m). \(mon) 2025.pdf"), Data(repeating: 0x41, count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        let statement = inbox.appendingPathComponent("eStmt_2026-04-02.pdf")
        try writeBytes(statement, Data(repeating: 0x41, count: 64))
        let m = FileSyncManager(defaults: ScratchDefaults("AccountPlacementTests.4"))
        let page = """
        Bank of America Advantage Savings
        Statement Period January 1, 2026 - March 31, 2026
        Account number: 2370 2420 5582
        """
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { $0 == statement.path ? page : nil }
        m.filingTokensFromText = { _ in [] }
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Docs"))
        let best = try #require(m.filingSuggestions.first { $0.filePath == statement.path }?.best)
        #expect(best.path == account.path + "/2026")
        #expect(best.proposedName == "3. Jan-Mar 2026.pdf", "\(String(describing: best.proposedName))")
    }
    /// A policy paper's home is moved to its term's year after every lane has spoken
    /// (``PolicyTerms``), whichever lane found the policy's folder.
    @Test func aPolicyRenewalLandsInItsTermsYear() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingPolicyTerm")
        defer { try? FileManager.default.removeItem(at: root) }
        let insurance = root.appendingPathComponent("Docs/Home/Insurance")
        for name in ["2025/Acme-Homesafe Policy - Jan 2025-Jan 2026.pdf",
                     "2025/Acme-Homesafe Evidence of Insurance - Jan 2025-Jan 2026.pdf",
                     "2024/Acme-Homesafe Policy - Jan 2024-Jan 2025.pdf"] {
            try writeBytes(insurance.appendingPathComponent(name), Data(repeating: 0x41, count: 64))
        }
        // An account elsewhere, so the scan reads page 1 as it does on a real tree.
        let account = root.appendingPathComponent("Docs/Bank Accounts/Bank of America/Checking 5696")
        for m in 1...6 {
            try writeBytes(account.appendingPathComponent(String(format: "2025/eStmt_2025-%02d-28.pdf", m)), Data(repeating: 0x41, count: 64))
        }
        let inbox = root.appendingPathComponent("Inbox")
        let letter = inbox.appendingPathComponent("Home Insurance Renewal.pdf")
        try writeBytes(letter, Data(repeating: 0x41, count: 64))
        let m = FileSyncManager(defaults: ScratchDefaults("AccountPlacementTests.3"))
        let page = """
        Acme Insurance Agency Underwritten by: HOMESAFE INSURANCE COMPANY
        Renewal For Policy Number 12345678 November 11, 2025
        Thank you for renewing your condominium policy. Please review your declarations page.
        """
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { $0 == letter.path ? page : nil }
        m.filingTokensFromText = { _ in [] }
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Docs"))

        let card = try #require(m.filingSuggestions.first { $0.filePath == letter.path })
        let best = try #require(card.best)
        #expect(best.path == insurance.path + "/2026", "\(card.candidates.map(\.path))")
        #expect(best.proposedName == "Acme-Homesafe Renewal - Jan 2026-Jan 2027.pdf")
    }
}
