import Foundation
import Testing
@testable import Sync

/// Which files Read Documents opens (``VaultReadPlan``), and the account numbers it reads from
/// a household's papers under Health, Home, Vehicles and School. Every number is made up.
@Suite struct VaultReadPlanTests {
    static let docs = "/Users/anna/Documents"
    static func url(_ path: String) -> URL { URL(fileURLWithPath: docs + "/" + path) }

    static func plan(_ paths: [String], modified: [String: Date] = [:]) -> [VaultReadPlan.Step] {
        VaultReadPlan(files: paths.map(url), modified: { modified[$0.path] }).steps
    }

    static func names(_ steps: [VaultReadPlan.Step]) -> [String] {
        steps.map { String($0.file.path.dropFirst(docs.count + 1)) }
    }

    @Test func identityPapersAreReadWhole() {
        let paths = ["Immigration/Passport/Anna/scan.pdf", "Immigration/Visa/US/foil.jpg", "Legal/US/Driver License/front.pdf"]
        #expect(Self.names(Self.plan(paths)) == paths)
        #expect(Self.plan(paths).allSatisfy { $0.account == nil })
    }

    @Test func anAccountIsReadOncePerYearNewestFirst() {
        let paths = ["Home/Utilities/EBMUD/2024/Jan.pdf", "Home/Utilities/EBMUD/2024/Feb.pdf",
                     "Home/Utilities/EBMUD/2025/Mar.pdf", "Home/Utilities/EBMUD/2026/Apr.pdf"]
        let modified = [Self.url(paths[0]).path: VaultReadingTests.day(2024, 1, 20),
                        Self.url(paths[1]).path: VaultReadingTests.day(2024, 2, 20)]
        let steps = Self.plan(paths, modified: modified)
        // 2024's newest stands for it; the years newest first, all one account.
        #expect(Self.names(steps) == ["Home/Utilities/EBMUD/2026/Apr.pdf", "Home/Utilities/EBMUD/2025/Mar.pdf",
                                      "Home/Utilities/EBMUD/2024/Feb.pdf"])
        #expect(Set(steps.map(\.account)).count == 1, "a month's bill and the next month's are one account")
    }

    @Test func papersOfDifferentAccountsInOneFolderAreReadEach() {
        let june = VaultReadingTests.day(2025, 6, 1)
        let cards = ["Health/Insurance/ID Cards/Delta.pdf", "Health/Insurance/ID Cards/Kaiser.pdf",
                     "Health/Insurance/ID Cards/VSP.pdf"]
        let steps = Self.plan(cards, modified: Dictionary(uniqueKeysWithValues: cards.map { (Self.url($0).path, june) }))
        #expect(Set(Self.names(steps)) == Set(cards), "three plans' cards, one year: three accounts")
        let bills = Self.plan(["Home/Utilities/PGE 2024.pdf", "Home/Utilities/EBMUD 2024.pdf",
                               "Home/Utilities/PGE Statement 2024-03.pdf"])
        #expect(bills.count == 2, "PG&E's two bills of 2024 are one account, EBMUD's another")
        #expect(VaultReadPlan.paperName("PGE_eBill_Apr 2024") == VaultReadPlan.paperName("PGE Statement 2024-03"))
    }

    @Test func onlyFoldersBelowTheReadFolderSayWhatAPaperIs() {
        // Read from a disk mounted under "Service" and an "Archive": neither is a record folder here.
        let root = "/Volumes/Archive/Service/Documents"
        let steps = VaultReadPlan(files: [URL(fileURLWithPath: root + "/Home/Utilities/EBMUD/2025/a.pdf")], under: [root]).steps
        #expect(steps.count == 1)
        // The read folder is an area itself.
        #expect(VaultReadPlan.area(of: Self.docs + "/Health/Medical/card.pdf", under: [Self.docs + "/Health"]) == .accounts)
        // An area's own subfolder named like another area stays in its area.
        #expect(VaultReadPlan.area(of: Self.docs + "/Home/Legal/Deed.pdf", under: [Self.docs]) == .accounts)
        #expect(VaultReadPlan.area(of: Self.docs + "/Home/Legal/Deed.pdf") == .accounts, "the reader, with no read folder, agrees")
    }

    @Test func aYearComesFromTheFolderElseTheNameElseTheFileDate() {
        let steps = Self.plan(["Vehicles/Honda/Insurance/Renewal 2023.pdf", "Vehicles/Honda/Insurance/Renewal 2022.pdf",
                               "Vehicles/Honda/Insurance/Card.pdf"],
                              modified: [Self.url("Vehicles/Honda/Insurance/Card.pdf").path: VaultReadingTests.day(2021, 6, 1)])
        #expect(steps.count == 3, "three years, three papers")
    }

    @Test func recordsHomeworkAndBylawsAreNeverOpened() {
        let paths = ["Health/Medical/Anna/Test Results/2024/CBC.pdf", "Health/Medical/Anna/Visits/note.pdf",
                     "Home/HOA/CC&Rs/Master/bylaws.pdf", "School/US/Liv/Homework/math.pdf",
                     "Vehicles/Honda/Accord/Brochures/2019.pdf"]
        #expect(Self.plan(paths).isEmpty)
    }

    @Test func atSchoolOnlyPapersNamedForAStudentsNumber() {
        let steps = Self.plan(["School/US/Liv/Twin Willow/Report Card 2025.pdf", "School/US/Liv/Twin Willow/Field trip.pdf",
                               "School/US/Liv/Twin Willow/Student ID 2024.jpg", "School/US/Liv/Twin Willow/Enrollment 2023.pdf"])
        #expect(Set(Self.names(steps)) == ["School/US/Liv/Twin Willow/Report Card 2025.pdf",
                                          "School/US/Liv/Twin Willow/Student ID 2024.jpg",
                                          "School/US/Liv/Twin Willow/Enrollment 2023.pdf"])
    }

    @Test func elsewhereOnlyFilesNamedAsAnID() {
        let paths = ["Travel/Trips/India/Passport copy.pdf", "Travel/Trips/India/Itinerary.pdf",
                     "Finance/US/Chase/2025/Statement.pdf", "Work/Visa letter.pdf", "Scans/DL back.jpg"]
        #expect(Self.names(Self.plan(paths)) == ["Travel/Trips/India/Passport copy.pdf", "Work/Visa letter.pdf", "Scans/DL back.jpg"])
    }
}

@Suite struct VaultAccountReadingTests {
    static func read(_ lines: [String], at path: String) -> [VaultFind] {
        VaultReading.finds(in: lines, from: "/Users/anna/Documents/" + path)
    }

