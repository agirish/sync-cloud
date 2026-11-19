import Foundation
import Testing
@testable import Sync

/// What the review of the whole Vault on 2026-11-19 found in the readers, each pinned down: a
/// page that crashed the read, words that made a number of something else, and details taken
/// from the wrong line. Every number here is made up.
@Suite struct VaultReviewReaderTests {
    static func read(_ lines: [String]) -> [VaultFind] { VaultIDReadingTests.read(lines) }
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultIDReadingTests.day(y, m, d) }

    // MARK: Pages that crashed the read

    @Test func anotherScriptsDigitsNeitherCrashNorRead() {
        #expect(Self.read(["Unique Identification Authority of India", "2345 ६७८९ ०१२३"]).isEmpty)
        #expect(!VaultReading.passesVerhoeff("2345६७८९०१२३"))
        let barcode = VaultIDReadingTests.barcode.map { $0 == "DBA05162030" ? "DBA０５１６２０３０" : $0 }
        #expect(Self.read(barcode).first?.validUntil == nil)
    }

    // MARK: Words that made a number of something else

    @Test func theWordEpicIsNotAVoterIDPage() {
        #expect(Self.read(["Thanks for your epic order!", "Invoice INV2024001"]).isEmpty)
        #expect(Self.read(["EPIC No ABC1234567", "Name: Anna Eriksson"]).map(\.value) == ["ABC1234567"])
    }

    @Test func aSurnameAndAPhoneNumberAreNotAReceipt() {
        #expect(Self.read(["Landlord: Wei Lin 4155551234"]).isEmpty)
        #expect(Self.read(["Landlord: Wei LIN 4155551234"]).isEmpty)
        // Run together, or on a notice, it is one.
        #expect(Self.read(["LIN2412345678"]).map(\.value) == ["LIN2412345678"])
        #expect(Self.read(["Receipt Number", "LIN 24 123 45678"]).map(\.value) == ["LIN2412345678"])
    }

    @Test func aHospitalsAdmissionNumberIsNotAnI94() {
        #expect(Self.read(["Patient Admission No: 24000123456"]).isEmpty)
        #expect(Self.read(["Most Recent I-94", "Admission I-94 Record Number: 24000123456"]).map(\.value) == ["24000123456"])
    }

    @Test func aTaxNoticeIsNotAPANCardAndItsEmployerIsNotThePerson() {
        let notice = ["INCOME TAX DEPARTMENT", "Intimation under section 143(1)", "15/09/2024",
                      "Permanent Account Number ABCPE1234F", "TAN of employer AAACX1234X"]
        let finds = Self.read(notice)
        #expect(finds.map(\.value) == ["ABCPE1234F"])
        #expect(finds.first?.facts.primary?.rank == VaultReading.IDRank.quoted)
        #expect(finds.first?.facts.born == nil)
    }

    @Test func anAccountNumberUnderAnAadhaarLineIsNotAnAadhaar() {
        let account = VaultIDReadingTests.aadhaar("23456789012")
        #expect(Self.read(["Aadhaar seeding: Linked", VaultIDReadingTests.spaced(account)]).isEmpty)
        #expect(Self.read(["Aadhaar seeded A/c " + VaultIDReadingTests.spaced(account)]).isEmpty)
    }

    @Test func theSocialSecurityApplicationFormIsNotACard() {
        #expect(Self.read(["Application for a Social Security Card", "Form SS-5", "123-45-6789"]).isEmpty)
        #expect(Self.read(["Employment Eligibility Verification", "VALID FOR WORK ONLY WITH DHS AUTHORIZATION",
                           "123-45-6789"]).isEmpty)
    }

    // MARK: Details from the wrong line

    @Test func aVisaControlNumberHasNoLetterForADigit() throws {
        let zone = VaultReadingTests.zone("V", number: "X1234567", born: "740812", expires: "300516")
        let find = try #require(VaultReading.read(pages: [["Control Number 2O24123456789O"] + zone], from: "/v.pdf").finds
            .first { $0.category == .usVisa })
        #expect(find.value == "20241234567890")
    }

    @Test func twoNoticesInOneFileKeepTheirOwnPeople() {
        let first = ["I-797A Approval Notice", "Receipt Number WAC2412345678", "Beneficiary ERIKSSON, ANNA",
                     "Form I-129", "Valid from 10/01/2024 to 09/30/2027"]
        let second = ["I-797C Receipt Notice", "Receipt Number WAC2412349999", "Applicant ERIKSSON, BJORN", "Form I-539"]
        let finds = VaultReading.read(pages: [first, second], from: "/n.pdf").finds
        let bjorn = finds.first { $0.value == "WAC2412349999" }
        #expect(bjorn?.holder == "Bjorn Eriksson")
        #expect(bjorn?.facts.form == "I-539")
        #expect(bjorn?.validUntil == nil)
    }

    @Test func twoSocialSecurityCardsOnOnePageGiveNeitherAName() {
        let page = ["THIS NUMBER HAS BEEN ESTABLISHED FOR", "123-45-6789", "ANNA ERIKSSON", "SIGNATURE",
                    "THIS NUMBER HAS BEEN ESTABLISHED FOR", "234-56-7890", "LUKAS ERIKSSON", "SIGNATURE"]
        let finds = Self.read(page)
        #expect(finds.count == 2)
        #expect(finds.allSatisfy { $0.holder == nil })
    }

    @Test func datesInColumnsAreReadFromTheirOwnColumn() {
        let page = ["UNION OF INDIA DRIVING LICENSE", "License No. : KA05 20090001234", "Name : ANNA ERIKSSON",
                    "Date of Issue   Date of Expiry", "01-02-2010   31-01-2030"]
        let find = Self.read(page).first
        #expect(find?.dated == Self.day(2010, 2, 1))
        #expect(find?.validUntil == Self.day(2030, 1, 31))
    }

    @Test func aPassportThatRanOutLastCenturyIsNotGoodUntilThisOne() throws {
        let zone = VaultReadingTests.zone("P", number: "X1234567", born: "740812", expires: "990516")
        let find = try #require(VaultReading.read(pages: [zone], from: "/p.pdf").finds.first)
        #expect(find.validUntil == Self.day(1999, 5, 16))
    }

    @Test func aLicensesStateComesFromItsHeaderNotItsAddress() {
        let page = ["Illinois DRIVER LICENSE", "DL D1234567", "123 MICHIGAN AVE", "CHICAGO IL 60601"]
        #expect(Self.read(page).first?.title == "Driver’s license · IL")
        #expect(VaultReading.issuingState(["West Virginia DRIVER LICENSE"]) == "WV")
    }

    @Test func aPANCardsFatherIsNotItsHolder() {
        let card = ["INCOME TAX DEPARTMENT", "GOVT. OF INDIA", "Permanent Account Number Card", "ABCPD1234F",
                    "Father\u{27}s Name", "RAMESH DANI", "Date of Birth", "12/08/1974"]
        #expect(Self.read(card).first?.holder == nil)
    }

    @Test func aVoterIDsHusbandIsNotItsHolder() {
        let page = ["ELECTION COMMISSION OF INDIA", "ABC1234567", "Husband\u{27}s Name : SURESH KUMAR"]
        #expect(Self.read(page).first?.holder == nil)
    }

    @Test func aLicenseNamesStopAtTheNextLabel() {
        #expect(VaultReading.labelledName("Name : RAVI KUMAR Blood Group : O+") == "Ravi Kumar")
        #expect(VaultReading.labelledName("Name : Blood Group") == nil)
    }

    @Test func aStateIDCardAndAPayloadWithoutSeparatorsReadRightly() throws {
        let id = VaultIDReadingTests.barcode.map {
            $0.hasPrefix("ANSI") ? "ANSI 636014090002ID00410278ZC03190024IDDAQD1234567" : $0
        }
        let find = try #require(Self.read(id).first)
        #expect(find.title == "State ID · CA")
        #expect(VaultReading.licenseNumber("D1234567DCSSMITHDACJOHNDBA08312030") == "D1234567")
    }

    @Test func aGroupedLicenseNumberIsNotReadCutShort() {
        #expect(Self.read(["DRIVER LICENSE", "DL 12345 678"]).isEmpty)
    }
}
