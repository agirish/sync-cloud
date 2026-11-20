import Foundation
import Testing
@testable import Sync

/// A passport's printed issue date, older visa foils, OCI cards and Indian e-Visas, and how two
/// readings of one card fill each other in. Every number here is made up.
@Suite struct VaultTravelReadingTests {
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultReadingTests.day(y, m, d) }

    static func detail(_ find: VaultFind?, _ label: String) -> VaultDetail.Value? {
        find?.facts.details.first { $0.label == label }?.value
    }

    // MARK: Passports

    @Test func aPassportsIssueDateIsTheOneItsExpiryIsAnAnniversaryOf() throws {
        // A US photo page: the date of issue ten years less a day before the expiry.
        let us = VaultReadingTests.zone("P", number: "C1111111", born: "900605", expires: "341001", country: "USA")
        let usPage = ["Date of birth / Date de naissance", "05 Jun 1990", "Date of issue / Date de délivrance",
                      "02 Oct 2024", "Date of expiration", "01 Oct 2034"] + us
        let usFind = try #require(VaultReading.finds(in: usPage, from: "/Passport/Anna.pdf").first)
        #expect(Self.detail(usFind, "Issued") == .date(Self.day(2024, 10, 2)))
        #expect(usFind.facts.details.map(\.label) == ["Issuing country", "Issued", "Valid until"])

        // An Indian page in columns, day first: read either way round, only one is an anniversary.
        let india = VaultReadingTests.zone("P", number: "Z1234567", born: "880304", expires: "280314", country: "IND")
        let indiaPage = ["Date of Issue   Date of Expiry", "15/03/2018   14/03/2028"] + india
        let indiaFind = try #require(VaultReading.finds(in: indiaPage, from: "/Passport/Erik.pdf").first)
        #expect(Self.detail(indiaFind, "Issued") == .date(Self.day(2018, 3, 15)))

        // A minor's five-year passport, its label read apart from its date.
        let child = VaultReadingTests.zone("P", number: "C2222222", born: "190520", expires: "280207", country: "USA")
        let childPage = ["Date of issue / Date de délivrance", "Authority", "United States", "08 Feb 2023"] + child
        let childFind = try #require(VaultReading.finds(in: childPage, from: "/Passport/Liv.pdf").first)
        #expect(Self.detail(childFind, "Issued") == .date(Self.day(2023, 2, 8)))
    }

    @Test func aDateThatIsNoAnniversaryCountsOnlyBesideItsLabel() throws {
        let zone = VaultReadingTests.zone("P", number: "C1111111", born: "900605", expires: "341001", country: "USA")
        // Two stamps on the page: neither labelled nor an anniversary of the expiry, and not the
        // only date between the birth and the expiry, so neither is guessed.
        let stamped = ["Entered 14 Mar 2025", "Exited 02 Apr 2025"] + zone
        #expect(Self.detail(VaultReading.finds(in: stamped, from: "/p.pdf").first, "Issued") == nil)
        // Beside the label, it is taken, as long as it is within ten years of the expiry.
        let labelled = ["Date of issue", "15 Jan 2025"] + zone
        #expect(Self.detail(VaultReading.finds(in: labelled, from: "/p.pdf").first, "Issued") == .date(Self.day(2025, 1, 15)))
        let tooOld = ["Date of issue", "03 Oct 2014"] + zone
        #expect(Self.detail(VaultReading.finds(in: tooOld, from: "/p.pdf").first, "Issued") == nil)
        // No page text at all: no issue date, as before.
        let bare = try #require(MachineZone.read(zone))
        #expect(bare.passportFind(from: "/p.pdf", page: nil).facts.details.map(\.label) == ["Issuing country", "Valid until"])
    }

    // MARK: Visa foils

    @Test func aMarkAfterTheControlNumberAndADateApartFromItsLabelAreRead() throws {
        // Valid five years less a week: no anniversary to go by.
        let foil = VaultReadingTests.zone("V", number: "H1234567", born: "740812", expires: "190825", country: "USA")
        // As a 2014 foil scanned: labels in one column, values in another, a smudge after the number.
        let page = ["Passport Number", "H1234567", "Issue Date", "Annotation", "02SEP2014", "Control Number",
                    "20141234560001ź", "Birth Date", "12AUG1974", "Expiration Date", "25AUG2019"] + foil
        let find = try #require(VaultReading.finds(in: page, from: "/Visas/Mom - Visa.jpg").first)
        #expect(find.value == "20141234560001")
        #expect(Self.detail(find, "Issued") == .date(Self.day(2014, 9, 2)))
        // Two candidate dates between birth and expiry: neither is guessed.
        let twoDates = page + ["Printed 05JAN2015"]
        #expect(Self.detail(VaultReading.finds(in: twoDates, from: "/v.pdf").first, "Issued") == nil)
    }

    @Test func aVisaNumberThatFailsItsCheckIsReadOnlyWithThePrintedOne() throws {
        let foil = VaultReadingTests.zone("V", number: "J1234567", born: "880304", expires: "190825", country: "USA")
        // One digit of the passport number misread in the zone; birth and expiry still check.
        let misread = [foil[0], "J1234667" + foil[1].dropFirst(8)]
        #expect(MachineZone.zones(in: misread).isEmpty)
        let page = ["Passport Number Sex", "J1234567 F", "Control Number", "20141234560002"] + misread
        let zone = try #require(MachineZone.zones(in: page).first)
        #expect(zone.number == "J1234567")
        // A printed number further off than two characters is another passport: not used.
        let other = ["Passport Number", "J7654321"] + misread
        #expect(MachineZone.zones(in: other).isEmpty)
    }

    // MARK: OCI

    static func ociZone() -> [String] {
        let zone = VaultReadingTests.zone("V", number: "A1234567", born: "190520", expires: "190701", country: "USA")
        return ["V<IND" + zone[0].dropFirst(5), zone[1]]
    }

    @Test func anOCICardIsKnownByItsOwnNumberAndIsForLife() throws {
        let front = ["OVERSEAS CITIZEN OF INDIA CARD HOLDER", "Visa Type", "LIFE LONG", "A 1234567"] + Self.ociZone()
        let back = ["Passport No.", "A12345678", "Date of Issue", "14/02/2026", "USA"]
        let read = VaultReading.read(pages: [front, back], from: "/OCI/Liv/Liv OCI.pdf")
        let find = try #require(read.finds.first)
        #expect(read.finds.count == 1)
        #expect(find.title == "OCI card")
        #expect(find.value == "A1234567")
        #expect(find.category == .usVisa)
        #expect(find.facts.form == "OCI")
        #expect(find.facts.issuer == "IND")
        #expect(find.validUntil == nil, "the date in the zone's expiry field is not one")
        #expect(find.facts.inPassport == nil, "an OCI card never keeps an old passport in use")
        #expect(Self.detail(find, "Issued") == .date(Self.day(2026, 2, 14)))
        #expect(Self.detail(find, "Valid") == .text("Lifelong"))
        #expect(Self.detail(find, "Passport") == .number("A12345678"))
        // Its number is the card's, never taken for a passport.
        #expect(!read.mentions.contains { $0.value == "A1234567" })
        #expect(VaultGeo.read(.usVisa, facts: find.facts).geo == .india)
    }

    @Test func anEOCIIsReadFromItsUnlabelledFields() throws {
        let page = ["LIV ERIKSSON", "USA", "A1234567", "14/FEB/2026", "LIFELONG", "A12345678", "-", "20/MAY/2019",
                    "To print the card, use the given link.", "For more on OCI visit https://ociservices.gov.in",
                    "Generated On : 10/JUL/2026 10:00:00 AM"]
        let find = try #require(VaultReading.finds(in: page, from: "/OCI/Liv/Liv - eOCI.pdf").first)
        #expect(find.value == "A1234567")
        #expect(find.holder == "Liv Eriksson")
        #expect(find.facts.born == Self.day(2019, 5, 20))
        #expect(Self.detail(find, "Issued") == .date(Self.day(2026, 2, 14)))
        #expect(Self.detail(find, "Passport") == .number("A12345678"))
        // An OCI application, which quotes numbers of its own, is not a card.
        #expect(VaultReading.finds(in: ["OCI Application status", "LIFELONG", "A1234567"], from: "/a.pdf").isEmpty)
    }

    // MARK: Indian e-Visa

    static let eta = ["INDIAN e-VISA", "Electronic Travel Authorization (ETA)", "Application Id : I012V3456789",
                      "Passport Number : A12345678", "Application Status : GRANTED", "ETA Number : 12345A67B",
                      "Nationality : UNITED STATES OF AMERICA", "Visa Type : e-Visa", "Service name : eTOURIST VISA",
                      "No. of Entries : Multiple", "Date of issue of ETA :- 14/FEB/2023",
                      "Date of expiry of ETA :- 13/FEB/2028"]

    @Test func anIndianEVisaIsKnownByItsApplicationIdWithItsETA() throws {
        let find = try #require(VaultReading.finds(in: Self.eta, from: "/Visa/IN/Liv/Liv ETA (2023).pdf").first)
        #expect(find.title == "India e-Visa")
        #expect(find.value == "I012V3456789")
        #expect(find.facts.form == "e-Visa")
        #expect(find.facts.inPassport == "A12345678")
        #expect(find.validUntil == Self.day(2028, 2, 13))
        #expect(find.facts.details.map(\.label) == ["Visa", "ETA number", "Entries", "Issued", "Valid until", "In passport"])
        #expect(Self.detail(find, "Visa") == .text("e-Tourist Visa"))
        #expect(Self.detail(find, "ETA number") == .number("12345A67B"))
        // Not granted: not a visa.
        let refused = Self.eta.map { $0.replacingOccurrences(of: "GRANTED", with: "REJECTED") }
        #expect(VaultReading.finds(in: refused, from: "/eta.pdf").isEmpty)
        #expect(VaultGeo.read(.usVisa, facts: find.facts).geo == .india)
    }

    @Test func anotherCountrysOnlineVisaIsReadByTheSameLabels() throws {
        // An eTA as Canada words it: its own labels for the same fields, its dates year first.
        let page = ["Immigration, Refugees and Citizenship Canada", "Electronic Travel Authorization (eTA) approved",
                    "Application number: V123456789", "Passport number: A12345678",
                    "Date of grant: 2025-06-10", "Expiry date: 2030-06-09"]
        let find = try #require(VaultReading.finds(in: page, from: "/Travel/Canada eTA.pdf").first)
        #expect(find.title == "Canada e-Visa")
        #expect(find.value == "V123456789")
        #expect(find.facts.issuer == "CAN")
        #expect(find.facts.inPassport == "A12345678")
        #expect(Self.detail(find, "Issued") == .date(Self.day(2025, 6, 10)))
        #expect(find.validUntil == Self.day(2030, 6, 9))
        // A country it cannot tell is still a visa, under no country's name.
        let unnamed = page.dropFirst().map { $0 }
        #expect(VaultReading.finds(in: unnamed, from: "/eta.pdf").first?.title == "e-Visa")
        #expect(VaultReading.finds(in: unnamed, from: "/eta.pdf").first.map { VaultGeo.read(.usVisa, facts: $0.facts).geo }
                == .anywhere)
    }

    @Test func aLabelIsFoundWithItsSpacesBrokenButNeverInsideAWord() {
        #expect(PrintedPage.labelHit(["date of issue"], in: "Date o f Issue") != nil)
        #expect(PrintedPage.labelHit(["iss"], in: "ISSUE 01/02/2020") == nil)
        #expect(PrintedPage.labelHit(["iss"], in: "4a ISS 01/02/2020") != nil)
        let page = PrintedPage(["Date of issue of ETA :- 14/FEB/2023", "Date of Issue   Date of Expiry", "15/03/2018   14/03/2028"])
        #expect(page.date(["date of issue of eta", "date of issue"], order: .dayFirst) == Self.day(2023, 2, 14))
        #expect(page.date(["date of expiry"], order: .dayFirst) == Self.day(2028, 3, 14))
        // Labels stacked over their dates, as a 2014 foil was read, beside another stamp's date.
        let stacked = PrintedPage(["7 OCT 2014", "Issue Date", "Expiration Date", "02SEP2014", "25AUG2019"])
        #expect(stacked.date(["issue date"], order: nil) == Self.day(2014, 9, 2))
        #expect(stacked.date(["expiration date"], order: nil) == Self.day(2019, 8, 25))
    }

    @Test func aUSVisaAnEVisaAndAnOCICardAreEachWeighedOnlyAgainstTheirKind() {
        let anna = Self.day(2019, 5, 20)
        let s = VaultStandingsTests.self
        let us = s.input("V1", .usVisa, born: anna, issuer: "USA", dated: Self.day(2024, 10, 2), until: Self.day(2029, 9, 30))
        let eVisa = s.input("E1", .usVisa, born: anna, issuer: "IND", form: "e-Visa", dated: Self.day(2023, 2, 14),
                            until: Self.day(2028, 2, 13))
        let oci = s.input("O1", .usVisa, born: anna, issuer: "IND", form: "OCI", dated: Self.day(2026, 2, 14))
        let olderEVisa = s.input("E0", .usVisa, born: anna, issuer: "IND", form: "e-Visa", dated: Self.day(2019, 11, 1),
                                 until: Self.day(2024, 10, 31))
        #expect(s.tabs([us, eVisa, oci, olderEVisa]) == [.current, .current, .current, .archive])
    }

    // MARK: Two readings of one card

    @Test func theReadingThatSaysMoreSpeaksAndTheOtherFillsItsGaps() throws {
        let until = Self.day(2026, 11, 30)
        func find(_ role: String, _ details: [VaultDetail], path: String, until: Date) -> VaultFind {
            VaultFind(title: "Driver’s license · CA", value: "D1234567", note: "",
                      facts: VaultReadFacts(category: .driversLicense, issuer: "USA", validUntil: until, details: details,
                                            sources: [VaultSource(path: path, role: role, rank: 40)]))
        }
        // The front, filed first by name, reads its state; the barcode its class and issue date.
        let front = find("Driver’s license", [VaultDetail("State", .text("CA")), VaultDetail("Valid until", .date(until))],
                         path: "/DL/A front.pdf", until: until)
        let barcode = find("Driver’s license barcode",
                           [VaultDetail("Class", .text("C")), VaultDetail("Issued", .date(Self.day(2025, 7, 25))),
                            VaultDetail("Valid until", .date(until))], path: "/DL/B back.pdf", until: until)
        let merged = try #require(VaultCopies.merged([front, barcode]))
        #expect(merged.facts.details.map(\.label) == ["State", "Class", "Issued", "Valid until"])
        #expect(Set(merged.facts.sources.map(\.path)) == ["/DL/A front.pdf", "/DL/B back.pdf"])

        // The card it replaced, under the same number, lends it nothing.
        let old = find("Driver’s license barcode", [VaultDetail("Restrictions", .text("Lenses")),
                                                    VaultDetail("Valid until", .date(Self.day(2024, 1, 3)))],
                       path: "/DL/Archive/old.pdf", until: Self.day(2024, 1, 3))
        let withOld = try #require(VaultCopies.merged([front, old]))
        #expect(withOld.facts.details.map(\.label) == ["State", "Valid until"])
    }
}
