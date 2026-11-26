import Foundation
import Testing
@testable import Sync

/// Tax forms file by their tax year into the tree's own `Income Tax/<year>` layout (``TaxLane``).
@Suite struct TaxLaneTests {

    @Test func pageOneSaysWhichFormItIs() {
        func label(_ page: String) -> String? { TaxLane.kind(of: page.lowercased())?.label }
        #expect(label("2025 Form 1099-DIV Dividends and Distributions") == "1099-DIV")
        #expect(label("2025 Composite Form 1099 1099-DIV 1099-INT 1099-B") == "1099", "a composite is the composite")
        #expect(label("Form 1099-R Distributions From Pensions") == "1099-R")
        #expect(label("Form W-2 Wage and Tax Statement 2025") == "W-2")
        #expect(label("Form 1098-T Tuition Statement") == "1098-T")
        #expect(label("Form 1095-B Health Coverage") == "1095")
        #expect(label("Form 1040 U.S. Individual Income Tax Return 2025") == "1040")
        #expect(label("Your 2025 Form 1099 is now available online") == nil, "a notice is not the form")
        #expect(label("Form 1098 Mortgage Interest Statement") == nil, "a mortgage 1098 lives with the mortgage")
    }

    @Test func theYearIsTheOnePrinted() {
        #expect(TaxLane.taxYear(of: "2025 form 1099-div") == 2025)
        #expect(TaxLane.taxYear(of: "form 1040 u.s. individual income tax return 2024") == 2024)
        #expect(TaxLane.taxYear(of: "form 1095-b health coverage for calendar year 2023") == 2023)
        #expect(TaxLane.taxYear(of: "wage and income transcript tax period: december 31, 2024") == 2024)
    }

