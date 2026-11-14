import Testing
import Foundation
@testable import Sync

/// The cases the review of the statement-filing overhaul found: a payment line's number, a number
/// running into a date, a year inside a folder name, a labelled period below another date, a tax
/// form named in passing, a category with digits, an inbox as a proposal's parent.
@Suite struct AccountIdentityReviewTests {
    private func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
    private func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
    private func account(_ p: String, folder: String = "2025") -> FileNode {
        dir(p, [dir(p + "/" + folder, (1...6).map { file(p + "/" + folder + String(format: "/eStmt_2025-%02d-28.pdf", $0)) })])
    }

    @Test func aPaymentLinesAccountIsNotThePagesOwn() {
        let f = DocumentFacts(page: """
            Chase Freedom
            Statement Period: 02/20/26 - 03/19/26
            Account number: XXXX XXXX XXXX 1768
            AutoPay from account ending in 5696
            Transfer from account number 0004121
            """)
        #expect(f.matchingNumbers.map(\.ending) == ["1768"], "\(f.ownNumbers)")
        let tree = [dir("Bank Accounts", [dir("Bank Accounts/Chase", [account("Bank Accounts/Chase/Checking 5696")])])]
        #expect(AccountIndex.build(tree: tree).match(f).account == nil, "not the checking account it is paid from")
    }

    @Test func aNumberStopsBeforeTheDateAfterIt() {
        let f = DocumentFacts(page: "Bank\nAccount # 1234-5678 03/31/2026\nStatement Period: March 1, 2026 to March 31, 2026")
        #expect(f.ownNumbers.first?.ending == "5678", "\(f.ownNumbers)")
    }

    @Test func aTaxpayerWordMustBeAWord() {
        let f = DocumentFacts(page: "Investing Account Number 3345678\nStatement Period: March 1, 2026 to March 31, 2026")
        #expect(f.ownNumbers.map(\.ending) == ["5678"])
    }

    @Test func theLabelledPeriodWinsOverOtherDates() {
        let f = DocumentFacts(page: """
            Bank
            Beginning balance as of 12/31/2025
            Statement Period 02/01/2026 - 02/28/2026
            Rewards earned Jan 1-31, 2026
            """)
        #expect(f.period?.year == 2026 && f.period?.month == 2, "\(String(describing: f.period))")
    }

    @Test func aStatementNamingATaxFormIsAStatement() {
        let filler = String(repeating: "Your balance and activity are below. ", count: 10)
        let f = DocumentFacts(page: "Fidelity Investments\nStatement Period: February 1, 2026 to February 28, 2026\n\(filler)\nYour 2025 Form 1099 is available")
        #expect(f.kind == .statement)
        #expect(DocumentFacts(page: "Form 1099-DIV 2025\nFidelity Investments\nAccount Number Z26-141750").kind == .taxForm)
    }

    @Test func aYearInsideAFolderNameMovesWithTheStatement() throws {
        let node = account("Bank/Chase/Checking 5696", folder: "Statements 2025")
        let p = AccountPlacement.place(in: node, period: .init(year: 2026, month: 1), taxForm: false, fileName: "x.pdf")
        #expect(p.folder == "Statements 2026", "\(p.folder)")
        #expect(p.newSegments == ["Statements 2026"])
    }

    @Test func aCategoryWithDigitsDoesntSwallowTheAccountsBelow() {
        let tree = [dir("Investments", [dir("Investments/401k", [dir("Investments/401k/Fidelity", [account("Investments/401k/Fidelity/HPE 4138")])])])]
        let roots = AccountIndex.build(tree: tree).accounts.map(\.root)
        #expect(roots == ["Investments/401k/Fidelity/HPE 4138"], "\(roots)")
    }

    @Test func aProposalNeverGoesIntoAnInbox() {
        let tree = [dir("Inbox", [dir("Inbox/Chase", [])]),
                    dir("Money", [dir("Money/Chase", []), dir("Money/Citi", [account("Money/Citi/Checking 1111")])])]
        let p = AccountProposal.propose(institution: "chase", type: "Checking", ending: "0779",
                                        index: AccountIndex.build(tree: tree), tree: tree, period: nil)
        #expect(p?.accountRoot.hasPrefix("Inbox") != true, "\(p?.accountRoot ?? "nil")")
    }
}
