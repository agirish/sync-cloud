import Foundation
import Testing
@testable import Sync

/// A scan on colored security paper, read once more in its ink alone (``VaultPageSource``):
/// that reading is taken only when it keeps all the first one knew. Every number is made up;
/// the passport lines are ICAO Doc 9303's own example.
@Suite struct VaultInkOnlyTests {
    static let path = "/docs/Immigration/Passport/Anna/scan.pdf"
    static let passport = ["PASSPORT", "UTOPIA", VaultReadingTests.nameLine, VaultReadingTests.numberLine]
    /// The same page as the pattern behind its name line reads: a letter of the name taken for
    /// another. The zone's check digits cover the number and dates, never the name.
    static let patterned = ["PASSPORT", "UTOPIA", "P<UTOERIKSSOT<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<", VaultReadingTests.numberLine]

    static func picture(reads: [String]?, inkOnly: [String]?) -> VaultPageSource.Picture {
        VaultPageSource.Picture(isScan: { true }, read: { sharper in sharper ? nil : reads }, barcodes: { [] },
                                inkOnly: { inkOnly })
    }

    @Test func theInkAloneIsTakenWhenItKeepsTheNumberAndReadsTheNameTrue() throws {
        let lines = try #require(VaultPageSource.seen(Self.picture(reads: Self.patterned, inkOnly: Self.passport), from: Self.path))
        #expect(lines == Self.passport)
        #expect(VaultReading.finds(in: lines, from: Self.path).first?.holder?.contains("Eriksson") == true)
    }

    @Test func theFirstReadingStandsWhenTheInkAloneLosesTheNumber() throws {
        let lost = ["PASSPORT", "UTOPIA", VaultReadingTests.nameLine]
        let lines = try #require(VaultPageSource.seen(Self.picture(reads: Self.patterned, inkOnly: lost), from: Self.path))
        #expect(lines == Self.patterned)
    }

    @Test func aPageNotOnColoredPaperIsReadOnce() throws {
        var inkAsked = false
        let picture = VaultPageSource.Picture(isScan: { true }, read: { _ in Self.patterned }, barcodes: { [] },
                                              inkOnly: { inkAsked = true; return nil })
        #expect(VaultPageSource.seen(picture, from: Self.path) == Self.patterned)
        #expect(inkAsked, "asked, and the app answers nil for a page that is not colored")
    }

    /// The ink alone keeps the card's background small print too, which a scan misreads: that
    /// line ends the name as the signature does, rather than joining it.
    @Test func aCardsSmallPrintMisreadEndsTheName() {
        let card = ["THIS NUMBER HAS BEEN ESTABLISHED FOR", "DIVIT", "ABHISHEK", "ICA SDCIAL SEGURITY", "SIGNATURE"]
        #expect(VaultReading.cardName(card) == "Divit Abhishek")
        #expect(VaultReading.cardName(["THIS NUMBER HAS BEEN ESTABLISHED FOR", "SHWETA RAVINDRA", "DANI", "SIGNATURE"])
                == "Shweta Ravindra Dani")
        #expect(VaultReading.holdsMisreadCardWord("UNITED STATEE") && !VaultReading.holdsMisreadCardWord("SHWETA RAVINDRA"))
    }

    @Test func theInkAloneMayNotKnowLess() {
        func find(_ value: String, holder: String? = "Anna", validUntil: Date? = VaultReadingTests.day(2030, 1, 1),
                  details: [VaultDetail] = []) -> VaultFind {
            VaultFind(title: "Passport", value: value,
                      facts: VaultReadFacts(category: .passport, holder: holder, validUntil: validUntil, details: details,
                                            sources: [VaultSource(path: Self.path, role: "Passport", rank: 1)]))
        }
        let first = [find("L898902C3", details: [VaultDetail("Issued", .text("01 Jan 2020"))])]
        #expect(VaultPageSource.inkKeepsEverything(first, [find("L898902C3", holder: "Anne",
                                                                details: [VaultDetail("Issued", .text("01 Jan 2020"))])]),
                "a name read differently is what the ink alone is for")
        #expect(!VaultPageSource.inkKeepsEverything(first, [find("L898902C3")]), "a detail printed in color, lost")
        #expect(!VaultPageSource.inkKeepsEverything(first, [find("L898902C3", validUntil: nil,
                                                                 details: [VaultDetail("Issued", .text("01 Jan 2020"))])]))
        #expect(!VaultPageSource.inkKeepsEverything(first, []))
        #expect(VaultPageSource.inkKeepsEverything([], [find("L898902C3")]), "a number the first reading missed")
    }
}