    /// VT53: a mortgage's number an insurance cover sheet labels "Account Number" (Other) and its
    /// next page "Loan Number" (Loans) is a loan number, whichever page comes first, and across
    /// two files as within one. Other is no kind. Every number is made up.
    @Test func aNumberReadAsOtherAndAsALoanIsALoan() throws {
        let path = "/Users/anna/Documents/Home/Insurance/2025/cover.pdf"
        let cover = ["Insurance cover sheet", "Account Number: 0123456789"]
        let statement = ["Mortgage statement", "Loan Number: 0123456789"]
        for pages in [[cover, statement], [statement, cover]] {
            let finds = VaultReading.read(pages: pages, from: path).finds
            #expect(finds.count == 1)
            #expect(finds.first?.category == .loans)
            #expect(finds.first?.title.hasSuffix("Loan number") == true)
        }
        let other = try #require(VaultReading.read(pages: [cover], from: path).finds.first)
        let loan = try #require(VaultReading.read(pages: [statement], from: "/Users/anna/Documents/Home/Mortgage/2025/Apr.pdf").finds.first)
        #expect(other.category == .other && loan.category == .loans)
        for copies in [[other, loan], [loan, other]] {
            let merged = try #require(VaultCopies.merged(copies))
            // The cover speaks (by name), so the rule, not the order, makes it a loan.
            #expect(merged.facts.spokenBy == path)
            #expect(merged.facts.category == .loans)
            // Named by who issued it, as its details say, and by the kind's name.
            #expect(merged.title == "Insurance · Loan number")
            #expect(merged.facts.form == "Loan number")
        }
        // Never an identity kind: an account number a page quotes as an SSN stays Other.
        var quoted = loan
        quoted.facts.category = .ssn
        #expect(VaultCopies.merged([other, quoted])?.facts.category == .other)
        // Nor when an identity kind is among them: a loan and an SSN are two kinds that disagree.
        #expect(VaultCopies.merged([other, loan, quoted])?.facts.category == .other)
        // A cover with no issuer read is titled by the kind's name alone, as its paper would be.
        var bare = other
        bare.facts.details = []
        bare.facts.dated = VaultReadingTests.day(2025, 4, 1)
        let titled = try #require(VaultCopies.merged([bare, loan]))
        #expect(titled.facts.spokenBy == path && titled.title == "Loan number")
        // Two kinds that disagree: the reading that speaks keeps its own. Dated, the cover speaks.
        var dated = other
        dated.facts.dated = VaultReadingTests.day(2025, 4, 1)
        var utility = loan
        utility.facts.category = .utilities
        #expect(VaultCopies.merged([dated, loan])?.facts.spokenBy == path)
        #expect(VaultCopies.merged([dated, loan])?.facts.category == .loans)
        #expect(VaultCopies.merged([dated, loan, utility])?.facts.category == .other)
    }

    @Test func aUtilityBillsAccountNumberIsFiledByItsFolder() throws {
        let bill = ["Your monthly statement", "Account Number: 1234 5678 9012", "Amount Due $86.20",
                    "Customer service (510) 555-0142"]
        let find = try #require(Self.read(bill, at: "Home/Utilities/EBMUD/2025/Mar.pdf").first)
        #expect(find.value == "1234 5678 9012")
        #expect(find.title == "EBMUD · Account number")
        #expect(find.category == .utilities)
        #expect(find.facts.form == "Account number")
        #expect(find.facts.dated == VaultReadingTests.day(2025, 1, 1))
        // The same page anywhere else is not an account: an account number on a petition is a bank's.
        #expect(Self.read(bill, at: "Immigration/H-1B/2025/Petition.pdf").isEmpty)
        #expect(Self.read(bill, at: "Finance/US/2025/Statement.pdf").isEmpty)
    }

    /// A label in a header row reads the value in its own column of the line under it, never the
    /// first one on that line (the second review: the pharmacy's BIN was read as the Member ID).
    @Test func aHeaderRowsLabelReadsItsOwnColumn() throws {
        let card = ["Delta Dental", "RxBIN    Member ID", "610014    XZB123456789"]
        let finds = Self.read(card, at: "Health/Dental/ID Cards/card.pdf")
        #expect(finds.map(\.value) == ["XZB123456789"])
        // A label at the line's start still reads the first value under it.
        let first = ["Delta Dental", "Member ID    RxBIN", "XZB123456789    610014"]
        #expect(Self.read(first, at: "Health/Dental/ID Cards/card.pdf").map(\.value) == ["XZB123456789"])
    }

    /// A label whose cell starts with another word ("Your Account Number") reads that cell's
    /// column, never one past it (the third review: the read crashed on the first page, and lost
    /// the number on the second).
    @Test func aHeaderRowsLabelAfterAWordOfItsOwnCellReadsThatCell() throws {
        let last = ["Pacific Water", "Statement Date    Your Account Number", "01/15/2026    1234-5678-90"]
        #expect(Self.read(last, at: "Home/Utilities/Pacific Water/2026/Bill.pdf").map(\.value) == ["1234-5678-90"])
        let first = ["Pacific Water", "Your Account Number    Bill Date    Amount Due", "1234-5678-90    01/15/2026    $45.00"]
        #expect(Self.read(first, at: "Home/Utilities/Pacific Water/2026/Bill.pdf").map(\.value) == ["1234-5678-90"])
        let line = "Statement Date    Your Account Number"
        #expect(PrintedPage.column(of: try #require(line.range(of: "Account")).lowerBound, in: line) == 1)
        #expect(PrintedPage.column(of: try #require(line.range(of: "Statement")).lowerBound, in: line) == 0)
    }

    @Test func aHealthCardsMemberIDHasItsGroupAndHolder() throws {
        let card = ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789", "Group Number: 0012345"]
        let finds = Self.read(card, at: "Health/Dental/ID Cards/card.pdf")
        let find = try #require(finds.first)
        #expect(finds.count == 1, "the plan's group number is a detail, never a number of its own")
        #expect(find.value == "XZB123456789")
        #expect(find.category == .health)
        #expect(find.holder == "Anna Eriksson")
        #expect(find.facts.details.first { $0.label == "Group number" }?.value == .number("0012345"))
        #expect(find.title == "Dental · Member ID")
        #expect(find.facts.primary?.role == "ID card")
    }

