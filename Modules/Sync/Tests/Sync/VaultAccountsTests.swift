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
        let steps = Self.plan(["School/US/Liv/Twin Creeks/Report Card 2025.pdf", "School/US/Liv/Twin Creeks/Field trip.pdf",
                               "School/US/Liv/Twin Creeks/Student ID 2024.jpg", "School/US/Liv/Twin Creeks/Enrollment 2023.pdf"])
        #expect(Set(Self.names(steps)) == ["School/US/Liv/Twin Creeks/Report Card 2025.pdf",
                                          "School/US/Liv/Twin Creeks/Student ID 2024.jpg",
                                          "School/US/Liv/Twin Creeks/Enrollment 2023.pdf"])
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
        let student = try #require(Self.read(["Twin Creeks Elementary", "Student ID: 2045871"],
                                             at: "School/US/Liv/Twin Creeks/Report Card 2025.pdf").first)
        #expect(student.facts.form == "Student ID")
        #expect(student.title == "Twin Creeks · Student ID")
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
        #expect(VaultReading.accountIssuer(root + "School/US/Liv/Twin Creeks/TODO/a.pdf") == "Twin Creeks")
        #expect(VaultReading.accountIssuer(root + "Home/Insurance/Policy/a.pdf") == "Insurance")
        #expect(VaultReading.accountIssuer(root + "Vehicles/a.pdf") == nil)
        // A person's folder says whose the card is, never who issued it.
        let people = [Person(id: "shweta", displayName: "Shweta"), Person(id: "liv", displayName: "Liv")]
        #expect(VaultReading.accountIssuer(root + "Health/Medical/Shweta/ID Cards/a.pdf", people: people) == "Medical")
        #expect(VaultReading.accountIssuer(root + "School/US/Twin Creeks/Liv/a.pdf", people: people) == "Twin Creeks")
        #expect(VaultReading.accountIssuer(root + "Health/Shweta/a.pdf", people: people) == nil)
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
        #expect(Self.read(["Twin Creeks Elementary", "Student ID: 123456 5th Grade"],
                          at: "School/US/Liv/Twin Creeks/Report Card 2025.pdf").first?.value == "123456")
        // A long run of digits is whole already: what follows a space is the loan's term.
        #expect(Self.read(["Mortgage statement", "Loan Number: 0123456789 30 Year Fixed"],
                          at: "Home/Mortgage/Statements/2025/Apr.pdf").first?.value == "0123456789")
        // A number printed in groups, by spaces or dashes, is still read to its last group.
        for whole in ["1234 5678 9012", "XZB-45-1234", "CA-123-4567-89", "8155 60 012 3456789"] {
            #expect(Self.read(["Account Number: " + whole + " Due 02/01/2025"], at: "Home/Utilities/Cable/2025/bill.pdf")
                .first?.value == whole, "\(whole.count)")
        }
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
            Self.root + "/School/US/Liv/Twin Creeks/Student ID.pdf": ["Student ID: 2045871"],
            Self.root + "/Health/Vision/ID Cards/card.pdf": ["Member ID: VSP99887766"],
        ]))
        let rows = model.rows
        #expect(rows.first { $0.value == "2045871" }?.personID == "liv")
        #expect(rows.first { $0.value == "VSP99887766" }?.personID == nil, "no person's folder above it but the Mac's own")
    }
}
