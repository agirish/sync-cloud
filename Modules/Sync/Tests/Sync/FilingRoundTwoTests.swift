import Testing
import Foundation
@testable import Sync

/// Round two of the second review: what round one's page rules got wrong on real pages, a file
/// name that crashed the scan, and the tree shapes and choices round one missed.
@Suite struct FilingRoundTwoPageTests {
    private func period(_ page: String) -> String { DocumentFacts(page: page).period.map { "\($0.year)-\($0.month)" } ?? "nil" }

    @Test func aLabelledRangeEndsWhereItsSecondDateIs() {
        // Chase cards: the statement is January's, not December's.
        #expect(period("Chase Freedom\nOpening/Closing Date 12/29/25 - 01/28/26\nAccount Number: XXXX XXXX XXXX 1768") == "2026-1")
    }

    @Test func aBalanceAsOfLosesToThePrintedRange() {
        #expect(period("E*TRADE\nAccount at a glance as of 01/31/2026\nFebruary 1, 2026 - February 28, 2026") == "2026-2")
        #expect(period("Fidelity\nBeginning Portfolio Value as of Jan 1, 2025\nInvestment Report January 1, 2025 - December 31, 2025") == "2025-12")
    }

    @Test func aConsolidated1099IsATaxForm() {
        #expect(DocumentFacts(page: "E*TRADE\nThis statement includes your consolidated Form 1099\nTax Year 2025").kind == .taxForm)
        #expect(DocumentFacts(page: "Fidelity\nYour 2025 Form 1099 is now available\nStatement Period: January 1, 2026 to January 31, 2026").kind == .statement)
    }

    @Test func aLongNumberOnTheNextLineIsTheAccounts() {
        let f = DocumentFacts(page: "Chase\nAccount Number:\n000000123452378 DRE 802 142 22\nStatement Period: March 1, 2026 to March 31, 2026")
        #expect(f.ownNumbers.map(\.ending).contains("2378"), "\(f.ownNumbers)")
        #expect(!DocumentFacts(page: "Bank\nAccount: 401(k) Plan\nStatement Period: March 1, 2026 to March 31, 2026").ownNumbers.contains { $0.digits == "401" })
        #expect(DocumentFacts(page: "Bank\nAccount number: 123 456 789.\nStatement Period: March 1, 2026 to March 31, 2026")
                    .ownNumbers.first?.ending == "6789", "a full stop ends a sentence, not an amount")
    }

    @Test func aFileNameWithOtherScriptsDigitsDoesntCrash() {
        #expect(StatementFamily.period(ofName: "Statement_2026-٠٣-٣١.pdf", folder: "") == nil)
        #expect(StatementFamily.period(ofName: "Statement ０٣٣١2026.pdf", folder: "") == nil)
    }

    @Test func aFlatTreeWithTheBankAtTheTopMatchesByThePage() {
        func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        let acct = "Chase/Sapphire Reserve 1234"
        let tree = [dir("Chase", [dir(acct, (1...6).map { file(acct + String(format: "/eStmt_2025-%02d-28.pdf", $0)) })])]
        let index = AccountIndex.build(tree: tree)
        #expect(index.accounts.first?.institution == "chase", "the top-level bank stays the bank")
        let page = DocumentFacts(page: "Chase Sapphire\nStatement Period: March 1, 2026 to March 31, 2026\nAccount Number XXXX XXXX XXXX 1234")
        guard case .high(let a, _) = index.match(page) else { Issue.record("\(index.match(page))"); return }
        #expect(a.root == acct)
    }

    @Test func theSurveysInboxIsNeverAnAccount() {
        func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        let acct = "To Sort/Chase/Checking 0779"
        let tree = [dir("To Sort", [dir("To Sort/Chase", [dir(acct, (1...6).map { file(acct + String(format: "/eStmt_2025-%02d-28.pdf", $0)) })])])]
        #expect(!AccountIndex.build(tree: tree).accounts.isEmpty, "by name it isn't one")
        #expect(AccountIndex.build(tree: tree, isInbox: { $0.hasPrefix("To Sort") }).accounts.isEmpty, "the survey says it is")
    }

    @Test func aMovedAccountKeepsItsPlaceInTheWalkedTree() {
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        let tree = [dir("Inv", [dir("Inv/Archive", [dir("Inv/Archive/Schwab", [dir("Inv/Archive/Schwab/Roth 2336", [])])])])]
        let moved = FileSyncManager.relocatingNode(in: tree, from: "Inv/Archive/Schwab/Roth 2336", to: "Inv/Schwab/Roth 2336")
        #expect(AccountProposal.node(at: "Inv/Schwab/Roth 2336", in: moved) != nil)
        #expect(AccountProposal.node(at: "Inv/Archive/Schwab/Roth 2336", in: moved) == nil)
    }
}

@MainActor
@Suite struct FilingRoundTwoFlowTests {
    /// Scanning a folder one level, a home below it typed or chosen is not "the folder being
    /// filed from".
    @Test func aFolderBelowAOneLevelScanIsAHome() throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingR2Below")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Finance/Chase/Checking 1234"), withIntermediateDirectories: true)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingRoundTwoFlowTests.below"))
        m.filingLastProviderRoot = docs.path
        m.filingScanFolder = docs.path + "/Finance"
        m.filingScanExcludesSubtree = false
        let card = FilingSuggestion(filePath: docs.path + "/Finance/x.pdf", fileName: "x.pdf", size: 1, modificationDate: nil,
                                    candidates: [], providerRoot: docs.path)
        #expect((try? m.filingDestination(typed: "Finance/Chase/Checking 1234", for: card).get()) != nil)
        #expect(m.filingDestination(typed: "Finance", for: card) == .failure(.intoSource), "the folder itself never")
        m.filingScanExcludesSubtree = true
        #expect(m.filingDestination(typed: "Finance/Chase/Checking 1234", for: card) == .failure(.intoSource), "a scan that read below it")
    }

    /// Try Another said "not there": the next scan doesn't put the account back.
    @Test func aRejectedAccountIsNotOfferedAgain() {
        func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
        func dir(_ p: String, _ c: [FileNode]) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c) }
        let acct = "Bank/Chase/Checking 1234"
        let tree = [dir("Bank", [dir("Bank/Chase", [dir(acct, (1...6).map { file(acct + String(format: "/eStmt_2025-%02d-28.pdf", $0)) })])])]
        let index = AccountIndex.build(tree: tree)
        let card = FilingSuggestion(filePath: "/In/a.pdf", fileName: "a.pdf", size: 1, modificationDate: nil, candidates: [], providerRoot: "/D")
        let page = "JPMorgan Chase Bank\nStatement Period: March 1, 2026 to March 31, 2026\nAccount Number 000012341234"
        let offered = FileSyncManager.applyingAccounts([card], index: index, snippets: [card.filePath: page], taxonomy: tree,
                                                       root: "/D", scannedFolder: "/In").suggestions[0]
        #expect(offered.best?.account != nil)
        let refused = FileSyncManager.applyingAccounts([card], index: index, snippets: [card.filePath: page], taxonomy: tree,
                                                       root: "/D", scannedFolder: "/In",
                                                       rejected: [card.filePath: ["/D/" + acct]]).suggestions[0]
        #expect(refused.best?.account == nil, "\(String(describing: refused.best?.path))")
    }
}
