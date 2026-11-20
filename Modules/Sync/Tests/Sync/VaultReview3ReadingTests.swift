import Foundation
import Testing
@testable import Sync

/// The third adversarial review of the Vault's readers: each test is a finding's own failing
/// input, which read wrongly before its fix. Every number is made up.
@Suite struct VaultReview3ReadingTests {
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultReadingTests.day(y, m, d) }
    static func detail(_ find: VaultFind?, _ label: String) -> VaultDetail.Value? {
        VaultTravelReadingTests.detail(find, label)
    }

    @Test func aUSVisaInAFileWithAnOCICardIsStillAVisa() throws {
        let oci = ["OVERSEAS CITIZEN OF INDIA CARD HOLDER"] + VaultTravelReadingTests.ociZone()
        let visa = ["Control Number 20241234560001", "Visa Type/Class H-1B"]
            + VaultReadingTests.zone("V", number: "L8988901", born: "740812", expires: "290930", country: "USA")
        let read = VaultReading.read(pages: [oci, visa], from: "/Immigration/Liv OCI and visa.pdf")
        #expect(Set(read.finds.map(\.title)) == ["OCI card", "US visa · H-1B"])
        #expect(Set(read.finds.map(\.value)) == ["A1234567", "20241234560001"])
        #expect(read.mentions.map(\.value) == ["L8988901"], "the visa's zone names its passport")
    }

    @Test func anEVisaApplicationFormIsNotAVisa() {
        let form = ["Indian e-Visa Application", "Temporary Application ID : I012V3456789",
                    "Passport No. : A12345678", "Date of Issue : 01/02/2020", "Date of Expiry : 31/01/2030"]
        #expect(VaultReading.finds(in: form, from: "/Visa/IN/Liv/form.pdf").isEmpty)
    }

    @Test func anEVisasOwnDatesWinOverItsPassportsAndTheMostTellingLabelFirst() throws {
        let page = ["Electronic Travel Authorization", "Indian e-Visa", "Application ID: I012V3456789",
                    "Passport Date of Issue: 01/02/2020", "Passport Date of Expiry: 31/01/2030",
                    "Date of issue: 10/02/2023", "Date of issue of ETA: 14/02/2023", "Date of expiry of ETA: 13/02/2028"]
        let find = try #require(VaultReading.finds(in: page, from: "/eta.pdf").first)
        #expect(Self.detail(find, "Issued") == .date(Self.day(2023, 2, 14)))
        #expect(find.validUntil == Self.day(2028, 2, 13))
    }

    @Test func aUSOnlineVisaReadsItsDatesMonthFirstAndItsStatusAsWords() throws {
        let page = ["U.S. Customs and Border Protection", "ESTA Application", "ESTA Application Number: U12345678ABC",
                    "Authorization Status: Authorization Approved", "Date of grant: 03/12/2025",
                    "Authorization Expires: Jun 12, 2027", "Passport Number: 123456789"]
        let find = try #require(VaultReading.finds(in: page, from: "/esta.pdf").first)
        #expect(find.title == "US e-Visa")
        #expect(Self.detail(find, "Issued") == .date(Self.day(2025, 3, 12)))
        #expect(find.validUntil == Self.day(2027, 6, 12))
        let denied = page.map { $0.replacingOccurrences(of: "Authorization Approved", with: "Travel Not Authorized") }
        #expect(VaultReading.finds(in: denied, from: "/esta.pdf").isEmpty)
    }

    @Test func aReferenceNumberIsNeverTheNextColumnsLabel() throws {
        let page = ["Immigration, Refugees and Citizenship Canada", "Electronic Travel Authorization",
                    "Application number   Passport number", "V123456789   A12345678", "Expiry date: 2030-06-09"]
        #expect(try #require(VaultReading.finds(in: page, from: "/eta.pdf").first).value == "V123456789")
    }

    @Test func aRenewedCardNeverBorrowsTheExpiryOrDetailsOfTheOneItReplaced() throws {
        func find(_ details: [VaultDetail], dated: Date, until: Date?, path: String) -> VaultFind {
            VaultFind(title: "Driver’s license · CA", value: "D1234567", note: "",
                      facts: VaultReadFacts(category: .driversLicense, issuer: "USA", dated: dated, validUntil: until,
                                            details: details, sources: [VaultSource(path: path, role: "Driver’s license", rank: 40)]))
        }
        let renewed = find([VaultDetail("State", .text("CA")), VaultDetail("Issued", .date(Self.day(2024, 12, 1)))],
                           dated: Self.day(2024, 12, 1), until: nil, path: "/DL/new front.pdf")
        // The old card, from its barcode in Archive, ran out before the renewal was issued.
        let old = find([VaultDetail("Class", .text("C")), VaultDetail("Issued", .date(Self.day(2019, 1, 3))),
                        VaultDetail("Valid until", .date(Self.day(2024, 6, 30)))],
                       dated: Self.day(2019, 1, 3), until: Self.day(2024, 6, 30), path: "/DL/Archive/old back.pdf")
        let merged = try #require(VaultCopies.merged([old, renewed]))
        #expect(merged.facts.dated == Self.day(2024, 12, 1), "the renewal speaks")
        #expect(merged.validUntil == nil, "the renewal took the old card's expiry, and showed as expired")
        #expect(merged.facts.details.map(\.label) == ["State", "Issued"])
    }

    @Test func aNewerExtensionStillLendsItsAdmitUntilToThePrintout() throws {
        // As read from the household's files on 2026-11-19: the printout speaks for the number but
        // prints no admit-until; the I-797A tear-offs that extended it carry one and no entry date.
        let printout = VaultFind(title: "I-94 admission number", value: "12345678901", note: "",
                                 facts: VaultReadFacts(category: .i94, dated: Self.day(2015, 6, 1),
                                                       details: [VaultDetail("Class of admission", .text("F2")),
                                                                 VaultDetail("Entered", .date(Self.day(2015, 6, 1)))],
                                                       sources: [VaultSource(path: "/I-94/printout.pdf", role: "CBP I-94 printout",
                                                                             rank: VaultReading.Rank.i94Printout)]))
        let tearOff = VaultFind(title: "I-94 admission number", value: "12345678901", note: "",
                                facts: VaultReadFacts(category: .i94, validUntil: Self.day(2019, 8, 25),
                                                      details: [VaultDetail("Admitted until", .date(Self.day(2019, 8, 25)))],
                                                      sources: [VaultSource(path: "/I-797/approval.pdf", role: "I-797A tear-off",
                                                                            rank: VaultReading.Rank.tearOff)]))
        let merged = try #require(VaultCopies.merged([printout, tearOff]))
        #expect(merged.validUntil == Self.day(2019, 8, 25))
        #expect(merged.facts.details.map(\.label) == ["Admitted until", "Class of admission", "Entered"])
    }

    @Test func eachPassportOnAPageHasItsOwnIssueDate() throws {
        let anna = VaultReadingTests.zone("P", number: "C1111111", born: "900605", expires: "341001", given: "ANNA")
        let erik = VaultReadingTests.zone("P", number: "C2222222", born: "850101", expires: "330501", given: "ERIK")
        let page = ["Date of issue", "02 Oct 2024"] + anna + ["Date of issue", "02 May 2023"] + erik
        let finds = VaultReading.finds(in: page, from: "/Passport/both.pdf")
        let issued = Dictionary(uniqueKeysWithValues: finds.map { ($0.value, Self.detail($0, "Issued")) })
        #expect(issued["C1111111"] == .date(Self.day(2024, 10, 2)))
        #expect(issued["C2222222"] == .date(Self.day(2023, 5, 2)))
    }

    @Test func aRowOfLabelsWithFewerDatesUnderItGivesNone() {
        let page = PrintedPage(["Date of Issue   Date of Expiry", "31-01-2030"])
        #expect(page.date(["date of issue"], order: .dayFirst) == nil)
        #expect(page.date(["date of expiry"], order: .dayFirst) == nil)
    }

    @Test func abbreviationsWithOrWithoutTheirLastDotAndBilingualMonths() {
        #expect(PrintedPage(["D.O.B 01-02-1990"]).date(["DOB", "D.O.B.", "D.O.B"], order: .dayFirst) == Self.day(1990, 2, 1))
        #expect(PrintedPage.dates(in: "14 FEB /FÉV 2023", order: nil).map(\.date) == [Self.day(2023, 2, 14)])
        #expect(PrintedPage.dates(in: "June 12 2026", order: nil).map(\.date) == [Self.day(2026, 6, 12)])
    }

    @Test func OCIInsideAnotherWordIsNotAnEOCI() {
        let page = ["Lifelong Members Association", "JOHN SMITH", "M1234567", "01/02/2020"]
        #expect(VaultReading.finds(in: page, from: "/club.pdf").isEmpty)
    }

    @Test func aVisaClassIsReadAfterItsTypeLetterOnItsOwnLine() throws {
        let foil = VaultReadingTests.zone("V", number: "H1234567", born: "740812", expires: "240901", country: "USA")
        let page = ["Control Number", "20141234560001", "Visa Type /Class", "R", "B1/B2"] + foil
        #expect(try #require(VaultReading.finds(in: page, from: "/visa.pdf").first).title == "US visa · B1/B2")
        let sameLine = ["Control Number 20141234560001", "Visa Type/Class R H1B"] + foil
        #expect(try #require(VaultReading.finds(in: sameLine, from: "/visa.pdf").first).title == "US visa · H1B")
    }

    @Test func aGoodVisaOfAnotherClassIsNotReplacedByANewerOne() {
        let anna = Self.day(1974, 8, 12)
        func visa(_ value: String, _ visaClass: String, dated: Date, until: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .usVisa,
                               facts: VaultReadFacts(category: .usVisa, born: anna, issuer: "USA", dated: dated, validUntil: until,
                                                     details: [VaultDetail("Visa class", .text(visaClass))],
                                                     sources: [VaultSource(path: "/docs/v.pdf", role: "Visa foil", rank: 40)]),
                               pin: nil)
        }
        let visitor = visa("V1", "B1/B2", dated: Self.day(2019, 3, 1), until: Self.day(2029, 2, 28))
        let work = visa("V2", "H-1B", dated: Self.day(2025, 10, 2), until: Self.day(2028, 9, 30))
        let oldWork = visa("V0", "H-1B", dated: Self.day(2022, 10, 2), until: Self.day(2027, 9, 30))
        #expect(VaultStandingsTests.tabs([visitor, work, oldWork]) == [.current, .current, .archive])
    }
}