    @Test func aNumberPrintedAsTheSubscribersBesideAnotherNameIsMarked() throws {
        let at = "Health/Dental/ID Cards/card.pdf"
        let dependent = try #require(Self.read(["Subscriber Name: ANNA ERIKSSON", "Member Name: LIV ERIKSSON",
                                                "Subscriber ID: XZB123456789"], at: at).first)
        #expect(dependent.holder == "Liv Eriksson" && dependent.facts.printedForSubscriber == true)
        let subscriber = try #require(Self.read(["Subscriber Name: ANNA ERIKSSON", "Subscriber ID: XZB123456789"],
                                                at: at).first)
        #expect(subscriber.facts.printedForSubscriber == nil, "the name is the subscriber's own")
        let member = try #require(Self.read(["Member Name: LIV ERIKSSON", "Member ID: XZB123456789"], at: at).first)
        #expect(member.facts.printedForSubscriber == nil)
        // Both labels on one line: the Member ID's, which comes first.
        let both = try #require(Self.read(["Member Name: LIV ERIKSSON", "Subscriber / Member ID: XZB123456789"],
                                          at: at).first)
        #expect(both.facts.printedForSubscriber == nil)
    }

    @Test func aLoanAPolicyAndAStudentIDGoOnTheirCards() throws {
        let loan = try #require(Self.read(["Mortgage statement", "Loan Number: 0123456789"],
                                          at: "Home/Mortgage/Statements/2025/Apr.pdf").first)
        #expect(loan.category == .loans)
        #expect(loan.title == "Mortgage · Loan number")
        let policy = try #require(Self.read(["Declarations", "Policy Number: CA-123-4567-89"],
                                            at: "Vehicles/Honda/Insurance/2025/Renewal.pdf").first)
        #expect(policy.category == .other)
        #expect(policy.value == "CA-123-4567-89")
        #expect(policy.title == "Honda · Policy number")
        // Columns read as one line: the policy's number, then its effective date.
        let row = ["Policy Number: 12345-67-89 01-01-2022"]
        #expect(Self.read(row, at: "Home/HOA/Coverage/2022/limits.pdf").first?.value == "12345-67-89")
        let student = try #require(Self.read(["Twin Willow Elementary", "Student ID: 2045871"],
                                             at: "School/US/Liv/Twin Willow/Report Card 2025.pdf").first)
        #expect(student.facts.form == "Student ID")
        #expect(student.title == "Twin Willow · Student ID")
    }

    /// VT91: an Indian school's or university's "Enrolment No" over fourteen or sixteen digits of
    /// its own is the student's number, never UIDAI's enrolment number: the page is no Aadhaar
    /// letter, so a twelve-digit number it prints elsewhere is no Aadhaar. Every number is made up.
    @Test func anIndianSchoolsEnrolmentNumberIsTheStudentsID() throws {
        let at = "School/IN/Lotus Vidyalaya/Anna/Enrolment 2024.pdf"
        // A twelve-digit roll number that passes Verhoeff, as one in ten does.
        let roll = "Roll " + VaultIDReadingTests.spaced(VaultIDReadingTests.aadhaar("23456789012"))
        let labelled = try #require(Self.read(["Lotus Vidyalaya", "Student ID: 31415926535897"], at: at).first)
        for (label, value) in [("Enrolment No.: ", "31415926535897"), ("Enrollment No: ", "31415926535897"),
                               ("Enrolment Number: ", "2718281828459045"), ("Enrollment Number - ", "2718281828459045"),
                               ("Enrolment No.: ", "2718 2818 2845 9045")] {
            let finds = Self.read(["Lotus Vidyalaya", "Name of Student: Anna Eriksson", label + value, roll], at: at)
            #expect(finds.map(\.value) == [value], "\(label)\(value.count)")
            #expect(finds.first?.facts.form == "Student ID", "\(label)\(value.count)")
            #expect(finds.first?.category == labelled.category, "\(label)\(value.count)")
            #expect(finds.first?.title == labelled.title, "\(label)\(value.count)")
        }
        // The label over its number, on the line below.
        let below = Self.read(["Lotus Vidyalaya", "Enrolment No.", "31415926535897", roll], at: at)
        #expect(below.map(\.value) == ["31415926535897"])
        // Outside School an enrollment number is a plan's, not a student's.
        #expect(Self.read(["Enrollment No: 31415926535897"], at: "Health/Kaiser/Anna/ID Cards/card.pdf").isEmpty)
    }

    /// VT91's other side: a child's Aadhaar letter filed under School is still the letter, and its
    /// enrolment number, its slashes read or lost, is no student's.
    @Test func anAadhaarLetterFiledUnderSchoolIsStillTheLetter() throws {
        let at = "School/IN/Lotus Vidyalaya/Anna/Admission 2024.pdf"
        let number = VaultIDReadingTests.aadhaar("23456789012")
        for enrolment in ["Enrolment No.: 1234/12345/12345", "Enrolment No.: 12341234512345"] {
            let finds = Self.read(["Unique Identification Authority of India", enrolment, "To", "Anna Eriksson",
                                   VaultIDReadingTests.spaced(number)], at: at)
            #expect(finds.map(\.value) == [number], "\(enrolment.count)")
            #expect(finds.first?.facts.primary?.rank == VaultReading.IDRank.card, "\(enrolment.count)")
        }
    }

    @Test func aVINCountsOnlyWhenItsCheckDigitAgrees() throws {
        // The check-digit example every VIN decoder uses: a 2003 Honda Accord.
        #expect(VaultReading.isVIN("1HGCM82633A004352"))
        #expect(!VaultReading.isVIN("1HGCM82633A004353"), "one character misread")
        #expect(!VaultReading.isVIN("1HGCM8263OA004352"), "an O is never in a VIN")
        let page = ["Registration Card", "Vehicle Identification Number: 1HGCM82633A004352"]
        let vin = try #require(Self.read(page, at: "Vehicles/Honda/Accord/Registration/2025.pdf").first)
        #expect(vin.facts.form == "VIN")
        #expect(vin.title == "Accord · VIN")
        let misread = ["Vehicle Identification Number: 1HGCM82633A004353"]
        #expect(Self.read(misread, at: "Vehicles/Honda/Accord/Registration/2025.pdf").isEmpty)
        // A registration's row runs on into the model year: the VIN is still read.
        let row = ["VIN 1HGCM82633A004352 2003 HONDA"]
        #expect(Self.read(row, at: "Vehicles/Honda/Accord/Registration/2025.pdf").first?.value == "1HGCM82633A004352")
    }

    @Test func whoIssuedItIsTheFolderNotAPaperOrAYear() {
        let root = "/Users/anna/Documents/"
        #expect(VaultReading.accountIssuer(root + "Home/Utilities/EBMUD/2024/a.pdf") == "EBMUD")
        #expect(VaultReading.accountIssuer(root + "Health/Medical/Insurance/ID Cards/a.pdf") == "Medical")
        #expect(VaultReading.accountIssuer(root + "Health/Medical/Visitor Insurance/2023 - Erik/a.pdf") == "Visitor Insurance")
        #expect(VaultReading.accountIssuer(root + "School/US/Liv/Twin Willow/TODO/a.pdf") == "Twin Willow")
        #expect(VaultReading.accountIssuer(root + "Home/Insurance/Policy/a.pdf") == "Insurance")
        #expect(VaultReading.accountIssuer(root + "Vehicles/a.pdf") == nil)
        // A person's folder says whose the card is, never who issued it.
        let people = [Person(id: "sigrid", displayName: "Sigrid"), Person(id: "liv", displayName: "Liv")]
        #expect(VaultReading.accountIssuer(root + "Health/Medical/Sigrid/ID Cards/a.pdf", people: people) == "Medical")
        #expect(VaultReading.accountIssuer(root + "School/US/Twin Willow/Liv/a.pdf", people: people) == "Twin Willow")
        #expect(VaultReading.accountIssuer(root + "Health/Sigrid/a.pdf", people: people) == nil)
    }

    @Test func theHolderIsReadOnlyBesideALabelForAPerson() {
        let card = ["Kaiser Permanente", "Plan Name: Kaiser Permanente", "Member Services Toll Free", "Member ID: 12345678"]
        let find = Self.read(card, at: "Health/Medical/ID Cards/card.pdf").first
        #expect(find?.value == "12345678")
        #expect(find?.holder == nil, "a plan's name or a phone line's heading is nobody")
    }

    @Test func aLabelWithNoNumberDoesNotEndTheSearch() {
        let bill = ["Please write your account number on your check", "Account Number: 1234567890"]
        #expect(Self.read(bill, at: "Home/Utilities/EBMUD/2025/bill.pdf").map(\.value) == ["1234567890"])
        let card = ["Member ID Card", "Member ID: XZB123456789"]
        #expect(Self.read(card, at: "Health/Dental/ID Cards/card.pdf").map(\.value) == ["XZB123456789"])
        // A label beside something that looks like a number and is not: the search goes on.
        let opened = ["Account Number: 01-15-2025 opened", "Account Number: 1234567890"]
        #expect(Self.read(opened, at: "Home/Utilities/EBMUD/2025/bill.pdf").map(\.value) == ["1234567890"])
        // Words after a label are never part of a number.
        let sentence = ["Your account number is 987654"]
        #expect(Self.read(sentence, at: "Home/Utilities/EBMUD/2025/bill.pdf").allSatisfy { $0.value.first?.isNumber == true })
    }

    @Test func aBareNumberIsOnlyACandidateOnAStatement() {
        let header = ["Jan 15, 2026", "123456789", "1 of 3", "$84.20", "94566-1234", "(510) 555-0142"]
        #expect(VaultReading.bareAccountNumbers(on: PrintedPage(header), from: "/Users/anna/Documents/Home/Utilities/T-Mobile/2026/Jan.pdf")
                == ["123456789"])
        #expect(VaultReading.bareAccountNumbers(on: PrintedPage(header), from: "/Users/anna/Documents/Vehicles/Honda/Registration/2026.pdf")
                .isEmpty, "a registration repeats other numbers year to year")
    }

    @Test func aMaskedNumberADateOrAPhoneIsNotAnAccount() {
        let bill = "Home/Utilities/PG&E/2025/bill.pdf"
        // Each long enough, with digits enough, to reach the check it is here for.
        for masked in ["XXXXXX12345", "****12345", "Account No: ****12345"] {
            #expect(Self.read(["Account Number: " + masked], at: bill).isEmpty, "\(masked)")
        }
        for date in ["01-15-2025", "03-04-2025", "2025-01-02"] {
            #expect(Self.read(["Account Number: " + date], at: bill).isEmpty, "\(date)")
        }
        for phone in ["510-555-0142", "1-800-743-5000", "1 800 743 5000", "800 743 5000", "800.743.5000"] {
            #expect(Self.read(["Customer Number: " + phone], at: bill).isEmpty, "\(phone)")
        }
        #expect(VaultReading.accountNumber("94566 1234") == nil, "a ZIP+4")
        #expect(VaultReading.accountNumber("12-34-5678") == "12-34-5678", "no date has a 34th month or day")
        // A number runs to its last group with a digit, never into the next word.
        #expect(Self.read(["Account Number: 12345 Due 02/01/2025"], at: "Home/Utilities/PG&E/2025/bill.pdf").first?.value == "12345")
    }

    @Test func aNumberStopsBeforeWhatIsPrintedAfterIt() {
        // A word that holds a digit is the next thing on the line, not more of the number.
        #expect(Self.read(["Twin Willow Elementary", "Student ID: 123456 5th Grade"],
                          at: "School/US/Liv/Twin Willow/Report Card 2025.pdf").first?.value == "123456")
        // One or two digits before a word are a count of it: a loan's term, a policy's months.
        let after = ["0123456789 30 Year Fixed": "0123456789", "0123-456789 30 Year Fixed": "0123-456789",
                     "12345 30 Year Fixed": "12345", "4123-45-67-89 6 Month Policy": "4123-45-67-89",
                     // A date either way round, an amount, a phone number.
                     "12345-67-89 2022-01-01": "12345-67-89", "12345 1,234.56": "12345", "98765 510-555-0142": "98765"]
        for (printed, number) in after {
            #expect(Self.read(["Mortgage statement", "Loan Number: " + printed], at: "Home/Mortgage/Statements/2025/Apr.pdf")
                .first?.value == number, "\(printed.count)")
        }
        // The same, as papers more often print them: the count tied to its word by a dash, a
        // date with its month spelled or its slashes spaced, a toll-free number, a rate.
        let tied = ["0123456789 30-Year Fixed", "0123456789 15-yr ARM", "0123456789 2-year agreement",
                    "0123456789 05-Jan-2025", "0123456789 05/JAN/2025", "0123456789 01 / 02 / 2025",
                    "0123456789 1-800-555-0142", "0123456789 1 (800) 555-0142", "0123456789 (510) 555-0142",
                    "0123456789 800 555-0142", "0123456789 5% fixed"]
        for printed in tied {
            #expect(Self.read(["Mortgage statement", "Loan Number: " + printed], at: "Home/Mortgage/Statements/2025/Apr.pdf")
                .first?.value == "0123456789", "\(printed.dropFirst(11))")
        }
        #expect(Self.read(["Mortgage statement", "Loan Number  Loan Type", "0123456789 30-Year Fixed"],
                          at: "Home/Mortgage/Statements/2025/Apr.pdf").first?.value == "0123456789")
        #expect(Self.read(["Twin Willow Elementary", "Student ID: 123456 5-A"],
                          at: "School/US/Liv/Twin Willow/Report Card 2025.pdf").first?.value == "123456")
        // A number printed in groups, by spaces or dashes, is still read to its last group.
        for whole in ["1234 5678 9012", "XZB-45-1234", "CA-123-4567-89", "8155 60 012 3456789"] {
            #expect(Self.read(["Account Number: " + whole + " Due 02/01/2025"], at: "Home/Utilities/Cable/2025/bill.pdf")
                .first?.value == whole, "\(whole.count)")
        }
    }

    @Test func aNumberWithASpaceInItIsNotCutShort() {
        // However long its first group: a scan puts a space into a long run, and a plan prints a
        // member's suffix after one.
        for whole in ["123456 789012", "1234567 8901234", "XZB123 456789", "123456789 01"] {
            #expect(Self.read(["Account Number: " + whole], at: "Home/Utilities/Cable/2025/bill.pdf").first?.value == whole,
                    "\(whole.count)")
        }
        // A group in the middle may hold a letter, as an insurer's policy number does: cut at it,
        // the first two groups passed for the whole number. An ordinal is still the next word.
        #expect(Self.read(["Auto policy declarations", "Policy Number: 01234 56 78U 7101 2"],
                          at: "Vehicles/Insurance/2025/Declarations.pdf").first?.value == "01234 56 78U 7101 2")
        #expect(Self.read(["Twin Willow Elementary", "Student ID: 123456 5th 2025"],
                          at: "School/US/Liv/Twin Willow/Report Card 2025.pdf").first?.value == "123456")
        // Four digits and two pairs are a date only when they could be one.
        #expect(Self.read(["Auto policy declarations", "Policy Number: 12 3456-78-90"],
                          at: "Vehicles/Insurance/2025/Declarations.pdf").first?.value == "12 3456-78-90")
        // A VIN is checked by its own check digit, so a space anywhere in it costs nothing.
        for printed in ["1HGCM82633 A004352", "1HGCM 82633A 004352", "1HG CM82633A004352", "1HGCM-82633A-004352"] {
            #expect(Self.read(["VIN: " + printed], at: "Vehicles/Honda/Accord/Registration/2025.pdf").first?.value
                    == "1HGCM82633A004352", "\(printed.count)")
        }
        #expect(Self.read(["Vehicle Identification Number", "1HGCM82633 A004352"],
                          at: "Vehicles/Honda/Accord/Registration/2025.pdf").first?.value == "1HGCM82633A004352")
    }

    @Test func aNumberIsSevenGroupsAtMost() {
        // The eighth is left off; a seventh holding a letter is kept, the digits after it are not.
        #expect(VaultAccountValue.leading("1234 5678 9012 3456 7890 1234 5678 9012") == "1234 5678 9012 3456 7890 1234 5678")
        #expect(VaultAccountValue.leading("1 2 3 4 5 6 7A 8") == "1 2 3 4 5 6 7A")
        #expect(VaultAccountValue.leading("1 2 3 4 5 6 7A") == "1 2 3 4 5 6")
        // A last group holding a letter is left off: a plan's name, a rate, a term, a date.
        for (printed, number) in ["1234 5678 A1": "1234 5678", "1234 5678 5G Home": "1234 5678", "1234567890 E1": "1234567890",
                                  "0123456789 30Y": "0123456789", "1234567890 12JAN2025": "1234567890"] {
            #expect(VaultAccountValue.leading(printed) == number, "\(printed.count)")
        }
    }

    @Test func oneOrTwoDigitsBeforeAWordAreASuffixOrTheLastGroupOnlyWhenTheyCannotCountIt() {
        // A prefix of letters is no group, and a lettered group cannot vouch for the digits that
        // vouch for it: the next column's street number still ends these.
        #expect(VaultAccountValue.leading("CA-1234567 12 Main St") == "CA-1234567")
        #expect(VaultAccountValue.leading("1234567890 E1 12 Main St") == "1234567890")
        #expect(VaultAccountValue.leading("1234 56A 78 Due") == "1234")
        #expect(VaultAccountValue.leading("XZB-45-1234 90 Due") == "XZB-45-1234 90")
        // A member's suffix before a name, a last pair of a number already in groups: its own.
        #expect(Self.read(["Account Number: 1234 5678 90 Due 02/01/2025"], at: "Home/Utilities/Cable/2025/bill.pdf")
            .first?.value == "1234 5678 90")
        #expect(Self.read(["Member ID: 123456789 01 ANNA"], at: "Health/Delta Dental/2025/Card.pdf").first?.value
                == "123456789 01")
        // A count of what follows, spelled or short, a date's day before its month, a page count,
        // a time, and the next column's street number.
        for printed in ["0123456789 30 Year Fixed", "0123456789 15 yrs", "0123456789 6 MONTH POLICY",
                        "0123456789 12 mos", "0123456789 05 Jan 2025", "0123456789 5 september 2025",
                        "0123456789 30-Day Notice", "0123456789 5/A", "0123456789 1 of 3", "0123456789 01 of 03",
                        "0123456789 10 AM", "0123456789 2 Lines", "0123456789 30 kWh", "0123456789 12 Main St"] {
            #expect(Self.read(["Mortgage statement", "Loan Number: " + printed], at: "Home/Mortgage/Statements/2025/Apr.pdf")
                .first?.value == "0123456789", "\(printed.dropFirst(11))")
        }
    }

    @Test func groupsThatOnlyLookLikeAPhoneNumberAreAnAccount() {
        #expect(Self.read(["Account Number: 123456 7890"], at: "Home/Utilities/Cable/2025/bill.pdf").first?.value
                == "123456 7890")
        #expect(Self.read(["Account Number: 1234567 8901"], at: "Home/Utilities/Cable/2025/bill.pdf").first?.value
                == "1234567 8901")
        // A phone number with its area code set apart is still none.
        for phone in ["510-555-0142", "(510) 555-0142", "(510)555-0142", "510 555 0142", "1-800-555-0142",
                      "1 800 555 0142", "1.800.555.0142"] {
            #expect(VaultReading.accountNumber(phone) == nil, "\(phone)")
        }
    }

    @Test func anotherCharactersDashOrSpaceIsReadAsOne() {
        for (printed, number) in ["1234\u{2013}5678\u{2013}9012": "1234-5678-9012", "1234\u{2011}5678": "1234-5678",
                                  "1234\u{2212}5678": "1234-5678", "1234\u{00A0}5678\u{00A0}9012": "1234 5678 9012",
                                  "1234\u{202F}5678": "1234 5678", "1234\u{2009}5678": "1234 5678"] {
            #expect(Self.read(["Account Number: " + printed], at: "Home/Utilities/Cable/2025/bill.pdf").first?.value
                    == number, "\(printed.unicodeScalars.count)")
        }
        // An em dash parts words: the number ends before it.
        #expect(VaultAccountValue.leading("12345\u{2014}67") == "12345")
        // A no-break space between the label and the number is passed over like any other.
        for printed in ["Account Number:\u{00A0}12345678", "Account Number\u{00A0}: 12345678"] {
            #expect(Self.read([printed], at: "Home/Utilities/Cable/2025/bill.pdf").first?.value == "12345678")
        }
    }

    @Test func aRowsBirthDateIsTheDateAfterItsNumberThoughThatHasAnEnDash() {
        // The number reads with an ASCII dash; the date after it, not the one before, is the birth.
        let page = PrintedPage(["DOB 03/04/1992 Member ID 1234\u{2013}5678 DOB 01/02/1990"])
        let rows = page.values(["member id"], VaultAccountValue.leading)
        #expect(rows.first?.value == "1234-5678")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let born = rows.first.flatMap { VaultReading.birthDate(of: $0, on: page) }
        #expect(born.map { calendar.dateComponents([.year, .month, .day], from: $0) }
                == DateComponents(year: 1990, month: 1, day: 2))
    }

    @Test func aPhoneAloneOnALineIsNoBareNumberThoughAScanDroppedItsDash() {
        let header = ["Statement date 01/05/2026", "510555 0142", "Page 1 of 3"]
        #expect(VaultReading.bareAccountNumbers(on: PrintedPage(header),
                                                from: "/Users/anna/Documents/Home/Utilities/T-Mobile/2026/Jan.pdf").isEmpty)
    }

    @Test func aPrefixOfLettersIsFourAtMostAndDashed() {
        #expect(VaultAccountValue.leading("ABCD-12") == "ABCD-12")
        #expect(VaultAccountValue.leading("ABCDE-12") == nil)
        #expect(VaultAccountValue.leading("Due 12345") == nil)
    }

    @Test func theReadersLettersAreTheCaseBlindPatternsOnes() {
        // ſ and K (Kelvin) count as letters, so a run holding one goes on; ſ folds to s, so "5ſt" is
        // an ordinal.
        #expect(VaultAccountValue.leading("12\u{17F}4 5678") == "12\u{17F}4 5678")
        #expect(VaultAccountValue.leading("12\u{212A}4 5678") == "12\u{212A}4 5678")
        #expect(VaultAccountValue.leading("123456 5\u{17F}t 2025") == "123456")
        #expect(VaultAccountValue.leading("12é4 5678") == "12")
    }
}

