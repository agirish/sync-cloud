import Foundation
import Testing
@testable import Sync

/// The fourth adversarial review, of the third's fixes: each test is a finding's own scenario,
/// which went wrong before its fix. Every number is made up.
@Suite struct VaultReview4Tests {
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultReadingTests.day(y, m, d) }

    static func license(_ details: [VaultDetail], dated: Date?, until: Date?, path: String) -> VaultFind {
        VaultFind(title: "Driver’s license · CA", value: "D1234567", note: "",
                  facts: VaultReadFacts(category: .driversLicense, issuer: "USA", dated: dated, validUntil: until,
                                        details: details, sources: [VaultSource(path: path, role: "Driver’s license", rank: 40)]))
    }

    // MARK: Merging copies of one number

    @Test func anEarlyRenewalSpeaksOverTheCardFiledInArchive() throws {
        let renewed = Self.license([VaultDetail("State", .text("CA")), VaultDetail("Issued", .date(Self.day(2024, 12, 1)))],
                                   dated: Self.day(2024, 12, 1), until: nil, path: "/Legal/DL/front.pdf")
        // Renewed early: the old card runs out after the renewal was issued.
        let old = Self.license([VaultDetail("Class", .text("C")), VaultDetail("Valid until", .date(Self.day(2025, 3, 31)))],
                               dated: Self.day(2019, 1, 3), until: Self.day(2025, 3, 31), path: "/Legal/DL/Archive/old.pdf")
        let merged = try #require(VaultCopies.merged([old, renewed]))
        #expect(merged.facts.dated == Self.day(2024, 12, 1))
        #expect(merged.validUntil == nil, "the renewal showed the old card's expiry")
        #expect(merged.facts.details.map(\.label) == ["State", "Issued"])
    }

    @Test func anUndatedScanOfTheOldCardLendsTheRenewalNothing() throws {
        let renewed = Self.license([VaultDetail("Issued", .date(Self.day(2024, 12, 1))),
                                    VaultDetail("Valid until", .date(Self.day(2029, 12, 1)))],
                                   dated: Self.day(2024, 12, 1), until: Self.day(2029, 12, 1), path: "/Legal/DL/new.pdf")
        let old = Self.license([VaultDetail("Restrictions", .text("Lenses")), VaultDetail("Valid until", .date(Self.day(2025, 3, 31)))],
                               dated: nil, until: Self.day(2025, 3, 31), path: "/Legal/DL/scan.pdf")
        let merged = try #require(VaultCopies.merged([renewed, old]))
        #expect(merged.facts.details.map(\.label) == ["Issued", "Valid until"])
    }

    // MARK: Zones

    @Test func anOCICardWhoseIssuingStateWasNotReadIsStillOne() throws {
        let zone = VaultReadingTests.zone("V", number: "A1234567", born: "190520", expires: "190701", country: "USA")
        // The issuing state read as two letters: the issuer falls back to the holder's nationality.
        let garbled = ["V<IN<" + zone[0].dropFirst(5), zone[1]]
        let page = ["OVERSEAS CITIZEN OF INDIA CARD HOLDER"] + garbled
        let find = try #require(VaultReading.finds(in: page, from: "/OCI/card.pdf").first)
        #expect(find.title == "OCI card")
        #expect(find.value == "A1234567")
    }

    @Test func twoZonesReadOneAfterTheOtherStillReadTheirFields() throws {
        let passport = VaultReadingTests.zone("P", number: "C1111111", born: "740812", expires: "341001", country: "USA")
        let visa = VaultReadingTests.zone("V", number: "C1111111", born: "740812", expires: "290930", country: "USA")
        // Side by side, as Vision reads them: every field first, then both zones.
        let page = ["Control Number", "20241234560001", "Visa Type/Class H-1B", "Date of issue", "02 Oct 2024"]
            + passport + visa
        let finds = VaultReading.finds(in: page, from: "/scan.pdf")
        #expect(finds.contains { $0.value == "20241234560001" }, "the visa lost its Control Number")
        #expect(finds.contains { $0.value == "C1111111" })
    }

    // MARK: Labels

    @Test func anotherFieldsWordCountsOnlyRightBeforeTheLabel() {
        let page = PrintedPage(["Passport No: A12345678  Date of Issue: 14/02/2023", "Passport Date of Issue: 01/02/2020"])
        #expect(page.date(["date of issue"], order: .dayFirst, unless: ["passport"]) == Self.day(2023, 2, 14))
        let only = PrintedPage(["Passport Date of Issue: 01/02/2020"])
        #expect(only.date(["date of issue"], order: .dayFirst, unless: ["passport"]) == nil)
    }

    @Test func aPlaceBesideADateIsNotADateColumn() {
        let page = PrintedPage(["Date of Issue    Issued By", "12/03/2020   RTO MUMBAI"])
        #expect(page.date(["date of issue"], order: .dayFirst) == Self.day(2020, 3, 12))
    }

    // MARK: Whose, and which is current

    @Test func oneVisaClassWrittenTwoWaysIsOneClass() {
        let anna = Self.day(1974, 8, 12)
        func visa(_ value: String, _ visaClass: String, dated: Date, until: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .usVisa,
                               facts: VaultReadFacts(category: .usVisa, born: anna, issuer: "USA", dated: dated, validUntil: until,
                                                     details: [VaultDetail("Visa class", .text(visaClass))],
                                                     sources: [VaultSource(path: "/docs/v.pdf", role: "Visa foil", rank: 40)]),
                               pin: nil)
        }
        let old = visa("V0", "H1B", dated: Self.day(2022, 10, 2), until: Self.day(2027, 9, 30))
        let new = visa("V1", "H-1B", dated: Self.day(2025, 10, 2), until: Self.day(2028, 9, 30))
        #expect(VaultStandingsTests.tabs([old, new]) == [.archive, .current])
    }

    @Test func aFirstNameMisreadByOneLetterIsStillOnePerson() {
        let born = Self.day(1988, 3, 4)
        let s = VaultStandingsTests.self
        let old = s.input("P0", .passport, born: born, holder: "Abhlshek Girish", issuer: "IND",
                          dated: s.day(2022, 5, 16), until: s.day(2022, 5, 16))
        let new = s.input("P1", .passport, born: born, holder: "Abhishek Girish", issuer: "IND",
                          dated: s.day(2032, 5, 16), until: s.day(2032, 5, 16))
        #expect(s.tabs([old, new]) == [.archive, .current])
        #expect(VaultPeopleClusters.sameFirstName("g", "girish"))
        #expect(!VaultPeopleClusters.sameFirstName("liv", "nils"))
        #expect(!VaultPeopleClusters.sameFirstName("anna", "erik"))
    }
}

/// The number shown under "every number" stays while it is worked on.
@MainActor
@Suite struct VaultReview4ModelTests {
    typealias Rig = VaultModelTests.Rig

    @Test func typingInTheEditorKeepsTheNumberShownPastItsThirtySeconds() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        #expect(await model.show(VaultModelTests.passport.id))
        rig.clock.advance(25)
        model.noteActivity()
        rig.clock.advance(20)
        model.tick()
        #expect(model.canShow(VaultModelTests.passport), "the editor's number was taken away mid-edit")
        rig.clock.advance(31)
        model.tick()
        #expect(!model.canShow(VaultModelTests.passport), "left alone, it hides again")
    }
}
