import Foundation
import Testing
@testable import Sync

/// **When a run of letters ending in "mar" is March, and when it is a surname.**
///
/// `FileNameDate.monthSuffix` reads a letter run that *ends with* a month name, which exists to
/// reach glued provider names like `DetailedBillApr2025`. It read any such ending, and ordinary
/// words have them: `Kumar` ended in "mar", `Rajan` in "jan", `codec` in "dec".
///
/// That is not academic on this tree. `spelledMonth` needs one month and one plausible year, and
/// `Sanjay Kumar 2023.pdf` supplies both — so the rename pass proposed `03. Mar 2023.pdf` for a
/// document with no date in it at all, over the evidence line "“Kumar 2023” in the name", which
/// reads convincingly enough to accept. The check the old comment leaned on ("held in check by
/// requiring a plausible year") is precisely what a `<Name> <Year>.pdf` file satisfies.
///
/// The rule is a word boundary, and inside one letter run the only boundary available is a
/// capital.
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

    /// The positive control, so the test above is known to be measuring the boundary rule rather
    /// than a mining path that has stopped working: the same shape with a real month still mines.
    @Test func aRealMonthAndAYearStillMineTheDate() throws {
        let runs = FileNameDate.tokenRuns("Statement Mar 2023")
        let mined = try #require(FileNameDate.spelledMonth(in: runs),
                                 "a real spelled month stopped mining — the rule is too tight")
        #expect(mined.month == 3)
        #expect(mined.year == 2023)
    }
}
