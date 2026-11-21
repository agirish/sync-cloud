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