/// Read Documents carries on when the panel closes, and lets the numbers go when it ends.
@MainActor
@Suite struct VaultBackgroundReadTests {
    typealias Rig = VaultModelTests.Rig

    /// A read that closes the panel as it opens its first file, or as it walks the folders.
    struct ClosingDocuments: VaultDocumentReading {
        let pages: [String: [String]]
        let opened = VaultFakeDocuments.OpenedFiles()
        let onFirst: @MainActor @Sendable () async -> Void
        var onWalk: @MainActor @Sendable () async -> Void = {}
        func files() async -> [URL] {
            await onWalk()
            return pages.keys.sorted().map { URL(fileURLWithPath: $0) }
        }
        func pages(in file: URL) async -> [[String]] {
            if opened.all.isEmpty { await onFirst() }
            opened.add(file.path)
            return pages[file.path].map { [$0] } ?? []
        }
        func stamp(of file: URL) -> String? { "1" }
    }

    @Test func aReadGoesOnWithThePanelClosedAndItsNumbersGoWhenItEnds() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        let front = VaultFixtures.front(expiring: "05/16/2030")
        let other = ["California USA DRIVER LICENSE", "DL D7654321", "LN ERIKSSON", "FN ERIK", "EXP 01/02/2031"]
        let documents = ClosingDocuments(pages: ["/r/a.pdf": front, "/r/b.pdf": other], onFirst: { model.closed() })
        await model.readDocuments(with: documents)
        #expect(documents.opened.all == ["/r/a.pdf", "/r/b.pdf"], "closing the panel stopped the read")
        #expect(model.entries.isEmpty && model.finds.isEmpty, "a closed, locked Vault held its numbers after the read")
        // What it read was sealed: the next open has both waiting.
        await model.opened()
        #expect(Set(model.finds.map(\.value)) == ["D1234567", "D7654321"])
    }

    @Test func reopenedAndStillLockedTheReadEndsWithNothingHeldAndWhatItReadSealed() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        let documents = ClosingDocuments(pages: ["/r/a.pdf": VaultFixtures.front(expiring: "05/16/2030"),
                                                 "/r/b.pdf": VaultFixtures.licensePage],
                                         onFirst: { model.closed(); rig.auth.answer = .cancelled; await model.opened() })
        await model.readDocuments(with: documents)
        // Reopened, and the proof was cancelled: the panel shows only its lock, so the read ends
        // with nothing held, as it would have with the panel closed. What it read is sealed.
        #expect(model.isSealedShut)
        #expect(model.entries.isEmpty && model.finds.isEmpty, "a locked panel held its IDs after the read")
        rig.auth.answer = .allowed
        #expect(await model.unlock())
        #expect(!model.entries.isEmpty && !model.finds.isEmpty, "one proof later, the saved ID and what was read are there")
    }

    @Test func theMacLockingStopsTheRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        // Locked, then opened again before the read noticed: it still stops, reads nothing more,
        // and adds nothing from the page it had in hand.
        let documents = ClosingDocuments(pages: ["/r/a.pdf": VaultFixtures.front(expiring: "05/16/2030"),
                                                 "/r/b.pdf": VaultFixtures.licensePage],
                                         onFirst: { model.systemLocked(); await model.opened() })
        model.startReading(with: documents)
        let task = try #require(model.readingTask)
        await task.value
        #expect(documents.opened.all == ["/r/a.pdf"], "the read went on after the Mac locked")
        #expect(model.finds.isEmpty, "a stopped read added what it read after the lock")
    }

    @Test func aReadStoppedAsTheVaultClosesLetsTheNumbersGo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        // The Mac locks; the Vault is opened again, not unlocked, and closed while the stopped
        // read is still winding down.
        let documents = ClosingDocuments(pages: ["/r/a.pdf": VaultFixtures.front(expiring: "05/16/2030")], onFirst: {
            model.systemLocked()
            rig.auth.answer = .cancelled
            await model.opened()
            model.closed()
        })
        model.startReading(with: documents)
        let task = try #require(model.readingTask)
        await task.value
        #expect(model.entries.isEmpty && model.finds.isEmpty, "a closed, locked Vault held its numbers")
    }

    @Test func aLockDuringTheWalkKeepsWhatWasReadBefore() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: ClosingDocuments(pages: ["/r/a.pdf": VaultFixtures.licensePage], onFirst: {}))
        #expect(model.finds.count == 1)
        // The next read: the Mac locks while it walks the folders, and the walk finds nothing.
        var walking = ClosingDocuments(pages: [:], onFirst: {})
        walking.onWalk = { model.systemLocked() }
        await model.readDocuments(with: walking)
        await model.opened()
        #expect(model.finds.count == 1, "the stopped read sealed an empty Vault over what was read")
    }

    @Test func aReadStoppedBeforeItBeganLoadsNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        let documents = ClosingDocuments(pages: ["/r/a.pdf": VaultFixtures.licensePage], onFirst: {})
        model.startReading(with: documents)
        let task = try #require(model.readingTask)
        model.systemLocked()
        await task.value
        #expect(model.entries.isEmpty, "the stopped read loaded the numbers back")
        #expect(documents.opened.all.isEmpty)
    }
}

