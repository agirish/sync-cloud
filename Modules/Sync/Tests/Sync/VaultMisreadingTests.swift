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
        // Nor is a capital E that ends another word, or a schedule's letter.
        for line in ["Schedule E PAN ABCPE1234F", "PART E-PAN DETAILS ABCPE1234F", "Employee-PAN ABCPE1234F"] {
            let named = VaultFixtures.read(["INCOME TAX DEPARTMENT", line])
            #expect(named.first?.facts.primary?.rank == VaultReading.IDRank.quoted, "\(line.prefix(12))")
        }
    }

    @Test func anEPANIsACardHoweverAScanSpacesTheWord() throws {
        // The hyphen read as a gap, the words run together, a letter set apart, the word split
        // over two lines: each was a card before the word had to stand alone, and still is.
        let spellings = [["e-PAN Card"], ["e - PAN"], ["ePAN"], ["e PAN Card"], ["e-PANCard"], ["Instant e-PAN"],
                         ["e-P AN"], ["e -  PAN"], ["e-", "PAN Card"], ["E-PAN CARD"]]
        for spelling in spellings {
            let page = ["INCOME TAX DEPARTMENT"] + spelling + ["ABCPE1234F", "Name", "ANNA ERIKSSON"]
            let card = try #require(VaultFixtures.read(page).first, "\(spelling)")
            #expect(card.facts.primary?.rank == VaultReading.IDRank.card, "\(spelling)")
            #expect(card.holder == "Anna Eriksson", "\(spelling)")
        }
    }

    @Test func anOpenEnrollmentNoticeIsNotAnAadhaarLetter() throws {
        // A health plan's twelve-digit member ID, which passes Verhoeff one time in ten.
        let member = VaultIDReadingTests.spaced(VaultIDReadingTests.aadhaar("23456789012"))
        #expect(VaultFixtures.read(["Open Enrollment Notice", "Plan year 2026", "Member " + member]).isEmpty)
        #expect(VaultFixtures.read(["Enrollment No: 778812", "Member " + member]).isEmpty, "a plan's own enrollment number")
        // A school's, printed as a year and a serial, is not UIDAI's three groups.
        #expect(VaultFixtures.read(["Enrollment Number: 2024/00123", "Roll " + member]).isEmpty)
        #expect(VaultFixtures.read(["Enrollment Number", "2024/00123 Session 2024-25", "Roll " + member]).isEmpty)
        // "uidai" is also the middle of other words.
        #expect(VaultFixtures.read(["Liquid Aid dish soap", "Order " + member]).isEmpty)
    }

    @Test func anAadhaarLettersEnrolmentNumberSaysWhosePageItIs() throws {
        // With the authority's name cropped off, the enrolment number alone marks the letter,
        // however a scan reads its slashes, breaks its label or sets Hindi between the two.
        let member = VaultIDReadingTests.spaced(VaultIDReadingTests.aadhaar("23456789012"))
        let labels = ["Enrolment No.: 1234/12345/12345", "Enrollment Number: 1234/12345/12345",
                      "Enrolment No.: 1234112345112345", "Enrolment No.: 1234I12345I12345", "Enrolment No.: 1234|12345|12345",
                      "Enrolment No.; 12 34/1 2345/12345", "Enrolm ent No.: 1234/12345/12345",
                      "Enrolment No / नामांकन क्रम : 1234/12345/12345"]
        for label in labels {
            let letter = try #require(VaultFixtures.read([label, "To", "Anna Eriksson", member]).first, "\(label.count)")
            #expect(letter.facts.primary?.rank == VaultReading.IDRank.card, "\(label.count)")
            #expect(letter.holder == "Anna Eriksson")
        }
        #expect(VaultFixtures.read(["help@uidai.gov.in", member]).first?.facts.primary?.rank == VaultReading.IDRank.card)
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
        let pages = [
            ["Form W-4", "Employee\u{27}s Withholding Certificate", "(b) Social security number", "123-45-6789",
             "Does your name match the name on your social security card? If not, contact SSA."],
            ["Application For Employment Authorization", "USCIS Form I-765", "U.S. Social Security Number (SSN)",
             "123-45-6789", "Do you want the SSA to issue you a Social Security card?"],
            ["Department of the Treasury", "OMB No. 1545-0074", "123-45-6789", "the name shown on your social security card"],
            // Forms no list of form numbers will ever be complete for.
            ["Form N-400 Edition 04/01/24 Page 2 of 14", "Do you want the SSA to issue you a Social Security card?", "123-45-6789"],
            ["Form Approved OMB # 1845-0001", "exactly as it appears on your Social Security card", "123-45-6789"],
            ["Form W\u{2013}4", "the name on your social security card", "123-45-6789"],
            ["New hire checklist", "Bring your Social Security card on your first day", "123-45-6789"],
            // A sentence that wraps so its last words stand alone.
            ["Do you want the SSA to issue you a", "Social Security card?", "123-45-6789"],
        ]
        for page in pages {
            #expect(VaultFixtures.read(page).isEmpty, "\(page[0])")
            // Nor is it rendered again at 4000 pixels in the hope of a number.
            #expect(!VaultReading.wantsSharperRead(page.map { $0 == "123-45-6789" ? "1234-56-789" : $0 }), "\(page[0])")
        }
    }

    @Test func theSheetACardIsMailedOnIsStillACard() {
        // With nothing of the card's own print read: the sheet's heading, or what it tells the
        // holder to do with the card.
        let heading = ["Your Social Security Card", "ANNA MARIA ERIKSSON", "12 OAK STREET", "123-45-6789"]
        let care = ["SOCIAL SECURITY ADMINISTRATION", "123-45-6789", "ADULTS: Sign this card in ink immediately.",
                    "Keep your Social Security card in a safe place."]
        let back = ["123-45-6789", "This card belongs to the Social Security Administration and you must return it",
                    "Do not laminate. Contact us about your Social Security card."]
        for page in [heading, care, back] {
            #expect(VaultFixtures.read(page).map(\.value) == ["123456789"], "\(page[0].prefix(12))")
        }
        // Scanned with its back, which prints the card's own form number; or with a stray "Form"
        // on the line above the number.
        #expect(VaultFixtures.read(heading + ["Form SSA-3000 (01-2011)"]).map(\.value) == ["123456789"])
        #expect(VaultFixtures.read(["Your Social Security Card", "Form", "123-45-6789"]).map(\.value) == ["123456789"])
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
