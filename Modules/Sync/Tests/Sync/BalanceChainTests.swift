import Foundation
@testable import Sync
import Testing

/// What a statement opened and closed at, read from page 1 as each bank prints it.
@Suite struct BalanceChainReadingTests {
    private func read(_ page: String) -> BalanceChain.Balances { BalanceChain.balances(in: page) }

    @Test func aCardStatementsPreviousAndNewBalance() {
        let b = read("""
        Account Summary
        Previous Balance $1,234.56
        Payments and Other Credits -$1,234.56
        New Balance $2,000.07
        """)
        #expect(b.opening == [123456] && b.closing == [200007], "\(b)")
    }

    /// Apple Card prints `Previous Total Balance` beside `Total Balance`: the first opens.
    @Test func previousTotalBalanceIsTheOpeningNotTheClosing() {
        let b = read("""
        Previous Total Balance $500.10
        Total Balance $612.00
        Prior Monthly Balance $80.00
        """)
        #expect(b.opening == [50010, 8000] && b.closing == [61200], "\(b)")
    }

    /// A date between the label and the amount: Bank of America's and Citi's.
    @Test func aDateBetweenTheLabelAndTheAmount() {
        let b = read("""
        Beginning balance on March 1, 2025 $3,400.00
        Ending balance on March 31, 2025 $3,512.25
        New balance as of 01/27/26: $99.10
        """)
        #expect(b.opening == [340000] && b.closing == [351225, 9910], "\(b)")
    }

    /// A two-column summary extracts the label on one line and its value on the next.
    @Test func theValueOnTheNextLine() {
        let b = read("New Balance\n$45.67\nMinimum Payment Due\n$25.00")
        #expect(b.closing == [4567] && b.opening.isEmpty, "\(b)")
    }

    /// A card paid in full opens at zero every month: zero names no account. Points are no balance.
    @Test func zeroAndPointsBalancesAreLeftOut() {
        let b = read("""
        Previous Balance $0.00
        Beginning Points Balance 1,234.00
        New Balance $10.00 CR
        """)
        #expect(b.opening.isEmpty && b.closing == [1000], "\(b)")
    }

    /// Bank of America runs a spaced dot leader from the label to the amount, longer than any date.
    @Test func aLongDotLeaderBeforeTheAmount() {
        let b = read("""
        Previous Balance . . . . . . . . . . . . . . . . . . . . . . . . . . . $1,204.18
        New Balance Total. . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . 980.00
        """)
        #expect(b.opening == [120418] && b.closing == [98000], "\(b)")
    }

    private func node(_ name: String, isDirectory: Bool, children: [FileNode]? = nil) -> FileNode {
        FileNode(id: "/D/" + name, name: name, isDirectory: isDirectory, children: children)
    }

    @Test func theNewestStatementOfAnAccount() {
        let node = node("Credit 5542", isDirectory: true, children: [
            node("2025", isDirectory: true, children: (1...12).map { m in
                node("\(m). \(AccountPlacement.Template.monthNames[m - 1]) 2025.pdf", isDirectory: false)
            }),
            node("2026", isDirectory: true, children: [
                node("1. Jan 2026.pdf", isDirectory: false),
                node("2. Feb 2026.pdf", isDirectory: false),
            ]),
            node("Tax", isDirectory: true, children: [node("1. Dec 2026.pdf", isDirectory: false)]),
        ])
        let n = BalanceChain.newestStatement(in: node)
        #expect(n?.file == "2026/2. Feb 2026.pdf" && n?.period.monthIndex == 2026 * 12 + 2,
                "a tax folder's files are never the account's statements: \(String(describing: n))")
    }
}

/// Which account a statement continues: one, never two, never one that closed after it.
@Suite struct BalanceChainMatchTests {
    private let card = AccountIndex.Account(root: "Apple/Credit 5542", identities: ["5542"], institution: "apple", archived: false)
    private let savings = AccountIndex.Account(root: "Apple/Savings 9952", identities: ["9952"], institution: "apple", archived: false)
    private let april = DocumentFacts(page: """
        Apple Card
        Statement Apr 1 - Apr 30, 2026
        Previous Total Balance $1,234.56
        Total Balance $1,500.00
        """)
    private func link(_ month: Int, _ closing: Int...) -> BalanceChain.Link {
        BalanceChain.Link(period: .init(year: 2026, month: month), closing: Set(closing))
    }

