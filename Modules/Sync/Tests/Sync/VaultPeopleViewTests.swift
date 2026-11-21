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
        #expect(anna.names == [.init(name: "Anna Maria Eriksson", on: ["passport"])], "\(anna.names)")
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

    @Test func aNameReadWithALineBreakOrInAnotherCaseIsTheSameName() {
        #expect(VaultPersonText.tidied("\nanna  maria\tEriksson ") == "anna maria Eriksson")
        #expect(VaultPersonText.tidied("Anna Maria Eriksson") == "Anna Maria Eriksson")
        #expect(VaultPersonText.tidied(" \n ") == "")
    }

    @Test func aNameNobodyInPeopleAnswersToGetsItsOwnSection() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        // Only someone with another surname is in People now. (A shared surname alone would give
        // Anna's papers to the one person who has it, which is the People list's rule, not this view's.)
        model.people = [Person(id: "erik", displayName: "Erik", fullNames: ["Erik Lindqvist"])]
        let titles = model.peopleSections.map(\.title)
        #expect(titles == ["Erik", "Anna Eriksson", "Anna Maria Eriksson", "Household"]
                || titles == ["Erik", "Anna Maria Eriksson", "Household"], "\(titles)")
        #expect(model.peopleSections.contains { $0.id == .unnamed("Anna Maria Eriksson") })
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

    // MARK: As text

    @Test func aSummaryHasEndingsAndNoBirthDateAndTheFullTextHasBoth() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let anna = try #require(model.peopleSections.first { $0.id == .person("anna") })
        let summary = VaultPersonText.text(anna, numbers: false)
        #expect(summary.hasPrefix("Anna\nName on passport: Anna Maria Eriksson\nPassport: ends 02C3"), "\(summary)")
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
