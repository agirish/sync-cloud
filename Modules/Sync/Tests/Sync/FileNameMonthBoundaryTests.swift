import Foundation
import Testing
@testable import Sync

/// When a run of letters ending in "mar" is March, and when it is a surname.
///
/// `FileNameDate.monthSuffix` reads a letter run that ends with a month name, to reach glued
/// provider names like `DetailedBillApr2025`. Ordinary words end that way too (`Kumar`, `Rajan`,
/// `codec`), and with a plausible year beside one (`Sanjay Kumar 2023.pdf`) the rename pass would
/// propose a date for a file that has none. The rule is a word boundary, which inside one letter
/// run only a change of case marks: a title-cased month carries its own (`HDFC|Apr`), an all-caps
/// month needs a lowercase character before it (`KU|MAR` has none).
///
/// The uppercase and acronym cases are what tell the candidate rules apart; the simple cases
/// alone pass under all of them.
@Suite struct FileNameMonthBoundaryTests {

    // MARK: What must still be read as a month

    @Test func aRunThatIsTheMonthIsStillTheMonth() {
        #expect(FileNameDate.monthSuffix("Mar") == 3)
        #expect(FileNameDate.monthSuffix("mar") == 3)
        #expect(FileNameDate.monthSuffix("MAR") == 3)
        #expect(FileNameDate.monthSuffix("March") == 3)
        #expect(FileNameDate.monthSuffix("september") == 9)
    }

    /// The case the suffix rule was written for: a provider's glued name, where the month begins
    /// at a capital.
    @Test func aGluedProviderNameStillEndsInItsMonth() {
        #expect(FileNameDate.monthSuffix("DetailedBillApr") == 4)
        #expect(FileNameDate.monthSuffix("StatementSep") == 9)
        #expect(FileNameDate.monthSuffix("BillSeptember") == 9)
    }

    // MARK: What must not be

    /// The upper-case half: inside an all-caps run every character is a capital, so a "starts with
    /// a capital" rule reads all of these as months. `NAPR` is a vendor-shaped token ending in
    /// `APR`.
    @Test func anAllCapsRunIsNotAMonthHoweverItEnds() {
        for run in ["KUMAR", "RAJAN", "CODEC", "NAPR", "NAPRDB", "BILLAPR", "BILLSEPTEMBER"] {
            #expect(FileNameDate.monthSuffix(run) == nil, "“\(run)” was read as a month")
        }
    }

    /// The acronym half: an acronym before a title-cased month is a boundary a reader sees, so a
    /// rule requiring a lowercase character there would drop real provider names.
    @Test func anAcronymBeforeATitleCasedMonthIsStillABoundary() {
        #expect(FileNameDate.monthSuffix("HDFCApr") == 4)
        #expect(FileNameDate.monthSuffix("AMEXApr") == 4)
        #expect(FileNameDate.monthSuffix("IRSMar") == 3)
        #expect(FileNameDate.monthSuffix("ATTApr") == 4)
    }

    /// And the end-to-end consequence of the upper-case half, at the level the user sees.
    @Test func anAllCapsNameAndAYearMineNoDate() {
        #expect(FileNameDate.spelledMonth(in: FileNameDate.tokenRuns("SANJAY KUMAR 2023")) == nil,
                "an all-caps surname and a year still mine a date out of nothing")
        #expect(FileNameDate.spelledMonth(in: FileNameDate.tokenRuns("ACME export 2024")) == nil,
                "a vendor token and a year still mine a date out of nothing")
    }

    @Test func aSurnameEndingInAMonthAbbreviationIsNotAMonth() {
        #expect(FileNameDate.monthSuffix("Kumar") == nil, "Kumar was read as March")
        #expect(FileNameDate.monthSuffix("kumar") == nil)
        #expect(FileNameDate.monthSuffix("Rajan") == nil, "Rajan was read as January")
        #expect(FileNameDate.monthSuffix("Arjan") == nil)
        #expect(FileNameDate.monthSuffix("codec") == nil, "codec was read as December")
        #expect(FileNameDate.monthSuffix("dismay") == nil, "dismay was read as May")
    }

    // MARK: And the consequence, at the level the user sees

    /// The whole point: no month, so no mined date, so no rename proposed for it.
    @Test func aNameAndAYearMineNoDate() {
        let runs = FileNameDate.tokenRuns("Sanjay Kumar 2023")
        #expect(FileNameDate.spelledMonth(in: runs) == nil,
                "a surname and a year still mine a date out of nothing")
    }

    /// The positive control: the same shape with a real month still mines, so the test above
    /// measures the boundary rule and not a mining path that stopped working.
    @Test func aRealMonthAndAYearStillMineTheDate() throws {
        let runs = FileNameDate.tokenRuns("Statement Mar 2023")
        let mined = try #require(FileNameDate.spelledMonth(in: runs),
                                 "a real spelled month stopped mining — the rule is too tight")
        #expect(mined.month == 3)
        #expect(mined.year == 2023)
    }
}
