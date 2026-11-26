import Foundation
import Testing
@testable import Sync

/// What page 1 text Refine with Claude sends: a number long enough to be an account's leaves the
/// Mac as `••` and its last four digits, never whole. Dates, amounts, years and form names go as
/// printed, since the model files by them.
@Suite struct CloudFilingExcerptMaskTests {

    /// The excerpt line of the request for one file whose page 1 reads `page`.
    private func sent(_ page: String) throws -> String {
        let file = FilingCandidateFile(filePath: "/root/Downloads/scan.pdf", fileName: "scan.pdf", ext: "pdf",
                                       year: "2026", contentSnippet: page)
        let body = CloudFilingProtocol.requestBody(taxonomyFolders: ["Finance"], files: [file])
        let userText = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        let line = try #require(userText.split(separator: "\n").first { $0.hasPrefix("    excerpt: ") })
        return String(line.dropFirst("    excerpt: ".count))
    }

    private func masked(_ text: String) -> String { ExcerptNumberMask.masked(text) }

    // MARK: What is cut

    @Test func aLabelledAccountNumberLeavesAsItsEnding() throws {
        let page = "Bank of Example\nAccount number: 4829173650\nStatement Period 03/01/2026 - 03/31/2026"
        let text = try sent(page)
        #expect(!text.contains("482917"))
        #expect(text == "Bank of Example Account number: ••3650 Statement Period 03/01/2026 - 03/31/2026")
        // The ending sent is the ending filing matches an account folder by.
        #expect(DocumentFacts(page: page).ownNumbers.map(\.ending) == ["3650"])
    }

    /// A short number is cut when the page labels it, and one printed in groups is cut whole.
    @Test(arguments: [
        ("Loan Number: 48291", "Loan Number: ••8291"),
        ("Policy No. 482917", "Policy No. ••2917"),
        ("Account Number\n3841-9312\nPage 2 of 6", "Account Number\n••9312\nPage 2 of 6"),
        ("Account Number 3841 9312 2 of 6", "Account Number ••9312 2 of 6"),
        ("Member number: 000 123 456 789", "Member number: ••6789"),
        ("Account Number: Z26-221746", "Account Number: Z••1746"),
        ("Account Number: 946261935\u{2212}01", "Account Number: ••3501"),
    ])
    func aNumberThePageLabelsIsCutHoweverItIsPrinted(page: String, expected: String) {
        #expect(masked(page) == expected)
        // The same ending `DocumentFacts` reads, which is what a card shows and filing learns.
        let ending = DocumentFacts.ownNumbers(in: page).first?.ending
        #expect(ending.map { expected.contains(ExcerptNumberMask.bullets + $0) } == true)
    }

    /// A long number is cut with no label at all: the page may call it anything, or nothing.
    @Test(arguments: [
        ("Member ID W123456789", "Member ID W••6789"),
        ("Ref 4829173650 enclosed", "Ref ••3650 enclosed"),
        ("SSN: 123-45-6789", "SSN: ••6789"),
        ("EIN 12-3456789", "EIN ••6789"),
        ("AutoPay from account number 4829173650", "AutoPay from account number ••3650"),
        ("Routing 121000248 Checking 000123456789", "Routing ••0248 Checking ••6789"),
        ("Card 4829 1736 5012 3456 exp", "Card ••3456 exp"),
        ("Amex 3782 822463 10005", "Amex ••0005"),
        ("Card 4829\u{00A0}1736\u{00A0}5012\u{00A0}3456", "Card ••3456"),
        ("Card 4829  1736  5012  3456", "Card ••3456"),
        ("Taxpayer 123 45 6789", "Taxpayer ••6789"),
        ("Branch 0012.4829173650", "Branch 0012.••3650"),
        ("Passport Z1234567", "Passport Z••4567"),
        ("No.4829173650.", "No.••3650."),
        ("Accounts: 4829173650,4829173651", "Accounts: ••3650,••3651"),
        ("12-34-5678", "••5678"),
    ])
    func aLongNumberIsCutWhateverItIsCalled(page: String, expected: String) {
        #expect(masked(page) == expected)
    }

    // MARK: What is left as printed

    /// A number the page already masks shows only what the page chose to show.
    @Test(arguments: [
        "Account ending in 6701",
        "Visa XXXX XXXX XXXX 1833",
        "Savings ******4824",
        "Card XXXX-XXXX-XXXX-1833",
        "Account •••• 9312",
    ])
    func aNumberMaskedOnThePageIsLeftAsPrinted(page: String) {
        #expect(masked(page) == page)
    }

