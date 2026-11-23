import Foundation
import Testing
@testable import Sync

/// The panel's lists as a plain value works them out from the rows (VT7 d): the search, the tab
/// and the choices are all it is given. Every number and name is made up.
@Suite struct VaultRowFilterTests {
    typealias Row = VaultModel.Row

    /// Anna's passport (US), her PAN card (India), a water bill nobody in particular owns, and a
    /// typed gym card: rows as ``VaultRowSource`` works them out, on a day none has run out.
    static let rows: [Row] = {
        typealias T = VaultRowSourceTests
        return T.source(entries: [VaultEntry(title: "Gym card", value: "GYM5550001", addedAt: T.day)], finds: [
            T.find("X1234567", .passport, holder: "Anna Maria Eriksson", at: "/Immigration/Passport/scan.pdf"),
            T.find("ABCDE1234F", .pan, holder: "Anna Maria Eriksson", at: "/India/PAN/card.pdf"),
            T.find("58210 44719 00", .utilities, at: "/Home/Utilities/Bay Water/bill.pdf"),
        ]).rows().rows
    }()

    static func filter(query: String = "", tab: VaultStanding.Tab = .current, person: VaultModel.PersonFilter = .everyone,
                       geo: VaultGeoFilter = .all, kind: VaultGroups.ID? = nil) -> VaultRowFilter {
        VaultRowFilter(query: query, tab: tab, person: person, geo: geo, kind: kind, kinds: VaultKinds(), groups: .default)
    }

    static func values(_ rows: [Row]) -> Set<String> { Set(rows.map(\.value)) }

    @Test func theChoicesLeaveOnlyWhatTheyName() throws {
        let rows = Self.rows
        #expect(Self.values(Self.filter().visible(rows)) == ["X1234567", "ABCDE1234F", "58210 44719 00", "GYM5550001"])
        #expect(Self.values(Self.filter(person: .person("anna")).visible(rows)) == ["X1234567", "ABCDE1234F"])
        #expect(Self.values(Self.filter(person: .household).visible(rows)) == ["58210 44719 00", "GYM5550001"])
        let pan = try #require(rows.first { $0.value == "ABCDE1234F" })
        #expect(Self.filter(geo: .us).passes(pan) == false)
        #expect(Self.filter(geo: .us).passes(pan, geo: .india), "a choice given in place of the one chosen")
        #expect(Self.filter().visible(rows).isEmpty == false)
        #expect(Self.filter(tab: .archive).visible(rows).isEmpty)
    }

    @Test func aSearchMatchesNamesAndKindsNeverDigitsAndLooksPastTheChoices() {
        let rows = Self.rows
        #expect(Self.values(Self.filter(query: "  Passports ", person: .household).visible(rows)) == ["X1234567"])
        #expect(Self.values(Self.filter(query: "anna").visible(rows)) == ["X1234567", "ABCDE1234F"])
        #expect(Self.filter(query: "1234").visible(rows).isEmpty, "a search never confirms a number's digits")
        #expect(Self.filter(query: "1234").searching)
        #expect(Self.filter(query: "  ").searching == false)
    }

    @Test func countsGoByTheTabAskedForAndTheChoices() {
        let rows = Self.rows
        let filter = Self.filter(person: .person("anna"))
        #expect(filter.count(rows) == 2)
        #expect(filter.count(rows, in: .archive) == 0)
        #expect(filter.count(rows, person: .household) == 2)
        // A country shows its own and what is used anywhere: only the PAN card is India's alone.
        #expect(filter.count(rows, person: .everyone, geo: .us) == rows.count - 1)
        #expect(filter.count(rows, person: .everyone, geo: .india) == rows.count)
    }

    @Test func theOtherCountryIsCountedOnlyWhileOneIsChosen() {
        let rows = Self.rows
        let us = Self.filter(geo: .us)
        let visible = us.visible(rows)
        #expect(Self.values(visible).contains("ABCDE1234F") == false)
        #expect(us.elsewhere(.builtIn(.pan), in: rows)?.filter == .india)
        #expect(us.elsewhere(.builtIn(.pan), in: rows)?.count == 1)
        #expect(us.elsewhereKinds(rows, visible: visible)?.count == 1)
        #expect(Self.filter().elsewhere(.builtIn(.pan), in: rows) == nil)
        // Only what the person choice would show there: the PAN card is Anna's.
        #expect(Self.filter(person: .household, geo: .us).elsewhere(.builtIn(.pan), in: rows) == nil)
        #expect(Self.filter(query: "anna", geo: .us).elsewhereKinds(rows, visible: visible) == nil)
    }

    @Test func cardsComeInTheKindsOrderEachWithItsRows() {
        let filter = Self.filter()
        let cards = filter.cards(filter.visible(Self.rows))
        let order = VaultKinds().order
        #expect(cards.map(\.card) == cards.map(\.card).sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
        #expect(cards.allSatisfy { card in card.rows.allSatisfy { $0.card == card.card } })
        #expect(cards.flatMap(\.rows).count == 4)
    }

    @Test func peopleHaveASectionEachInPeoplesOrderAndTheHouseholdLast() {
        let filter = Self.filter()
        let rows = Self.rows
        let sections = filter.peopleSections(rows, visible: filter.visible(rows), people: [VaultRowSourceTests.anna], roles: [:])
        #expect(sections.map(\.id) == [.person("anna"), .household])
        #expect(sections.first?.names.map(\.name) == ["Anna Maria Eriksson"])
        #expect(sections.first?.names.first?.on == ["passport", "PAN card"])
        let onlyHousehold = filter.peopleSections(rows, visible: Self.filter(person: .household).visible(rows),
                                                  people: [VaultRowSourceTests.anna], roles: [:])
        #expect(onlyHousehold.map(\.id) == [.household])
    }
}
