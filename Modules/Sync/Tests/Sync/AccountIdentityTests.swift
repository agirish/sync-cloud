import Testing
import Foundation
@testable import Sync

/// The reader and the account index. Pages are made up, shaped like the statements the design
/// was measured on: the label on the line before the number (a brokerage), masked card numbers, a
/// checking statement that names *another* account in a transfer line, trust and due dates that
/// are not periods, a taxpayer number, a routing number.
@Suite struct AccountIdentityTests {

    // MARK: Reader

    @Test func aLabelledNumberOnTheNextLineIsTheStatementsOwn() {
        let page = """
        Schwab One® Trust Account of
        A PERSON TTEE
        U/A DTD 02/24/2024
        Account Number
        1234-5678
        Statement Period
        March 1-31, 2026
        """
        let f = DocumentFacts(page: page)
        #expect(f.ownNumbers.map(\.digits) == ["12345678"])
        #expect(f.kind == .statement)
        #expect(f.period == .init(year: 2026, month: 3, day: 31), "the trust date is not the period")
    }

    @Test func aMaskedCardNumberAndTheClosingDateNotTheDueDate() {
        let page = """
        Manage your account online at: www.examplebank.com
        Payment Due Date 04/22/2026
        Opening/Closing Date 02/20/26 - 03/19/26
        Account Number: XXXX XXXX XXXX 1768
        """
        let f = DocumentFacts(page: page)
        #expect(f.ownNumbers.contains { $0.digits == "1768" && $0.masked })
        #expect(f.period == .init(year: 2026, month: 3, day: 19), "\(String(describing: f.period))")
    }

    @Test func aTransferLineNamesAnotherAccountNotThisOne() {
        let page = """
        Total Checking
        February 13, 2026 through March 12, 2026
        Account Number:
        A PERSON
        09/04 Online Realtime Transfer To Boa Checking 5696 Transaction#: 30681874336
        """
        let f = DocumentFacts(page: page)
        #expect(f.ownNumbers.isEmpty, "a mention is not the page's own number: \(f.ownNumbers)")
        #expect(f.period == .init(year: 2026, month: 3, day: 12))
    }

