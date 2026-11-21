import Foundation
import Testing
@testable import Sync

/// Pages that must not give a number, or must not give the wrong one.
@Suite struct VaultMisreadingTests {
    @Test func aBankPagesNoticeWordsAreNoUSCISCue() {
        #expect(VaultFixtures.read(["Privacy notice", "Branch: LIN 4155551234"]).isEmpty)
        #expect(VaultFixtures.read(["In case of emergency", "MEI LIN 4155551234"]).isEmpty)
    }

    @Test func aLicenseFrontsNextFieldNumberDoesNotHideIt() {
        let page = ["California USA DRIVER LICENSE", "4d DL D1234567 4b EXP 08/31/2029"]
        #expect(VaultFixtures.read(page).map(\.value) == ["D1234567"])
    }

    @Test func anOlderPANCardWithoutItsLabelsIsStillACard() {
        let card = ["INCOME TAX DEPARTMENT", "GOVT. OF INDIA", "Permanent Account Number", "ABCPE1234F",
                    "ANNA ERIKSSON", "ERIK ERIKSSON", "12/08/1974"]
        let find = VaultFixtures.read(card).first
        #expect(find?.facts.primary?.rank == VaultReading.IDRank.card)
        #expect(find?.holder == "Anna Eriksson")
    }

    @Test func anotherScriptsDigitsNeitherCrashNorRead() {
        #expect(VaultFixtures.read(["Unique Identification Authority of India", "2345 ६७८९ ०१२३"]).isEmpty)
        #expect(!VaultReading.passesVerhoeff("2345६७८९०१२३"))
        let barcode = VaultIDReadingTests.barcode.map { $0 == "DBA05162030" ? "DBA０５１６２０３０" : $0 }
        #expect(VaultFixtures.read(barcode).first?.validUntil == nil)
    }

    @Test func theWordEpicIsNotAVoterIDPage() {
        #expect(VaultFixtures.read(["Thanks for your epic order!", "Invoice INV2024001"]).isEmpty)
        #expect(VaultFixtures.read(["EPIC No ABC1234567", "Name: Anna Eriksson"]).map(\.value) == ["ABC1234567"])
    }

    @Test func aSurnameAndAPhoneNumberAreNotAReceipt() {
        #expect(VaultFixtures.read(["Landlord: Wei Lin 4155551234"]).isEmpty)
        #expect(VaultFixtures.read(["Landlord: Wei LIN 4155551234"]).isEmpty)
        // Run together, or on a notice, it is one.
        #expect(VaultFixtures.read(["LIN2412345678"]).map(\.value) == ["LIN2412345678"])
        #expect(VaultFixtures.read(["Receipt Number", "LIN 24 123 45678"]).map(\.value) == ["LIN2412345678"])
    }

    @Test func aHospitalsAdmissionNumberIsNotAnI94() {
        #expect(VaultFixtures.read(["Patient Admission No: 24000123456"]).isEmpty)
        #expect(VaultFixtures.read(["Most Recent I-94", "Admission I-94 Record Number: 24000123456"]).map(\.value) == ["24000123456"])
    }

    @Test func aTaxNoticeIsNotAPANCardAndItsEmployerIsNotThePerson() {
        let notice = ["INCOME TAX DEPARTMENT", "Intimation under section 143(1)", "15/09/2024",
                      "Permanent Account Number ABCPE1234F", "TAN of employer AAACX1234X"]
        let finds = VaultFixtures.read(notice)
        #expect(finds.map(\.value) == ["ABCPE1234F"])
        #expect(finds.first?.facts.primary?.rank == VaultReading.IDRank.quoted)
        #expect(finds.first?.facts.born == nil)
    }

    @Test func aCertificateNamingAnEmployeesPANIsNotAnEPAN() throws {
        // "Employee PAN" runs together as "…epan" once a scan's spaces are dropped.
        let certificate = ["INCOME TAX DEPARTMENT", "Certificate of tax deducted at source on salary",
                           "PAN of the Deductor AAACX1234X", "Employee PAN ABCPE1234F"]
        let finds = VaultFixtures.read(certificate)
        #expect(finds.map(\.value) == ["ABCPE1234F"], "the deductor's is a company's, nobody's in the household")
        #expect(finds.first?.facts.primary?.rank == VaultReading.IDRank.quoted)
        #expect(VaultFixtures.read(["Schedule E PAN ABCPE1234F"]).isEmpty, "a lone letter before the word is no e-PAN")
        // An e-PAN, however it writes the word, is still the card.
        for word in ["e-PAN Card", "ePAN", "e - PAN"] {
            let card = try #require(VaultFixtures.read([word, "ABCPE1234F", "Name", "ANNA ERIKSSON"]).first, "\(word)")
            #expect(card.facts.primary?.rank == VaultReading.IDRank.card, "\(word)")
            #expect(card.holder == "Anna Eriksson")
        }
    }

    @Test func anOpenEnrollmentNoticeIsNotAnAadhaarLetter() throws {
        // A health plan's twelve-digit member ID, which passes Verhoeff one time in ten.
        let member = VaultIDReadingTests.spaced(VaultIDReadingTests.aadhaar("23456789012"))
        #expect(VaultFixtures.read(["Open Enrollment Notice", "Plan year 2026", "Member " + member]).isEmpty)
        #expect(VaultFixtures.read(["Enrollment No: 778812", "Member " + member]).isEmpty, "a plan's own enrollment number")
        // The letter's enrolment number, as UIDAI prints it, still says whose page it is.
        let letter = try #require(VaultFixtures.read(["Enrolment No.: 1234/12345/12345", "To", "Anna Eriksson", member]).first)
        #expect(letter.facts.primary?.rank == VaultReading.IDRank.card)
        #expect(letter.holder == "Anna Eriksson")
    }

