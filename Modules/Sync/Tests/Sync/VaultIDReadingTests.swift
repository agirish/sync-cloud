import Foundation
import Testing
@testable import Sync

/// The identity cards Legal holds (``VaultReading/identityNumbers(on:from:)``): licenses, Social
/// Security cards and ITINs, PAN, Aadhaar and voter IDs.
///
/// Every number here is made up; the Aadhaar ones are given a real Verhoeff check digit.
@Suite struct VaultIDReadingTests {
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultReadingTests.day(y, m, d) }

    static func read(_ lines: [String], path: String = "/docs/Legal/card.pdf") -> [VaultFind] {
        VaultReading.read(pages: [lines], from: path).finds
    }

    /// `head` with the check digit that makes it pass Verhoeff.
    static func aadhaar(_ head: String) -> String {
        head + String((0...9).first { VaultReading.passesVerhoeff(head + String($0)) }!)
    }

    static func spaced(_ digits: String) -> String {
        stride(from: 0, to: digits.count, by: 4).map { i in
            String(Array(digits)[i..<min(i + 4, digits.count)])
        }.joined(separator: " ")
    }

    // MARK: US licenses

    static let barcode = [
        "@", "ANSI 636014090002DL00410278ZC03190024DLDAQD1234567", "DCSERIKSSON", "DDEN", "DACANNA", "DADMARIA",
        "DBD05162025", "DBB08121974", "DBA05162030", "DBC2", "DAJCA", "DCGUSA", "DCAC",
    ]

    @Test func aLicenseBarcodeStatesTheNumberNameAndDates() throws {
        let find = try #require(Self.read(["CLASS: C", "RESTRICTIONS: None"] + Self.barcode).first)
        #expect(find.category == .driversLicense)
        #expect(find.value == "D1234567")
        #expect(find.title == "Driver’s license · CA")
        #expect(find.holder == "Anna Eriksson")
        #expect(find.facts.born == Self.day(1974, 8, 12))
        #expect(find.dated == Self.day(2025, 5, 16))
        #expect(find.validUntil == Self.day(2030, 5, 16))
        #expect(find.facts.issuer == "USA")
        #expect(find.facts.primary?.role == "Driver’s license barcode")
    }

    @Test func aLicenseFrontIsReadBesideItsLabel() throws {
        let front = ["California USA DRIVER LICENSE", "DL D1234567", "EXP 05/16/2030", "LN ERIKSSON",
                     "FN ANNA MARIA", "DOB 08/12/1974", "DD 05/16/2025123456/ABCD/30", "ISS", "05/16/2025"]
        let finds = Self.read(front)
        #expect(finds.map(\.value) == ["D1234567"])
        let find = try #require(finds.first)
        #expect(find.holder == "Anna Maria Eriksson")
        #expect(find.validUntil == Self.day(2030, 5, 16))
        #expect(find.dated == Self.day(2025, 5, 16))
        #expect(find.facts.born == Self.day(1974, 8, 12))
        #expect(find.title == "Driver’s license · CA")
    }

    @Test func aLicenseNumberWithoutItsLabelIsNotRead() {
        #expect(Self.read(["DRIVER LICENSE", "D1234567", "EXP 05/16/2030"]).isEmpty)
        // A "DL" label on a page that is not a license.
        #expect(Self.read(["Shipping", "DL D1234567"]).isEmpty)
    }

    // MARK: Indian licenses

    static let indianLicense = [
        "UNION OF INDIA DRIVING LICENSE", "Issuing Authority : RTO BANGALORE (SOUTH)",
        "Authorization to Drive : LMV,MCWG License No. : KA05 20090001234 Date of Issue : 01-02-2009",
        "Date of Expiry : 31-01-2029", "Name : ANNA ERIKSSON", "DOB : 12-08-1974", "S/W/D : ERIK ERIKSSON",
    ]

    @Test func anIndianLicenseIsReadDayFirst() throws {
        let finds = Self.read(Self.indianLicense)
        #expect(finds.map(\.value) == ["KA0520090001234"])
        let find = try #require(finds.first)
        #expect(find.title == "Driver’s license · India")
        #expect(find.holder == "Anna Eriksson")
        #expect(find.dated == Self.day(2009, 2, 1))
        #expect(find.validUntil == Self.day(2029, 1, 31))
        #expect(find.facts.born == Self.day(1974, 8, 12))
        #expect(find.facts.issuer == "IND")
    }

    @Test func anIndianLicenseNeedsAStateCode() {
        let lines = Self.indianLicense.map { $0.replacingOccurrences(of: "KA05", with: "ZZ05") }
        #expect(Self.read(lines).isEmpty)
    }

    // MARK: Social Security numbers and ITINs

    static let ssnCard = ["SOCIAL SECURITY", "VALID FOR WORK ONLY", "WITH DHS AUTHORIZATION", "123-45-6789",
                          "THIS NUMBER HAS BEEN ESTABLISHED FOR", "ANNA MARIA", "ERIKSSON", "SIGNATURE", "05/16/2025"]

    @Test func aSocialSecurityCardIsRead() throws {
        let finds = Self.read(Self.ssnCard)
        #expect(finds.map(\.value) == ["123456789"])
        let find = try #require(finds.first)
        #expect(find.category == .ssn)
        #expect(find.title == "Social Security number")
        #expect(find.holder == "Anna Maria Eriksson")
        #expect(find.facts.form == "SSN")
        #expect(find.dated == Self.day(2025, 5, 16))
        #expect(!VaultReading.wantsSharperRead(Self.ssnCard))
    }

    @Test func aMisreadSocialSecurityNumberIsSkippedAndReadAgainSharper() {
        // A digit run in, a hyphen lost, digits dropped: none is mended.
        for misread in ["1234-56-7890", "123-456789", "12-45-6789", "123-45-67890"] {
            let lines = Self.ssnCard.map { $0 == "123-45-6789" ? misread : $0 }
            #expect(Self.read(lines).isEmpty, "\(misread.count)")
            #expect(VaultReading.wantsSharperRead(lines))
        }
    }

    @Test func aNumberSSANeverAssignsIsNotRead() {
        for never in ["000-45-6789", "666-45-6789", "923-45-6789", "123-00-6789", "123-45-0000"] {
            #expect(Self.read(Self.ssnCard.map { $0 == "123-45-6789" ? never : $0 }).isEmpty)
        }
    }

    @Test func aSocialSecurityNumberOffACardIsNotRead() {
        // A tax form prints the label and the number, but is not where the number comes from.
        #expect(Self.read(["Form W-2 Wage and Tax Statement", "a Employee\u{27}s social security number",
                           "123-45-6789", "Signature"]).isEmpty)
        #expect(!VaultReading.wantsSharperRead(["Form W-2", "social security number", "1234-56-7890"]))
    }

    @Test func aMisreadSignatureBelowTheNameEndsIt() {
        let card = Self.ssnCard.map { $0 == "SIGNATURE" ? "Prbr" : $0 }
        #expect(Self.read(card).first?.holder == "Anna Maria Eriksson")
    }

    @Test func aMisreadNameIsDroppedAndTheStubsNameTaken() throws {
        let card = Self.ssnCard.map { $0 == "ANNA MARIA" ? "• ANNA" : $0 }
        #expect(Self.read(card).first?.holder == nil)
        let stub = ["YOUR SOCIAL SECURITY CARD", "ANNA ERIKSSON", "1234 MAIN STREET", "SPRINGFIELD IL 62701"] + card
        #expect(Self.read(stub).first?.holder == "Anna Eriksson")
    }

    static let itinNotice = [
        "Department of Treasury", "Internal Revenue Service", "Notice date", "November 12, 2019",
        "ANNA ERIKSSON", "1234 MAIN STREET", "Individual Taxpayer Identification Number (ITIN) assigned",
        "Identification Number (ITIN) 912-70-1234 based", "Date of birth", "August 12, 1974",
    ]

    @Test func anITINNoticeIsRead() throws {
        let finds = Self.read(Self.itinNotice)
        #expect(finds.map(\.value) == ["912701234"])
        let find = try #require(finds.first)
        #expect(find.title == "ITIN")
        #expect(find.facts.form == "ITIN")
        #expect(find.holder == "Anna Eriksson")
        #expect(find.dated == Self.day(2019, 11, 12))
        #expect(find.facts.born == Self.day(1974, 8, 12))
        // A middle pair the IRS never assigns.
        #expect(Self.read(Self.itinNotice.map { $0.replacingOccurrences(of: "912-70", with: "912-40") }).isEmpty)
    }

    @Test func anITINGivesWayToTheSamePersonsSSN() {
        let anna = Self.day(1974, 8, 12)
        let ssn = VaultStandingsTests.input("123456789", .ssn, born: anna, form: "SSN", dated: Self.day(2025, 5, 16))
        let itin = VaultStandingsTests.input("912701234", .ssn, born: anna, form: "ITIN", dated: Self.day(2019, 11, 12))
        let out = VaultStandings.compute([ssn, itin], now: VaultStandingsTests.today)
        #expect(out[ssn.id]?.tab == .current)
        #expect(out[itin.id]?.tab == .archive)
        #expect(out[itin.id]?.reason == "Replaced by an SSN")
        // Alone, an ITIN is the person's current number.
        #expect(VaultStandings.compute([itin], now: VaultStandingsTests.today)[itin.id]?.tab == .current)
    }

    // MARK: PAN

    static let panCard = ["INCOME TAX DEPARTMENT", "GOVT. OF INDIA", "Permanent Account Number Card", "ABCPE1234F",
                          "Name", "ANNA ERIKSSON", "Father\u{27}s Name", "ERIK ERIKSSON", "Date of Birth", "12/08/1974"]

    @Test func aPANCardIsReadWithItsHolder() throws {
        let finds = Self.read(Self.panCard)
        #expect(finds.map(\.value) == ["ABCPE1234F"])
        let find = try #require(finds.first)
        #expect(find.category == .pan)
        // The card's own name, not the father's below it, nor the department's above.
        #expect(find.holder == "Anna Eriksson")
        #expect(find.facts.born == Self.day(1974, 8, 12))
    }

    @Test func aPANsHolderMustMatchItsSurnameLetter() {
        // The fifth letter is the surname's first: a name starting otherwise is not the holder.
        let lines = Self.panCard.map { $0 == "ABCPE1234F" ? "ABCPK1234F" : $0 }
        #expect(Self.read(lines).first?.holder == nil)
    }

    @Test func aPANIsReadOnlyOnAPageAboutOne() {
        #expect(Self.read(["Invoice", "Reference ABCPE1234F"]).isEmpty)
    }

    // MARK: Aadhaar

    @Test func anAadhaarLetterIsReadAndItsVIDIsNot() throws {
        let number = Self.aadhaar("23456789012")
        // A VID of sixteen digits whose last twelve would pass on their own.
        let vid = "9123" + number
        let lines = ["Unique Identification Authority of India", "Enrolment No.: 1234/12345/12345", "To",
                     "Anna Eriksson", "Issue Date: 01/02/2020", Self.spaced(number), "VID : " + Self.spaced(vid),
                     Self.spaced(vid), "Anna Eriksson", "DOB: 12/08/1974"]
        let finds = Self.read(lines)
        #expect(finds.map(\.value) == [number])
        let find = try #require(finds.first)
        #expect(find.category == .aadhaar)
        #expect(find.holder == "Anna Eriksson")
        #expect(find.facts.born == Self.day(1974, 8, 12))
        #expect(find.dated == Self.day(2020, 2, 1))
        // Only the VID: nothing.
        #expect(Self.read(["Unique Identification Authority of India", Self.spaced(vid)]).isEmpty)
    }

    @Test func anAadhaarNumberMustPassItsCheckDigit() {
        let number = Self.aadhaar("23456789012")
        let wrong = String(number.dropLast()) + String((Int(String(number.last!))! + 1) % 10)
        #expect(Self.read(["Unique Identification Authority of India", Self.spaced(wrong)]).isEmpty)
    }

    @Test func anAadhaarNumberOffAUIDAIPageNeedsItsLabel() {
        let number = Self.aadhaar("23456789012")
        #expect(Self.read(["Bank account opening form", "Aadhaar number", Self.spaced(number)]).map(\.value) == [number])
        #expect(Self.read(["Aadhaar seeding", "Account 1234", "Other", Self.spaced(number)]).isEmpty)
    }

    // MARK: Voter IDs

    @Test func aVoterIDIsReadOnAnElectionCommissionPage() throws {
        let lines = ["ELECTION COMMISSION OF INDIA", "ABC1234567", "Name: Anna Eriksson",
                     "Father\u{27}s Name: Erik Eriksson", "Date of Birth / Age: 12-08-1974"]
        let find = try #require(Self.read(lines).first)
        #expect(find.category == .voterID)
        #expect(find.value == "ABC1234567")
        #expect(find.holder == "Anna Eriksson")
        #expect(find.facts.born == Self.day(1974, 8, 12))
        #expect(Self.read(["Order", "ABC1234567"]).isEmpty)
    }

    // MARK: Standings and categories

    @Test func aUSLicenseAndAnIndianOneAreBothCurrent() {
        let anna = Self.day(1974, 8, 12)
        let us = VaultStandingsTests.input("D1234567", .driversLicense, born: anna, issuer: "USA",
                                           dated: Self.day(2025, 5, 16), until: Self.day(2030, 5, 16))
        let oldUS = VaultStandingsTests.input("N7654321", .driversLicense, born: anna, issuer: "USA",
                                              dated: Self.day(2014, 1, 3), until: Self.day(2019, 1, 3))
        let india = VaultStandingsTests.input("KA0520090001234", .driversLicense, born: anna, issuer: "IND",
                                              dated: Self.day(2009, 2, 1), until: Self.day(2029, 1, 31))
        let out = VaultStandings.compute([us, oldUS, india], now: VaultStandingsTests.today)
        #expect(out[us.id]?.tab == .current)
        #expect(out[india.id]?.tab == .current)
        #expect(out[oldUS.id]?.tab == .archive)
        #expect(out[oldUS.id]?.reason == "Expired Jan 2019 · replaced")
    }

    @Test func theNewKindsAreCardsOnTheMainView() {
        for category in [VaultCategory.ssn, .pan, .aadhaar, .voterID] {
            #expect(VaultCategory.mainView.contains(category))
            #expect(category.kind == .identity)
        }
        #expect(VaultCategory.from(kind: .identity, title: "Social Security") == .ssn)
        #expect(VaultCategory.from(kind: .identity, title: "PAN card") == .pan)
        #expect(VaultCategory.from(kind: .identity, title: "Aadhaar") == .aadhaar)
        #expect(VaultCategory.from(kind: .identity, title: "Voter ID") == .voterID)
        #expect(VaultCategory.from(kind: .identity, title: "Company card") == .other)
    }

    @Test func aCardIsReadFromItsOwnFolderFirst() {
        let home = VaultSource(path: "/d/Legal/US/SSN/Anna/card.pdf", role: "Social Security card", rank: 40)
        let copy = VaultSource(path: "/d/Legal/US/Driver License/Anna/Application/card.pdf", role: "Social Security card", rank: 40)
        #expect(home.placement(for: .ssn) > copy.placement(for: .ssn))
    }

    // MARK: One number on several documents

    @Test func aLicenseBarcodeIsReadBeforeTheFrontOnAnEarlierPage() throws {
        let front = ["California USA DRIVER LICENSE", "DL D1234567", "EXP 05/16/2030", "FN ANNA"]
        let find = try #require(VaultReading.read(pages: [front, Self.barcode], from: "/d/l.pdf").finds.first)
        #expect(find.facts.primary?.role == "Driver’s license barcode")
        #expect(find.holder == "Anna Eriksson")
    }

    @Test func aRenewedCardSpeaksForItsNumberOverTheOneItReplaced() {
        func facts(until: Date, rank: Int, holder: String?) -> VaultReadFacts {
            VaultReadFacts(category: .driversLicense, holder: holder, validUntil: until,
                           sources: [VaultSource(path: "/d/x.pdf", role: "Driver’s license", rank: rank)])
        }
        let renewed = facts(until: Self.day(2030, 5, 16), rank: 40, holder: "Anna")
        let replaced = facts(until: Self.day(2025, 5, 16), rank: 45, holder: "Anna Eriksson")
        #expect(VaultModel.supersedes(renewed, replaced))
        #expect(!VaultModel.supersedes(replaced, renewed))
        // One date, or none: the more trusted document.
        let sameDay = facts(until: Self.day(2030, 5, 16), rank: 45, holder: nil)
        #expect(VaultModel.supersedes(sameDay, renewed))
        #expect(!VaultModel.supersedes(renewed, sameDay))
    }

    @Test func theFullerOfTwoNamesForOneNumberIsKept() {
        #expect(VaultModel.fuller("Anna", "Anna Eriksson") == "Anna Eriksson")
        #expect(VaultModel.fuller("Anna Eriksson", "Anna") == "Anna Eriksson")
        #expect(VaultModel.fuller(nil, "Anna") == "Anna")
        // Two different people's names: the one kept stays.
        #expect(VaultModel.fuller("Anna", "Erik Eriksson") == "Anna")
    }

    @Test func aLicenseBackWithNoBarcodeReadIsReadAgainSharper() {
        let back = ["CLASS: C - Veh w/GVWR", "ENDORSEMENTS: None", "RESTRICTIONS: None",
                    "This license is issued as a license to drive a motor vehicle"]
        #expect(VaultReading.wantsSharperRead(back))
        #expect(!VaultReading.wantsSharperRead(back + Self.barcode))
        #expect(!VaultReading.wantsSharperRead(["Statement", "Restrictions apply"]))
    }
}