/// The lock counts idle time only: any use of the panel starts it again.
@MainActor
@Suite struct VaultIdleLockTests {
    typealias Rig = VaultModelTests.Rig

    @Test func usingThePanelKeepsItOpenAndLeavingItAloneLocksIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        #expect(model.isOpen)
        #expect(VaultLockSettings(defaults: rig.defaults).relock == .afterOneMinute, "one idle minute is the default")
        // Five minutes of use, a pointer moving or a click every 40 seconds.
        for _ in 0..<8 {
            rig.clock.advance(40)
            model.panelActivity()
            model.tick()
            #expect(model.isOpen, "it locked while in use")
        }
        rig.clock.advance(61)
        model.tick()
        #expect(!model.isOpen, "left alone a minute, it locks")
    }

    @Test func activityNeverKeepsAShownNumberUpUnderEveryNumber() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        #expect(await model.show(VaultModelTests.passport.id))
        rig.clock.advance(20); model.panelActivity()
        rig.clock.advance(15); model.tick()
        #expect(!model.canShow(VaultModelTests.passport), "a number's thirty seconds are its own")
    }
}

@MainActor
@Suite struct VaultAccountModelTests {
    typealias Rig = VaultModelTests.Rig

    /// Pages by path, as a planned read opens them.
    struct PlannedDocuments: VaultDocumentReading {
        let pages: [String: [String]]
        let opened = VaultFakeDocuments.OpenedFiles()
        func files() async -> [URL] { pages.keys.sorted().map { URL(fileURLWithPath: $0) } }
        func pages(in file: URL) async -> [[String]] {
            opened.add(file.path)
            return pages[file.path].map { [$0] } ?? []
        }
        func stamp(of file: URL) -> String? { "1" }
        func modified(of file: URL) -> Date? { nil }
        var followsReadPlan: Bool { true }
    }

