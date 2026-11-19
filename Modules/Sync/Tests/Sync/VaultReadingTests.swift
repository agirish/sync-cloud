import Foundation
import Testing
@testable import Sync

/// What the Vault reads from a page's recognised lines (``VaultReading``, ``PassportMRZ``).
///
/// Every number here is a specimen or made up. The passport lines are ICAO Doc 9303's own example.
@Suite struct VaultReadingTests {
    static let nameLine = "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"
    static let numberLine = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        VaultReading.calendarDate(year: y, month: m, day: d)!
    }

    /// Marked as of a fixed day, so a test's documents do not expire under it.
    static func marked(_ finds: [VaultFind]) -> [VaultFind] {
        VaultReading.markingOlder(finds, now: day(2026, 11, 19))
    }

    @Test func aDocumentThatHasRunOutIsOlderEvenWhenItIsTheOnlyOne() {
        let marked = Self.marked([
            // The only passport read for this person, expired in 2022.
            VaultFind(title: "Passport", value: "A1111111", kind: .identity, holder: "Anna Eriksson",
                      sourcePath: "/P/Anna Passport.pdf", dated: Self.day(2022, 5, 1), validUntil: Self.day(2022, 5, 1)),
            // An I-94 on a 2019 approval notice's tear-off, valid to that August.
            VaultFind(title: "I-94 admission number", value: "123456789A1", kind: .identity,
                      sourcePath: "/H-4/Approval Notice - 2019.pdf", validUntil: Self.day(2019, 8, 25)),
            // A notice still good until 2029.
            VaultFind(title: "USCIS receipt number", value: "WAC2412345678", kind: .identity,
                      sourcePath: "/H-1B/Approval.pdf", validUntil: Self.day(2029, 9, 30)),
        ])
        #expect(marked.map(\.isOlder) == [true, true, false])

        // Read from the page: a tear-off's validity becomes the I-94's.
        let notice = ["Receipt Number WAC1912345678", "Valid from 10/01/2016 to 08/25/2019",
                      "I-94 Number 123456789A1"]
        let i94 = VaultReading.finds(in: notice, from: "/n.pdf").first { $0.title == "I-94 admission number" }
        #expect(i94?.validUntil == Self.day(2019, 8, 25))
    }

    @Test func theSpecimenZoneReadsWithEveryCheckAgreeing() throws {
        let zone = try #require(PassportMRZ.read(["PASSPORT", Self.nameLine, Self.numberLine]))
        #expect(zone.number == "L898902C3")
        #expect(zone.issuer == "UTO")
        #expect(zone.holder == "Anna Maria Eriksson")
        #expect(zone.expires == Self.day(2012, 4, 15))
        #expect(zone.born == Self.day(1974, 8, 12))
    }

    @Test func spacesTheLetterOAndTheGuillemetVisionGivesAreForgiven() throws {
        // Vision often spaces the zone, reads a zero in a date as O and a run of fillers as «.
        let spaced = "L898902C3 6UTO74O8122F12O4159ZE184226B««<10"
        let zone = try #require(PassportMRZ.read(["p<utoeriksson«anna<maria", spaced]))
        #expect(zone.number == "L898902C3")
        #expect(zone.expires == Self.day(2012, 4, 15))
    }

    @Test func aMisreadCharacterFailsItsCheckAndIsNotOffered() {
        // One character of the number changed: its check digit no longer agrees.
        #expect(PassportMRZ.read([Self.nameLine, "L898902C46UTO7408122F1204159ZE184226B<<<<<10"]) == nil)
        // The expiry changed: its own check catches it.
        #expect(PassportMRZ.read([Self.nameLine, "L898902C36UTO7408122F1205159ZE184226B<<<<<10"]) == nil)
        // A page with no zone at all.
        #expect(PassportMRZ.read(["Passport", "Surname ERIKSSON"]) == nil)
    }

    @Test func aPassportFindSaysWhoItNamesAndWhenItLapses() throws {
        let finds = VaultReading.finds(in: [Self.nameLine, Self.numberLine], from: "/scan.pdf")
        let find = try #require(finds.first)
        #expect(finds.count == 1)
        #expect(find.title == "Passport")
        #expect(find.value == "L898902C3")
        #expect(find.kind == .identity)
        #expect(find.holder == "Anna Maria Eriksson")
        #expect(find.note == "Anna Maria Eriksson, expired 15 April 2012, issued by UTO")
        #expect(find.sourcePath == "/scan.pdf")
    }

    @Test func aReceiptNumberIsReadWithItsFormAndValidity() throws {
        let page = """
            I-797A, Notice of Action
            Receipt Number WAC-24-123-4S678   Case Type I-129 Petition for a Nonimmigrant Worker
            Valid from 10/01/2026 to 09/30/2029
            """
        let finds = VaultReading.finds(in: page.components(separatedBy: "\n"), from: "/notice.pdf")
        let find = try #require(finds.first { $0.title == "USCIS receipt number" })
        #expect(find.value == "WAC2412345678", "the S Vision read for a 5 is fixed in a digit field")
        #expect(find.note == "Form I-129, valid to 30 September 2029")
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
        // "194" or "1 94" inside other text is not the label; only "I-94", "I94" and the
        // one-for-I misreading with its hyphen are.
        #expect(VaultReading.admissionNumbers(in: "Unit 1 94 Main St 12345678901", from: "/a").isEmpty)
        #expect(VaultReading.admissionNumbers(in: "Invoice 2194 123456789A1", from: "/a").isEmpty)
        #expect(VaultReading.admissionNumbers(in: "I94: 123456789A1", from: "/a").first?.value == "123456789A1")
        // A filler number, even beside the label.
        #expect(VaultReading.admissionNumbers(in: "I-94 Number: 60000000000", from: "/a").isEmpty)
    }

    @Test func anI94PrintoutSaysWhoseItIsAndWhenTheyEntered() throws {
        // CBP's printout since 2025, as its text layer reads. Every value is made up.
        let current = """
            Most Recent I-94
            Admission I-94 Record Number: 123456789A1
            Arrival/Issued Date: 2026 April 12
            Class of Admission: H1B
            Admit Until Date: 2029 September 30
            Last/Surname: ERIKSSON
            First (Given) Name: ANNA
            """
        let find = try #require(VaultReading.finds(in: current.components(separatedBy: "\n"), from: "/i94.pdf").first)
        #expect(find.holder == "Anna Eriksson")
        #expect(find.dated == Self.day(2026, 4, 12))
        #expect(find.note == "Anna Eriksson, entered 12 April 2026, admitted until 30 September 2029")

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

    @Test func theNewestOfAKindForAPersonIsCurrentAndTheRestOlder() {
        func passport(_ number: String, _ holder: String, expires: Date, _ path: String) -> VaultFind {
            VaultFind(title: "Passport", value: number, kind: .identity, holder: holder,
                      sourcePath: path, dated: expires)
        }
        let finds = [
            passport("A1111111", "Anna Eriksson", expires: Self.day(2034, 1, 1), "/P/Anna/Passport.pdf"),
            passport("A2222222", "Anna Eriksson", expires: Self.day(2024, 1, 1), "/P/Anna/Archive/Old.pdf"),
            passport("A3333333", "Anna Eriksson", expires: Self.day(2014, 1, 1), "/P/Anna/Archive/Older.pdf"),
            passport("B1111111", "Erik Eriksson", expires: Self.day(2030, 1, 1), "/P/Erik/Passport.pdf"),
        ]
        let marked = Self.marked(finds)
        #expect(marked.filter { !$0.isOlder }.map(\.value) == ["A1111111", "B1111111"])

        // The date wins over the folder: a later copy filed in Archive is still the current one.
        let misfiled = Self.marked([
            passport("A1111111", "Anna Eriksson", expires: Self.day(2024, 1, 1), "/P/Anna/Passport.pdf"),
            passport("A2222222", "Anna Eriksson", expires: Self.day(2034, 1, 1), "/P/Anna/Archive/New.pdf"),
        ])
        #expect(misfiled.filter { !$0.isOlder }.map(\.value) == ["A2222222"])

        // Filed only in Archive: all older. With no holder, the folder above says whose.
        let archived = Self.marked([
            VaultFind(title: "I-94 admission number", value: "123456789A1", kind: .identity,
                      sourcePath: "/I-94/Erik/Archive/Form I-94 2015.pdf"),
            VaultFind(title: "I-94 admission number", value: "223456789A1", kind: .identity,
                      sourcePath: "/I-94/Anna/Form I-94 - Anna - Apr 2026.pdf"),
            VaultFind(title: "I-94 admission number", value: "323456789A1", kind: .identity,
                      sourcePath: "/I-94/Anna/Archive/Form I-94 - Anna - Jul 2024.pdf"),
        ])
        #expect(archived.map(\.isOlder) == [true, false, true])

        // Two expiring the same day, with no name read: two children's, issued together. Both current.
        let siblings = Self.marked([
            VaultFind(title: "Passport", value: "C1111111", kind: .identity, sourcePath: "/P/Kids/a.pdf",
                      dated: Self.day(2030, 5, 1)),
            VaultFind(title: "Passport", value: "C2222222", kind: .identity, sourcePath: "/P/Kids/b.pdf",
                      dated: Self.day(2030, 5, 1)),
        ])
        #expect(siblings.allSatisfy { !$0.isOlder })

        // Receipt numbers are cases: two for different forms both stay current, a later case for
        // the same form replaces an earlier one, and one naming no form is only made older by an
        // Archive folder.
        let receipts = Self.marked([
            VaultFind(title: "USCIS receipt number", value: "WAC2412345678", kind: .identity,
                      note: "Form I-129", sourcePath: "/H-1B/Approval/a.pdf", dated: Self.day(2026, 7, 10)),
            VaultFind(title: "USCIS receipt number", value: "WAC2412345677", kind: .identity,
                      note: "Form I-539", sourcePath: "/H-1B/Approval/b.pdf", dated: Self.day(2026, 7, 2)),
            VaultFind(title: "USCIS receipt number", value: "WAC2012345678", kind: .identity,
                      note: "Form I-129", sourcePath: "/H-1B/2020/d.pdf", dated: Self.day(2020, 3, 1)),
            VaultFind(title: "USCIS receipt number", value: "LIN2112345678", kind: .identity,
                      sourcePath: "/H-1B/2021/e.pdf", dated: Self.day(2021, 3, 1)),
            VaultFind(title: "USCIS receipt number", value: "EAC1912345678", kind: .identity,
                      sourcePath: "/H-1B/Archive/c.pdf", dated: Self.day(2019, 3, 25)),
        ])
        #expect(receipts.map(\.isOlder) == [false, false, true, false, true])

        // Once older, always older: the current one leaving does not promote the next.
        let left = Self.marked(marked.filter { $0.value != "A1111111" })
        #expect(left.first { $0.value == "A2222222" }?.isOlder == true)
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

/// The folders Read Documents looks in (``VaultReadFolders``).
@Suite struct VaultReadFoldersTests {
    @Test func aFolderIsListedOnceAndAnEnclosingOneTakesItsPlace() throws {
        let suite = "vault-read-folders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

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

/// A document's name, drawn while its number is hidden (``VaultMask/fileName(_:)``).
@Suite struct VaultFileNameMaskTests {
    @Test func aNumberInAFileNameIsCutToItsEnding() {
        #expect(VaultMask.fileName("/Docs/Passport A38291647.pdf") == "Passport •••••1647.pdf")
        #expect(VaultMask.fileName("/Docs/I-797A WAC2412345678 approval.pdf") == "I-797A •••••••••5678 approval.pdf")
        #expect(VaultMask.fileName("/Docs/Scan 2024-03-01.png") == "Scan 2024-03-01.png")
        #expect(VaultMask.fileName("/Docs/Passport.pdf") == "Passport.pdf")
    }
}