    private static let root = "/r/Docs"
    private static func file(_ rel: String) -> FileNode {
        FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent, isDirectory: false)
    }
    private static func dir(_ rel: String, _ c: [FileNode] = []) -> FileNode {
        FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent, isDirectory: true, children: c)
    }
    private static let it = "Finance/US/Income Tax"
    private static let taxonomy = [dir("Finance", [dir("Finance/US", [
        dir(it, [
            dir(it + "/2024", [
                dir(it + "/2024/Income", [dir(it + "/2024/Income/Form 1099", [file(it + "/2024/Income/Form 1099/a.pdf")]),
                                          dir(it + "/2024/Income/Form W-2")]),
                dir(it + "/2024/Deductions", [dir(it + "/2024/Deductions/Form 1098-T")]),
                dir(it + "/2024/Tax Returns", [dir(it + "/2024/Tax Returns/Refund"), dir(it + "/2024/Tax Returns/Payments")]),
                dir(it + "/2024/Tax Records"),
            ]),
            dir(it + "/2025", [dir(it + "/2025/Income")]),
        ]),
        dir("Finance/US/Investments", [dir("Finance/US/Investments/Schwab", [dir("Finance/US/Investments/Schwab/Brokerage 0371",
            [dir("Finance/US/Investments/Schwab/Brokerage 0371/Tax")])])]),
    ])])]

    @Test func theLayoutIsLearnedFromTheNewestYearHoldingIt() throws {
        let tax = try #require(TaxLane.incomeTaxRoot(in: Self.taxonomy))
        #expect(tax.path == Self.it)
        #expect(TaxLane.layout(for: .init(label: "1099", folder: "Form 1099"), in: tax.node) == "Income/Form 1099")
        #expect(TaxLane.layout(for: .init(label: "1098-T", folder: "Form 1098-T"), in: tax.node) == "Deductions/Form 1098-T")
        #expect(TaxLane.layout(for: .init(label: "5498", folder: "Form 5498"), in: tax.node) == nil, "no year has one")
    }

    private static func card(_ name: String, leadingInto rel: String, account: Bool = false) -> FilingSuggestion {
        let acct = account ? FilingAccount(root: root + "/Finance/US/Investments/Schwab/Brokerage 0371", ending: "0371",
                                           institution: "charles schwab", archived: false, kind: .taxForm) : nil
        return FilingSuggestion(filePath: "/r/In/" + name, fileName: name, size: 1, modificationDate: nil,
                                candidates: [FilingDestination(path: root + "/" + rel, confidence: .medium, reasons: ["r"],
                                                               newSegments: [], fromContent: true, account: acct)],
                                providerRoot: root)
    }

    /// A 1099 matched to its account files by its tax year, keeping the account's `Tax` as a copy.
    @Test func a1099GoesToItsTaxYearWithACopyInItsAccount() throws {
        let page = "2025 FORM 1099-DIV Dividends and Distributions Charles Schwab Account 4410-0371"
        let s = Self.card("1099.pdf", leadingInto: "Finance/US/Investments/Schwab/Brokerage 0371/Tax", account: true)
        let out = TaxLane.placing([s], pages: [s.filePath: page], taxonomy: Self.taxonomy, root: Self.root)
        let best = try #require(out.first?.best)
        #expect(best.path == Self.root + "/" + Self.it + "/2025/Income/Form 1099")
        #expect(best.newSegments == ["Form 1099"], "2025/Income exists, its Form 1099 doesn't yet")
        #expect(best.alsoCopiesTo.map(\.path) == [Self.root + "/Finance/US/Investments/Schwab/Brokerage 0371/Tax"])
        #expect(out.first?.candidates.count == 2, "the account's folder stays an option too")
    }

    /// A return goes to its year's `Tax Returns`, never to the bank account its refund names.
    @Test func aReturnGoesToItsYearsReturns() throws {
        let page = "Form 1040 U.S. Individual Income Tax Return 2025 Direct deposit routing number account number 1234"
        let s = Self.card("Form-1040.pdf", leadingInto: "Finance/US/Investments/Schwab/Brokerage 0371/Tax")
        let best = try #require(TaxLane.placing([s], pages: [s.filePath: page], taxonomy: Self.taxonomy, root: Self.root).first?.best)
        #expect(best.path == Self.root + "/" + Self.it + "/2025/Tax Returns")
        #expect(best.alsoCopiesTo.isEmpty)
    }

    /// A transcript is a record, not the return it names; refunds and payments go to the year they
    /// settle: the one printed, else the year before a spring date.
    @Test func transcriptsRefundsAndPaymentsGoByTheirTaxYear() throws {
        func best(_ page: String) -> String? {
            let s = Self.card("x.pdf", leadingInto: "Finance/US/Investments/Schwab/Brokerage 0371")
            return TaxLane.placing([s], pages: [s.filePath: page], taxonomy: Self.taxonomy, root: Self.root).first?.best?.path
                .replacingOccurrences(of: Self.root + "/" + Self.it + "/", with: "")
        }
        #expect(best("Form 1040 Tax Return Transcript Request Date: 01-18-2026 Report for Tax Period Ending: 12-31-2024")
                == "2024/Tax Records")
        #expect(best("Get Refund Status Your Personal Tax Data IRS Individual Taxpayer Tax Period Ending: December 31, 2024 Your Refund Amount")
                == "2024/Tax Returns/Refund")
        #expect(best("Account Activity Posting date Mar 3, 2025 FRANCHISE TAX BD DES:CASTTAXRFD Deposit")
                == "2024/Tax Returns/Refund", "a spring refund settles the year before")
        #expect(best("Direct Pay Confirmation Thank you for using Direct Pay! Payment date April 14, 2025")
                == "2024/Tax Returns/Payments")
        #expect(best("Direct Pay Confirmation Thank you for using Direct Pay! Payment date September 14, 2025")
                == Self.root + "/Finance/US/Investments/Schwab/Brokerage 0371",
                "a later date names no tax year, so it is left")
        #expect(best("Bank of America statement Account summary for March 1-31, 2025 FRANCHISE TAX BD TAXRFD deposit")
                == Self.root + "/Finance/US/Investments/Schwab/Brokerage 0371", "a bank statement is the bank's")
    }

    /// Left alone: a statement mentioning a 1099, a form with no year, and a tree with no
    /// `Income Tax` folder.
    @Test func anythingElseIsLeftAsItWas() {
        let s = Self.card("x.pdf", leadingInto: "Finance/US/Investments/Schwab/Brokerage 0371")
        let statement = "Schwab One Account statement Account summary for March 1-31, 2026. "
            + String(repeating: "Activity detail. ", count: 40) + "Your 2025 Form 1099 information follows"
        for page in [statement,
                     "Form 1099-DIV Dividends and Distributions"] {
            #expect(TaxLane.placing([s], pages: [s.filePath: page], taxonomy: Self.taxonomy, root: Self.root) == [s], "\(page.prefix(30))")
        }
        let none = [Self.dir("Finance")]
        #expect(TaxLane.placing([s], pages: [s.filePath: "2025 Form 1099-DIV"], taxonomy: none, root: Self.root) == [s])
    }
}
