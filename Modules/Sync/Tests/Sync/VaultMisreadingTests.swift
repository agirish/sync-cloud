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
        // Nor a lettered item of a list, a word that only starts the same way, or the end of "i.e".
        let pages = [["TDS certificate", "E - PAN of the deductor", "AAACX1234X", "F - PAN of the employee", "ABCPE1234F"],
                     ["TDS certificate", "E-PAN DETAILS", "ABCPE1234F"],
                     ["Gram e-Panchayat property tax receipt", "Payer PAN ABCPE1234F"],
                     ["e-panel hearing notice", "PAN ABCPE1234F"],
                     ["Quote the PAN (i.e - PAN of the deductor)", "ABCPE1234F"],
                     ["Quote the PAN (i.e-PAN of the deductor)", "ABCPE1234F"],
                     ["e", "- PAN of the Deductor", "ABCPE1234F"]]
        for page in pages {
            let read = VaultFixtures.read(["INCOME TAX DEPARTMENT"] + page)
            #expect(!read.contains { $0.facts.primary?.rank == VaultReading.IDRank.card }, "\(page[0].prefix(14))")
        }
    }

    @Test func anEPANIsACardHoweverAScanSpacesTheWord() throws {
        // The hyphen read as a gap, the words run together, a letter set apart, the word split
        // over two lines: each was a card before the word had to stand alone, and still is.
        let spellings = [["e-PAN Card"], ["e - PAN"], ["ePAN"], ["e PAN Card"], ["e-PANCard"], ["Instant e-PAN"],
                         ["e-P AN"], ["e -  PAN"], ["e-", "PAN Card"], ["E-PAN CARD"],
                         // Capitals, a gap for the hyphen, another dash, mid-sentence.
                         ["e PAN CARD"], ["E PAN CARD"], ["e PAN"], ["Your E-PAN Card is attached"], ["INSTANT E-PAN"],
                         ["e\u{2013}PAN Card"], ["e\u{2011}PAN Card"], ["ePANcard"]]
        for spelling in spellings {
            let page = ["INCOME TAX DEPARTMENT"] + spelling + ["ABCPE1234F", "Name", "ANNA ERIKSSON"]
            let card = try #require(VaultFixtures.read(page).first, "\(spelling)")
            #expect(card.facts.primary?.rank == VaultReading.IDRank.card, "\(spelling)")
            #expect(card.holder == "Anna Eriksson", "\(spelling)")
        }
    }

    @Test func aFormAskingForAnEPANIsNotTheCard() throws {
        // A form that only names the e-PAN as a paper to attach quotes the number, as any form does:
        // it never says whose it is, nor ties the card.
        let forms = [["KYC Application Form", "Name of applicant: ANNA ERIKSSON", "PAN ABCPE1234F",
                      "Please attach a copy of PAN card / e-PAN"],
                     ["INCOME TAX DEPARTMENT", "Form 49A", "PAN ABCPE1234F", "Upload your e-PAN"],
                     ["Account opening checklist", "ePAN or PAN card copy", "PAN: ABCPE1234F", "Date of birth: 12/08/1974"]]
        for form in forms {
            let find = try #require(VaultFixtures.read(form).first, "\(form[0])")
            #expect(find.value == "ABCPE1234F", "\(form[0])")
            #expect(find.facts.primary?.rank == VaultReading.IDRank.quoted, "\(form[0])")
            #expect(find.holder == nil, "\(form[0])")
            #expect(find.facts.born == nil, "\(form[0])")
        }
        // The e-PAN itself prints its own heading (here the only cue: the name shares its label's
        // line), or the holder's block under bilingual labels.
        let ePANs = [["e - Permanent Account Number (e-PAN) Card", "ABCPE1234F", "Name ANNA ERIKSSON"],
                     ["INCOME TAX DEPARTMENT", "e-PAN", "ABCPE1234F", "नाम / Name", "ANNA ERIKSSON",
                      "पिता का नाम / Father\u{2019}s Name", "ERIK ERIKSSON", "जन्म की तारीख / Date of Birth", "12/08/1974"]]
        for page in ePANs {
            let card = try #require(VaultFixtures.read(page).first, "\(page[1])")
            #expect(card.facts.primary?.rank == VaultReading.IDRank.card, "\(page[1])")
            #expect(card.holder == "Anna Eriksson", "\(page[1])")
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
        // Nor with whatever digits the page prints next: a helpline, a postcode, a second number.
        for after in [["1800 123 4567 Helpline"], ["110011 New Delhi"], []] {
            let school = ["Enrollment Number: 2024/00123" + (after.isEmpty ? " 1234567" : "")] + after + ["Roll " + member]
            #expect(VaultFixtures.read(school).isEmpty, "\(after)")
        }
        #expect(VaultFixtures.read(["Enrolment No: 2024/00123", "110011 New Delhi", "Roll " + member]).isEmpty)
        // A plan's sixteen digits in one run are not three groups with 1 for a slash.
        #expect(VaultFixtures.read(["Enrollment Number: 1234112345112345", "Member " + member]).isEmpty)
        // "uidai" is also the middle of other words, set apart or run together.
        #expect(VaultFixtures.read(["Liquid Aid dish soap", "Order " + member]).isEmpty)
        #expect(VaultFixtures.read(["LiquidAid dish soap", "Order " + member]).isEmpty)
    }

    @Test func anAadhaarLettersEnrolmentNumberSaysWhosePageItIs() throws {
        // With the authority's name cropped off, the enrolment number alone marks the letter,
        // however a scan reads its slashes, breaks its label or sets Hindi between the two.
        let member = VaultIDReadingTests.spaced(VaultIDReadingTests.aadhaar("23456789012"))
        let labels = ["Enrolment No.: 1234/12345/12345", "Enrollment Number: 1234/12345/12345",
                      "Enrolment No.: 1234112345112345", "Enrolment No.: 1234I12345I12345", "Enrolment No.: 1234|12345|12345",
                      "Enrolment No.; 12 34/1 2345/12345", "Enrolm ent No.: 1234/12345/12345",
                      "Enrolment No / नामांकन क्रम : 1234/12345/12345",
                      // The slashes read as gaps, dashes or a digit; the number on the line below.
                      "Enrolment No.: 1234 12345 12345", "Enrolment No.: 1234-12345-12345",
                      "Enrolment No.: 1234712345712345", "Enrolment No.\n1234/12345/12345",
                      // A zero read as the letter, a slash as a small L.
                      "Enrolment No.: 1234/1O345/12345", "Enrolment No.: 1234l12345l12345"]
        for label in labels {
            let letter = try #require(VaultFixtures.read(label.components(separatedBy: "\n") + ["To", "Anna Eriksson", member]).first,
                                      "\(label.count)")
            #expect(letter.facts.primary?.rank == VaultReading.IDRank.card, "\(label.count)")
            #expect(letter.holder == "Anna Eriksson")
        }
        // The authority's own name, however a scan runs it into its address or spaces it out.
        for name in ["help@uidai.gov.in", "www.uidaigov.in", "U I D A I"] {
            #expect(VaultFixtures.read([name, member]).first?.facts.primary?.rank == VaultReading.IDRank.card, "\(name.count)")
        }
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

    /// The card's words, a number alone on a line, and nothing that only the card or its sheet
    /// prints: each of these was a card.
    @Test func aPageThatOnlyTalksAboutTheCardIsNotACard() {
        let pages = [
            // What a sheet tells the holder, in words every benefits page uses.
            ["Flexible Spending Account summary", "Unused funds do not carry over to the next plan year.", "Employee SSN",
             "123-45-6789", "Bring your Social Security card to HR if your name has changed."],
            ["Identity theft tips", "Do not carry your Social Security card in your wallet.", "Your SSN on file", "123-45-6789"],
            ["Benefits enrollment", "Keep your card with you at all times.", "Dependent SSN", "123-45-6789",
             "Name must match the Social Security card."],
            // One thing a sheet says, in words other cards' papers use too.
            ["Medicare and You", "Keep your card in a safe place.", "Your name as shown on your Social Security card", "123-45-6789"],
            ["Onboarding", "Do not laminate your badge.", "Copy of Social Security card attached", "123-45-6789"],
            ["Employee handbook", "Do not carry cash on site.", "Bring your Social Security card on your first day", "123-45-6789"],
            // "Established for" is said of accounts too.
            ["Trust account established for ANNA ERIKSSON", "Taxpayer ID", "123-45-6789"],
            // A sentence that wrapped, ending in a full stop: no heading.
            ["Please bring your", "Social Security card.", "123-45-6789"],
            // The sheet's own heading or its own sentence, on a form: the form's number settles it.
            ["Your Social Security Card", "Form W\u{2013}4", "123-45-6789"],
            ["Your Social Security Card", "Form W-9 (Rev. 10-2018)", "123-45-6789"],
            ["Social Security Card", "Form Approved OMB # 1845-0001", "123-45-6789"],
            ["Your Social Security Card", "OMB No. 1545-0074", "123-45-6789"],
            ["Sign this card in ink immediately. Your Social Security card", "Form N-400 Edition 04/01/24", "123-45-6789"],
        ]
        for page in pages {
            #expect(VaultFixtures.read(page).isEmpty, "\(page[0].prefix(16))")
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
        // Every heading the sheet has been printed with, and each of its own sentences, alone.
        for heading in ["Social Security Card", "Your Social Security Card", "Your New Social Security Card",
                        "New Social Security Card", "Replacement Social Security Card", "Your Replacement Social Security Card"] {
            #expect(VaultReading.sheetHeadings.contains(heading.lowercased().filter(\.isLetter)))
            #expect(VaultFixtures.read([heading, "ANNA MARIA ERIKSSON", "123-45-6789"]).map(\.value) == ["123456789"], "\(heading)")
        }
        let sentences = ["ADULTS: Sign this card in ink immediately.",
                         "This card belongs to the Social Security Administration and you must return it if we ask for it.",
                         "Improper use of this card or number by anyone is punishable by fine, imprisonment or both.",
                         "DO NOT CARRY THIS CARD WITH YOU."]
        #expect(sentences.count == VaultReading.sheetCues.count)
        for sentence in sentences {
            #expect(VaultFixtures.read(["123-45-6789", sentence, "Contact us about your Social Security card."]).map(\.value)
                    == ["123456789"], "\(sentence.prefix(16))")
        }
        // Two of the sentences other cards' papers print too; never one (the pages above).
        let loose = ["Do not laminate.", "Keep your card in a safe place to prevent loss or theft.",
                     "Keep your Social Security card in a safe place.", "Do not carry it with you.",
                     "CHILDREN: Do not sign until age 18 or your first job."]
        #expect(loose.count == VaultReading.looseSheetCues.count)
        for (first, second) in zip(loose, loose.dropFirst() + loose.prefix(1)) {
            #expect(VaultFixtures.read(["123-45-6789", first, second, "about your Social Security card"]).map(\.value)
                    == ["123456789"], "\(first.prefix(12)) + \(second.prefix(12))")
        }
        // The heading with a colon after it; and "form" as a plain word before the number.
        #expect(VaultFixtures.read(["Your Social Security Card:", "ANNA MARIA ERIKSSON", "123-45-6789"]).map(\.value) == ["123456789"])
        #expect(VaultFixtures.read(["Your Social Security Card", "123-45-6789",
                                    "Show the number in the form 123-45-6789 to your employer"]).map(\.value) == ["123456789"])
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
