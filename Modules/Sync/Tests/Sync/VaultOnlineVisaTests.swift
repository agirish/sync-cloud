import Foundation
import Testing
@testable import Sync

/// Visas granted online and the e-OCI (``VaultTravelReading.swift``).
@Suite struct VaultOnlineVisaTests {
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
        #expect(VaultFixtures.detail(find, "Issued") == .date(VaultFixtures.day(2023, 2, 14)))
        #expect(find.validUntil == VaultFixtures.day(2028, 2, 13))
    }

    @Test func aUSOnlineVisaReadsItsDatesMonthFirstAndItsStatusAsWords() throws {
        let page = ["U.S. Customs and Border Protection", "ESTA Application", "ESTA Application Number: U12345678ABC",
                    "Authorization Status: Authorization Approved", "Date of grant: 03/12/2025",
                    "Authorization Expires: Jun 12, 2027", "Passport Number: 123456789"]
        let find = try #require(VaultReading.finds(in: page, from: "/esta.pdf").first)
        #expect(find.title == "US e-Visa")
        #expect(VaultFixtures.detail(find, "Issued") == .date(VaultFixtures.day(2025, 3, 12)))
        #expect(find.validUntil == VaultFixtures.day(2027, 6, 12))
        let denied = page.map { $0.replacingOccurrences(of: "Authorization Approved", with: "Travel Not Authorized") }
        #expect(VaultReading.finds(in: denied, from: "/esta.pdf").isEmpty)
    }

    @Test func aReferenceNumberIsNeverTheNextColumnsLabel() throws {
        let page = ["Immigration, Refugees and Citizenship Canada", "Electronic Travel Authorization",
                    "Application number   Passport number", "V123456789   A12345678", "Expiry date: 2030-06-09"]
        #expect(try #require(VaultReading.finds(in: page, from: "/eta.pdf").first).value == "V123456789")
    }

    @Test func OCIInsideAnotherWordIsNotAnEOCI() {
        let page = ["Lifelong Members Association", "JOHN SMITH", "M1234567", "01/02/2020"]
        #expect(VaultReading.finds(in: page, from: "/club.pdf").isEmpty)
    }
}
