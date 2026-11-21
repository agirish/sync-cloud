import Foundation
import Testing
@testable import Sync

/// Card colors: a card takes its group's unless it has its own, what is kept between opens, and
/// what goes when a kind does. Nothing here holds an ID.
@MainActor
@Suite struct VaultColorsTests {
    typealias Rig = VaultModelTests.Rig

    static func scratch() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "vault-colors-\(UUID().uuidString)"))
    }

    // MARK: Which color a card is drawn in

    @Test func aCardTakesItsGroupsColorUntilItHasItsOwn() {
        var colors = VaultColors()
        let (kinds, groups) = (VaultKinds(), VaultGroups.default)
        // The app's: travel is blue, legal violet, health rose, home green.
        #expect(colors.tint(of: .builtIn(.passport), kinds: kinds, groups: groups) == .blue)
        #expect(colors.tint(of: .builtIn(.usVisa), kinds: kinds, groups: groups) == .blue)
        #expect(colors.tint(of: .builtIn(.ssn), kinds: kinds, groups: groups) == .violet)
        #expect(colors.tint(of: .builtIn(.health), kinds: kinds, groups: groups) == .rose)
        #expect(colors.tint(of: .builtIn(.loans), kinds: kinds, groups: groups) == .green)

        colors.cards[VaultCardID.builtIn(.ssn).key] = .tint(.plum)
        #expect(colors.tint(of: .builtIn(.ssn), kinds: kinds, groups: groups) == .plum, "its own wins")
        #expect(colors.tint(of: .builtIn(.pan), kinds: kinds, groups: groups) == .violet, "its neighbour still follows the group")

        colors.groups["legal"] = .tint(.teal)
        #expect(colors.tint(of: .builtIn(.pan), kinds: kinds, groups: groups) == .teal)
        #expect(colors.tint(of: .builtIn(.ssn), kinds: kinds, groups: groups) == .plum, "and a group's change leaves a card's own alone")
    }

    @Test func aKindMovedToAnotherGroupTakesThatGroupsColor() {
        var groups = VaultGroups.default
        groups.groupOf[.driversLicense] = "travel"
        #expect(VaultColors().tint(of: .builtIn(.driversLicense), kinds: VaultKinds(), groups: groups) == .blue)
    }

    @Test func aHouseholdsOwnKindFollowsTheGroupItIsListedUnder() {
        let school = VaultCustomKind(id: "school", name: "Kids’ School", group: "health")
        let kinds = VaultKinds(custom: [school])
        var colors = VaultColors()
        #expect(colors.tint(of: .custom("school"), kinds: kinds, groups: .default) == .rose)
        colors.cards[VaultCardID.custom("school").key] = .tint(.clay)
        #expect(colors.tint(of: .custom("school"), kinds: kinds, groups: .default) == .clay)
    }

    @Test func noColorIsAChoiceForACardAGroupAndForAll() {
        let (kinds, groups) = (VaultKinds(), VaultGroups.default)
        var colors = VaultColors()
        colors.cards[VaultCardID.builtIn(.passport).key] = .plain
        #expect(colors.tint(of: .builtIn(.passport), kinds: kinds, groups: groups) == nil, "this card alone")
        #expect(colors.tint(of: .builtIn(.usVisa), kinds: kinds, groups: groups) == .blue)

        colors.groups["health"] = .plain
        #expect(colors.tint(of: .builtIn(.health), kinds: kinds, groups: groups) == nil, "a whole group")
        #expect(colors.tint(ofGroup: "health") == nil)

        colors.isOn = false
        #expect(colors.tint(of: .builtIn(.usVisa), kinds: kinds, groups: groups) == nil, "and off draws none")
        #expect(colors.tint(ofGroup: "travel") == nil, "nor a dot on the group's chip")
        #expect(colors.color(ofGroup: "travel") == .tint(.blue), "though what was chosen is kept for when it is on again")
    }

    // MARK: Kept between opens

    @Test func onlyWhatDiffersFromTheAppsIsSavedAndItComesBack() throws {
        let defaults = try Self.scratch()
        var colors = VaultColors()
        colors.save(to: defaults)
        #expect(defaults.object(forKey: VaultColors.groupsKey) == nil)
        #expect(defaults.object(forKey: VaultColors.cardsKey) == nil)
        #expect(defaults.object(forKey: VaultColors.offKey) == nil)

        colors.groups["travel"] = .tint(.blue)   // the app's own: not a choice worth keeping
        colors.groups["home"] = .tint(.olive)
        colors.groups["health"] = .plain
        colors.cards[VaultCardID.builtIn(.ssn).key] = .tint(.plum)
        colors.isOn = false
        colors.save(to: defaults)
        #expect(defaults.dictionary(forKey: VaultColors.groupsKey) as? [String: String] == ["home": "olive", "health": "plain"])
        #expect(defaults.dictionary(forKey: VaultColors.cardsKey) as? [String: String] == ["ssn": "plum"])

        let back = VaultColors.load(from: defaults)
        #expect(!back.isOn)
        #expect(back.color(ofGroup: "home") == .tint(.olive))
        #expect(back.color(ofGroup: "health") == .plain)
        #expect(back.color(ofGroup: "travel") == .tint(.blue))
        #expect(back.own(.builtIn(.ssn)) == .tint(.plum))
    }

    @Test func aColorOrACardThisBuildDoesNotKnowIsAsIfNeverChosen() throws {
        let defaults = try Self.scratch()
        defaults.set(["travel": "chartreuse", "nowhere": "teal", "legal": "teal"], forKey: VaultColors.groupsKey)
        defaults.set(["passport": "mauve", "notAKind": "rose", "loans": "clay"], forKey: VaultColors.cardsKey)
        let colors = VaultColors.load(from: defaults)
        #expect(colors.isOn)
        #expect(colors.groups == ["legal": .tint(.teal)])
        #expect(colors.cards == ["loans": .tint(.clay)])
        #expect(colors.color(ofGroup: "travel") == .tint(.blue), "the unknown color falls back to the app's")
    }

    // MARK: In the model

    @Test func theModelKeepsAColorAcrossOpensAndLetsItGoWithItsKind() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        let school = try #require(model.addKind(named: "Kids’ School"))
        #expect(model.tint(of: school) == .green, "listed under Home & Money, so green")
        model.setColor(.tint(.clay), of: school)
        model.setColor(.tint(.plum), of: .builtIn(.ssn))
        #expect(model.tint(of: school) == .clay)

        let again = rig.model()
        #expect(again.tint(of: school) == .clay, "read back from the same preferences")
        #expect(again.tint(of: .builtIn(.ssn)) == .plum)

        again.setColor(nil, of: .builtIn(.ssn))
        #expect(again.tint(of: .builtIn(.ssn)) == .violet, "nil follows its group again")

        again.setKinds(VaultKinds())
        #expect(again.colors.own(school) == nil, "a removed kind's color goes with it")
        #expect(VaultColors.load(from: rig.defaults).cards.isEmpty)
    }

    // MARK: The Color choice: the card's own, and its group's

    @Test func aGroupsColorSetFromOneCardReachesTheCardsThatFollowItAndIsKept() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.setColor(.tint(.plum), of: .builtIn(.i94))
        model.setColor(.tint(.teal), ofGroup: "travel")
        #expect(model.tint(of: .builtIn(.passport)) == .teal)
        #expect(model.tint(of: .builtIn(.usVisa)) == .teal, "its neighbour in the group follows too")
        #expect(model.tint(of: .builtIn(.i94)) == .plum, "a card with its own color keeps it")
        #expect(model.tint(of: .builtIn(.ssn)) == .violet, "and another group is not touched")
        #expect(model.colors.own(.builtIn(.passport)) == nil, "the card was given no color of its own by it")

        let again = rig.model()
        #expect(again.tint(of: .builtIn(.passport)) == .teal, "read back from the same preferences")
        again.setColor(.plain, ofGroup: "travel")
        #expect(again.tint(of: .builtIn(.passport)) == nil, "no color is a choice for a group")
        #expect(again.tint(of: .builtIn(.i94)) == .plum)
    }

    @Test func theChoiceShowsTheCardsOwnColorAndItsGroupsApart() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        var choice = model.colorChoice(for: .builtIn(.passport))
        #expect(choice.title == "Passports")
        #expect(choice.own == nil, "it follows its group")
        #expect(choice.group == "travel")
        #expect(choice.groupName == "Travel & Immigration")
        #expect(choice.groupColor == .tint(.blue))
        #expect(choice.isOn)
        let others = choice.others
        #expect(others == ["Visas", "I-94 Records", "USCIS Cases"], "the group's other cards, in the cards' order: \(others)")
        #expect(choice.reach == "Colors Passports, Visas, I-94 Records, and USCIS Cases.")

        // With its own color the card is no longer among those the group's color reaches.
        model.setColor(.tint(.clay), of: .builtIn(.passport))
        choice = model.colorChoice(for: .builtIn(.passport))
        #expect(choice.own == .tint(.clay))
        #expect(choice.groupColor == .tint(.blue), "the group's is still its own question")
        #expect(choice.reach == "Colors Visas, I-94 Records, and USCIS Cases. Passports has its own.")
        // And a neighbour's choice no longer lists it.
        #expect(model.colorChoice(for: .builtIn(.usVisa)).others == ["I-94 Records", "USCIS Cases"])

        var colors = model.colors
        colors.isOn = false
        model.setColors(colors)
        #expect(!model.colorChoice(for: .builtIn(.passport)).isOn)
    }

    @Test func otherFindsCardsAreNotColored() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        #expect(model.tint(of: .builtIn(.passport)) == .blue)
        model.tab = .other
        #expect(model.tint(of: .builtIn(.passport)) == nil)
    }
}
