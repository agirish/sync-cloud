import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// The Contact group's cards as Cards and List draw them. Every address and number is made up.
@MainActor
@Suite struct VaultContactCardsPanelTests {
    static let larkspur = VaultAddress(street: "2841 Larkspur Lane", city: "San Jose", state: "CA", zip: "95132")

    /// The render rig with a shared address typed for Anna and Erik, and a phone and an email.
    static func typed(_ layout: VaultLayout) async throws -> (model: VaultModel, defaults: UserDefaults, cleanUp: () -> Void) {
        let rig = try await VaultPanelRenderTests.rig()
        rig.defaults.set(layout.rawValue, forKey: "vaultLayout")
        rig.model.layout = layout
        #expect(rig.model.setAddress(Self.larkspur, for: "anna", alsoFor: ["erik"]))
        #expect(rig.model.setPhone("4085550142", label: "Mobile", for: "anna"))
        #expect(rig.model.setEmail("erik@example.com", label: "Work", for: "erik"))
        return (rig.model, rig.defaults, rig.cleanUp)
    }

    @Test(arguments: [VaultLayout.cards, .list])
    func theContactCardsAreDrawnAfterTheIDs(_ layout: VaultLayout) async throws {
        let plain = try await VaultPanelRenderTests.rig(); defer { plain.cleanUp() }
        plain.defaults.set(layout.rawValue, forKey: "vaultLayout")
        plain.model.layout = layout
        // The IDs fill the window above them: Contact alone is chosen, so its cards are in view.
        plain.model.kindFilter = VaultGroups.contact
        let before = try VaultPanelRenderTests.render(plain.model, defaults: plain.defaults, name: "contact-cards-\(layout)-none")
        let typed = try await Self.typed(layout); defer { typed.cleanUp() }
        typed.model.kindFilter = VaultGroups.contact
        #expect(typed.model.contactCards.map(\.kind) == [.addresses, .phones, .emails])
        let after = try VaultPanelRenderTests.render(typed.model, defaults: typed.defaults, name: "contact-cards-\(layout)")
        #expect(differingPixels(before, after) > 3000, "\(layout): three cards of contacts are drawn")
    }

    @Test func aRowSaysWhoseAndWhereItComesFrom() async throws {
        let typed = try await Self.typed(.cards); defer { typed.cleanUp() }
        let home = try #require(typed.model.contactCards.first?.items.first)
        #expect(home.people == ["anna", "erik"])
        #expect(VaultCard.contactSubtitle(home, names: ["Anna", "Erik"]).hasPrefix("Anna, Erik · From you · "))
        let phone = try #require(typed.model.contactCards.first { $0.kind == .phones }?.items.first)
        #expect(VaultCard.contactSubtitle(phone, names: ["Anna"]) == "Anna · Mobile · From you")
        #expect(VaultCard.contactRemoveTitle(home) == "Remove", "typed, not read: nothing to say is not theirs")
        var past = home
        past.past = true
        #expect(VaultCard.contactSubtitle(past, names: ["Anna"]).hasPrefix("Anna · Past · From you"), "a past one, found by a search")
    }

    @Test func aContactCardFoldsAndCollapseAllTakesItToo() async throws {
        let typed = try await Self.typed(.cards); defer { typed.cleanUp() }
        let model = typed.model
        model.toggleFold(.phones)
        #expect(model.isFolded(.phones) && !model.isFolded(.addresses))
        #expect(VaultCard.contactFoldedSummary(try #require(model.contactCards.first), people: model.people) == "Anna, Erik")
        model.toggleFoldAll()
        #expect(model.allFolded && model.isFolded(.addresses) && model.isFolded(.emails))
        model.toggleFoldAll()
        #expect(!model.isFolded(.phones) && !model.allFolded)
        // ⌥-click on a Contact card goes by its own state.
        model.toggleFold(.emails, all: true)
        #expect(model.allFolded)
    }

    @Test func theArrowsWalkTheRowsAsDrawnAndStayAtTheEnds() {
        let (a, b) = (UUID(), UUID())
        let stops: [VaultWalkStop] = [.id(a), .id(b), .contact("address:home:x"), .contact("phone:anna:0")]
        func walk(_ here: VaultWalkStop?, _ step: Int) -> VaultWalkStop? { VaultCard.walk(from: here, by: step, stops: stops) }
        #expect(walk(.id(b), 1) == .contact("address:home:x"), "down from the last ID: the first contact")
        #expect(walk(.contact("address:home:x"), -1) == .id(b), "and back up")
        #expect(walk(.contact("phone:anna:0"), 1) == .contact("phone:anna:0"), "the end stays")
        #expect(walk(.id(a), -1) == .id(a), "so does the top")
        #expect(walk(nil, 1) == .id(a), "nothing chosen: the first")
        #expect(walk(.contact("gone"), 1) == .id(a), "a row no longer there: the first")
        #expect(VaultCard.walk(from: nil, by: 1, stops: []) == nil)
    }

    @Test func groupHeadingsAreDrawnOverEachGroupAndHideOnRequest() async throws {
        let shown = try await Self.typed(.cards); defer { shown.cleanUp() }
        #expect(shown.model.showsGroupHeadings)
        let with = try VaultPanelRenderTests.render(shown.model, defaults: shown.defaults, name: "cards-group-headings")
        let hidden = try await Self.typed(.cards); defer { hidden.cleanUp() }
        hidden.model.showsGroupHeadings = false
        let without = try VaultPanelRenderTests.render(hidden.model, defaults: hidden.defaults, name: "cards-no-group-headings")
        #expect(differingPixels(with, without) > 3000, "a heading over each group, and the cards under it")
        // Contact moved first: its cards lead.
        var groups = hidden.model.groups
        groups.move(VaultGroups.contact, by: -10)
        hidden.model.setGroups(groups)
        let moved = try VaultPanelRenderTests.render(hidden.model, defaults: hidden.defaults, name: "cards-contact-first")
        #expect(differingPixels(without, moved) > 3000, "the cards follow the groups' order without the headings too")
    }

    @Test func theDetailsGiveEachPartAFormAsksFor() async throws {
        let typed = try await Self.typed(.cards); defer { typed.cleanUp() }
        let home = try #require(typed.model.contactCards.first?.items.first)
        #expect(VaultCard.contactParts(home).map(\.label) == ["Street", "City", "State", "ZIP"])
        #expect(VaultCard.contactParts(home).map(\.value) == ["2841 Larkspur Lane", "San Jose", "CA", "95132"])
        let email = try #require(typed.model.contactCards.first { $0.kind == .emails }?.items.first)
        #expect(VaultCard.contactParts(email).map(\.label) == ["Address", "Label"])
    }
}
