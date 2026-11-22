import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// What the Vault reads from a document's recognised lines (``VaultReading``, ``MachineZone``).
///
/// Every number here is a specimen or made up. The passport lines are ICAO Doc 9303's own example;
/// the others are built by ``zone(_:number:born:expires:surname:given:)`` with real check digits.
@Suite struct VaultReadingTests {
    static let nameLine = "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"
    static let numberLine = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        VaultReading.calendarDate(year: y, month: m, day: d)!
    }

    /// A machine-readable zone of two lines for a made-up document: a passport's (`P`, 44 with the
    /// overall check) or a visa's (`V`, 44 with no overall check), every check digit computed.
    static func zone(_ kind: Character, number: String, born: String, expires: String,
                     surname: String = "ERIKSSON", given: String = "ANNA", country: String = "UTO") -> [String] {
        func pad(_ s: String, _ n: Int) -> String { s + String(repeating: "<", count: max(0, n - s.count)) }
        let first = pad("\(kind)<\(country)\(surname)<<\(given)", 44)
        let num = pad(number, 9)
        let head = num + "\(MachineZone.checkDigit(num))" + country + born + "\(MachineZone.checkDigit(born))"
            + "F" + expires + "\(MachineZone.checkDigit(expires))"
        var second: String
        if kind == "P" {
            let personal = pad("", 14)
            let body = head + personal + "\(MachineZone.checkDigit(personal))"
            let composite = String(body.prefix(10)) + String(body.dropFirst(13).prefix(7)) + String(body.dropFirst(21).prefix(22))
            second = body + "\(MachineZone.checkDigit(composite))"
        } else {
            second = pad(head, 44)
        }
        return [first, second]
    }

    @Test func theSpecimenZoneReadsWithEveryCheckAgreeing() throws {
        let zone = try #require(MachineZone.read(["PASSPORT", Self.nameLine, Self.numberLine]))
        #expect(zone.kind == .passport)
        #expect(zone.number == "L898902C3")
        #expect(zone.issuer == "UTO")
        #expect(zone.holder == "Anna Maria Eriksson")
        #expect(zone.expires == Self.day(2012, 4, 15))
        #expect(zone.born == Self.day(1974, 8, 12))
    }

    @Test func spacesTheLetterOAndTheGuillemetVisionGivesAreForgiven() throws {
        // Vision often spaces the zone, reads a zero in a date as O and a run of fillers as «.
        let spaced = "L898902C3 6UTO74O8122F12O4159ZE184226B««<10"
        let zone = try #require(MachineZone.read(["p<utoeriksson«anna<maria«««««««««««««««««", spaced]))
        #expect(zone.number == "L898902C3")
        #expect(zone.expires == Self.day(2012, 4, 15))
    }

    @Test func aMisreadCharacterFailsItsCheckAndIsNotOffered() {
        // One character of the number changed: its check digit no longer agrees.
        #expect(MachineZone.read([Self.nameLine, "L898902C46UTO7408122F1204159ZE184226B<<<<<10"]) == nil)
        // The expiry changed: its own check catches it.
        #expect(MachineZone.read([Self.nameLine, "L898902C36UTO7408122F1205159ZE184226B<<<<<10"]) == nil)
        // A page with no zone at all.
        #expect(MachineZone.read(["Passport", "Surname ERIKSSON"]) == nil)
    }

    @Test func twoPassportsOnOnePageAreTwoPeopleEachWithTheNameAboveIt() {
        // A page holding both children's photo pages, read top to bottom.
        let liv = Self.zone("P", number: "C1111111", born: "150301", expires: "300923", given: "LIV")
        let nils = Self.zone("P", number: "C2222222", born: "180611", expires: "300923", given: "NILS")
        let zones = MachineZone.zones(in: ["PASSPORT"] + liv + ["PASSPORT"] + nils)
        #expect(zones.map(\.number) == ["C1111111", "C2222222"])
        #expect(zones.map(\.givenNames) == ["Liv", "Nils"])
        #expect(zones.map(\.born) == [Self.day(2015, 3, 1), Self.day(2018, 6, 11)])
    }

    @Test func aNameLineOnAnotherPageIsNeverPaired() {
        // Page one has the name line only; page two the number line only.
        let lines = Self.zone("P", number: "C1111111", born: "150301", expires: "300923", given: "LIV")
        let read = VaultReading.read(pages: [[lines[0]], [lines[1]]], from: "/kids.pdf")
        // Read without a name, from its whole line and overall check, never with page one's name.
        #expect(read.finds.map(\.value) == ["C1111111"])
        #expect(read.finds.first?.holder == nil)
    }

    @Test func aVisaIsKnownByItsControlNumberAndNamesItsPassport() throws {
        // A US visa's zone carries the passport's number (as every visa scanned on 2026-11-19
        // did), not the visa's own: that is the Control Number printed on the foil.
        let foil = Self.zone("V", number: "L8988901", born: "740812", expires: "290930", country: "USA")
        let page = foil + ["Control Number 20241234560001", "Visa Type/Class H-1B", "Issue Date 02OCT2024",
                           "Passport Number L8988901"]
        let read = VaultReading.read(pages: [page], from: "/H-1B Visa - Anna.pdf")
        let find = try #require(read.finds.first)
        #expect(read.finds.count == 1, "the passport number in the zone is not a passport of its own")
        #expect(find.category == .usVisa)
        #expect(find.value == "20241234560001")
        #expect(find.title == "US visa · H-1B")
        #expect(find.facts.inPassport == "L8988901")
        #expect(find.facts.dated == Self.day(2024, 10, 2))
        // The visa page is a document of that passport.
        #expect(read.mentions.map(\.value) == ["L8988901"])
        #expect(read.mentions.first?.source.role == "US visa")
        // No Control Number read: no visa row, but still a document of the passport.
        let unread = VaultReading.read(pages: [foil], from: "/visa.pdf")
        #expect(unread.finds.isEmpty)
        #expect(unread.mentions.map(\.value) == ["L8988901"])

        // The visa's name line missed by Vision, and its trailing fillers dropped: the number line
        // alone passes three checks but has no room for a passport's overall check. Not a passport.
        let bare = String(foil[1].prefix(30))
        #expect(VaultReading.finds(in: [bare], from: "/H-4 Visa.pdf").isEmpty)
        // An identity card's zone (I…) is not read at all.
        let card = ["I<UTOERIKSSON<<ANNA<<<<<<<<<<<<<<<<<<<<<<<<<"] + [foil[1]]
        #expect(VaultReading.finds(in: card, from: "/card.pdf").isEmpty)
    }

    @Test func aCharacterVisionCouldNotReadIsFilledOnlyWhenTheChecksAgreeOnOne() throws {
        let lines = Self.zone("P", number: "U5054030", born: "850514", expires: "330601", given: "SHWETA")
        // A digit of the expiry read as "~", as on a real scan.
        var garbled = Array(lines[1])
        garbled[24] = "~"
        let zone = try #require(MachineZone.read([lines[0], String(garbled)]))
        #expect(zone.number == "U5054030")
        #expect(zone.expires == Self.day(2033, 6, 1))
        // Three unreadable characters is too many to trust.
        garbled[14] = "~"; garbled[3] = "~"
        #expect(MachineZone.read([lines[0], String(garbled)]) == nil)
    }

    @Test func aStrayCharacterBetweenFieldsIsDroppedAndAnOddLetterInADateFilled() throws {
        let lines = Self.zone("P", number: "Z1234567", born: "550312", expires: "310704", given: "GIRISH", country: "IND")
        // Vision put a "-" after the birth date's check digit, making the line 45 long.
        var long = Array(lines[1])
        long.insert("-", at: 20)
        #expect(MachineZone.read([lines[0], String(long)])?.number == "Z1234567")
        // A digit of the expiry read as "A", which no look-alike explains.
        var lettered = Array(lines[1])
        lettered[22] = "A"
        #expect(MachineZone.read([lines[0], String(lettered)])?.expires == Self.day(2031, 7, 4))
        // The number's leading Z read as a 2.
        var two = Array(lines[1])
        two[0] = "2"
        #expect(MachineZone.read([lines[0], String(two)])?.number == "Z1234567")
        // Not for another country's passport, whose number may well start with a digit.
        let other = Self.zone("P", number: "Z1234567", born: "550312", expires: "310704", given: "GIRISH")
        var otherTwo = Array(other[1])
        otherTwo[0] = "2"
        #expect(MachineZone.read([other[0], String(otherTwo)]) == nil)
        // A date's 6 read as a B, which the look-alike table fixes to the wrong digit (8).
        let six = Self.zone("P", number: "Z1234567", born: "550312", expires: "360704", given: "GIRISH", country: "IND")
        var bee = Array(six[1])
        bee[22] = "B"
        #expect(MachineZone.read([six[0], String(bee)])?.expires == Self.day(2036, 7, 4))
    }

    @Test func theDocumentReadFromIsTheOneFiledWhereItsKindLives() {
        var facts = VaultReadFacts(category: .passport)
        let page = "Passport photo page"
        facts.add(VaultSource(path: "/D/Immigration/H-1B/Petition/Supporting Documents/Passport/Shweta Passport.pdf", role: page, rank: 40))
        facts.add(VaultSource(path: "/D/Immigration/Passport/Shweta/Archive/Passport Old.pdf", role: page, rank: 40))
        facts.add(VaultSource(path: "/D/Immigration/Passport/Shweta/Passport - Shweta.pdf", role: page, rank: 40))
        facts.add(VaultSource(path: "/D/Immigration/Form I-94/Shweta/I-94.pdf", role: "I-94", rank: 10))
        #expect(facts.primary?.path == "/D/Immigration/Passport/Shweta/Passport - Shweta.pdf")
        #expect(facts.orderedSources.map { ($0.path as NSString).lastPathComponent }
                == ["Passport - Shweta.pdf", "Passport Old.pdf", "Shweta Passport.pdf", "I-94.pdf"])
    }

    @Test func aPassportFindSaysWhoItNamesAndWhenItLapses() throws {
        let finds = VaultReading.finds(in: [Self.nameLine, Self.numberLine], from: "/scan.pdf")
        let find = try #require(finds.first)
        #expect(finds.count == 1)
        #expect(find.title == "Passport")
        #expect(find.value == "L898902C3")
        #expect(find.category == .passport)
        #expect(find.holder == "Anna Maria Eriksson")
        #expect(find.facts.born == Self.day(1974, 8, 12))
        #expect(find.facts.issuer == "UTO")
        #expect(find.sourcePath == "/scan.pdf")
        #expect(find.facts.primary?.role == "Passport photo page")
        #expect(find.facts.details.map(\.label) == ["Issuing country", "Valid until"])
        #expect(!find.facts.details.contains { $0.label.lowercased().contains("birth") }, "a date of birth is never a detail")
    }

    @Test func aReceiptNumberIsReadWithItsFormPersonAndValidity() throws {
        let page = """
            I-797A, Notice of Action
            Approval Notice
            Receipt Number WAC-24-123-4S678   Case Type I-129 Petition for a Nonimmigrant Worker
            Notice Date 07/10/2026
            Beneficiary ERIKSSON, ANNA
            Valid from 10/01/2026 to 09/30/2029
            """
        let finds = VaultReading.finds(in: page.components(separatedBy: "\n"), from: "/notice.pdf")
        let find = try #require(finds.first { $0.category == .uscisCase })
        #expect(find.value == "WAC2412345678", "the S Vision read for a 5 is fixed in a digit field")
        #expect(find.title == "I-129 case")
        #expect(find.facts.form == "I-129")
        #expect(find.holder == "Anna Eriksson")
        #expect(!find.facts.pending)
        #expect(find.facts.primary?.role == "I-797A approval")
        let labels = find.facts.details.map(\.label)
        #expect(labels == ["Form", "Status", "Notice date", "Valid from", "Valid until"],
                "validity is two details, each copied on its own")
    }

    @Test func aDateCopiesTheWayAFormAsksForIt() {
        let detail = VaultDetail("Valid until", .date(Self.day(2029, 9, 30)))
        #expect(detail.copied == "09/30/2029")
        #expect(detail.drawn(shown: false) == "30 September 2029")
        let passport = VaultDetail("In passport", .number("L8988901"))
        #expect(passport.drawn(shown: false) == "••••8901")
        #expect(passport.copied == "L8988901")
    }

    @Test func aDocumentIsGoodThroughItsLastDayWhereTheMacIs() throws {
        let last = Self.day(2026, 11, 20)
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 4 pm on the 19th in California is midnight on the 20th in UTC: still good.
        let afternoonBefore = Date(timeIntervalSince1970: last.timeIntervalSince1970)
        #expect(!VaultReading.hasRunOut(last, now: afternoonBefore, timeZone: pacific))
        // 11 pm on the 20th in California: still its last day.
        #expect(!VaultReading.hasRunOut(last, now: last.addingTimeInterval(31 * 3600), timeZone: pacific))
        // The 21st: run out.
        #expect(VaultReading.hasRunOut(last, now: last.addingTimeInterval(33 * 3600), timeZone: pacific))
        // The same rule counts the days left (VT102): one rule, never two that can drift apart.
        #expect(VaultReading.daysLeft(last, now: afternoonBefore, timeZone: pacific) == 1)
        #expect(VaultReading.daysLeft(last, now: last.addingTimeInterval(31 * 3600), timeZone: pacific) == 0)
        #expect(VaultReading.daysLeft(last, now: last.addingTimeInterval(33 * 3600), timeZone: pacific) == -1)
        // Against the rule as it was written before (UTC day printed, local day today, compared).
        func before(_ until: Date, _ now: Date, _ zone: TimeZone) -> Bool {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            var local = Calendar(identifier: .gregorian)
            local.timeZone = zone
            let a = utc.dateComponents([.year, .month, .day], from: until)
            let b = local.dateComponents([.year, .month, .day], from: now)
            return (b.year!, b.month!, b.day!) > (a.year!, a.month!, a.day!)
        }
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        for hours in stride(from: -60, through: 60, by: 1) {
            let now = last.addingTimeInterval(Double(hours) * 3600)
            for zone in [pacific, tokyo, TimeZone(identifier: "UTC")!] {
                #expect(VaultReading.hasRunOut(last, now: now, timeZone: zone) == before(last, now, zone), "\(hours) h, \(zone.identifier)")
                var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
                var local = Calendar(identifier: .gregorian); local.timeZone = zone
                let days = utc.dateComponents([.day], from: utc.date(from: local.dateComponents([.year, .month, .day], from: now))!,
                                              to: utc.date(from: utc.dateComponents([.year, .month, .day], from: last))!).day!
                #expect(VaultReading.daysLeft(last, now: now, timeZone: zone) == days, "\(hours) h, \(zone.identifier)")
            }
        }
    }

    @Test func onlyAnArchiveFolderInsideTheReadFolderCounts() {
        let roots = ["/Users/a/Documents/Archive/Immigration"]
        #expect(!VaultReading.isArchivePath("/Users/a/Documents/Archive/Immigration/Passport/Anna/p.pdf", under: roots))
        #expect(VaultReading.isArchivePath("/Users/a/Documents/Archive/Immigration/Passport/Anna/Archive/p.pdf", under: roots))
    }

    @Test func aCenterCodeFollowedByAWordIsNotAReceiptNumber() {
        #expect(VaultReading.receiptNumbers(in: "LIN DOGBOSSILLIGO", from: "/a").isEmpty)
        #expect(VaultReading.receiptNumbers(in: "Send to EAC 12345", from: "/a").isEmpty)
    }

    @Test func anAdmissionNumberNeedsItsLabel() throws {
        #expect(VaultReading.admissionNumbers(in: "Reference 12345678901", from: "/a").isEmpty)
        let finds = VaultReading.admissionNumbers(
            in: "Admission (I-94) Record Number: 123456789 A1", from: "/a")
        let find = try #require(finds.first)
        #expect(find.value == "123456789A1")
        #expect(find.title == "I-94 admission number")
        // The format before 2013: eleven digits.
        #expect(VaultReading.admissionNumbers(in: "I-94 No. 98765432101", from: "/a").first?.value
                == "98765432101")
        // As Vision read a real approval notice: the I of the label as a one, then "(if
        // applicable)", and a tear-off whose number runs into the next characters.
        #expect(VaultReading.admissionNumbers(in: "1-94 # (if applicable): 123456789A1", from: "/a").first?.value
                == "123456789A1")
        #expect(VaultReading.admissionNumbers(in: "I-94 123456789 A1îŚ", from: "/a").first?.value
                == "123456789A1")
        // Letters that only become digits once fixed are a word.
        #expect(VaultReading.admissionNumbers(in: "Admission BOGGLISSOOD", from: "/a").isEmpty)
    }

    @Test func aUtilityBillsDigitsAreNotAnAdmissionNumber() {
        // The shape of a PG&E bill as read: a payment line of digits holding "194", then the
        // account number. Every digit here is made up.
        let bill = """
            Thank you.
            30172194560000000000000000012345678
            PG&E
            Account Number:
            60000000000-5
            Due Date:
            01/26/2015
            """
        #expect(VaultReading.finds(in: bill.components(separatedBy: "\n"), from: "/bill.pdf").isEmpty)
        #expect(VaultReading.admissionNumbers(in: "Unit 1 94 Main St 12345678901", from: "/a").isEmpty)
        #expect(VaultReading.admissionNumbers(in: "Invoice 2194 123456789A1", from: "/a").isEmpty)
        #expect(VaultReading.admissionNumbers(in: "I94: 123456789A1", from: "/a").first?.value == "123456789A1")
        #expect(VaultReading.admissionNumbers(in: "I-94 Number: 60000000000", from: "/a").isEmpty)
    }

    @Test func anI94PrintoutSaysWhoseItIsWhenTheyEnteredAndWhichPassport() throws {
        // CBP's printout since 2025, as its text layer reads. Every value is made up.
        let current = """
            Most Recent I-94
            Admission I-94 Record Number: 123456789A1
            Arrival/Issued Date: 2026 April 12
            Class of Admission: H1B
            Admit Until Date: 2029 September 30
            Last/Surname: ERIKSSON
            First (Given) Name: ANNA
            Birth Date: 1974 August 12
            Document Number: L8988901
            """
        let read = VaultReading.read(pages: [current.components(separatedBy: "\n")], from: "/i94.pdf")
        let find = try #require(read.finds.first)
        #expect(find.holder == "Anna Eriksson")
        #expect(find.dated == Self.day(2026, 4, 12))
        #expect(find.facts.born == Self.day(1974, 8, 12))
        #expect(find.facts.primary?.role == "CBP I-94 printout")
        #expect(find.facts.details.map(\.label) == ["Class of admission", "Entered", "Admitted until"])
        // The passport it names is a document for that passport, not a number of its own.
        #expect(read.mentions.map(\.value) == ["L8988901"])
        #expect(read.mentions.first?.source.role == "I-94")

        // CBP's web printout, whose text layer draws every label four times before its value.
        let repeated = """
            Admission I-94 Record Number:Admission I-94 Record Number:Admission I-94 Record Number: 123456789A1
            Class of Admission:Class of Admission:Class of Admission:Class of Admission: F1
            Last/Surname:Last/Surname:Last/Surname:Last/Surname: ERIKSSON
            First (Given) Name:First (Given) Name:First (Given) Name:First (Given) Name: ANNA MARIA
            Birth Date:Birth Date:Birth Date:Birth Date: 1974 August 12
            """
        let web = try #require(VaultReading.finds(in: repeated.components(separatedBy: "\n"), from: "/web.pdf").first)
        #expect(web.holder == "Anna Maria Eriksson", "not the next copy of the label")
        #expect(web.facts.details.first { $0.label == "Class of admission" }?.copied == "F1")
        #expect(web.facts.born == Self.day(1974, 8, 12))
        // A label with no value on its line takes nothing from the next line.
        let empty = "Last/Surname:\nFirst (Given) Name:\nI-94 Number 123456789A1"
        #expect(VaultReading.finds(in: empty.components(separatedBy: "\n"), from: "/e.pdf").first?.holder == nil)

        // The older printout: "Most Recent Date of Entry", and "I­94" with a soft hyphen.
        let older = "Admission (I\u{00AD}94) Record Number: 98765432101\nMost Recent Date of Entry: 2015 Jan 12"
        let old = try #require(VaultReading.finds(in: older.components(separatedBy: "\n"), from: "/old.pdf").first)
        #expect(old.value == "98765432101")
        #expect(old.dated == Self.day(2015, 1, 12))
    }

    @Test func aFileNamesDateIsReadWhenThePageHasNone() {
        #expect(VaultReading.fileDate("/a/Form I-94 - Anna - Jul 2024.pdf") == Self.day(2024, 7, 1))
        #expect(VaultReading.fileDate("/a/Anna I-94 - July 2025.pdf") == Self.day(2025, 7, 1))
        #expect(VaultReading.fileDate("/a/Scan 2023-11-04.pdf") == Self.day(2023, 11, 4))
        #expect(VaultReading.fileDate("/a/Form I-94 2015.pdf") == Self.day(2015, 1, 1))
        #expect(VaultReading.fileDate("/a/Passport - Anna - Bio Pages.pdf") == nil)
        #expect(VaultReading.fileDate("/a/Passport L8989021.pdf") == nil, "a number is not a year")
    }

    @Test func aNumberPrintedTwiceIsFoundOnce() {
        let page = ["Receipt Number: IOE0912345678", "Receipt # IOE 09 123 45678",
                    "I-94 Number 123456789A1", "Admission number: 123456789A1"]
        let finds = VaultReading.finds(in: page, from: "/a")
        #expect(finds.map(\.value).sorted() == ["123456789A1", "IOE0912345678"])
    }

    @Test func aFindNeverPrintsItsNumber() {
        let find = VaultFind(title: "Passport", value: "L898902C3", kind: .identity, sourcePath: "/a")
        for text in ["\(find)", String(reflecting: find), "\([find])"] {
            #expect(!text.contains("L898902C3"), "\(text)")
            #expect(text.contains("02C3"))
        }
    }
}

