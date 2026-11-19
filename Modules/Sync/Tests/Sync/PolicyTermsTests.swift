import Foundation
import Testing
@testable import Sync

/// Policy papers file by the year their term starts, named for the term (``PolicyTerms``).
@Suite struct PolicyTermsTests {

    private typealias M = PolicyTerms.Month
    private static func term(_ m1: Int, _ y1: Int, _ m2: Int, _ y2: Int) -> PolicyTerms.Term {
        .init(start: M(year: y1, month: m1), end: M(year: y2, month: m2))
    }

    @Test func aNameCarriesItsInsurerAndTerm() {
        #expect(PolicyTerms.namedPaper("Acme-Homesafe Policy - Jan 2025-Jan 2026.pdf")
                == .init(insurer: "Acme-Homesafe", term: Self.term(1, 2025, 1, 2026)))
        #expect(PolicyTerms.namedPaper("Acme Evidence of Insurance - Feb 2023-Feb 2024.pdf")?.insurer == "Acme")
        #expect(PolicyTerms.namedPaper("Acme Renewal Package - Feb 2023-Feb 2024.pdf")?.insurer == "Acme")
        #expect(PolicyTerms.namedPaper("Acme Terms and Conditions (Jun 2022).pdf") == nil)
        #expect(PolicyTerms.namedPaper("11. Nov 2025 - Renewal Package.pdf") == nil)
        #expect(PolicyTerms.namedPaper("Acme Policy - Jan 2026-Jan 2025.pdf") == nil, "a term runs forward")
    }

    /// A renewal is for the term starting in or after its letter's month; anything else for the
    /// term in force on its date. Stepped on the folder's own cadence, either way.
    @Test func theTermFollowsTheFoldersCadence() {
        let known = Self.term(1, 2025, 1, 2026)
        #expect(PolicyTerms.term(for: M(year: 2025, month: 11), renewal: true, following: known)
                == Self.term(1, 2026, 1, 2027), "a November letter renews January's term")
        #expect(PolicyTerms.term(for: M(year: 2025, month: 11), renewal: false, following: known)
                == known, "any other paper belongs to the term in force")
        #expect(PolicyTerms.term(for: M(year: 2026, month: 1), renewal: true, following: known)
                == Self.term(1, 2026, 1, 2027), "a letter in the start month is for that term")
        #expect(PolicyTerms.term(for: M(year: 2022, month: 12), renewal: false, following: Self.term(2, 2024, 2, 2025))
                == Self.term(2, 2022, 2, 2023), "stepped back from a later term")
        #expect(PolicyTerms.term(for: M(year: 2022, month: 12), renewal: true, following: Self.term(2, 2024, 2, 2025))
                == Self.term(2, 2023, 2, 2024))
    }

    @Test func aPrintedTermIsReadInEachWayItIsPrinted() {
        #expect(PolicyTerms.printedTerm(onPage: "evidence of property insurancedate 12/30/2022 effective date and more effective date 02/19/2023 12:01 am expiration date 02/19/2024 12:01 am")
                == Self.term(2, 2023, 2, 2024))
        #expect(PolicyTerms.printedTerm(onPage: "declarations page effective date*: 02/19/2024 12:01 am policy expiration date*: 02/19/2025")
                == Self.term(2, 2024, 2, 2025))
        #expect(PolicyTerms.printedTerm(onPage: "policy period: 01/15/2026 to 01/15/2027") == Self.term(1, 2026, 1, 2027))
        #expect(PolicyTerms.printedTerm(onPage: "this policy covers the home from january 15, 2026 through january 15, 2027")
                == Self.term(1, 2026, 1, 2027))
        #expect(PolicyTerms.printedTerm(onPage: "renewal for policy number 123 november 11, 2025") == nil)
    }

    // MARK: - Placing a card

    private static let root = "/r/Docs"
    private static func file(_ rel: String) -> FileNode {
        FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent, isDirectory: false)
    }
    private static func dir(_ rel: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent, isDirectory: true, children: children)
    }
    private static let taxonomy = [dir("Home", [dir("Home/Insurance", [
        dir("Home/Insurance/2024", [file("Home/Insurance/2024/Hearth Declarations - Feb 2024-Feb 2025.pdf")]),
        dir("Home/Insurance/2025", [file("Home/Insurance/2025/Acme-Homesafe Policy - Jan 2025-Jan 2026.pdf"),
                                    file("Home/Insurance/2025/Acme-Homesafe Evidence of Insurance - Jan 2025-Jan 2026.pdf")]),
    ])])]

    private static func card(leadingInto rel: String, confidence: FilingConfidence = .high) -> FilingSuggestion {
        FilingSuggestion(filePath: "/r/Inbox/scan.pdf", fileName: "scan.pdf", size: 1, modificationDate: nil,
                         candidates: [FilingDestination(path: root + "/" + rel, confidence: confidence,
                                                        reasons: ["Policy number on page 1"], newSegments: [],
                                                        fromContent: true, proposedName: "11. Nov 2025 - Renewal Package.pdf")],
                         providerRoot: root)
    }
    private static let renewal = """
        Acme Insurance Agency Underwritten by: HOMESAFE INSURANCE COMPANY
        Renewal For Policy Number 12345678 November 11, 2025
        Thank you for renewing your condominium policy. Please review your declarations page.
        """

    /// The case that started this: a renewal letter printing only its own date, led by its policy's
    /// number into last year's folder. It moves to the year its term starts, named for the term,
    /// at Medium, since the term was worked out rather than read.
    @Test func aRenewalGoesToTheYearItsTermStarts() throws {
        let out = PolicyTerms.placing([Self.card(leadingInto: "Home/Insurance/2025")],
                                      pages: ["/r/Inbox/scan.pdf": Self.renewal],
                                      taxonomy: Self.taxonomy, root: Self.root)
        let best = try #require(out.first?.best)
        #expect(best.path == Self.root + "/Home/Insurance/2026")
        #expect(best.newSegments == ["2026"])
        #expect(best.proposedName == "Acme-Homesafe Renewal - Jan 2026-Jan 2027.pdf")
        #expect(best.confidence == .medium)
        #expect(best.reasons.last?.contains("Jan 2026-Jan 2027") == true)
    }

    /// A term the page prints is read, not worked out, so the card keeps its confidence.
    @Test func aPrintedTermKeepsTheCardsConfidence() throws {
        let page = "Acme-Homesafe evidence of insurance for policy 12345678 dated 11/20/2025. "
            + "Effective Date 01/15/2026 Expiration Date 01/15/2027"
        let out = PolicyTerms.placing([Self.card(leadingInto: "Home/Insurance/2025")],
                                      pages: ["/r/Inbox/scan.pdf": page], taxonomy: Self.taxonomy, root: Self.root)
        let best = try #require(out.first?.best)
        #expect(best.path == Self.root + "/Home/Insurance/2026")
        #expect(best.proposedName == "Acme-Homesafe Evidence of Insurance - Jan 2026-Jan 2027.pdf")
        #expect(best.confidence == .high)
    }

    /// Left alone: a page that isn't a policy's own paper, an insurer the folder has no papers
    /// for, and a folder not named by term.
    @Test func anythingElseIsLeftAsItWas() {
        let card = Self.card(leadingInto: "Home/Insurance/2025")
        let bill = "Acme Insurance policy 12345678 premium bill. Amount due December 1, 2025"
        let otherInsurer = Self.renewal.replacingOccurrences(of: "Acme", with: "Zenith")
            .replacingOccurrences(of: "HOMESAFE", with: "ZENITH")
        for page in [bill, otherInsurer] {
            let out = PolicyTerms.placing([card], pages: ["/r/Inbox/scan.pdf": page],
                                          taxonomy: Self.taxonomy, root: Self.root)
            #expect(out == [card], "\(page.prefix(30))")
        }
        let plain = [Self.dir("Home", [Self.dir("Home/Insurance", [
            Self.dir("Home/Insurance/2025", [Self.file("Home/Insurance/2025/11. Nov 2025 - Renewal.pdf")])])])]
        #expect(PolicyTerms.placing([card], pages: ["/r/Inbox/scan.pdf": Self.renewal],
                                    taxonomy: plain, root: Self.root) == [card])
    }
}
