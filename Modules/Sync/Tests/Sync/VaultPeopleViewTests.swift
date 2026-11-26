import Combine
import Foundation
import Testing
@testable import Sync

/// The People view: each person's IDs together, with their name as documents print it and their
/// date of birth. Every number is made up.
@MainActor
@Suite struct VaultPeopleViewTests {
    typealias Rig = VaultModelTests.Rig

    static let root = "/Users/anna/Documents"
    static let passport = root + "/Immigration/Passport/Anna/scan.pdf"
    static let dental = root + "/Health/Dental/ID Cards/card.pdf"
    static let water = root + "/Home/Utilities/Bay Water/2026/bill.pdf"
    static let people = [Person(id: "erik", displayName: "Erik", fullNames: ["Erik Johan Eriksson"]),
                         Person(id: "anna", displayName: "Anna", fullNames: ["Anna Maria Eriksson", "Anna Eriksson"])]

    /// A passport and a dental card of Anna's, a water bill nobody in particular owns, and a typed
    /// loan number for Erik.
    static func model(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        model.people = people
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            passport: VaultToConfirmTests.passportPage,
            dental: ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"],
            water: ["Account Number: 58210 44719 00"],
        ]))
        _ = model.add(VaultModel.Draft(title: "Car loan", value: "0044918857", personID: "erik", category: .loans))
        return model
    }

    @Test func eachPersonHasASectionInPeoplesOrderAndTheHouseholdComesLast() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let sections = model.peopleSections
        #expect(sections.map(\.title) == ["Erik", "Anna", "Household"], "\(sections.map(\.title))")
        #expect(sections.map(\.id) == [.person("erik"), .person("anna"), .household])
        let anna = try #require(sections.first { $0.id == .person("anna") })
        #expect(anna.rows.map(\.category) == [.passport, .health], "her IDs in the cards' order")
        #expect(sections.last?.rows.map(\.category) == [.utilities])
    }

    @Test func aPersonsNameIsListedAsEachIdentityPaperPrintsItAndTheirBirthDateOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        // The passport's zone gives the name and the birth date; the dental card's holder line is
        // the plan's wording, not a name a form asks for.
        #expect(anna.names.map(\.name) == ["Anna Maria Eriksson"] && anna.names.map(\.on) == [["passport"]]
                    && anna.names.map(\.role) == [.legal], "\(anna.names)")
        #expect(anna.names.first?.rows.map(\.category) == [.passport], "the IDs that print it, for “From Passport”")
        #expect(anna.born == [VaultReadingTests.day(1974, 8, 12)])
        let erik = try #require(model.peopleSections.first { $0.id == .person("erik") })
        #expect(erik.names.isEmpty && erik.born.isEmpty, "a typed number says nothing about its person")
        #expect(model.peopleSections.last?.names.isEmpty == true, "the household has no name or birth date")
    }

    // MARK: Where a date of birth was read

    static let renewal = root + "/Immigration/Passport/Anna/renewal.pdf"

    /// Anna's two passports, whose zones give different dates of birth: one of them was misread.
    static func twoDates(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        model.people = people
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            passport: VaultToConfirmTests.passportPage,
            renewal: VaultReadingTests.zone("P", number: "X7654321", born: "731218", expires: "340101", given: "ANNA<MARIA"),
        ]))
        // Whatever the reading made of two dates under one name, both are hers here.
        for row in model.rows where row.category == .passport && row.personID != "anna" { model.assign(row.id, to: .person("anna")) }
        return model
    }

    @Test func eachDateOfBirthNamesTheIDsItWasReadFrom() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.twoDates(rig)
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(anna.born == [VaultReadingTests.day(1973, 12, 18), VaultReadingTests.day(1974, 8, 12)], "both, earliest first: \(anna.born)")
        let wrong = try #require(anna.births.first), right = try #require(anna.births.last)
        #expect(wrong.rows.count == 1 && right.rows.count == 1)
        #expect(wrong.rows.first?.facts?.primary?.path == Self.renewal, "the date traced to the scan it came from")
        #expect(right.rows.first?.facts?.primary?.path == Self.passport)
        #expect(wrong.rows.first?.id != right.rows.first?.id)

        // The ID is where it is put right: given to someone else, its date goes with it.
        model.assign(try #require(wrong.rows.first).id, to: .person("erik"))
        let after = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(after.born == [VaultReadingTests.day(1974, 8, 12)], "one date again: \(after.born)")
        #expect(model.peopleSections.first { $0.id == .person("erik") }?.born == [VaultReadingTests.day(1973, 12, 18)])
    }

    @Test func aSourceOnTheOtherTabOrBehindAFilterIsStillNamedAndCanBeChosen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.twoDates(rig)
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        let source = try #require(anna.births.first?.rows.first)
        model.pin(source.id, .older)
        model.personFilter = .person("erik")
        model.personFilter = .everyone
        model.tab = .current
        let still = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(still.births.count == 2, "a date from an archived ID is still her date as read")
        #expect(still.births.first?.rows.first?.standing.tab == .archive)
        model.reveal(source.id)
        #expect(model.tab == .archive && model.selection == source.id, "choosing it goes to its tab")
    }

    @Test func aPersonsIDsAreGroupedInTheGroupsOrderAndWalkedInThatOrder() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        _ = model.add(VaultModel.Draft(title: "Social Security number", value: "123-45-6789", personID: "anna", category: .ssn))
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(anna.groups.map(\.name) == ["Travel & Immigration", "Legal & IDs", "Health"], "\(anna.groups.map(\.name))")
        #expect(anna.groups.map { $0.rows.map(\.category) } == [[.passport], [.ssn], [.health]])
        #expect(anna.rows.map(\.category) == [.passport, .ssn, .health], "rows are the groups' rows, in order")
        // A kind moved to another group goes with it.
        var groups = model.groups
        groups.groupOf[.ssn] = "travel"
        model.setGroups(groups)
        let moved = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(moved.groups.map { $0.rows.map(\.category) } == [[.passport, .ssn], [.health]])
    }

    @Test func theDateMostIDsGiveComesFirst() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.twoDates(rig)
        // A third passport scan that agrees with the 1974 date: two IDs against one.
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            Self.passport: VaultToConfirmTests.passportPage,
            Self.renewal: VaultReadingTests.zone("P", number: "X7654321", born: "731218", expires: "340101", given: "ANNA<MARIA"),
            Self.root + "/Immigration/Passport/Anna/old.pdf": VaultReadingTests.zone("P", number: "Q1234567", born: "740812", expires: "200101", given: "ANNA<MARIA"),
        ]))
        for row in model.rows where row.category == .passport && row.personID != "anna" { model.assign(row.id, to: .person("anna")) }
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(anna.births.map(\.rows.count) == [2, 1], "\(anna.births.map { ($0.date, $0.rows.count) })")
        #expect(anna.born.first == VaultReadingTests.day(1974, 8, 12), "the later date leads: more IDs give it")
    }

    @Test func aNameSaysWhereItIsPrintedInOneShortLine() {
        let one = VaultPersonSection.PrintedName(name: "Anna", on: ["passport"])
        let many = VaultPersonSection.PrintedName(name: "Anna", on: ["passport", "visa", "I-94", "USCIS notice", "PAN card"])
        #expect(VaultPersonText.paperLine(one, only: true) == "On passport")
        #expect(VaultPersonText.paperLine(many, only: true) == "On all 5 kinds of identity paper", "every paper agrees")
        #expect(VaultPersonText.paperLine(many, only: false) == "On passport, visa, I-94 and 2 more", "one spelling of several")
        #expect(VaultPersonText.paperLine(.init(name: "Anna", on: ["passport", "visa"]), only: false) == "On passport and visa")
    }

    // MARK: Names and their roles

    static let notice = root + "/Immigration/USCIS/Anna/notice.pdf"
    static let i94 = root + "/Immigration/I-94/Anna/i94.pdf"

    /// Anna's passport; a USCIS notice that misreads her surname by one letter; and an I-94 that
    /// prints her without her middle name. All three hers.
    static func spellings(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        model.people = people
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            passport: VaultToConfirmTests.passportPage,
            notice: ["I-797A Approval Notice", "Receipt Number WAC2412345678", "Beneficiary ERICSSON, ANNA MARIA", "Received Date 01/05/2026"],
            i94: ["I-94 Number 123456789A1", "Last/Surname: ERIKSSON", "First (Given) Name: ANNA", "Admit Until Date: 12/24/2027"],
        ]))
        for row in model.rows where row.personID != "anna" && row.facts?.holder != nil { model.assign(row.id, to: .person("anna")) }
        return model
    }

    static func anna(_ model: VaultModel) throws -> VaultPersonSection {
        try #require(model.peopleSections.first { $0.id == .person("anna") })
    }

    @Test func thePassportsSpellingIsTheLegalNameAndAOneLetterSlipLooksMisread() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        let names = try Self.anna(model).names
        #expect(names.first?.name == "Anna Maria Eriksson" && names.first?.role == .legal, "\(names)")
        let slip = try #require(names.first { $0.name == "Anna Maria Ericsson" })
        #expect(slip.role == .alsoUsed && slip.looksMisread, "one letter, one paper")
        #expect(names.filter { $0.role == .goesBy }.isEmpty, "nothing is Goes by until chosen")
        let short = try #require(names.first { $0.name == "Anna Eriksson" }, "the I-94's spelling is not listed")
        #expect(!short.looksMisread, "a dropped middle name is a real spelling, many letters away")
    }

    @Test func rolesChosenAreKeptSealedAcrossOpens() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        model.setRole(.goesBy, of: "Anna Maria Eriksson", for: "anna")
        let after = try Self.anna(model).names
        #expect(after.first { $0.role == .goesBy }?.name == "Anna Maria Eriksson")
        #expect(after.first { $0.role == .legal }?.name != "Anna Maria Eriksson", "one spelling, one role")
        model.setRole(.legal, of: "Anna Maria Eriksson", for: "anna")
        model.setRole(.alsoUsed, of: "Anna Maria Ericsson", for: "anna")
        #expect(try Self.anna(model).names.first { $0.name == "Anna Maria Ericsson" }?.looksMisread == false, "kept as real: no longer flagged")

        let again = rig.model()
        again.people = Self.people
        await again.opened()
        let names = try Self.anna(again).names
        #expect(names.first?.name == "Anna Maria Eriksson" && names.first?.role == .legal)
        #expect(names.first { $0.name == "Anna Maria Ericsson" }?.looksMisread == false, "read back from the sealed file")
        #expect(!rig.defaults.dictionaryRepresentation().values.contains { "\($0)".contains("Ericsson") || "\($0)".contains("ericsson") },
                "no name goes to preferences")
    }

    @Test func misreadCorrectsEveryIDReadWithItAndCanBeTakenBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        #expect(model.setRole(.misread, of: "Anna Maria Ericsson", for: "anna") == 1, "the notice's ID")
        let names = try Self.anna(model).names
        #expect(!names.contains { $0.name == "Anna Maria Ericsson" }, "\(names)")
        let legal = try #require(names.first { $0.role == .legal })
        #expect(legal.on.contains("USCIS notice"), "the notice now prints the legal name")
        let notice = try #require(model.rows.first { $0.facts?.primary?.path == Self.notice })
        #expect(notice.holderAsRead == "Anna Maria Ericsson", "what was read is kept")

        model.undoMisread("Anna Maria Ericsson")
        #expect(try Self.anna(model).names.contains { $0.name == "Anna Maria Ericsson" })
    }

    /// The panel draws the household from the model, so a new list says so, its order or a name
    /// changed (the store sorts a person added from the Vault); the same list, nothing at all.
    @Test func aChangeOfPeopleTellsTheViewAndTheSameListDoesNot() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        let anna = Person(id: "anna", displayName: "Anna"), erik = Person(id: "erik", displayName: "Erik")
        model.people = [erik, anna]
        var told = 0
        let watch = model.objectWillChange.sink { told += 1 }
        defer { watch.cancel() }

        model.people = [erik, anna]
        #expect(told == 0, "the same list")
        model.people = [anna, erik]
        #expect(told > 0, "sorted")
        told = 0
        model.people = [anna, Person(id: "erik", displayName: "Erik J")]
        #expect(told > 0, "renamed")
    }

    /// Not a Misreading changes no view state of its own, so the model must say it changed:
    /// before, People showed the old role until the next second's redraw (VT99).
    @Test func everyRoleChangeTellsTheViewAtOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        var told = 0
        let watch = model.objectWillChange.sink { told += 1 }
        defer { watch.cancel() }

        model.setRole(.alsoUsed, of: "Anna Maria Ericsson", for: "anna")
        #expect(told > 0, "Also used")
        told = 0
        model.setRole(.misread, of: "Anna Maria Ericsson", for: "anna")
        #expect(told > 0, "Misread")
        told = 0
        model.undoMisread("Anna Maria Ericsson")
        #expect(told > 0, "taking a Misread back")
    }

    /// Rows never read a spelling's role, so choosing one rebuilds none (VT101). A Misread does
    /// change what rows show, and does rebuild them.
    @Test func aRoleRebuildsNoRowsButAMisreadDoes() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        let before = model.rowsRevision
        model.setRole(.alsoUsed, of: "Anna Maria Ericsson", for: "anna")
        model.setRole(.legal, of: "Anna Maria Eriksson", for: "anna")
        #expect(model.rowsRevision == before)
        model.setRole(.misread, of: "Anna Maria Ericsson", for: "anna")
        #expect(model.rowsRevision != before)
    }

    /// The panel draws every second; what it lists is worked out again only when what it is
    /// made of moves (VT9): a tick recomputes nothing, a search once.
    @Test func aTickRecomputesNothingTheListsAreMadeOf() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let sections = model.peopleSections, cards = model.cards.map(\.card), visible = model.visibleRows.map(\.id)
        _ = model.count(in: .current); _ = model.refreshSources
        let before = model.visibleComputations
        let everything = model.viewComputations
        for _ in 0..<5 {
            rig.clock.advance(1)
            model.tick()
            #expect(model.peopleSections == sections)
            #expect(model.cards.map(\.card) == cards)
            #expect(model.visibleRows.map(\.id) == visible)
            _ = model.count(in: .current); _ = model.refreshSources
        }
        #expect(model.visibleComputations == before, "a tick worked the lists out again")
        #expect(model.viewComputations == everything, "a tick worked the cards, counts, people or sources out again")
        model.query = "dental"
        #expect(model.visibleRows.count < visible.count)
        _ = model.cards; _ = model.peopleSections
        #expect(model.visibleComputations == before + 1)
        model.query = ""
        #expect(model.visibleRows.map(\.id) == visible, "back to what it was")
        // What People is made of beyond the rows moves it too.
        model.people = [Person(id: "anna", displayName: "Anna")]
        #expect(model.peopleSections != sections, "a change of people left People as it was")
        model.tab = .archive
        #expect(model.count(in: .current) == model.rows.filter { $0.standing.tab == .current && model.passesFilters($0) }.count)
        // Let go with the numbers.
        model.systemLocked()
        #expect(!model.holdsViewCaches, "a list of the numbers was kept after they were let go")
    }

    @Test func theLegalNameIsNeverMarkedMisreadAndALockedVaultChangesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        #expect(model.setRole(.misread, of: "Anna Maria Eriksson", for: "anna") == 0)
        #expect(try Self.anna(model).names.first?.name == "Anna Maria Eriksson")
        // Locked, the numbers let go: a role asked for changes nothing, now or once opened again.
        let before = try Self.anna(model).names
        model.systemLocked()
        #expect(model.setRole(.misread, of: "Anna Maria Ericsson", for: "anna") == 0)
        model.setRole(.goesBy, of: "Anna Eriksson", for: "anna")
        #expect(model.nameRoles.isEmpty, "a locked Vault took a role in memory")
        #expect(await model.unlock())
        #expect(try Self.anna(model).names == before, "a locked Vault took a role")
    }

    /// Roles are the user's, kept across a change of reader rules like corrections and lessons:
    /// what an older build read is let go, never what was chosen about it (VT105).
    @Test func rolesOutliveAChangeOfReaderRules() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        model.setRole(.goesBy, of: "Anna Eriksson", for: "anna")
        model.closed()
        var state = try #require(rig.store.readingOnDisk())
        #expect(state.nameRoles?["anna"]?.goesBy != nil)
        state.version -= 1                                     // as an older build's rules sealed it
        try rig.store.writeReadingOnDisk(state)
        let again = rig.model()
        again.people = Self.people
        await again.opened()
        #expect(again.needsReadAgain, "the rules did not change")
        #expect(again.nameRoles["anna"] == state.nameRoles?["anna"], "a change of rules let the roles go")
        again.closed()
        #expect(try rig.store.readingOnDisk()?.nameRoles?["anna"] == state.nameRoles?["anna"], "the reseal dropped the roles")
    }

    @Test func theSummaryLeadsWithTheNameTheyGoByThenTheLegalOne() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.spellings(rig)
        model.setRole(.alsoUsed, of: "Anna Maria Ericsson", for: "anna")
        if let short = try Self.anna(model).names.first(where: { $0.name != "Anna Maria Eriksson" && $0.name != "Anna Maria Ericsson" }) {
            model.setRole(.goesBy, of: short.name, for: "anna")
        }
        let text = VaultPersonText.text(try Self.anna(model), numbers: false)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(4)) == ["Anna", "Goes by: Anna Eriksson", "Legal name: Anna Maria Eriksson",
                                           "Also printed as: Anna Maria Ericsson"], "\(lines)")
    }

    @Test func aGuessPrefersThePassportAndOneLetterApartIsTheLimitOfASlip() {
        typealias Name = VaultPersonSection.PrintedName
        let names = [Name(name: "Anna Eriksson", on: ["visa", "I-94", "USCIS notice"]), Name(name: "Anna Maria Eriksson", on: ["passport"])]
        #expect(VaultNameGuess.legal(names, excluding: nil) == 1, "the passport's, though fewer papers print it")
        #expect(VaultNameGuess.legal(names, excluding: VaultReading.spellingKey("Anna Maria Eriksson")) == 0)
        #expect(VaultNameGuess.looksMisread(Name(name: "Anna Maria Ericson", on: ["visa"]), legal: "Anna Maria Eriksson"), "two letters")
        #expect(!VaultNameGuess.looksMisread(Name(name: "Ana Mariah Ericsson", on: ["visa"]), legal: "Anna Maria Eriksson"), "four letters")
        #expect(!VaultNameGuess.looksMisread(Name(name: "Anna Maria Ericsson", on: ["visa", "I-94"]), legal: "Anna Maria Eriksson"), "two papers agree")
        #expect(VaultNameGuess.distance(Array("dant"), Array("dani")) == 1)
    }

    /// VT100: spellings that differ only in punctuation, spaces or case are one name to the Vault
    /// (its roles and corrections go by ``VaultReading/spellingKey(_:)``), so one chip, written as
    /// most of its papers write it; Legal on it marks the name, never another chip.
    @Test func aNameWrittenWithAHyphenOrWithoutIsOneChip() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        model.people = Self.people
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            Self.passport: VaultToConfirmTests.passportPage,
            Self.notice: ["I-797A Approval Notice", "Receipt Number WAC2412345678", "Beneficiary ERIKSSON, ANNA-MARIA", "Received Date 01/05/2026"],
            Self.root + "/Immigration/USCIS/2025/I-797C.pdf": ["I-797C Notice of Action", "Receipt Number EAC2512345678",
                                                             "Beneficiary ERIKSSON, ANNA-MARIA", "Received Date 03/02/2025"],
        ]))
        for row in model.rows where row.personID != "anna" && row.facts?.holder != nil { model.assign(row.id, to: .person("anna")) }
        let key = "anna maria eriksson"
        let all = try Self.anna(model).names
        let names = all.filter { VaultReading.spellingKey($0.name) == key }
        #expect(names.count == 1, "\(all.map(\.name))")
        let chip = try #require(names.first)
        #expect(chip.name.contains("-"), "written as most of its papers write it: \(chip.name)")
        #expect(chip.alsoWritten.count == 1 && chip.alsoWritten.first?.contains("-") == false)
        #expect(chip.rows.count == 3, "every paper behind each way of writing it")

        #expect(chip.on.count == 2, "the passport and the notices, though they write it two ways")
        #expect(chip.role == .legal, "the passport's name, written as its papers mostly write it")
        let summary = VaultPersonText.text(try Self.anna(model), numbers: false)
        #expect(summary.contains("Also printed as:") && summary.contains(chip.alsoWritten[0]))

        model.setRole(.goesBy, of: "Anna Maria Eriksson", for: "anna")
        let after = try Self.anna(model).names.filter { VaultReading.spellingKey($0.name) == key }
        #expect(after.count == 1 && after.first?.role == .goesBy, "the one chip takes the role")
    }

    /// A tie goes to the form that keeps its marks: a passport's machine line prints no hyphen.
    @Test func aTieGoesToTheNameWrittenWithItsHyphen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        model.people = Self.people
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            Self.passport: VaultToConfirmTests.passportPage,
            Self.notice: ["I-797A Approval Notice", "Receipt Number WAC2412345678", "Beneficiary ERIKSSON, ANNA-MARIA", "Received Date 01/05/2026"],
        ]))
        for row in model.rows where row.personID != "anna" && row.facts?.holder != nil { model.assign(row.id, to: .person("anna")) }
        let chip = try #require(try Self.anna(model).names.first { VaultReading.spellingKey($0.name) == "anna maria eriksson" })
        #expect(chip.name.contains("-") && chip.alsoWritten.count == 1, "\(chip.name)")
    }

    /// VT70: Add to Vault proposes whose a waiting ID is as its row says, the name corrected, not
    /// by the name as printed; a choice made already stands.
    @Test func addToVaultProposesWhoseItIsAsItsRowSays() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        model.people = Self.people
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            Self.notice: ["I-797A Approval Notice", "Receipt Number WAC2412345678", "Beneficiary OLSEN, KARI", "Received Date 01/05/2026"],
        ]))
        let find = try #require(model.finds.first { $0.value == "WAC2412345678" })
        #expect(VaultModel.Draft(find, people: model.people).personID == nil, "printed, the name answers to nobody")
        model.correctEverywhere(VaultReading.spellingKey("Kari Olsen"), to: "Anna Maria Eriksson")
        let row = try #require(model.rows.first { $0.id == find.id })
        try #require(row.personID == "anna", "the row goes by the name as corrected")
        #expect(model.confirmationDraft(find).personID == "anna")
        let id = try #require(model.confirm(find.id, as: model.confirmationDraft(find)))
        #expect(model.entry(id: id)?.assignment == .person("anna"), "Confirm saves what the list showed")
    }

    /// A nameless account the rows give to the household stays the Vault's guess: proposed as no
    /// choice, so Confirm saves none and it is ranked on its own, as before VT70.
    @Test func aNamelessAccountsHouseholdStaysAGuess() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let bill = try #require(model.finds.first { $0.category == .utilities })
        try #require(model.rows.first { $0.id == bill.id }?.isHousehold == true)
        let draft = model.confirmationDraft(bill)
        #expect(!draft.isHousehold && draft.personID == nil)
        let id = try #require(model.confirm(bill.id, as: draft))
        #expect(model.entry(id: id)?.assignment == nil)
        #expect(model.rows.first { $0.id == id }?.isHousehold == true, "still the household's, by the guess")
    }

    @Test func aNameReadWithALineBreakOrInAnotherCaseIsTheSameName() {
        #expect(VaultPersonText.tidied("\nanna  maria\tEriksson ") == "anna maria Eriksson")
        #expect(VaultPersonText.tidied("Anna Maria Eriksson") == "Anna Maria Eriksson")
        #expect(VaultPersonText.tidied(" \n ") == "")
    }

    /// One section for a name nobody in People answers to, however its middle name is printed:
    /// first and last name, as the rest of the Vault weighs names, titled with the fullest spelling
    /// (owner, 2026-11-23; it was one section per spelling).
    @Test func aNameNobodyInPeopleAnswersToGetsOneSection() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        // Only someone with another surname is in People now. (A shared surname alone would give
        // Anna's papers to the one person who has it, which is the People list's rule, not this view's.)
        model.people = [Person(id: "erik", displayName: "Erik", fullNames: ["Erik Lindqvist"])]
        let titles = model.peopleSections.map(\.title)
        #expect(titles == ["Erik", "Anna Maria Eriksson", "Household"], "\(titles)")
        let anna = try #require(model.peopleSections.first { $0.title == "Anna Maria Eriksson" })
        #expect(anna.id == .unnamed("name:anna eriksson"))
        let printed = Set(anna.rows.compactMap { $0.facts?.holder.map(VaultPersonText.tidied) })
        #expect(printed.isSuperset(of: ["Anna Eriksson", "Anna Maria Eriksson"]), "both spellings, one person: \(printed)")
    }

    @Test func theFiltersAndTheTabNarrowTheSectionsAndTheOtherTabIsCounted() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let passport = try #require(model.rows.first { $0.category == .passport })
        model.pin(passport.id, .older)
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(anna.rows.map(\.category) == [.health], "the archived passport left Current")
        #expect(anna.elsewhere == 1, "and is counted as in Archive")
        #expect(anna.names.first?.name == "Anna Maria Eriksson", "her name still comes from it")

        model.personFilter = .person("erik")
        #expect(model.peopleSections.map(\.title) == ["Erik"])
        model.personFilter = .everyone
        model.query = "dental"
        #expect(model.peopleSections.map(\.title) == ["Anna"], "a search narrows it too")
    }

    @Test func theArrowKeysWalkTheRowsInTheOrderThePeopleViewDrawsThem() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.layout = .people
        let drawn = model.peopleSections.flatMap { $0.rows.map(\.id) }
        model.selection = drawn[0]
        var walked = [drawn[0]]
        for _ in 1..<drawn.count {
            model.moveSelection(by: 1)
            walked.append(try #require(model.selection))
        }
        #expect(walked == drawn)
        // The cards draw the same rows in another order, so the test would notice the wrong one.
        model.layout = .cards
        #expect(model.cards.flatMap { $0.rows.map(\.id) } != drawn)
    }

    @Test func theLayoutChosenIsTheOneTheNextOpenDraws() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        #expect(rig.model().layout == .cards, "Cards, when nothing was chosen")
        #expect(rig.defaults.string(forKey: "vaultLayout") == nil, "read as it opens, never saved by it")
        // Chosen before People was a layout: Cards or List.
        rig.defaults.set(true, forKey: "vaultShowsList")
        #expect(rig.model().layout == .list)
        #expect(rig.defaults.string(forKey: "vaultLayout") == nil, "the older choice is not saved over")
        rig.model().layout = .people
        #expect(rig.model().layout == .people, "kept for the next open")
        #expect(rig.defaults.string(forKey: "vaultLayout") == "people", "under the key it has always had")
    }

    @MainActor @Test func aResetOfTheSavedLayoutIsFollowedWithoutSavingItAgain() async throws {
        // Settings ▸ Advanced ▸ Reset All while the app runs: the model outlives the panel, and
        // the next open draws Cards, as it did when the panel kept the choice itself.
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.layout = .people
        rig.defaults.removeObject(forKey: "vaultLayout")
        for _ in 0..<200 where model.layout != .cards { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.layout == .cards)
        #expect(rig.defaults.string(forKey: "vaultLayout") == nil, "followed, not saved back")
        // A choice made afterwards is saved again.
        model.layout = .list
        #expect(rig.defaults.string(forKey: "vaultLayout") == "list")
    }

    // MARK: As text

    @Test func aSummaryHasEndingsAndNoBirthDateAndTheFullTextHasBoth() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        let summary = VaultPersonText.text(anna, numbers: false)
        #expect(summary.hasPrefix("Anna\nLegal name: Anna Maria Eriksson\nPassport: ends 02C3"), "\(summary)")
        #expect(!summary.contains("L898902C3") && !summary.contains("XZB123456789"), "no ID in full")
        #expect(!summary.contains("08/12/1974"), "and no birth date")
        #expect(summary.contains("ends 6789"))

        let full = VaultPersonText.text(anna, numbers: true)
        #expect(full.contains("Date of birth: 08/12/1974"))
        #expect(full.contains("Passport: L898902C3") && full.contains("XZB123456789"), "\(full)")
    }

    @Test func copyWithNumbersAsksForAProofAndCopySummaryDoesNot() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.lockNow()
        let asked = rig.auth.reasons.count
        var own: [String] = []
        model.sessionLine = { own.append($0) }

        #expect(await model.copyPerson(.person("anna"), numbers: false))
        #expect(rig.auth.reasons.count == asked, "a summary shows nothing the rows do not")
        #expect(rig.copied.last?.contains("ends 6789") == true)

        rig.auth.answer = .cancelled
        #expect(!(await model.copyPerson(.person("anna"), numbers: true)))
        #expect(rig.copied.count == 1, "a refused proof copies nothing")

        rig.auth.answer = .allowed
        #expect(await model.copyPerson(.person("anna"), numbers: true))
        #expect(rig.auth.reasons.last == "copy Anna’s IDs")
        #expect(rig.copied.last?.contains("XZB123456789") == true)
        // The log says what the proof was for, never whose (VT22).
        #expect(own == ["Vault: a proof for a person’s IDs was canceled", "Vault: a proof for a person’s IDs was given"])
    }

    @Test func aBirthDateShowsOnlyWhenOneOfTheirIDsMay() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.lockNow()
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        #expect(!model.canShowBirth(in: anna))
        rig.auth.answer = .allowed
        await model.unlock()
        #expect(model.canShowBirth(in: anna))
        #expect(await model.copyBirth(anna.born[0], in: anna))
        #expect(rig.copied.last == "08/12/1974", "as a US form asks for it")
    }
}
