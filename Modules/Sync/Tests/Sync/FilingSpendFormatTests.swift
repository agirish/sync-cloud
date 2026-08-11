import Testing
@testable import Sync

/// The spend rows' number formatting. `files(_:)` exists because both spend rows hard-coded
/// "\(n) files" and printed "1 files" — the count and its noun now agree in one place.
@Suite struct FilingSpendFormatTests {

    @Test func oneFileIsSingular() {
        #expect(FilingSpendFormat.files(1) == "1 file")
    }

    @Test func otherCountsArePlural() {
        #expect(FilingSpendFormat.files(0) == "0 files")
        #expect(FilingSpendFormat.files(3) == "3 files")
    }
}