    @Test func anAccountNumberUnderAnAadhaarLineIsNotAnAadhaar() {
        let account = VaultIDReadingTests.aadhaar("23456789012")
        #expect(VaultFixtures.read(["Aadhaar seeding: Linked", VaultIDReadingTests.spaced(account)]).isEmpty)
        #expect(VaultFixtures.read(["Aadhaar seeded A/c " + VaultIDReadingTests.spaced(account)]).isEmpty)
    }

    @Test func theSocialSecurityApplicationFormIsNotACard() {
        #expect(VaultFixtures.read(["Application for a Social Security Card", "Form SS-5", "123-45-6789"]).isEmpty)
        #expect(VaultFixtures.read(["Employment Eligibility Verification", "VALID FOR WORK ONLY WITH DHS AUTHORIZATION",
                           "123-45-6789"]).isEmpty)
    }

    @Test func aFormThatAsksAboutTheCardIsNotACard() {
        // Each prints "social security card" and the number alone on a line of its own.
        let w4 = ["Form W-4", "Employee\u{27}s Withholding Certificate", "(b) Social security number", "123-45-6789",
                  "Does your name match the name on your social security card? If not, contact SSA."]
        let i765 = ["Application For Employment Authorization", "USCIS Form I-765", "U.S. Social Security Number (SSN)",
                    "123-45-6789", "Do you want the SSA to issue you a Social Security card?"]
        let unnamed = ["Department of the Treasury", "OMB No. 1545-0074", "123-45-6789",
                       "the name shown on your social security card"]
        for form in [w4, i765, unnamed] {
            #expect(VaultFixtures.read(form).isEmpty, "\(form[0])")
            // Nor is it rendered again at 4000 pixels in the hope of a number.
            #expect(!VaultReading.wantsSharperRead(form.map { $0 == "123-45-6789" ? "1234-56-789" : $0 }), "\(form[0])")
        }
        // The stub's words alone, with nothing of the card's own print read, are still a card's,
        // and so is a card scanned with its back, which prints the card's own form number.
        let stub = ["Your Social Security Card", "ANNA MARIA ERIKSSON", "12 OAK STREET", "123-45-6789",
                    "ADULTS: Sign this card in ink immediately."]
        #expect(VaultFixtures.read(stub).map(\.value) == ["123456789"])
        #expect(VaultFixtures.read(stub + ["Form SSA-3000 (01-2011)"]).map(\.value) == ["123456789"])
    }

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
        let finds = VaultFixtures.read(page)
        #expect(finds.count == 2)
        #expect(finds.allSatisfy { $0.holder == nil })
    }

    @Test func aPassportThatRanOutLastCenturyIsNotGoodUntilThisOne() throws {
        let zone = VaultReadingTests.zone("P", number: "X1234567", born: "740812", expires: "990516")
        let find = try #require(VaultReading.read(pages: [zone], from: "/p.pdf").finds.first)
        #expect(find.validUntil == VaultFixtures.day(1999, 5, 16))
    }

    @Test func aLicensesStateComesFromItsHeaderNotItsAddress() {
        let page = ["Illinois DRIVER LICENSE", "DL D1234567", "123 MICHIGAN AVE", "CHICAGO IL 60601"]
        #expect(VaultFixtures.read(page).first?.title == "Driver’s license · IL")
        #expect(VaultReading.issuingState(["West Virginia DRIVER LICENSE"]) == "WV")
    }

    @Test func aPANCardsFatherIsNotItsHolder() {
        let card = ["INCOME TAX DEPARTMENT", "GOVT. OF INDIA", "Permanent Account Number Card", "ABCPD1234F",
                    "Father\u{27}s Name", "RAMESH DANI", "Date of Birth", "12/08/1974"]
        #expect(VaultFixtures.read(card).first?.holder == nil)
    }

    @Test func aVoterIDsHusbandIsNotItsHolder() {
        let page = ["ELECTION COMMISSION OF INDIA", "ABC1234567", "Husband\u{27}s Name : SURESH KUMAR"]
        #expect(VaultFixtures.read(page).first?.holder == nil)
    }

    @Test func aLicenseNamesStopAtTheNextLabel() {
        #expect(VaultReading.labelledName("Name : RAVI KUMAR Blood Group : O+") == "Ravi Kumar")
        #expect(VaultReading.labelledName("Name : Blood Group") == nil)
    }

    @Test func aStateIDCardAndAPayloadWithoutSeparatorsReadRightly() throws {
        let id = VaultIDReadingTests.barcode.map {
            $0.hasPrefix("ANSI") ? "ANSI 636014090002ID00410278ZC03190024IDDAQD1234567" : $0
        }
        let find = try #require(VaultFixtures.read(id).first)
        #expect(find.title == "State ID · CA")
        #expect(VaultReading.licenseNumber("D1234567DCSSMITHDACJOHNDBA08312030") == "D1234567")
    }

    @Test func aGroupedLicenseNumberIsNotReadCutShort() {
        #expect(VaultFixtures.read(["DRIVER LICENSE", "DL 12345 678"]).isEmpty)
    }
}