/// Which numbers are current (``VaultStandings``).
@Suite struct VaultStandingsTests {
    static let today = VaultReadingTests.day(2026, 11, 19)
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultReadingTests.day(y, m, d) }

    static func input(_ value: String, _ category: VaultCategory, born: Date? = nil, holder: String? = nil,
                      issuer: String? = nil, form: String? = nil, dated: Date? = nil, until: Date? = nil,
                      pending: Bool = false, inPassport: String? = nil, path: String = "/docs/a.pdf",
                      pin: VaultPin? = nil) -> VaultStandingInput {
        VaultStandingInput(id: UUID(), value: value, category: category,
                           facts: VaultReadFacts(category: category, holder: holder, born: born, issuer: issuer,
                                                 form: form, dated: dated, validUntil: until, pending: pending,
                                                 inPassport: inPassport,
                                                 sources: [VaultSource(path: path, role: "Document", rank: 1)]),
                           pin: pin)
    }

    static func tabs(_ inputs: [VaultStandingInput], roots: [String] = ["/docs"]) -> [VaultStanding.Tab] {
        let out = VaultStandings.compute(inputs, now: today, readFolders: roots)
        return inputs.map { out[$0.id]!.tab }
    }

    @Test func onePassportPerPersonAndCountry() {
        let anna = Self.day(1974, 8, 12)
        let erik = Self.day(1972, 1, 3)
        let inputs = [
            Self.input("A1", .passport, born: anna, issuer: "SWE", dated: Self.day(2032, 5, 16), until: Self.day(2032, 5, 16)),
            Self.input("A0", .passport, born: anna, issuer: "SWE", dated: Self.day(2014, 1, 3), until: Self.day(2014, 1, 3)),
            // A dual citizen: both valid passports stay current.
            Self.input("E1", .passport, born: erik, issuer: "SWE", dated: Self.day(2028, 2, 8), until: Self.day(2028, 2, 8)),
            Self.input("E2", .passport, born: erik, issuer: "FIN", dated: Self.day(2031, 3, 3), until: Self.day(2031, 3, 3)),
        ]
        #expect(Self.tabs(inputs) == [.current, .archive, .current, .current])
    }

    @Test func aPersonsOnlyPassportStaysCurrentWhenItHasExpired() {
        let liv = Self.input("C1", .passport, born: Self.day(2015, 3, 1), issuer: "SWE",
                             dated: Self.day(2025, 9, 23), until: Self.day(2025, 9, 23))
        let out = VaultStandings.compute([liv], now: Self.today)
        #expect(out[liv.id]?.tab == .current)
        #expect(out[liv.id]?.expired == true)
    }

    @Test func anOlderPassportHoldingAGoodVisaIsInUse() {
        let anna = Self.day(1974, 8, 12)
        let old = Self.input("A0", .passport, born: anna, issuer: "SWE", dated: Self.day(2024, 8, 25), until: Self.day(2024, 8, 25))
        let new = Self.input("A1", .passport, born: anna, issuer: "SWE", dated: Self.day(2032, 5, 16), until: Self.day(2032, 5, 16))
        let visa = Self.input("V1", .usVisa, born: anna, dated: Self.day(2024, 10, 2), until: Self.day(2029, 9, 30), inPassport: "A0")
        let out = VaultStandings.compute([old, new, visa], now: Self.today)
        #expect(out[old.id] == VaultStanding(tab: .current, expired: true, inUse: true))
        #expect(out[new.id]?.tab == .current)
    }

    @Test func anI94ExtendedWithoutTravelBeatsTheOlderPrintout() {
        let anna = Self.day(1974, 8, 12)
        let printout = Self.input("I1", .i94, born: anna, dated: Self.day(2023, 8, 23), until: Self.day(2026, 9, 30))
        let tearOff = Self.input("I2", .i94, born: anna, dated: Self.day(2026, 7, 2), until: Self.day(2029, 9, 30))
        #expect(Self.tabs([printout, tearOff]) == [.archive, .current])
    }

    @Test func casesAreOnePerFormAndPerson() {
        let i129Anna = Self.input("W1", .uscisCase, holder: "Anna Eriksson", form: "I-129", dated: Self.day(2026, 7, 10), until: Self.day(2029, 9, 30))
        let i129AnnaOld = Self.input("W0", .uscisCase, holder: "Anna Eriksson", form: "I-129", dated: Self.day(2023, 10, 6), until: Self.day(2026, 9, 30))
        // Both spouses on H-1B: two I-129 cases, both current.
        let i129Erik = Self.input("W2", .uscisCase, holder: "Erik Eriksson", form: "I-129", dated: Self.day(2026, 6, 1), until: Self.day(2029, 9, 30))
        // A case whose validity ended, with nothing newer: Archive, not current-expired.
        let ended = Self.input("W3", .uscisCase, holder: "Erik Eriksson", form: "I-539", dated: Self.day(2019, 3, 1), until: Self.day(2019, 8, 25))
        // A pending case: current.
        let pending = Self.input("W4", .uscisCase, holder: "Erik Eriksson", form: "I-765", dated: Self.day(2026, 8, 14), pending: true)
        // A case decided with no end date, such as an approved I-485: history, not current.
        let decided = Self.input("W5", .uscisCase, holder: "Anna Eriksson", form: "I-485", dated: Self.day(2017, 6, 1))
        #expect(Self.tabs([i129Anna, i129AnnaOld, i129Erik, ended, pending, decided])
                == [.current, .archive, .current, .archive, .current, .archive])
    }

    @Test func anExpiredVisaIsKeptInArchive() {
        let visa = Self.input("V1", .usVisa, born: Self.day(1974, 8, 12), dated: Self.day(2014, 9, 1),
                              until: Self.day(2019, 9, 1))
        #expect(Self.tabs([visa]) == [.archive])
    }

    @Test func noPersonReadMeansTheNumberStandsAloneNeverGroupedByFolder() {
        // Three passports in one folder, no name or birth date read: none makes another older.
        let inputs = ["X1", "X2", "X3"].enumerated().map { index, value in
            Self.input(value, .passport, dated: Self.day(2030 + index, 1, 1), until: Self.day(2030 + index, 1, 1),
                       path: "/docs/Passport/scan\(index).pdf")
        }
        #expect(Self.tabs(inputs) == [.current, .current, .current])
    }

    @Test func archiveFoldersAndPinsAreRespected() {
        let anna = Self.day(1974, 8, 12)
        let current = Self.input("I1", .i94, born: anna, dated: Self.day(2026, 4, 25), until: Self.day(2029, 9, 30),
                                 path: "/docs/I-94/Anna/a.pdf")
        let archived = Self.input("I0", .i94, born: anna, dated: Self.day(2024, 7, 28), until: Self.day(2029, 9, 30),
                                  path: "/docs/I-94/Anna/Archive/b.pdf")
        #expect(Self.tabs([current, archived]) == [.current, .archive])
        // Filed only in an Archive folder: Archive.
        let lone = Self.input("I9", .i94, born: Self.day(1950, 1, 1), dated: Self.day(2017, 3, 19),
                              path: "/docs/I-94/Grandpa/Archive/c.pdf")
        #expect(Self.tabs([lone]) == [.archive])
        // A choice the user made wins.
        var pinned = archived
        pinned.pin = .current
        #expect(Self.tabs([current, pinned]) == [.current, .current])
        // A number typed in is current unless marked older.
        let typed = VaultStandingInput(id: UUID(), value: "7365", category: .loans, facts: nil, pin: nil)
        var typedOlder = typed
        typedOlder.pin = .older
        #expect(Self.tabs([typed]) == [.current])
        #expect(VaultStandings.compute([typedOlder], now: Self.today)[typedOlder.id]?.tab == .archive)
    }
}