    @Test(arguments: [
        "Statement Period 03/01/2026 - 03/31/2026",
        "Closing Date 2026-03-31",
        "Statement Date: 03-31-2026",
        "Issued 31-03-2026",
        "2026-03-01-2026-03-31",
        "Period 2026-3-31",
        "As of 20260331",
        "March 1-31, 2026",
        "31-Mar-2026",
        "Printed 2026-03-31 10:45:32",
    ])
    func aDateIsLeftAsPrinted(page: String) {
        #expect(masked(page) == page)
    }

    @Test(arguments: [
        "New Balance $1,234,567.89",
        "Loan amount $1234567",
        "Principal $ 1250000 at 6.125%",
        "Total 1234567.89",
        "Gesamt 1234567,89 EUR",
        "Rs. 2500000",
        "INR 12500000 sanctioned",
        "USD1250000",
        "₹12,34,567.00",
    ])
    func anAmountIsLeftAsPrinted(page: String) {
        #expect(masked(page) == page)
    }

    @Test(arguments: [
        "Tax Year 2025",
        "2025 Form 1099-INT",
        "Form 1099-2025",
        "Form 1098 2025 Mortgage Interest Statement",
        "Form W-2 Wage and Tax Statement 2025",
        "Form 1040 2024 2025 2026",
        "H-1B Visa 2024-2026",
        "FY 2025-26",
        "Fremont, CA 94538",
        "Page 2 of 6",
        "Call 311 or 800 555",
        "Shares 100 200 150 4000",
        "Members 123456",
    ])
    func aYearAndAFormNameAreLeftAsPrinted(page: String) {
        #expect(masked(page) == page)
    }

    /// The model still reads what the document is: only the numbers change.
    @Test func aWholeStatementHeaderKeepsEverythingButItsNumbers() {
        let page = """
            Example Bank, N.A.
            P.O. Box 1234, Fremont, CA 94538
            Statement Period 03/01/2026 – 03/31/2026
            Primary Account Number: 000004829173650
            Ending Balance $12,345.67
            AutoPay from account ending in ****4824
            Tax ID XXX-XX-8508    Customer service 1-800-555-0100
            Your 2025 Form 1099-INT is now available
            """
        let expected = """
            Example Bank, N.A.
            P.O. Box 1234, Fremont, CA 94538
            Statement Period 03/01/2026 – 03/31/2026
            Primary Account Number: ••3650
            Ending Balance $12,345.67
            AutoPay from account ending in ****4824
            Tax ID XXX-XX-8508    Customer service ••0100
            Your 2025 Form 1099-INT is now available
            """
        #expect(masked(page) == expected)
    }

    // MARK: The request

    /// The cut at 800 characters comes after the numbers are cut, so a number across it leaves as
    /// its ending or a piece of that, never as its first digits.
    @Test func aNumberAcrossTheLengthCutLeavesAsNoMoreThanItsEnding() throws {
        let filler = String(repeating: "x", count: CloudFilingProtocol.maxSnippetChars - 5)
        let text = try sent(filler + " 4829173650 and more")
        #expect(text == filler + " ••36")
        #expect(text.count == CloudFilingProtocol.maxSnippetChars)
    }

    /// Text past the cut is never sent, masked or not.
    @Test func nothingPastTheLengthCutIsSent() throws {
        let filler = String(repeating: "x", count: CloudFilingProtocol.maxSnippetChars)
        #expect(try sent(filler + " Account number: 4829173650") == filler)
    }

    /// Every file in a batch is cut, and the one card's Ask Claude with Page 1 sends through the
    /// same request.
    @Test func everyFileInTheRequestIsCut() throws {
        let files = (0..<3).map { i in
            FilingCandidateFile(filePath: "/root/Downloads/\(i).pdf", fileName: "\(i).pdf", ext: "pdf", year: nil,
                                contentSnippet: "Account number: 482917365\(i)")
        }
        let body = CloudFilingProtocol.requestBody(taxonomyFolders: ["Finance"], files: files,
                                                   shape: .current(for: AskClaudeModels.options[0]))
        let userText = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        for i in 0..<3 { #expect(userText.contains("excerpt: Account number: ••365\(i)\n")) }
        // Nowhere in what goes over the wire, whatever part of the body it is in.
        let wire = try #require(String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8))
        #expect(!wire.contains("482917"))
    }
}
