import Foundation
import Testing
@testable import Sync

/// Labels, columns and dates on a printed page (``PrintedPage``), as every reader asks them.
@Suite struct VaultPrintedPageTests {
    @Test func aDottedLabelCountsAsAColumn() {
        let page = ["UNION OF INDIA DRIVING LICENSE", "License No. : KA05 20090001234", "Name : ANNA ERIKSSON",
                    "D.O.I.   Valid upto", "01-02-2010   31-01-2030"]
        #expect(VaultFixtures.read(page).first?.validUntil == VaultFixtures.day(2030, 1, 31))
    }

    @Test func datesInColumnsAreReadFromTheirOwnColumn() {
        let page = ["UNION OF INDIA DRIVING LICENSE", "License No. : KA05 20090001234", "Name : ANNA ERIKSSON",
                    "Date of Issue   Date of Expiry", "01-02-2010   31-01-2030"]
        let find = VaultFixtures.read(page).first
        #expect(find?.dated == VaultFixtures.day(2010, 2, 1))
        #expect(find?.validUntil == VaultFixtures.day(2030, 1, 31))
    }

    @Test func aRowOfLabelsWithFewerDatesUnderItGivesNone() {
        let page = PrintedPage(["Date of Issue   Date of Expiry", "31-01-2030"])
        #expect(page.date(["date of issue"], order: .dayFirst) == nil)
        #expect(page.date(["date of expiry"], order: .dayFirst) == nil)
    }

    @Test func abbreviationsWithOrWithoutTheirLastDotAndBilingualMonths() {
        #expect(PrintedPage(["D.O.B 01-02-1990"]).date(["DOB", "D.O.B.", "D.O.B"], order: .dayFirst) == VaultFixtures.day(1990, 2, 1))
        #expect(PrintedPage.dates(in: "14 FEB /FÉV 2023", order: nil).map(\.date) == [VaultFixtures.day(2023, 2, 14)])
        #expect(PrintedPage.dates(in: "June 12 2026", order: nil).map(\.date) == [VaultFixtures.day(2026, 6, 12)])
    }

    @Test func anotherFieldsWordCountsOnlyRightBeforeTheLabel() {
        let page = PrintedPage(["Passport No: A12345678  Date of Issue: 14/02/2023", "Passport Date of Issue: 01/02/2020"])
        #expect(page.date(["date of issue"], order: .dayFirst, unless: ["passport"]) == VaultFixtures.day(2023, 2, 14))
        let only = PrintedPage(["Passport Date of Issue: 01/02/2020"])
        #expect(only.date(["date of issue"], order: .dayFirst, unless: ["passport"]) == nil)
    }

    @Test func aPlaceBesideADateIsNotADateColumn() {
        let page = PrintedPage(["Date of Issue    Issued By", "12/03/2020   RTO MUMBAI"])
        #expect(page.date(["date of issue"], order: .dayFirst) == VaultFixtures.day(2020, 3, 12))
    }
}