/// The folders Read Documents looks in (``VaultReadFolders``).
@Suite struct VaultReadFoldersTests {
    @Test func aFolderIsListedOnceAndAnEnclosingOneTakesItsPlace() throws {
        let defaults = vaultScratchDefaults("vault-read-folders")

        VaultReadFolders.add("/Users/a/Documents/Immigration/Passport", in: defaults)
        VaultReadFolders.add("/Users/a/Documents/Immigration/Passport/", in: defaults)
        VaultReadFolders.add("/Users/a/Documents/Immigration/Passport/Old", in: defaults)
        #expect(VaultReadFolders.folders(in: defaults) == ["/Users/a/Documents/Immigration/Passport"])

        VaultReadFolders.add("/Users/a/Documents/Immigration", in: defaults)
        VaultReadFolders.add("/Users/a/Documents/Insurance", in: defaults)
        #expect(VaultReadFolders.folders(in: defaults)
                == ["/Users/a/Documents/Immigration", "/Users/a/Documents/Insurance"])

        VaultReadFolders.remove("/Users/a/Documents/Immigration", in: defaults)
        #expect(VaultReadFolders.folders(in: defaults) == ["/Users/a/Documents/Insurance"])
    }
}

/// A document's name and folder, drawn while its number is hidden (``VaultMask``).
@Suite struct VaultFileNameMaskTests {
    @Test func aNumberInAFileNameIsCutToItsEnding() {
        #expect(VaultMask.fileName("/Docs/Passport A38291647.pdf") == "Passport •••••1647.pdf")
        #expect(VaultMask.fileName("/Docs/I-797A WAC2412345678 approval.pdf") == "I-797A •••••••••5678 approval.pdf")
        #expect(VaultMask.fileName("/Docs/Scan 2024-03-01.png") == "Scan 2024-03-01.png")
        #expect(VaultMask.fileName("/Docs/Passport.pdf") == "Passport.pdf")
        #expect(VaultMask.fileName("/Docs/Form I-94 - Anna - Apr 2026.pdf") == "Form I-94 - Anna - Apr 2026.pdf")
    }

    @Test func aNumberWrittenWithSpacesOrDashesIsCutToo() {
        #expect(VaultMask.fileName("/Docs/WAC 26 901 23456.pdf") == "••• •• ••• •3456.pdf")
        #expect(VaultMask.fileName("/Docs/Receipt WAC-26-901-23456 notice.pdf") == "Receipt •••-••-•••-•3456 notice.pdf")
    }

    @Test func aFoldersNameIsCutLikeAFiles() {
        #expect(VaultMask.folder("~/Documents/Passport A38291647/Archive") == "~/Documents/Passport •••••1647/Archive")
        #expect(VaultMask.folder("~/Documents/Immigration/H-1B/2026-2029") == "~/Documents/Immigration/H-1B/2026-2029")
    }
}
