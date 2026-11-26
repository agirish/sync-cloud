import Testing
import Foundation
@testable import Sync

/// Where inside the tree a statement lands once its account is known, as his TODO met it on
/// 2026-11-15: Fidelity keeps a `Statements/<year>` folder of its own beside `Roth IRA 5442`, whose
/// 2022 statements sit in its `Tax` folder and whose `Statements` folder is still empty; Homesite
/// bills go where his insurance papers are, by year.
@Suite struct FilingAccountLayoutTests {

    private func file(_ path: String) -> FileNode {
        FileNode(id: "/D/" + path, name: (path as NSString).lastPathComponent, isDirectory: false, fileSize: 9000)
    }
    private func dir(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: "/D/" + path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    private static let fidelity = "Finance/US/Investments/Fidelity"
    private static let roth = fidelity + "/Roth IRA 5442"

    /// `withRoth: false` is a bank with only its shared folder (as `Credit Accounts/Citi` is).
    private func fidelityTree(withRoth: Bool = true) -> [FileNode] {
        let f = Self.fidelity, r = Self.roth
        var bank: [FileNode] = [dir(f + "/Statements", [
            dir(f + "/Statements/2025", (1...9).map { file(f + "/Statements/2025/Statement0\($0)262025.pdf") }),
        ])]
        if withRoth {
            bank.append(dir(r, [
                file(r + "/Statement01312021.pdf"), file(r + "/Statement12312020-4.pdf"),
                dir(r + "/Statements", []),
                dir(r + "/Tax", (1...9).map { file(r + "/Tax/Statement0\($0)282022.pdf") } + [file(r + "/Tax/Tax - 5498 2025.pdf")]),
            ]))
        }
        return [dir("Finance", [dir("Finance/US", [dir("Finance/US/Investments", [dir(f, bank)])])]),
                dir("Health", [dir("Health/Medical", [dir("Health/Medical/Kaiser", [dir("Health/Medical/Kaiser/Bills", [
                    dir("Health/Medical/Kaiser/Bills/2026", [file("Health/Medical/Kaiser/Bills/2026/Kaiser Billing Statement - Mar 2026.pdf")]),
                ])])])])]
    }

    private let kaiser = FilingDestination(path: "/D/Health/Medical/Kaiser/Bills/2026", base: .medium, evidence: .content,
                                           reasons: ["Matched “envelope” read from the file"], newSegments: [])

    private func card(_ path: String) -> FilingSuggestion {
        FilingSuggestion(filePath: path, fileName: (path as NSString).lastPathComponent, size: 1, modificationDate: nil,
                         candidates: [kaiser], providerRoot: "/D")
    }

    private func best(_ path: String, page: String, tree: [FileNode]) throws -> FilingDestination {
        let (out, _) = FileSyncManager.applyingAccounts([card(path)], index: AccountIndex.build(tree: tree),
                                                        snippets: [path: page], taxonomy: tree, root: "/D",
                                                        scannedFolder: "/D/TODO")
        return try #require(out.first?.best)
    }

    /// A consolidated report prints no account number; the inbox folder names Roth IRA 5442. It goes
    /// to that account's empty `Statements` folder, by year as Fidelity's own statements are, never
    /// to the `Tax` folder holding 2022's statements.
    @Test func anInboxNamedAccountGoesToItsOwnStatementsFolderNotTax() throws {
        let path = "/D/TODO/Finance/Fidelity/Roth IRA 5442/2026/01. Jan 2026.pdf"
        let page = "INVESTMENT REPORT\nJanuary 1, 2026 - January 31, 2026\nEnvelope # BSTLZKBBBGRTK\nOnline Fidelity.com"
        let b = try best(path, page: page, tree: fidelityTree())
        #expect(b.path == "/D/" + Self.roth + "/Statements/2026", "\(b.path) \(b.reasons)")
        #expect(b.newSegments == ["2026"] && b.proposedName == "01. Jan 2026.pdf" && b.confidence == .medium)
        #expect(FileSyncManager.isSettledByAccountNumber(b), "Claude doesn't move it")
        // Claude, which sees neither the inbox path nor the accounts, named the shared folder for
        // all eight of Fidelity's: the account home stands.
        let placed = FilingSuggestion(filePath: path, fileName: "01. Jan 2026.pdf", size: 1, modificationDate: nil,
                                      candidates: [b, kaiser], providerRoot: "/D")
        let claude = FilingVerdict(relativePath: Self.fidelity + "/Statements/2026", confidence: .high, reason: "Fidelity statement")
        let shared = Self.fidelity + "/Statements/2026"
        var existing: Set<String> = []
        var walked = ""
        for seg in shared.split(separator: "/") { walked += (walked.isEmpty ? "" : "/") + seg; existing.insert(walked) }
        // As Refine asks: the folder on the card's shortlist, a paid answer allowed to lead.
        let after = FilingEngine.applyVerdicts([path: claude], to: [placed], existingRelative: existing, providerRoot: "/D",
                                               routerShortlists: [path: [shared]], shortlistVerdictsLead: true,
                                               answersPastShortlistKept: true)
        #expect(after.first?.best?.path == b.path, "\(String(describing: after.first?.best?.path))")
        // A company home named by no number is still Claude's to improve.
        let company = FilingDestination(path: "/D/Home/Insurance", base: .medium, evidence: .measuredContent, reasons: [],
                                        newSegments: [])
        #expect(!FileSyncManager.isSettledByAccountNumber(company))
    }

    /// Brokerage ••1746 has no folder. Fidelity keeps another account in a folder of its own, so
    /// 1746 gets one too, laid out like it, ahead of a Kaiser folder matched on a page word.
    @Test func aNewAccountAtABankWithAccountFoldersGetsItsOwnFolder() throws {
        let path = "/D/TODO/Finance/Fidelity/Brokerage 1746/2026/03. Mar 2026.pdf"
        let page = "Envelope # BSZWVCBBBNQGK\nINVESTMENT REPORT\nMarch 1, 2026 - March 31, 2026\n"
            + "FIDELITY ACCOUNT FATHER ELDER - INDIVIDUAL TOD\nAccount Number: Z26-221746"
        let b = try best(path, page: page, tree: fidelityTree())
        #expect(b.path == "/D/" + Self.fidelity + "/Brokerage 1746/Statements/2026", "\(b.path) \(b.reasons)")
        #expect(b.newSegments == ["Brokerage 1746", "Statements", "2026"] && b.account?.ending == "1746")
        #expect(FileSyncManager.isSettledByAccountNumber(b))
        // A bank keeping every statement in one shared folder still gets no account folders.
        let shared = try best(path, page: page, tree: fidelityTree(withRoth: false))
        #expect(!shared.path.contains("Brokerage 1746"), "\(shared.path)")
    }

    /// Statements filed in a tax folder are never the account's layout, and an account whose
    /// `Statements` folder holds files keeps placing by its newest family.
    @Test func placementSkipsTaxFoldersAndUsesAnEmptyStatementsFolder() throws {
        let r = Self.roth
        let tree = fidelityTree()
        let node = try #require(AccountProposal.node(at: r, in: tree))
        let bank = AccountProposal.node(at: Self.fidelity, in: tree)
        let p = AccountPlacement.place(in: node, period: .init(year: 2026, month: 7, day: 31), taxForm: false,
                                       fileName: "07. Jul 2026.pdf", bank: bank)
        #expect(p.folder == "Statements/2026" && p.name == "07. Jul 2026.pdf", "\(p)")
        // With no bank known to file by year, the Statements folder itself.
        let flat = AccountPlacement.place(in: node, period: .init(year: 2026, month: 7, day: 31), taxForm: false,
                                          fileName: "07. Jul 2026.pdf")
        #expect(flat.folder == "Statements", "\(flat)")
        // A tax form still goes to the tax folder.
        #expect(AccountPlacement.place(in: node, period: nil, taxForm: true, fileName: "5498.pdf").folder == "Tax")
        // Without the empty Statements folder: the account root, where its last statements outside Tax are.
        let noStatements = dir(r, (node.children ?? []).filter { $0.name != "Statements" })
        let root = AccountPlacement.place(in: noStatements, period: .init(year: 2026, month: 7, day: 31), taxForm: false,
                                          fileName: "07. Jul 2026.pdf", bank: bank)
        #expect(root.folder == "", "\(root)")
    }

    // MARK: Insurance by year

    /// Homesite's bill prints next year's policy term; its date is the statement date.
    static let homesiteBill = """
        GEICO Insurance Agency, LLC
        HOMESITE INSURANCE COMPANY OF CALIFORNIA
        BILLING STATEMENT
        Policy Term: January 1, 2026 - January 1, 2027
        Billing Summary for Policy Number 44908159 (reflects activity this billing period)
        PRIOR BALANCE 11-07-2025 $1,102.00
        Statement Date: January 17, 2026
        """

    @Test func aPolicyTermIsNotTheStatementPeriod() {
        #expect(DocumentFacts(page: Self.homesiteBill).period == .init(year: 2026, month: 1, day: 17))
    }

    /// `Home/Insurance` keeps a folder per year and its newest papers in 2025's: the 2026 bill goes
    /// to a new `2026`. `Vehicles/Honda/Insurance` has year folders up to 2021 but keeps 2026's
    /// papers loose: it stays loose.
    @Test func aCompanyHomeFiledByYearGetsTheYearFolder() throws {
        let home = "Home/Insurance", honda = "Vehicles/Honda/Insurance"
        let tree: [FileNode] = [
            dir("Home", [dir(home, [
                dir(home + "/2024", [file(home + "/2024/Hippo Policy.pdf")]),
                dir(home + "/2025", [file(home + "/2025/11. Nov 2025 - Renewal Package.pdf")]),
                dir(home + "/Policy", []),
                file(home + "/GEICO-Homesite Condo Policy 44908159 - New Business Jan 2025.pdf"),
            ])]),
            dir("Vehicles", [dir("Vehicles/Honda", [dir(honda, [
                dir(honda + "/2021", [file(honda + "/2021/Policy.pdf")]),
                file(honda + "/GEICO Declarations - Jan 2026 to Jul 2026.pdf"),
            ])])]),
        ]
        let path = "/D/TODO/Finance/Homesite/Condo 8159/2026/01. Jan 2026 - Billing Summary.pdf"
        let b = try best(path, page: Self.homesiteBill, tree: tree)
        #expect(b.path == "/D/" + home + "/2026" && b.newSegments == ["2026"], "\(b.path) \(b.reasons)")
        #expect(b.account?.ending == "8159")
        let hondaNode = try #require(AccountProposal.node(at: honda, in: tree))
        #expect(FileSyncManager.yearFolder(in: hondaNode, for: 2026) == nil)
        let homeNode = try #require(AccountProposal.node(at: home, in: tree))
        #expect(FileSyncManager.yearFolder(in: homeNode, for: 2025)?.isNew == false)
    }
}
