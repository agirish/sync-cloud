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
        #expect(anna.births.map { VaultCard.sourceLabel($0.rows) } == ["From Passport", "From Passport"],
                "one line each; the document's name is in the link's tip")
        #expect(anna.births.compactMap { $0.rows.first.map(VaultCard.sourceHelp) }.map { $0.contains("renewal.pdf") } == [true, false],
                "two passports told apart by their documents, on hover")
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

    @Test func aMisreadRoleSaysWhatItShowsInstead() {
        #expect(VaultCard.roleMeaning(.misread, legal: "Anna Maria Eriksson").contains("shows Anna Maria Eriksson instead"))
    }

    // MARK: The fact tiles

    typealias Slot = VaultFactsLayout.Slot
    static let five: [Slot] = [.name, .birth, .address, .phone, .email]

    /// Each slot's row and its x and width, rounded, in the slots' order.
    static func arranged(_ slots: [Slot], at width: CGFloat) -> [Slot: [Int]] {
        Dictionary(uniqueKeysWithValues: VaultFactsLayout.places(slots, width: width, spacing: 8).map { place in
            (slots[place.index], [place.row, Int(place.x.rounded()), Int(place.width.rounded())])
        })
    }

    @Test func fiveTilesFillOneRowWhenWideAndTwoRowsOtherwise() {
        // 1,180 pt and up: one row, the address widest.
        let wide = Self.arranged(Self.five, at: 1240)
        #expect(Set(wide.values.map { $0[0] }) == [0])
        #expect(wide.values.map { $0[1] }.sorted() == [Slot.name, .birth, .address, .phone, .email].map { wide[$0]![1] },
                "in reading order: name, birth, address, phone, email")
        #expect(wide[.address]![2] > wide[.name]![2] && wide[.name]![2] > wide[.birth]![2])
        // 900 pt: four columns of 219, Name (2) · Date of birth · Phone, then Home address (2) · Email (2).
        #expect(Self.arranged(Self.five, at: 900) == [.name: [0, 0, 446], .birth: [0, 454, 219], .phone: [0, 681, 219],
                                                      .address: [1, 0, 446], .email: [1, 454, 446]])
        // Just under the line for one row, still two.
        #expect(Self.arranged(Self.five, at: 1179)[.address]![0] == 1)
        // 784 is where four columns start: each then holds “18 December 1974” and its copy icon.
        #expect(Self.arranged(Self.five, at: 784)[.birth] == [0, 396, 190])
        // Under it, as beside the details pane: two columns, Name · Date of birth, the address
        // across both, then Phone · Email.
        #expect(Self.arranged(Self.five, at: 640) == [.name: [0, 0, 316], .birth: [0, 324, 316], .address: [1, 0, 640],
                                                      .phone: [2, 0, 316], .email: [2, 324, 316]])
        // Under 400, one column.
        #expect(Self.arranged(Self.five, at: 360).values.map { $0[2] } == Array(repeating: 360, count: 5))
        #expect(Self.arranged(Self.five, at: 360).values.map { $0[0] }.sorted() == [0, 1, 2, 3, 4])
    }

    @Test func archivesThreeTilesShareOneRow() {
        let archive: [Slot] = [.name, .birth, .address]
        #expect(Self.arranged(archive, at: 900) == [.name: [0, 0, 219], .birth: [0, 227, 219], .address: [0, 454, 446]])
        #expect(Self.arranged(archive, at: 640) == [.name: [0, 0, 316], .birth: [0, 324, 316], .address: [1, 0, 640]])
        #expect(Self.arranged(archive, at: 1300)[.address]![0] == 0, "not the five-across row: it needs all five")
        #expect(Self.arranged([.address], at: 900) == [.address: [0, 0, 446]], "the household's address alone")
    }

    @Test func typedContactsAreDrawnInTheirTiles() async throws {
        let empty = try await Self.twoDates(); defer { empty.cleanUp() }
        let before = try VaultPanelRenderTests.render(empty.model, defaults: empty.defaults, name: "people-contacts-empty")
        let typed = try await Self.twoDates(); defer { typed.cleanUp() }
        #expect(typed.model.setPhone("4085550142", label: "Mobile", for: "anna"))
        #expect(typed.model.setEmail("anna@example.com", label: "Personal", for: "anna"))
        #expect(typed.model.setAddress(VaultAddress(street: "2841 Larkspur Lane", city: "San Jose", state: "CA", zip: "95132"), for: "anna"))
        let after = try VaultPanelRenderTests.render(typed.model, defaults: typed.defaults, name: "people-contacts-typed")
        #expect(differingPixels(before, after) > 1500, "the three values replace the three Add… lines")
    }

    @Test func someoneInPeopleAlwaysHasFiveTilesOnCurrent() async throws {
        let two = try await Self.twoDates(); defer { two.cleanUp() }
        let anna = try #require(two.model.peopleSections.first { $0.id == .person("anna") })
        #expect(VaultCard.factSlots(anna, tab: .current) == Self.five, "an address, phone and email not known yet keep their tiles")
        #expect(VaultCard.factSlots(anna, tab: .archive) == [.name, .birth], "no past address: no address tile on Archive")
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