    @Test func taxpayerAndRoutingNumbersAreNeverTheAccounts() {
        let page = """
        Form 1099-R 2025
        RECIPIENT'S TIN xxx-xx-7396
        Routing Number 021000021
        Account number 4433
        """
        let f = DocumentFacts(page: page)
        #expect(f.kind == .taxForm)
        #expect(f.period?.year == 2025)
        #expect(!f.ownNumbers.contains { $0.digits.hasSuffix("7396") }, "a taxpayer number")
        #expect(!f.ownNumbers.contains { $0.digits == "021000021" }, "a labelled routing number")
        #expect(DocumentFacts(page: "Account Number 021000021").ownNumbers.map(\.digits) == ["021000021"],
                "nine digits passing the checksum may still be the account's own")
        #expect(DocumentFacts(page: "Card ending **** **** **** 1917").ownNumbers.contains { $0.digits == "1917" },
                "a masked ending that reads like a year is still an ending")
        #expect(!DocumentFacts(page: "XXX7782 XXX-XX-7396").ownNumbers.contains { $0.digits.hasSuffix("7396") },
                "a taxpayer mask inside a masked run")
        #expect(DocumentFacts(page: "Savings account ******4121").ownNumbers.contains { $0.digits == "4121" },
                "a contiguous mask is an account's, not a taxpayer's")
        #expect(!DocumentFacts(page: "Transfer to SAV account ******4121").ownNumbers.contains { $0.digits == "4121" },
                "on a transfer line, masked or not, it is the other account's")
        #expect(DocumentFacts(page: "Card XXXXXXXXXXXX1768").ownNumbers.contains { $0.digits == "1768" })
        #expect(!DocumentFacts(page: "Card XXXX XXXX XXXX 1768\n01/03 Payment").ownNumbers.contains { $0.digits.hasSuffix("6801") },
                "a mask doesn't run onto the next line")
        #expect(f.ownNumbers.contains { $0.digits == "4433" })
    }

    @Test func periodLabelsAreWordsAndFormsPrintTheirYear() {
        let fidelity = DocumentFacts(page: "INVESTMENT REPORT\nJanuary 1, 2025 - December 31, 2025\nAccount Number: Z26-141750")
        #expect(fidelity.period == .init(year: 2025, month: 12, day: 31), "“vest” is not in “investment”")
        let w2 = DocumentFacts(page: "Form W-2 Wage and Tax Statement OMB No. 1545-0008\nEmployee 2024 Form W-2")
        #expect(w2.kind == .taxForm && w2.period?.year == 2024, "\(String(describing: w2.period))")
        let lines = DocumentFacts(page: "Statement Period\nFebruary 28, 2026 to\nMarch 31, 2026")
        #expect(lines.period == .init(year: 2026, month: 3, day: 31))
    }

    @Test func billingRangesAreStatementPeriods() {
        #expect(DocumentFacts(page: "Account Summary 12/28/2025 - 01/27/2026").period == .init(year: 2026, month: 1, day: 27))
        #expect(DocumentFacts(page: "for February 26, 2026 to March 27, 2026").kind == .statement)
        #expect(DocumentFacts(page: "Lease Maturity Date 06/25/2027").period == nil, "a maturity is no period")
        #expect(DocumentFacts(page: "Dear customer, thank you.").kind == .other)
    }

    // MARK: Index

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private func file(_ path: String) -> FileNode {
        FileNode(id: "/D/" + path, name: (path as NSString).lastPathComponent, isDirectory: false, fileSize: 9000)
    }
    private func dir(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: "/D/" + path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }
    private func monthly(_ folder: String, _ template: (Int) -> String, months: ClosedRange<Int> = 1...6) -> [FileNode] {
        months.map { file(folder + "/" + template($0)) }
    }

    private var tree: [FileNode] {
        let boa = "Finance/US/Bank Accounts/Bank of America"
        let chase = "Finance/US/Credit Accounts/Chase"
        let schwab = "Finance/US/Investments/Charles Schwab"
        return [dir("Finance", [dir("Finance/US", [
            dir("Finance/US/Bank Accounts", [dir(boa, [
                dir(boa + "/Checking 5696", [dir(boa + "/Checking 5696/2025",
                    monthly(boa + "/Checking 5696/2025") { String(format: "eStmt_2025-%02d-28.pdf", $0) })]),
                dir(boa + "/Savings 5582", [dir(boa + "/Savings 5582/2025",
                    monthly(boa + "/Savings 5582/2025") { String(format: "eStmt_2025-%02d-28.pdf", $0) })]),
            ])]),
            dir("Finance/US/Credit Accounts", [dir(chase, [
                dir(chase + "/Credit 1768", [dir(chase + "/Credit 1768/2025",
                    monthly(chase + "/Credit 1768/2025") { String(format: "%02d. ", $0) + Self.months[$0 - 1] + " 2025.pdf" })]),
                dir(chase + "/Other 4139", [dir(chase + "/Other 4139/2025",
                    monthly(chase + "/Other 4139/2025") { String(format: "%02d. ", $0) + Self.months[$0 - 1] + " 2025.pdf" })]),
            ])]),
            dir("Finance/US/Investments", [dir(schwab, [
                dir(schwab + "/Traditional IRA 7863",
                    monthly(schwab + "/Traditional IRA 7863") { String(format: "Brokerage Statement_2025-%02d-28_863.PDF", $0) }),
                dir(schwab + "/Archive", [dir(schwab + "/Archive/Roth IRA 2336",
                    monthly(schwab + "/Archive/Roth IRA 2336") { String(format: "Brokerage Statement_2025-%02d-28_336.PDF", $0) })]),
            ])]),
        ])]),
        // Digits that aren't accounts: no statements below them, or a form number.
        dir("Work", [dir("Work/Release Notes", [dir("Work/Release Notes/2110", [file("Work/Release Notes/2110/notes.pdf")])])]),
        dir("Taxes", [dir("Taxes/Form 1099-B", monthly("Taxes/Form 1099-B") { "\($0). cs-1 - Mar 2025.csv" })]),
        dir("Bank Accounts", [dir("Bank Accounts/Chase", [dir("Bank Accounts/Chase/Savings 4139",
            monthly("Bank Accounts/Chase/Savings 4139") { String(format: "Statement 2025-%02d.pdf", $0) })]),
            dir("Bank Accounts/Discover", [dir("Bank Accounts/Discover/Archive", [dir("Bank Accounts/Discover/Archive/Savings 4121",
                monthly("Bank Accounts/Discover/Archive/Savings 4121") { String(format: "Statement 2025-%02d.pdf", $0) })])]),
            dir("Bank Accounts/Bank of America", [dir("Bank Accounts/Bank of America/Savings 4139",
                monthly("Bank Accounts/Bank of America/Savings 4139") { String(format: "eStmt_2025-%02d-28.pdf", $0) })])]),
        ]
    }

    @Test func accountsAreFolderDigitsAboveARegularStatementFamily() {
        let index = AccountIndex.build(tree: tree)
        let roots = Set(index.accounts.map(\.root))
        #expect(roots.contains("Finance/US/Bank Accounts/Bank of America/Checking 5696"))
        #expect(roots.contains("Finance/US/Investments/Charles Schwab/Traditional IRA 7863"))
        #expect(!roots.contains { $0.contains("Release Notes") }, "no statements below it")
        #expect(!roots.contains { $0.contains("Form 1099") }, "a form number, not an account")
        let roth = index.accounts.first { $0.root.hasSuffix("Roth IRA 2336") }
        #expect(roth?.archived == true && roth?.institution == "charles schwab")
        #expect(index.accounts.first { $0.root.hasSuffix("Checking 5696") }?.institution == "bank of america")
        #expect(index.institutionTokens["bank of america"] == ["america"], "category words (bank, accounts) don't name it")
    }

    @Test func aStatementFromTheRightBankIsHigh() {
        let index = AccountIndex.build(tree: tree)
        let page = """
        Charles Schwab & Co., Inc.
        Account Number
        9999-7863
        Statement Period
        March 1-31, 2026
        """
        guard case .high(let account, _) = index.match(DocumentFacts(page: page)) else {
            Issue.record("expected High, got \(index.match(DocumentFacts(page: page)))"); return
        }
        #expect(account.root.hasSuffix("Traditional IRA 7863"))
    }

    @Test func aMaskedNumberThePageOnlyMentionsNeverDecides() {
        let index = AccountIndex.build(tree: tree)
        // Its own number is labelled and matches nothing here; the masked one is a transfer's target.
        let marcus = DocumentFacts(page: """
        Marcus by Goldman Sachs Online Savings Statement
        Statement Period January 1, 2026 - January 31, 2026
        Account Number 300036285203
        Transfer to DISCOVER BANK SAV account ******4121
        """)
        #expect(!marcus.ownNumbers.contains { $0.digits == "4121" }, "a transfer line's number is never the page's own")
        #expect(index.match(marcus) == .none, "\(index.match(marcus))")
    }

    @Test func theSameEndingAtTwoBanksIsDecidedByTheBankNamedOnThePage() {
        let index = AccountIndex.build(tree: tree)
        let boaPage = DocumentFacts(page: "Bank of America\nfor February 26, 2026 to March 27, 2026\nAccount number: 1111 2222 4139")
        guard case .high(let a, _) = index.match(boaPage) else { Issue.record("\(index.match(boaPage))"); return }
        #expect(a.root == "Bank Accounts/Bank of America/Savings 4139")
    }

    @Test func theSameEndingTwiceAtOneBankIsAmbiguous() {
        let index = AccountIndex.build(tree: tree)
        let chasePage = """
        Chase Freedom
        Opening/Closing Date 02/20/26 - 03/19/26
        Account Number: XXXX XXXX XXXX 4139
        """
        // `Credit Accounts/Chase/Other 4139` and `Bank Accounts/Chase/Savings 4139`: two Chase
        // accounts, one ending, so the page can't say which.
        if case .ambiguous(let accounts) = index.match(DocumentFacts(page: chasePage)) {
            #expect(accounts.count == 2)
        } else {
            Issue.record("expected ambiguous, got \(index.match(DocumentFacts(page: chasePage)))")
        }
    }

    @Test func anotherBanksPageNeverMatchesByANumberItMentions() {
        let index = AccountIndex.build(tree: tree)
        // A Chase page that labels a transfer's target with a number ending 5696.
        let page = """
        Chase Total Checking. Chase.com. Chase Bank.
        February 13, 2026 through March 12, 2026
        Transfer to account ending in 5696 at Bank of America
        """
        #expect(index.match(DocumentFacts(page: page)) == .none,
                "the page is mostly Chase's: \(index.match(DocumentFacts(page: page))) \(index.institutionTokens)")
    }

    @Test func aTaxFormOrAPageNamingNoBankIsOnlyMedium() {
        let index = AccountIndex.build(tree: tree)
        let tax = DocumentFacts(page: "Charles Schwab\nForm 1099 Composite\nTax Year 2025\nAccount Number\n9999-7863")
        if case .medium(_, _, let why) = index.match(tax) { #expect(why == .notAStatement) } else { Issue.record("\(index.match(tax))") }
        let silent = DocumentFacts(page: "Statement Period March 1-31, 2026\nAccount Number\n9999-7863")
        if case .medium(_, _, let why) = index.match(silent) { #expect(why == .institutionSilent) } else { Issue.record("\(index.match(silent))") }
    }

    @Test func wordsMatchOnBoundaries() {
        #expect(AccountIndex.wordCount("chase", in: "your purchases this month") == 0)
        #expect(AccountIndex.wordCount("chase", in: "chase.com and chase bank") == 2)
    }

    @Test func familiesNeedACadence() {
        let quarterly = (0..<4).map { StatementFamily.Member(name: "q", folder: "", period: .init(year: 2025, month: 1 + 3 * $0)) }
        #expect(StatementFamily.isRegular(quarterly), "quarterly counts")
        let yearly = (0..<4).map { StatementFamily.Member(name: "y", folder: "", period: .init(year: 2020 + $0, month: 12)) }
        #expect(!StatementFamily.isRegular(yearly), "a yearly form is no statement family")
        #expect(StatementFamily.period(ofName: "Statement01302026.pdf", folder: "") == .init(year: 2026, month: 1, day: 30))
        #expect(StatementFamily.period(ofName: "05. May.pdf", folder: "Credit/2024") == .init(year: 2024, month: 5))
        #expect(StatementFamily.period(ofName: "Statement 2025-11.pdf", folder: "") == .init(year: 2025, month: 11))
    }

    // MARK: Tier 3: accounts named without digits

    @Test func anAccountNamedWithoutDigitsIsLearnedFromItsStatements() throws {
        let citi = "Finance/US/Credit Accounts/Citi/Statements"
        let pilot = "Vehicles/Honda/Pilot/Statements"
        let boaFolder = "Finance/US/Bank Accounts/Bank of America"
        let t = [
            dir("Finance", [dir("Finance/US", [
                dir("Finance/US/Bank Accounts", [dir(boaFolder, [dir(boaFolder + "/Checking 5696", [dir(boaFolder + "/Checking 5696/2025",
                    monthly(boaFolder + "/Checking 5696/2025") { String(format: "eStmt_2025-%02d-28.pdf", $0) })])])]),
                dir("Finance/US/Credit Accounts", [dir("Finance/US/Credit Accounts/Citi", [dir(citi, [dir(citi + "/2025",
                    monthly(citi + "/2025") { "\(Self.months[$0 - 1]) 2025.pdf" })])])]),
            ])]),
            dir("Vehicles", [dir("Vehicles/Honda", [dir("Vehicles/Honda/Pilot", [dir(pilot,
                monthly(pilot) { String(format: "Statement 2025-%02d.pdf", $0) })])])]),
        ]
        let named = AccountIndex.build(tree: t)
        let samples = named.unnamedSamples(tree: t)
        #expect(samples.contains { $0.file.hasPrefix(citi) } && samples.contains { $0.file.hasPrefix(pilot) },
                "statements are sampled where they sit: \(samples.map(\.file))")
        let citiPage = DocumentFacts(page: "Citi Costco Card\nBilling Period: 01/04/26-02/03/26\nAccount number ending in: 8806")
        // A loan statement printing the checking account it is paid from, on every statement.
        let loanPage = DocumentFacts(page: "Honda Financial Services\nStatement Date 03/10/2026\nPaid from account ending in 5696\nAccount Number 4433688")
        let read = samples.compactMap { s -> (sample: AccountIndex.Sample, facts: DocumentFacts)? in
            if s.file.hasPrefix(citi) { return (s, citiPage) }
            if s.file.hasPrefix(pilot) { return (s, loanPage) }
            return nil
        }
        let index = named.adding(read: read)
        let citiAccount = try #require(index.accounts.first { $0.root.hasPrefix("Finance/US/Credit Accounts/Citi") }, "\(index.accounts.map(\.root)) \(read.map { $0.facts.kind }) \(read.map { $0.facts.ownNumbers })")
        #expect(citiAccount.root == citi, "the folder holding the statements that print it")
        #expect(citiAccount.identities == ["8806"] && citiAccount.institution == "citi", "\(citiAccount)")
        #expect(!index.accounts.contains { $0.root.hasPrefix("Vehicles") && $0.identities.contains("5696") },
                "5696 is a named account's; a loan paid from it doesn't take it")
        guard case .high(let a, _) = index.match(DocumentFacts(page: "Citi\nBilling Period: 02/04/26-03/03/26\nAccount number ending in: 8806")) else {
            Issue.record("a Citi statement should match Citi"); return
        }
        #expect(a.root == citiAccount.root)
        // And BoA's own statement is still BoA's alone.
        let boa = DocumentFacts(page: "Bank of America\nfor February 26, 2026 to March 27, 2026\nAccount number: 2370 2420 5696")
        guard case .high(let b, _) = index.match(boa) else { Issue.record("\(index.match(boa))"); return }
        #expect(b.root.hasSuffix("Checking 5696"))
    }
}
