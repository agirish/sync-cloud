import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// The People layout as the panel draws it. Every ID is made up.
@MainActor
@Suite struct VaultPeopleViewPanelTests {
    @Test func theSwitchOffersCardsListAndPeople() {
        #expect(VaultViewSwitch.segments.map(\.title) == ["Cards", "List", "People"])
        #expect(VaultViewSwitch.segments.map(\.layout) == [.cards, .list, .people])
    }

    @Test func aPersonsSubtitleCountsTheirIDsAndTheOtherTab() {
        #expect(VaultCard.personSubtitle(ids: 1, elsewhere: 0, tab: .current) == "1 ID")
        #expect(VaultCard.personSubtitle(ids: 4, elsewhere: 2, tab: .current) == "4 IDs · 2 in Archive")
        #expect(VaultCard.personSubtitle(ids: 2, elsewhere: 4, tab: .archive) == "2 IDs · 4 current")
    }

    @Test func aDateOfBirthSaysWhichIDItWasReadFromOrHowMany() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        let visa = try #require(rig.model.rows.first { $0.category == .usVisa })
        let passports = rig.model.rows.filter { $0.category == .passport }
        #expect(VaultCard.sourceLabel([visa]) == "From Visa", "one ID is named; a typed one has no document")
        #expect(VaultCard.sourceLabel(passports + [visa]) == "From 3 IDs", "several are counted, and listed in a popover")
        #expect(VaultCard.sourceLine(visa) == "Visa")
        rig.model.pin(visa.id, .older)
        let archived = try #require(rig.model.rows.first { $0.id == visa.id })
        #expect(VaultCard.sourceLine(archived) == "Visa (Archive)", "one on the other tab says so")
    }

    /// Two made-up passports of one person whose zones give different dates of birth.
    static let root = "/Users/anna/Documents"
    static let passport = root + "/Immigration/Passport/Anna/scan.pdf"
    static let renewal = root + "/Immigration/Passport/Anna/renewal.pdf"
    static let nameLine = "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"

    static func twoDates() async throws -> (model: VaultModel, defaults: UserDefaults, cleanUp: () -> Void) {
        let rig = try await VaultPanelRenderTests.rig()
        VaultReadFolders.add(root, in: rig.defaults)
        rig.model.people = [Person(id: "anna", displayName: "Anna", fullNames: ["Anna Maria Eriksson"]),
                            Person(id: "erik", displayName: "Erik")]
        await rig.model.readDocuments(with: VaultRefreshPanelTests.Shelf([
            passport: [nameLine, "L898902C36UTO7408122F1204159ZE184226B<<<<<10"],
            renewal: [nameLine, "X7654321<5UTO7312184F3401011<<<<<<<<<<<<<<02"],
        ]))
        for row in rig.model.rows where row.facts?.born != nil && row.personID != "anna" { rig.model.assign(row.id, to: .person("anna")) }
        rig.defaults.set(VaultLayout.people.rawValue, forKey: "vaultLayout")
        rig.model.layout = .people
        return (rig.model, rig.defaults, rig.cleanUp)
    }

    @Test func twoDatesOfBirthAreEachDrawnWithTheirSourceAndAWarning() async throws {
        let two = try await Self.twoDates(); defer { two.cleanUp() }
        let anna = try #require(two.model.peopleSections.first { $0.id == .person("anna") })
        #expect(anna.births.count == 2, "\(anna.births.map(\.date))")
        #expect(anna.births.map { VaultCard.sourceLabel($0.rows) } == ["From Passport · renewal.pdf", "From Passport · scan.pdf"],
                "two passports told apart by their documents")
        let both = try VaultPanelRenderTests.render(two.model, defaults: two.defaults, name: "people-two-dates")

        // Given to someone else, the wrong one goes: its line, its source and the warning with it.
        let one = try await Self.twoDates(); defer { one.cleanUp() }
        let wrong = try #require(one.model.peopleSections.first { $0.id == .person("anna") }?.births.first?.rows.first)
        one.model.assign(wrong.id, to: .person("erik"))
        let single = try VaultPanelRenderTests.render(one.model, defaults: one.defaults, name: "people-one-date")
        #expect(one.model.peopleSections.first { $0.id == .person("anna") }?.births.count == 1)
        #expect(differingPixels(both, single) > 3000, "the second date, where it was read and the warning are drawn only while there are two")
    }

    @Test func rowsGoTwoUpWhenEachColumnFitsAndNeverThreeUp() {
        let two = VaultTwoUp(minColumnWidth: 300, spacing: 14, rowSpacing: 2)
        #expect(two.columns(for: 613) == 1)
        #expect(two.columns(for: 614) == 2)
        #expect(two.columns(for: 2000) == 2, "a very wide panel still has two, so no title is cut to a stub")
    }

    @Test func otherSpellingsFoldUnderOneLineThatSaysWhatIsInIt() {
        #expect(VaultCard.foldLine(others: 3, misread: 1, unfolded: false) == "3 other spellings · 1 looks misread ›")
        #expect(VaultCard.foldLine(others: 1, misread: 0, unfolded: false) == "1 other spelling ›")
        #expect(VaultCard.foldLine(others: 4, misread: 2, unfolded: false) == "4 other spellings · 2 look misread ›")
        #expect(VaultCard.foldLine(others: 2, misread: 0, unfolded: true) == "Hide other spellings")
        #expect(VaultCard.roleMeaning(.misread, legal: "Anna Maria Eriksson").contains("shows Anna Maria Eriksson instead"))
    }

    /// Anna's passport and a notice that misreads her surname by one letter, drawn in People.
    static func spellings() async throws -> (model: VaultModel, defaults: UserDefaults, cleanUp: () -> Void) {
        let rig = try await VaultPanelRenderTests.rig()
        VaultReadFolders.add(root, in: rig.defaults)
        rig.model.people = [Person(id: "anna", displayName: "Anna", fullNames: ["Anna Maria Eriksson"]),
                            Person(id: "erik", displayName: "Erik")]
        await rig.model.readDocuments(with: VaultRefreshPanelTests.Shelf([
            passport: [nameLine, "L898902C36UTO7408122F1204159ZE184226B<<<<<10"],
            root + "/Immigration/USCIS/Anna/notice.pdf": ["I-797A Approval Notice", "Receipt Number WAC2412345678",
                                                         "Beneficiary ERICSSON, ANNA MARIA", "Received Date 01/05/2026"],
        ]))
        for row in rig.model.rows where row.facts?.holder != nil && row.personID != "anna" { rig.model.assign(row.id, to: .person("anna")) }
        rig.defaults.set(VaultLayout.people.rawValue, forKey: "vaultLayout")
        rig.model.layout = .people
        return (rig.model, rig.defaults, rig.cleanUp)
    }

    @Test func aSpellingThatLooksMisreadIsFlaggedAndCorrectingItTakesItsLineAway() async throws {
        let flagged = try await Self.spellings(); defer { flagged.cleanUp() }
        let names = try #require(flagged.model.peopleSections.first { $0.id == .person("anna") }?.names)
        #expect(names.map(\.name) == ["Anna Maria Eriksson", "Anna Maria Ericsson"], "\(names.map(\.name))")
        #expect(names.last?.looksMisread == true)
        let before = try VaultPanelRenderTests.render(flagged.model, defaults: flagged.defaults, name: "people-names-flagged")

        let fixed = try await Self.spellings(); defer { fixed.cleanUp() }
        #expect(fixed.model.setRole(.misread, of: "Anna Maria Ericsson", for: "anna") == 1)
        let after = try VaultPanelRenderTests.render(fixed.model, defaults: fixed.defaults, name: "people-names-fixed")
        #expect(fixed.model.peopleSections.first { $0.id == .person("anna") }?.names.map(\.name) == ["Anna Maria Eriksson"])
        #expect(differingPixels(before, after) > 3000, "the flagged line, its buttons and the roles' chips go")
    }

    @Test func aDocumentRunningOutWithinHalfAYearSaysHowSoon() throws {
        // Midnight UTC, as the reader stores a document's dates; "now" is midday here.
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            return utc.date(from: DateComponents(year: y, month: m, day: d))!
        }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let now = try #require(local.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12)))
        #expect(VaultCard.expiresSoon(day(2027, 3, 15), now: now) == "Expires in 114 days")
        #expect(VaultCard.expiresSoon(day(2026, 11, 22), now: now) == "Expires tomorrow")
        #expect(VaultCard.expiresSoon(day(2027, 5, 22), now: now) == "Expires in 182 days", "six months ahead is still said")
        #expect(VaultCard.expiresSoon(day(2027, 5, 23), now: now) == nil, "further off is not news")
        #expect(VaultCard.expiresSoon(day(2026, 11, 20), now: now) == nil, "run out: Expired says that")
        #expect(VaultCard.expiresSoon(nil, now: now) == nil)
    }

    @Test func peopleDrawsASectionPerPersonWithTheKindOnEachRowInItsColor() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        let cards = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "people-cards")
        rig.defaults.set(VaultLayout.people.rawValue, forKey: "vaultLayout")
        rig.model.layout = .people
        #expect(rig.model.peopleSections.map(\.title) == ["Anna", "Erik", "Household"])
        let people = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "people")
        #expect(differingPixels(cards, people) > 20_000, "another layout altogether")
        // No card title bars here; the kind's symbol on each row carries the color.
        let chip = Color(.sRGB, red: 1 - (1 - 0.21) * 0.16, green: 1 - (1 - 0.35) * 0.16, blue: 1 - (1 - 0.63) * 0.16)
        #expect(try pixels(near: chip, in: people) > 300, "the passports' and the visa's symbols sit on blue")
        var colors = rig.model.colors
        colors.isOn = false
        rig.model.setColors(colors)
        let plain = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "people-plain")
        #expect(try pixels(near: chip, in: plain) < 50, "and with colors off, on the window's hue instead")
    }
}