    @Test func theOneAccountWhoseLastClosingItOpensAt() throws {
        let hit = try #require(BalanceChain.account(for: april, among: [card, savings],
                                                    links: [card.root: link(3, 123456), savings.root: link(3, 99900)]))
        #expect(hit.account.root == card.root && hit.adjacent)
    }

    @Test func twoMatchesPlaceNothing() {
        #expect(BalanceChain.account(for: april, among: [card, savings],
                                     links: [card.root: link(3, 123456), savings.root: link(3, 123456)]) == nil,
                "one subscription billed to two cards leaves both at the same balance")
    }

    @Test func aStatementThatClosedSameMonthOrLaterIsNoPredecessor() {
        #expect(BalanceChain.account(for: april, among: [card], links: [card.root: link(4, 123456)]) == nil)
    }

    @Test func aGapIsNotAdjacent() throws {
        let hit = try #require(BalanceChain.account(for: april, among: [card], links: [card.root: link(1, 123456)]))
        #expect(!hit.adjacent)
    }

    @Test func aClosedAccountIsNeverContinued() {
        let closed = AccountIndex.Account(root: "Apple/Archive/Credit 1111", identities: ["1111"], institution: "apple", archived: true)
        #expect(BalanceChain.account(for: april, among: [closed], links: [closed.root: link(3, 123456)]) == nil)
    }
}

/// Which bank's accounts a statement printing no account's number is compared with.
@Suite struct BalanceChainCandidateTests {
    private let card = AccountIndex.Account(root: "Banana Republic/Credit 3857", identities: ["3857"],
                                            institution: "banana republic", archived: false)
    private let chase = AccountIndex.Account(root: "Chase/Credit 1768", identities: ["1768"], institution: "chase", archived: false)
    private var index: AccountIndex {
        AccountIndex(accounts: [card, chase], institutionTokens: ["banana republic": ["banana republic"], "chase": ["chase"]])
    }
    /// A page whose first 1,000 characters (its header) name no bank, then `tail`.
    private func page(_ tail: String) -> DocumentFacts {
        DocumentFacts(page: "Account Summary\nPrevious Balance $412.30\nNew Balance $88.00\n"
                      + String(repeating: "Interest charge calculation. ", count: 40) + "\n" + tail)
    }

    @Test func theBankNamedBelowTheHeader() {
        let f = page("Questions? Visit us at Banana Republic Rewards.")
        #expect(f.header.contains("banana") == false, "the test needs the name past the header")
        #expect(BalanceChain.candidates(for: f, match: .none, index: index, hint: "").map(\.root) == [card.root])
    }

    @Test func aPageNamingTwoBanksAlikeNamesNone() {
        #expect(BalanceChain.candidates(for: page("Banana Republic. Payment from Chase."), match: .none,
                                        index: index, hint: "").isEmpty)
    }

    @Test func theHeaderStillWinsOverTheRestOfThePage() {
        let f = DocumentFacts(page: "Chase Freedom\nPrevious Balance $412.30\n"
                              + String(repeating: "Interest charge calculation. ", count: 40)
                              + "\nBanana Republic Banana Republic")
        #expect(BalanceChain.candidates(for: f, match: .none, index: index, hint: "").map(\.root) == [chase.root])
    }
}

/// In a scan: a statement printing no number lands in the account its balance continues.
@MainActor
@Suite struct BalanceChainScanTests {
    private func statements(_ account: URL) throws {
        for m in 1...12 {
            try writeBytes(account.appendingPathComponent("2025/\(m). \(AccountPlacement.Template.monthNames[m - 1]) 2025.pdf"),
                           Data(repeating: 0x41, count: 64))
        }
        for m in 1...3 {
            try writeBytes(account.appendingPathComponent("2026/\(m). \(AccountPlacement.Template.monthNames[m - 1]) 2026.pdf"),
                           Data(repeating: 0x41, count: 64))
        }
    }

