import Testing
import Foundation
@testable import Sync

/// A statement for an account no folder holds becomes a NEW account folder named and placed like the
/// accounts beside it, never inside an archive, never above Medium.
@Suite struct AccountProposalTests {
    private func file(_ p: String) -> FileNode { FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: false, fileSize: 9000) }
    private func dir(_ p: String, _ c: [FileNode]) -> FileNode {
        FileNode(id: "/D/" + p, name: (p as NSString).lastPathComponent, isDirectory: true, children: c)
    }
    private func years(_ acct: String) -> [FileNode] {
        [dir(acct + "/2025", (1...6).map { file(acct + String(format: "/2025/eStmt_2025-%02d-28.pdf", $0)) })]
    }
    private var tree: [FileNode] {
        let boa = "Bank Accounts/Bank of America"
        return [dir("Bank Accounts", [
            dir(boa, [dir(boa + "/Checking 5696", years(boa + "/Checking 5696"))]),
            dir("Bank Accounts/Chase", [dir("Bank Accounts/Chase/Archive", [dir("Bank Accounts/Chase/Archive/Checking 1111",
                years("Bank Accounts/Chase/Archive/Checking 1111"))])]),
        ]), dir("Credit Accounts", [dir("Credit Accounts/Chase", [dir("Credit Accounts/Chase/Credit 1768",
            years("Credit Accounts/Chase/Credit 1768"))])])]
    }

    @Test func aNewCheckingAccountGoesBesideTheOtherBanksCheckingNotIntoArchive() throws {
        let index = AccountIndex.build(tree: tree)
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0779",
                                                     index: index, tree: tree, period: .init(year: 2026, month: 3)))
        #expect(p.folder == "Bank Accounts/Chase/Checking 0779/2026", "\(p.folder)")
        #expect(p.newSegments == ["Checking 0779", "2026"])
        #expect(p.namedLike?.hasSuffix("Checking 5696") == true, "a live account, never the archived one: \(p.namedLike ?? "nil")")
    }

    private static let people = PersonRegistry(people: [
        Person(id: "me", displayName: "Abhishek", relationship: "me", fullNames: ["Abhishek Girish"]),
        Person(id: "wife", displayName: "Shweta", relationship: "wife", fullNames: ["Shweta Dani"]),
    ])
    private var treeWithHerCard: [FileNode] {
        let chase = "Credit Accounts/Chase"
        return tree + [dir("Credit Accounts", [dir(chase, [dir(chase + "/Credit 8436 (Shweta)", years(chase + "/Credit 8436 (Shweta)"))])])]
    }

    /// The holder suffix is learned from the tree's own account names, and applied only when
    /// page 1 names that person and not the user: a joint account is his.
    @Test func theHolderIsNamedOnlyWhenThePageNamesHerAlone() {
        #expect(AccountProposal.holderNames(in: treeWithHerCard) == ["Shweta"])
        #expect(AccountProposal.holderNames(in: tree).isEmpty)
        let hers = "Chase Freedom statement SHWETA DANI Account summary"
        #expect(AccountProposal.holderSuffix(page: hers, tree: treeWithHerCard, registry: Self.people) == "Shweta")
        #expect(AccountProposal.holderSuffix(page: hers + " ABHISHEK GIRISH", tree: treeWithHerCard, registry: Self.people) == nil,
                "a joint account takes no suffix")
        #expect(AccountProposal.holderSuffix(page: hers, tree: tree, registry: Self.people) == nil,
                "no account carries a holder's name, so neither does a new one")
        let noMe = PersonRegistry(people: [Person(id: "wife", displayName: "Shweta", fullNames: ["Shweta Dani"])])
        #expect(AccountProposal.holderSuffix(page: hers, tree: treeWithHerCard, registry: noMe) == nil,
                "without knowing who the user is, the rule can't be applied")
    }

    /// The new account folder carries the suffix, from an inbox folder that names only the type
    /// and number.
    @Test func herNewCardIsNamedForHer() throws {
        let index = AccountIndex.build(tree: treeWithHerCard)
        let page = "Chase Freedom Unlimited\nAccount summary\nfor February 26, 2026 to March 27, 2026\n"
            + "Account number: XXXX XXXX XXXX 4321\nSHWETA DANI"
        let s = FilingSuggestion(filePath: "/In/Credit 4321/statement.pdf", fileName: "statement.pdf", size: 1,
                                 modificationDate: nil, candidates: [], providerRoot: "/D")
        let out = FileSyncManager.proposingAccount(for: s, facts: DocumentFacts(page: page),
                                                   period: .init(year: 2026, month: 3), hint: "Credit 4321",
                                                   index: index, taxonomy: treeWithHerCard, root: "/D", registry: Self.people)
        let best = try #require(out.best, "no proposal")
        #expect(best.path.hasPrefix("/D/Credit Accounts/Chase/Credit 4321 (Shweta)"), "\(best.path)")
        #expect(best.reasons.first?.contains("page 1 names only Shweta") == true)
        // Control: his own card from the same folder takes no suffix.
        let his = FileSyncManager.proposingAccount(for: s, facts: DocumentFacts(page: page.replacingOccurrences(of: "SHWETA DANI", with: "ABHISHEK GIRISH")),
                                                   period: .init(year: 2026, month: 3), hint: "Credit 4321",
                                                   index: index, taxonomy: treeWithHerCard, root: "/D", registry: Self.people)
        #expect(his.best?.path.hasPrefix("/D/Credit Accounts/Chase/Credit 4321/") == true, "\(his.best?.path ?? "nil")")
    }

    @Test func aTypeNoAccountHasGoesUnderTheBanksBusiestFolder() throws {
        let index = AccountIndex.build(tree: tree)
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Auto Lease", ending: "2388",
                                                     index: index, tree: tree, period: .init(year: 2026, month: 3)))
        #expect(p.accountRoot == "Credit Accounts/Chase/Auto Lease 2388",
                "the Chase folder with a live account, not the one holding only an archive: \(p.accountRoot)")
    }

    @Test func theHintNamesTypeNumberAndName() {
        func t(_ h: String) -> [String]? { AccountProposal.typeAndDigits(inHint: h).map { [$0.type, $0.digits, $0.name] } }
        #expect(t("Finance/Chase/Checking 0779/2026") == ["Checking", "0779", "Checking 0779"])
        #expect(t("Finance/Chase/Auto Lease 2388/2026") == ["Auto Lease", "2388", "Auto Lease 2388"])
        #expect(t("Finance/Discover/Credit 31001 (Shweta)") == ["Credit", "1001", "Credit 31001 (Shweta)"],
                "the folder's own spelling is kept")
        #expect(t("Downloads") == nil)
        #expect(t("Finance/ScholarShare 529/529 6797-02/2026") == nil, "a bank-level folder names no account")
    }

    @Test func aFolderTheSurveyMarksArchivedIsNeitherModelNorHome() throws {
        let index = AccountIndex.build(tree: tree)
        // The live checking account itself marked closed: no checking model is left.
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0779",
                                                     index: index, tree: tree, period: .init(year: 2026, month: 3),
                                                     isArchived: { $0 == "Bank Accounts/Bank of America/Checking 5696" }))
        #expect(p.namedLike == nil, "\(p.namedLike ?? "")")
        // Every Chase folder marked closed: nowhere to propose.
        #expect(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0779", index: index, tree: tree,
                                        period: nil, isArchived: { $0.hasSuffix("/Chase") }) == nil)
    }

    @Test func theNewAccountCopiesTheModelsLayoutInside() throws {
        let acct = "Bank Accounts/Wells Fargo/Checking 4410"
        let wells = dir("Bank Accounts/Wells Fargo", [dir(acct, [dir(acct + "/Statements", [dir(acct + "/Statements/2025",
            (1...6).map { file(acct + String(format: "/Statements/2025/eStmt_2025-%02d-28.pdf", $0)) })])])])
        let t = [dir("Bank Accounts", [wells, dir("Bank Accounts/Chase", [])])]
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0779",
                                                     index: AccountIndex.build(tree: t), tree: t,
                                                     period: .init(year: 2026, month: 3)))
        #expect(p.folder == "Bank Accounts/Chase/Checking 0779/Statements/2026", "\(p.folder)")
        #expect(p.newSegments == ["Checking 0779", "Statements", "2026"])
    }
}
