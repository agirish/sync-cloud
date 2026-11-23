import Foundation
import Testing
@testable import Sync

/// The groups' order: kept, moved, and what the cards, the arrow keys and Show Group Headings
/// make of it. Every number is made up.
@MainActor
@Suite struct VaultGroupOrderTests {
    typealias Rig = VaultModelTests.Rig

    // MARK: Moving a group

    @Test func aGroupMovesUpAndDownAndStaysAtTheEnds() {
        var groups = VaultGroups.default
        #expect(groups.order == ["travel", "legal", "health", "home", "contact"])
        groups.move("contact", by: -1)
        #expect(groups.order == ["travel", "legal", "health", "contact", "home"])
        groups.move("travel", by: -1)
        #expect(groups.order.first == "travel", "the top stays")
        #expect(!groups.canMove("travel", by: -1) && groups.canMove("travel", by: 1))
        groups.move("travel", by: 99)
        #expect(groups.order.last == "travel")
    }

    @Test func aDragMovesAsAListDoes() {
        var groups = VaultGroups.default
        // Contact dragged to the top: from index 4 to before 0.
        groups.move(fromOffsets: [4], toOffset: 0)
        #expect(groups.order == ["contact", "travel", "legal", "health", "home"])
        // Travel dragged below Health: from 1 to before 4.
        groups.move(fromOffsets: [1], toOffset: 4)
        #expect(groups.order == ["contact", "legal", "health", "travel", "home"])
    }

    @Test func theOrderIsKeptAndTheAppsIsNotWrittenDown() {
        let defaults = ScratchDefaults("VaultGroupOrderTests")
        var groups = VaultGroups.default
        groups.save(to: defaults)
        #expect(defaults.object(forKey: VaultGroups.orderKey) == nil, "the app's order is not stored")
        groups.move("contact", by: -10)
        groups.save(to: defaults)
        #expect(VaultGroups.load(from: defaults).order == ["contact", "travel", "legal", "health", "home"])
        // A stored order naming a group this build does not know, and missing one it does.
        defaults.set(["home", "later-group", "travel"], forKey: VaultGroups.orderKey)
        #expect(VaultGroups.load(from: defaults).order == ["home", "travel", "legal", "health", "contact"],
                "unknown ids dropped; groups not named keep their places after")
    }

    // MARK: The cards

    @Test func aKindTheHouseholdMadeJoinsItsGroup() throws {
        var kinds = VaultKinds(custom: [VaultCustomKind(id: "school", name: "Kids’ School", group: "travel")])
        let groups = VaultGroups.default
        #expect(kinds.order.last == .custom("school"), "made kinds come last in the kinds' own order")
        let byGroup = kinds.order(by: groups)
        let at = try #require(byGroup.firstIndex(of: .custom("school")))
        #expect(kinds.group(of: byGroup[at - 1], in: groups) == "travel" && kinds.group(of: byGroup[at + 1], in: groups) == "legal",
                "after Travel's own kinds, before Legal's")
        kinds.custom[0].group = "home"
        #expect(kinds.order(by: groups).last == .custom("school"))
    }

    /// A passport, a license and the household's water bill; Anna's typed phone.
    static func model(_ rig: Rig) async -> VaultModel {
        let model = await VaultContactsTests.model(rig)
        model.setPhone("4085550142", label: "Mobile", for: "anna")
        model.layout = .cards
        return model
    }

    @Test func theCardsFollowTheGroupsOrderAndContactTakesItsPlace() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(model.cardGroups.map(\.id) == ["legal", "home", "contact"], "\(model.cardGroups.map(\.id))")
        var groups = model.groups
        groups.move("contact", by: -10)
        groups.move("home", by: -10)
        model.setGroups(groups)
        #expect(model.cardGroups.map(\.id) == ["home", "contact", "legal"])
        #expect(model.cards.map { model.kinds.group(of: $0.card, in: model.groups) } == ["home", "home", "legal"],
                "the ID cards in the same order")
        #expect(model.cardGroups.first { $0.id == "contact" }?.slots.map(\.id) == ["contact:addresses", "contact:phones"])
        #expect(model.visibleRows.first?.category == .utilities, "and the rows the arrow keys walk")
    }

    @Test func foldingAGroupFoldsItsCardsAndOpensThemAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.toggleFold(group: "contact")
        #expect(model.isFolded(group: "contact") && model.isFolded(.addresses) && model.isFolded(.phones))
        #expect(!model.isFolded(group: "legal"), "another group stays open")
        model.toggleFold(group: "contact")
        #expect(!model.isFolded(group: "contact") && !model.isFolded(.phones))
        // ⌥-click: every card, the way this group goes.
        model.toggleFold(group: "legal", all: true)
        #expect(model.allFolded)
    }

    @Test func showGroupHeadingsIsKeptAndStartsOn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(model.showsGroupHeadings)
        model.showsGroupHeadings = false
        let again = rig.model()
        await again.opened()
        #expect(!again.showsGroupHeadings, "read back from preferences")
    }

    @Test func choosingContactInTheKindsSurvivesSavingTheGroups() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.kindFilter = VaultGroups.contact
        var groups = model.groups
        groups.move("contact", by: -1)
        model.setGroups(groups)
        #expect(model.kindFilter == VaultGroups.contact, "Contact holds no kind, yet stays chosen")
    }
}