    static let root = "/Users/anna/Documents"

    @Test func anAccountIsReadNoFurtherOnceTwoYearsAgree() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let bill = ["Account Number: 1234 5678 9012"]
        let ebmud = Self.root + "/Home/Utilities/EBMUD"
        let documents = PlannedDocuments(pages: [ebmud + "/2026/a.pdf": bill, ebmud + "/2025/a.pdf": bill,
                                                 ebmud + "/2024/a.pdf": bill, ebmud + "/2023/a.pdf": bill])
        await model.readDocuments(with: documents)
        #expect(documents.opened.all == [ebmud + "/2026/a.pdf", ebmud + "/2025/a.pdf"], "older years were opened")
        let row = try #require(model.rows.first)
        #expect(row.isHousehold, "a utility read with no person is the household's")
        // A number that changed: the older years are read until two agree again.
        let moved = PlannedDocuments(pages: [ebmud + "/2026/a.pdf": ["Account Number: 9999 8888 7777"],
                                             ebmud + "/2025/a.pdf": bill, ebmud + "/2024/a.pdf": bill,
                                             ebmud + "/2023/a.pdf": bill])
        await model.readDocuments(with: moved, again: true)
        #expect(moved.opened.all == [ebmud + "/2026/a.pdf", ebmud + "/2025/a.pdf", ebmud + "/2024/a.pdf"])
    }

    @Test func aNumberPrintedWithoutALabelCountsWhenTwoYearsPrintIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let phone = Self.root + "/Home/Utilities/T-Mobile"
        // The header as a phone bill prints it: date, account number, page. The invoice number changes.
        func bill(_ invoice: String) -> [String] { ["Jan 15, 2026", "123456789", "1 of 3", "Invoice", invoice] }
        let documents = PlannedDocuments(pages: [phone + "/2026/Jan.pdf": bill("700000001"), phone + "/2025/Jan.pdf": bill("700000002"),
                                                 phone + "/2024/Jan.pdf": bill("700000003")])
        await model.readDocuments(with: documents)
        #expect(model.finds.map(\.value) == ["123456789"], "only the number both years print")
        #expect(model.finds.first?.facts.sources.count == 2)
        #expect(documents.opened.all.count == 2, "settled once two years agreed")
        #expect(model.lastReading?.newNumbers == 1, "counted in the read's summary")
    }

    @Test func twoUnlabelledNumbersBothYearsPrintAreNeitherTaken() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let phone = Self.root + "/Home/Utilities/T-Mobile"
        let bill = ["Jan 15, 2026", "123456789", "1 of 3", "Fax", "5551234567890"]
        await model.readDocuments(with: PlannedDocuments(pages: [phone + "/2026/Jan.pdf": bill, phone + "/2025/Jan.pdf": bill]))
        #expect(model.finds.isEmpty, "two candidates: neither is guessed at")
    }

    @Test func areasAreTheFolderJustBelowTheReadFolder() {
        let root = Self.root
        #expect(VaultReadPlan.area(of: root + "/Home/Utilities/EBMUD/a.pdf", under: [root]) == .accounts)
        #expect(VaultReadPlan.area(of: root + "/Claude/Projects/Home/HOA/a.pdf", under: [root]) == .elsewhere)
        #expect(VaultReadPlan.area(of: root + "/Family/Home/a.pdf", under: [root]) == .elsewhere)
        #expect(VaultReadPlan.area(of: root + "/Immigration/Passport/a.pdf", under: [root]) == .identity)
    }

    @Test func aPaperWithNoNameIsWhoeversFolderItIsIn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        // "Anna" is also the Mac's home folder: never what makes a paper hers.
        model.people = [Person(id: "anna", displayName: "Anna"), Person(id: "liv", displayName: "Liv")]
        await model.opened()
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.root + "/School/US/Liv/Twin Willow/Student ID.pdf": ["Student ID: 2045871"],
            Self.root + "/Health/Vision/ID Cards/card.pdf": ["Member ID: VSP99887766"],
        ]))
        let rows = model.rows
        #expect(rows.first { $0.value == "2045871" }?.personID == "liv")
        #expect(rows.first { $0.value == "VSP99887766" }?.personID == nil, "no person's folder above it but the Mac's own")
    }

    /// A dependent's card that prints only the subscriber's number: a newer card under the saved
    /// number, but another person's, never speaks for it. It is listed as naming it.
    @Test func aDependentsCardPrintingTheSubscribersIDLeavesTheSavedIDAlone() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        model.people = [Person(id: "anna", displayName: "Anna Eriksson"), Person(id: "liv", displayName: "Liv Eriksson")]
        await model.opened()
        let dental = Self.root + "/Health/Dental/ID Cards"
        let anna = dental + "/2024/Anna card.pdf", liv = dental + "/2025/Liv card.pdf"
        let annaCard = ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"]
        let livCard = ["Delta Dental", "Member Name: LIV ERIKSSON", "Subscriber ID: XZB123456789"]
        await model.readDocuments(with: PlannedDocuments(pages: [anna: annaCard]))
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        let saved = try #require(model.confirm(find.id, as: model.prepared(VaultModel.Draft(find), for: find.id)))
        let before = try #require(model.rows.first { $0.id == saved })
        #expect(before.personID == "anna" && before.facts?.holder == "Anna Eriksson")

        await model.readDocuments(with: PlannedDocuments(pages: [anna: annaCard, liv: livCard]), again: true)
        let row = try #require(model.rows.first { $0.id == saved })
        #expect(row.facts?.holder == "Anna Eriksson" && row.personID == "anna", "Liv's card does not rename Anna's ID")
        #expect(row.facts?.dated == before.facts?.dated, "nor give it Liv's card's date")
        #expect(row.facts?.primary?.path == anna)
        #expect(row.facts?.sources.first { $0.path == liv }?.rank == VaultReading.Rank.mention,
                "Liv's card is listed as naming it, not as its source")
        #expect(model.finds.allSatisfy { $0.value != "XZB123456789" }, "nor offered again as a new ID")
    }

    static let dental = root + "/Health/Dental/ID Cards"
    static let annaCard = dental + "/2024/Anna card.pdf", livCard = dental + "/2025/Liv card.pdf"

    func family(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        model.people = [Person(id: "anna", displayName: "Anna Eriksson"), Person(id: "liv", displayName: "Liv Eriksson")]
        await model.opened()
        return model
    }

    /// Both cards read before either is confirmed: the card printing the number as its member's
    /// own says whose it is, and stays so once confirmed.
    @Test func aWaitingIDIsTheMemberIDCardsPersonsAndStaysSoOnceConfirmed() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await family(rig)
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.annaCard: ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"],
            Self.livCard: ["Delta Dental", "Member Name: LIV ERIKSSON", "Subscriber ID: XZB123456789"],
        ]))
        #expect(model.finds.filter { $0.value == "XZB123456789" }.count == 1)
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(find.holder == "Anna Eriksson" && find.facts.dated == VaultReadingTests.day(2024, 1, 1))
        #expect(find.facts.primary?.path == Self.annaCard)
        #expect(find.facts.sources.first { $0.path == Self.livCard }?.rank == VaultReading.Rank.mention)
        let waiting = try #require(model.rows.first { $0.id == find.id })
        #expect(waiting.personID == "anna")
        // Liv's card says whose it is; Anna's own says nothing more.
        #expect(model.otherHolder(of: Self.livCard, for: waiting) == "Liv Eriksson")
        #expect(model.otherHolder(of: Self.annaCard, for: waiting) == nil)

        let saved = try #require(model.confirm(find.id, as: model.prepared(VaultModel.Draft(find), for: find.id)))
        let row = try #require(model.rows.first { $0.id == saved })
        #expect(row.facts?.holder == "Anna Eriksson" && row.personID == "anna")
        #expect(row.facts?.primary?.path == Self.annaCard && row.facts?.dated == VaultReadingTests.day(2024, 1, 1),
                "Liv's newer card, a copy since before Confirm, does not speak for it after")
        #expect(model.otherHolder(of: Self.livCard, for: row) == "Liv Eriksson", "and says whose card it is")
    }

    /// The dependent added to People while the Vault is open: the waiting ID is worked out again at
    /// once, so the member's own card speaks for it, not the dependent's newer one (the 2026-11-23
    /// review). It waited for the next relock, and a confirm meanwhile kept the wrong person.
    @Test func aWaitingIDIsSplitAgainWhenPeopleChange() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        model.people = [Person(id: "anna", displayName: "Anna Eriksson")]
        await model.opened()
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.annaCard: ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"],
            Self.livCard: ["Delta Dental", "Member Name: LIV ERIKSSON", "Subscriber ID: XZB123456789"],
        ]))
        let before = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(before.facts.primary?.path == Self.livCard, "with Liv not in People, her newer card spoke")
        model.people = [Person(id: "anna", displayName: "Anna Eriksson"), Person(id: "liv", displayName: "Liv Eriksson")]
        let after = try #require(model.finds.first { $0.id == before.id })
        #expect(after.holder == "Anna Eriksson" && after.facts.primary?.path == Self.annaCard)
        #expect(after.facts.sources.first { $0.path == Self.livCard }?.rank == VaultReading.Rank.mention)
        #expect(model.rows.first { $0.id == before.id }?.personID == "anna")
    }

    /// Confirmed as Liv's after Add to People re-split it under the editor: the saved ID is worked
    /// out for the person chosen, so its name, person and documents agree (the 2026-11-23 review).
    @Test func aConfirmForAPersonAddedMeanwhileSavesThatPersonsReading() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        model.people = [Person(id: "anna", displayName: "Anna Eriksson")]
        await model.opened()
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.annaCard: ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"],
            Self.livCard: ["Delta Dental", "Member Name: LIV ERIKSSON", "Subscriber ID: XZB123456789"],
        ]))
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        var draft = model.prepared(VaultModel.Draft(find, people: model.people), for: find.id)
        // The editor's Add to People, then its choice of her.
        model.people = [Person(id: "anna", displayName: "Anna Eriksson"), Person(id: "liv", displayName: "Liv Eriksson")]
        draft.personID = "liv"
        let saved = try #require(model.confirm(find.id, as: draft))
        let row = try #require(model.rows.first { $0.id == saved })
        #expect(row.personID == "liv")
        #expect(row.facts?.holder == "Liv Eriksson", "named for one person, assigned to another")
        #expect(row.facts?.primary?.path == Self.livCard)
        // As stored, not only as drawn: the row is worked out again from the copies.
        let entry = try #require(model.entries.first { $0.id == saved })
        #expect(entry.facts?.holder == "Liv Eriksson" && entry.facts?.primary?.path == Self.livCard)
    }

    /// Both cards print the number as the subscriber's: whose it is cannot be told, so it shows
    /// no one's name until the person is chosen, and then that person's card speaks.
    @Test func aWaitingIDWhoseCardsCannotTellShowsNoNameUntilChosen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await family(rig)
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.annaCard: ["Delta Dental", "Member Name: ANNA ERIKSSON", "Subscriber ID: XZB123456789"],
            Self.livCard: ["Delta Dental", "Member Name: LIV ERIKSSON", "Subscriber ID: XZB123456789"],
        ]))
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(find.holder == nil && find.note.isEmpty, "neither Anna's nor Liv's name")
        let unknown = try #require(model.rows.first { $0.id == find.id })
        #expect(unknown.personID == nil)
        #expect(model.otherHolder(of: Self.livCard, for: unknown) == nil, "nobody's card is another's until it is told whose")
        #expect(find.facts.sources.map(\.path).sorted() == [Self.annaCard, Self.livCard])

        model.assign(find.id, to: .person("anna"))
        let chosen = try #require(model.finds.first { $0.id == find.id })
        #expect(chosen.holder == "Anna Eriksson" && chosen.facts.primary?.path == Self.annaCard)
        #expect(chosen.facts.sources.first { $0.path == Self.livCard }?.rank == VaultReading.Rank.mention)
    }

    /// One person's two cards under one number: the newer still speaks, as a renewal does.
    @Test func onePersonsNewerCardStillSpeaks() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await family(rig)
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.annaCard: ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"],
            Self.dental + "/2025/Anna card.pdf": ["Delta Dental", "Member Name: ANNA ERIKSSON", "Subscriber ID: XZB123456789"],
        ]))
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(find.facts.primary?.path == Self.dental + "/2025/Anna card.pdf" && find.holder == "Anna Eriksson")
    }
}
