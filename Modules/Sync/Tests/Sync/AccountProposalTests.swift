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
