import Foundation
import Testing
@testable import Sync

/// Passports, visa foils and OCI cards read from their machine-readable zones (``MachineZone``).
@Suite struct VaultZoneTests {
    @Test func aUSVisaInAFileWithAnOCICardIsStillAVisa() throws {
        let oci = ["OVERSEAS CITIZEN OF INDIA CARD HOLDER"] + VaultTravelReadingTests.ociZone()
        let visa = ["Control Number 20241234560001", "Visa Type/Class H-1B"]
            + VaultReadingTests.zone("V", number: "L8988901", born: "740812", expires: "290930", country: "USA")
        let read = VaultReading.read(pages: [oci, visa], from: "/Immigration/Liv OCI and visa.pdf")
        #expect(Set(read.finds.map(\.title)) == ["OCI card", "US visa · H-1B"])
        #expect(Set(read.finds.map(\.value)) == ["A1234567", "20241234560001"])
        #expect(read.mentions.map(\.value) == ["L8988901"], "the visa's zone names its passport")
    }

    @Test func eachPassportOnAPageHasItsOwnIssueDate() throws {
        let anna = VaultReadingTests.zone("P", number: "C1111111", born: "900605", expires: "341001", given: "ANNA")
        let erik = VaultReadingTests.zone("P", number: "C2222222", born: "850101", expires: "330501", given: "ERIK")
        let page = ["Date of issue", "02 Oct 2024"] + anna + ["Date of issue", "02 May 2023"] + erik
        let finds = VaultReading.finds(in: page, from: "/Passport/both.pdf")
        let issued = Dictionary(uniqueKeysWithValues: finds.map { ($0.value, VaultFixtures.detail($0, "Issued")) })
        #expect(issued["C1111111"] == .date(VaultFixtures.day(2024, 10, 2)))
        #expect(issued["C2222222"] == .date(VaultFixtures.day(2023, 5, 2)))
    }

    @Test func aVisaClassIsReadAfterItsTypeLetterOnItsOwnLine() throws {
        let foil = VaultReadingTests.zone("V", number: "H1234567", born: "740812", expires: "240901", country: "USA")
        let page = ["Control Number", "20141234560001", "Visa Type /Class", "R", "B1/B2"] + foil
        #expect(try #require(VaultReading.finds(in: page, from: "/visa.pdf").first).title == "US visa · B1/B2")
        let sameLine = ["Control Number 20141234560001", "Visa Type/Class R H1B"] + foil
        #expect(try #require(VaultReading.finds(in: sameLine, from: "/visa.pdf").first).title == "US visa · H1B")
    }

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
}