    private func scan(_ defaults: String, pages: [String: String], inbox: URL, docs: URL) async -> FileSyncManager {
        let m = FileSyncManager(defaults: ScratchDefaults(defaults))
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { pages[$0] }
        m.filingTokensFromText = { _ in [] }
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: inbox, providerRoot: docs)
        return m
    }

    @Test func anAppleCardStatementGoesWhereItsBalanceContinues() async throws {
        let root = try makeCanonicalTempRoot(prefix: "BalanceChainApple")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        let card = docs.appendingPathComponent("Credit Accounts/Apple/Credit 5542")
        let savings = docs.appendingPathComponent("Bank Accounts/Apple/Savings 9952")
        try statements(card)
        try statements(savings)
        let inbox = root.appendingPathComponent("Inbox")
        let loose = inbox.appendingPathComponent("Apple Card Statement - April 2026.pdf")
        try writeBytes(loose, Data(repeating: 0x41, count: 64))
        let pages = [
            loose.path: "Apple Card\nStatement Apr 1 - Apr 30, 2026\nPrevious Total Balance $1,234.56\nTotal Balance $1,500.00",
            card.path + "/2026/3. Mar 2026.pdf": "Apple Card\nStatement Mar 1 - Mar 31, 2026\nTotal Balance $1,234.56",
            savings.path + "/2026/3. Mar 2026.pdf": "Apple Savings\nStatement Mar 1 - Mar 31, 2026\nEnding Balance $9,000.00",
        ]
        let m = await scan("BalanceChainTests.1", pages: pages, inbox: inbox, docs: docs)

        let best = try #require(m.filingSuggestions.first { $0.filePath == loose.path }?.best)
        #expect(best.path == card.path + "/2026", "\(best.path)")
        #expect(best.confidence == .high, "the month before, to the cent, and no other number on the page")
        #expect(best.proposedName?.hasSuffix("Apr 2026.pdf") == true, "\(String(describing: best.proposedName))")
        #expect(best.account?.ending == "5542")
        #expect(best.reasons.contains("Opens at the balance ••5542’s Mar 2026 statement closed at"), "\(best.reasons)")
    }

    /// A card reissued under a new number: the folder still carries the old one. The chain finds it,
    /// at Medium, and filing it teaches the folder the new number.
    @Test func aReissuedCardContinuesItsOldFolderAtMedium() async throws {
        let root = try makeCanonicalTempRoot(prefix: "BalanceChainReissue")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        let card = docs.appendingPathComponent("Credit Accounts/Chase/Credit 1768")
        let other = docs.appendingPathComponent("Credit Accounts/Chase/Credit 2809")
        try statements(card)
        try statements(other)
        let inbox = root.appendingPathComponent("Inbox")
        let loose = inbox.appendingPathComponent("20260427-statements-7777-.pdf")
        try writeBytes(loose, Data(repeating: 0x41, count: 64))
        let pages = [
            loose.path: "Chase Freedom\nOpening/Closing Date 03/28/26 - 04/27/26\nAccount Number: XXXX XXXX XXXX 7777\nPrevious Balance $310.20\nNew Balance $95.00",
            card.path + "/2026/3. Mar 2026.pdf": "Chase Freedom\nOpening/Closing Date 02/28/26 - 03/27/26\nNew Balance $310.20",
            other.path + "/2026/3. Mar 2026.pdf": "Chase Sapphire\nOpening/Closing Date 02/28/26 - 03/27/26\nNew Balance $42.00",
        ]
        let m = await scan("BalanceChainTests.2", pages: pages, inbox: inbox, docs: docs)

        let best = try #require(m.filingSuggestions.first { $0.filePath == loose.path }?.best)
        #expect(best.path == card.path + "/2026", "\(best.path)")
        #expect(best.confidence == .medium, "a number no folder has: check it")
        #expect(best.account?.ending == "7777", "filing it teaches ••1768’s folder the new number")
        #expect(best.reasons.first?.contains("page 1 prints ••7777, a number no folder has") == true, "\(best.reasons)")
    }

    /// Both cards closed at the balance it opens at: neither is offered by the chain.
    @Test func aTieOffersNeitherAccount() async throws {
        let root = try makeCanonicalTempRoot(prefix: "BalanceChainTie")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Docs")
        let a = docs.appendingPathComponent("Credit Accounts/Discover/Credit 3531")
        let b = docs.appendingPathComponent("Credit Accounts/Discover/Credit 9278")
        try statements(a)
        try statements(b)
        let inbox = root.appendingPathComponent("Inbox")
        let loose = inbox.appendingPathComponent("Discover-Statement-20260412.pdf")
        try writeBytes(loose, Data(repeating: 0x41, count: 64))
        let pages = [
            loose.path: "Discover It\nOpen to Close Date: 03/13/2026 - 04/12/2026\nPrevious Balance $15.99\nNew Balance $31.98",
            a.path + "/2026/3. Mar 2026.pdf": "Discover It\nOpen to Close Date: 02/13/2026 - 03/12/2026\nNew Balance $15.99",
            b.path + "/2026/3. Mar 2026.pdf": "Discover It\nOpen to Close Date: 02/13/2026 - 03/12/2026\nNew Balance $15.99",
        ]
        let m = await scan("BalanceChainTests.3", pages: pages, inbox: inbox, docs: docs)

        let card = try #require(m.filingSuggestions.first { $0.filePath == loose.path })
        #expect(!card.candidates.contains { $0.reasons.contains { $0.hasPrefix("Opens at the balance") } }, "\(card.candidates.map(\.reasons))")
        #expect(card.best?.confidence != .high)
    }
}
