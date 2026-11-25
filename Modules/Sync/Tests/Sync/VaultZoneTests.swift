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

    // MARK: How a zone was recovered (VT51)

    /// The same characters with some replaced: `at` maps an index of `line` to what is read there.
    static func misread(_ line: String, _ at: [Int: Character]) -> String {
        String(line.enumerated().map { at[$0.offset] ?? $0.element })
    }

    @Test func eachZoneSaysHowItsNumberLineWasRead() throws {
        let specimen = try #require(MachineZone.read([VaultReadingTests.nameLine, VaultReadingTests.numberLine]))
        #expect(specimen.recovery == .asRead)
        // A look-alike letter in a date is put back as read, not recovered.
        let lines = VaultReadingTests.zone("P", number: "U5054030", born: "850514", expires: "330601")
        #expect(MachineZone.read([lines[0], Self.misread(lines[1], [23: "O"])])?.recovery == .asRead)
        // A character Vision could not read, filled.
        let filled = try #require(MachineZone.read([lines[0], Self.misread(lines[1], [24: "~"])]))
        #expect(filled.number == "U5054030" && filled.recovery == .fill)
        // An Indian passport's leading Z read as a 2, swapped back.
        let india = VaultReadingTests.zone("P", number: "Z1234567", born: "550312", expires: "310704", country: "IND")
        let swapped = try #require(MachineZone.read([india[0], Self.misread(india[1], [0: "2"])]))
        #expect(swapped.number == "Z1234567" && swapped.recovery == .swap)
        // A visa's passport number that failed its check, read with the one the foil prints.
        let foil = VaultReadingTests.zone("V", number: "J1234567", born: "880304", expires: "190825", country: "USA")
        let page = ["Passport Number", "J1234567", foil[0], Self.misread(foil[1], [5: "6"])]
        let printed = try #require(MachineZone.zones(in: page).first)
        #expect(printed.number == "J1234567" && printed.recovery == .printedNumber)
    }

    /// `readWithSwaps` tries two swaps only when no single one reads, and keeps a pair only when it
    /// is the only one that does.
    @Test func twoSwapsReadOnlyWhenNoOneDoesAndOnlyOnePairPasses() throws {
        // An Indian passport's leading Z read as a 2, and its birth year 85 read as "BB": the
        // look-alike table makes that 88, which fails. No single swap passes: the number's and the
        // birth date's checks each need their own.
        let passport = VaultReadingTests.zone("P", number: "Z1234567", born: "850514", expires: "310704", country: "IND")
        let misread = Self.misread(passport[1], [0: "2", 13: "B", 14: "B"])
        let zone = try #require(MachineZone.read([passport[0], misread]))
        #expect(zone.number == "Z1234567")
        #expect(zone.born == VaultReadingTests.day(1985, 5, 14))
        #expect(zone.recovery == .swap)
        // Two pairs pass the birth date's check: Z with 85 (the truth) and Z with 18 (the second B
        // left as an 8). The passport's overall check refuses the second; a visa has none, so its
        // two readings tie and nothing is read. With one B, a visa reads through its one pair.
        // A US visa, which carries the Indian holder's passport number (VT46 holds the swap to it).
        var visa = VaultReadingTests.zone("V", number: "Z1234567", born: "850514", expires: "310704", country: "IND")
        visa[0] = "V<USA" + visa[0].dropFirst(5)
        let onePair = try #require(MachineZone.read([visa[0], Self.misread(visa[1], [0: "2", 14: "B"])]))
        #expect(onePair.number == "Z1234567" && onePair.born == VaultReadingTests.day(1985, 5, 14))
        #expect(onePair.recovery == .swap)
        #expect(MachineZone.read([visa[0], Self.misread(visa[1], [0: "2", 13: "B", 14: "B"])]) == nil)
    }

    /// G and 6 are worth the same to a 7-3-1 check (16 and 6), so a G-series Indian passport with
    /// its G read as a 6 passes every check. Pinned as 6… until VT46: an Indian passport's number
    /// is a letter and seven digits, so it now reads as G (the owner's call, 2026-11-25).
    @Test func aGSeriesIndianPassportWithItsGReadAsA6ReadsAsG() throws {
        let lines = VaultReadingTests.zone("P", number: "G1234567", born: "850514", expires: "360704", country: "IND")
        let read = try #require(MachineZone.read(lines))
        #expect(read.number == "G1234567" && read.recovery == .asRead)
        let six = try #require(MachineZone.read([lines[0], Self.misread(lines[1], [0: "6"])]))
        #expect(six.number == "G1234567" && six.recovery == .swap)
        // And with a date's 6 read as a B too: both are put back.
        let both = try #require(MachineZone.read([lines[0], Self.misread(lines[1], [0: "6", 22: "B"])]))
        #expect(both.number == "G1234567" && both.expires == VaultReadingTests.day(2036, 7, 4))
        #expect(both.recovery == .swap)
    }

    @Test func theRecoveryLogLineCountsEachKindAndNeverANumber() throws {
        #expect(MachineZone.recoveryLine([]) == nil)
        let specimen = try #require(MachineZone.read([VaultReadingTests.nameLine, VaultReadingTests.numberLine]))
        var filled = specimen
        filled.recovery = .fill
        let line = try #require(MachineZone.recoveryLine([specimen, filled, specimen]))
        #expect(line == "Vault: 3 machine-readable zone(s) read: asRead 2, fill 1, swap 0, printedNumber 0")
        #expect(!line.contains(specimen.number))
    }
}
