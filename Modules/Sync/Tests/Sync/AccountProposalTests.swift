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
            dir(boa, [dir(boa + "/Checking 6701", years(boa + "/Checking 6701"))]),
            dir("Bank Accounts/Chase", [dir("Bank Accounts/Chase/Archive", [dir("Bank Accounts/Chase/Archive/Checking 1111",
                years("Bank Accounts/Chase/Archive/Checking 1111"))])]),
        ]), dir("Credit Accounts", [dir("Credit Accounts/Chase", [dir("Credit Accounts/Chase/Credit 1833",
            years("Credit Accounts/Chase/Credit 1833"))])])]
    }

    @Test func aNewCheckingAccountGoesBesideTheOtherBanksCheckingNotIntoArchive() throws {
        let index = AccountIndex.build(tree: tree)
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0896",
                                                     index: index, tree: tree, period: .init(year: 2026, month: 3)))
        #expect(p.folder == "Bank Accounts/Chase/Checking 0896/2026", "\(p.folder)")
        #expect(p.newSegments == ["Checking 0896", "2026"])
        #expect(p.namedLike?.hasSuffix("Checking 6701") == true, "a live account, never the archived one: \(p.namedLike ?? "nil")")
    }

    private static let people = PersonRegistry(people: [
        Person(id: "me", displayName: "Father", relationship: "me", fullNames: ["Father Elder"]),
        Person(id: "wife", displayName: "Mother", relationship: "wife", fullNames: ["Mother Maiden"]),
    ])
    private var treeWithHerCard: [FileNode] {
        let chase = "Credit Accounts/Chase"
        return tree + [dir("Credit Accounts", [dir(chase, [dir(chase + "/Credit 9592 (Mother)", years(chase + "/Credit 9592 (Mother)"))])])]
    }

    /// The holder suffix is learned from the tree's own account names, and applied only when
    /// page 1 names that person and not the user: a joint account is his.
    @Test func theHolderIsNamedOnlyWhenThePageNamesHerAlone() {
        #expect(AccountProposal.holderNames(in: treeWithHerCard) == ["Mother"])
        #expect(AccountProposal.holderNames(in: tree).isEmpty)
        let hers = "Chase Freedom statement MOTHER MAIDEN Account summary"
        #expect(AccountProposal.holderSuffix(page: hers, tree: treeWithHerCard, registry: Self.people) == "Mother")
        #expect(AccountProposal.holderSuffix(page: hers + " FATHER ELDER", tree: treeWithHerCard, registry: Self.people) == nil,
                "a joint account takes no suffix")
        #expect(AccountProposal.holderSuffix(page: hers, tree: tree, registry: Self.people) == nil,
                "no account carries a holder's name, so neither does a new one")
        let noMe = PersonRegistry(people: [Person(id: "wife", displayName: "Mother", fullNames: ["Mother Maiden"])])
        #expect(AccountProposal.holderSuffix(page: hers, tree: treeWithHerCard, registry: noMe) == nil,
                "without knowing who the user is, the rule can't be applied")
    }

    /// The new account folder carries the suffix, from an inbox folder that names only the type
    /// and number.
    @Test func herNewCardIsNamedForHer() throws {
        let index = AccountIndex.build(tree: treeWithHerCard)
        let page = "Chase Freedom Unlimited\nAccount summary\nfor February 26, 2026 to March 27, 2026\n"
            + "Account number: XXXX XXXX XXXX 4321\nMOTHER MAIDEN"
        let s = FilingSuggestion(filePath: "/In/Credit 4321/statement.pdf", fileName: "statement.pdf", size: 1,
                                 modificationDate: nil, candidates: [], providerRoot: "/D")
        let out = FileSyncManager.proposingAccount(for: s, facts: DocumentFacts(page: page),
                                                   period: .init(year: 2026, month: 3), hint: "Credit 4321",
                                                   index: index, taxonomy: treeWithHerCard, root: "/D", registry: Self.people)
        let best = try #require(out.best, "no proposal")
        #expect(best.path.hasPrefix("/D/Credit Accounts/Chase/Credit 4321 (Mother)"), "\(best.path)")
        #expect(best.reasons.first?.contains("page 1 names only Mother") == true)
        // Control: his own card from the same folder takes no suffix.
        let his = FileSyncManager.proposingAccount(for: s, facts: DocumentFacts(page: page.replacingOccurrences(of: "MOTHER MAIDEN", with: "FATHER ELDER")),
                                                   period: .init(year: 2026, month: 3), hint: "Credit 4321",
                                                   index: index, taxonomy: treeWithHerCard, root: "/D", registry: Self.people)
        #expect(his.best?.path.hasPrefix("/D/Credit Accounts/Chase/Credit 4321/") == true, "\(his.best?.path ?? "nil")")
    }

    @Test func aTypeNoAccountHasGoesUnderTheBanksBusiestFolder() throws {
        let index = AccountIndex.build(tree: tree)
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Auto Lease", ending: "3072",
                                                     index: index, tree: tree, period: .init(year: 2026, month: 3)))
        #expect(p.accountRoot == "Credit Accounts/Chase/Auto Lease 3072",
                "the Chase folder with a live account, not the one holding only an archive: \(p.accountRoot)")
    }

    @Test func theHintNamesTypeNumberAndName() {
        func t(_ h: String) -> [String]? { AccountProposal.typeAndDigits(inHint: h).map { [$0.type, $0.digits, $0.name] } }
        #expect(t("Finance/Chase/Checking 0896/2026") == ["Checking", "0896", "Checking 0896"])
        #expect(t("Finance/Chase/Auto Lease 3072/2026") == ["Auto Lease", "3072", "Auto Lease 3072"])
        #expect(t("Finance/Discover/Credit 61009 (Mother)") == ["Credit", "1009", "Credit 61009 (Mother)"],
                "the folder's own spelling is kept")
        #expect(t("Downloads") == nil)
        #expect(t("Finance/ScholarShare 529/529 7915-02/2026") == nil, "a bank-level folder names no account")
    }

    @Test func aFolderTheSurveyMarksArchivedIsNeitherModelNorHome() throws {
        let index = AccountIndex.build(tree: tree)
        // The live checking account itself marked closed: no checking model is left.
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0896",
                                                     index: index, tree: tree, period: .init(year: 2026, month: 3),
                                                     isArchived: { $0 == "Bank Accounts/Bank of America/Checking 6701" }))
        #expect(p.namedLike == nil, "\(p.namedLike ?? "")")
        // Every Chase folder marked closed: nowhere to propose.
        #expect(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0896", index: index, tree: tree,
                                        period: nil, isArchived: { $0.hasSuffix("/Chase") }) == nil)
    }

    @Test func theNewAccountCopiesTheModelsLayoutInside() throws {
        let acct = "Bank Accounts/Wells Fargo/Checking 4410"
        let wells = dir("Bank Accounts/Wells Fargo", [dir(acct, [dir(acct + "/Statements", [dir(acct + "/Statements/2025",
            (1...6).map { file(acct + String(format: "/Statements/2025/eStmt_2025-%02d-28.pdf", $0)) })])])])
        let t = [dir("Bank Accounts", [wells, dir("Bank Accounts/Chase", [])])]
        let p = try #require(AccountProposal.propose(institution: "chase", type: "Checking", ending: "0896",
                                                     index: AccountIndex.build(tree: t), tree: t,
                                                     period: .init(year: 2026, month: 3)))
        #expect(p.folder == "Bank Accounts/Chase/Checking 0896/Statements/2026", "\(p.folder)")
        #expect(p.newSegments == ["Checking 0896", "Statements", "2026"])
    }
}
