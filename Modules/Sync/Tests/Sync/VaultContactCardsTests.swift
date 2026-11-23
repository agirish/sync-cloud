import Foundation
import Testing
@testable import Sync

/// The Contact group's cards in Cards and List: everyone's home addresses, phones and emails.
/// Anna's license prints Alma Street (2021); the household's water bill, Larkspur Lane (2026).
/// Every address and number is made up.
@MainActor
@Suite struct VaultContactCardsTests {
    typealias Rig = VaultModelTests.Rig
    static let larkspur = VaultContactsTests.larkspur
    static let alma = VaultContactsTests.alma

    static func model(_ rig: Rig) async -> VaultModel {
        let model = await VaultContactsTests.model(rig)
        model.setPhone("4085550142", label: "Mobile", for: "anna")
        model.setEmail("anna@example.com", label: "Personal", for: "anna")
        model.setPhone("4085550187", label: "Mobile", for: "erik")
        return model
    }

    static func card(_ model: VaultModel, _ kind: VaultContactCard.Kind) -> VaultContactCard? {
        model.contactCards.first { $0.kind == kind }
    }

    // MARK: The group

    @Test func contactIsTheLastGroupAndNoKindCanBeMovedIntoIt() {
        #expect(VaultGroups.default.order.last == VaultGroups.contact)
        #expect(VaultGroups.default.name(VaultGroups.contact) == "Contact")
        #expect(!VaultGroups.default.idGroups.contains(VaultGroups.contact))
        #expect(VaultColors().tint(ofGroup: VaultGroups.contact) == .clay)
        let defaults = ScratchDefaults("VaultContactCardsTests")
        defaults.set(["passport": "contact", "health": "home"], forKey: VaultGroups.membersKey)
        let loaded = VaultGroups.load(from: defaults)
        #expect(loaded.group(of: .passport) == "travel", "a passport is never a contact")
        #expect(loaded.group(of: .health) == "home", "a move between ID groups still loads")
    }

    // MARK: Current and Archive

    @Test func aSharedAddressIsOneRowNamingEveryoneAndPhonesAndEmailsHaveCardsOfTheirOwn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(model.contactCards.map(\.kind) == [.addresses, .phones, .emails])
        let homes = try #require(Self.card(model, .addresses)).items
        #expect(homes.count == 1)
        #expect(homes.first?.value == Self.larkspur.oneLine && homes.first?.people == ["erik", "anna"],
                "the household's bill is everyone's home, in People's order: \(homes.map(\.people))")
        #expect(homes.first?.licenseDiffers == true, "Anna's license still prints Alma Street")
        #expect(Self.card(model, .phones)?.items.map(\.value) == ["(408) 555-0187", "(408) 555-0142"])
        #expect(Self.card(model, .emails)?.items.map(\.people) == [["anna"]])
        #expect(model.count(in: .current) == model.rows.filter { $0.standing.tab == .current }.count,
                "contacts are not counted beside the IDs")
        #expect(!model.rows.contains { $0.value == "4085550142" }, "nor are they rows")
    }

    @Test func archiveListsPastAddressesAndNoPhonesOrEmails() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.tab = .archive
        #expect(model.contactCards.map(\.kind) == [.addresses])
        let past = try #require(Self.card(model, .addresses)?.items.first)
        #expect(past.value == Self.alma.oneLine && past.people == ["anna"] && past.past)
        #expect(!past.licenseDiffers, "the flag is for where they live now")
    }

    // MARK: The choices

    @Test func aPersonFilterKeepsTheirRowsAndASharedAddressKeepsEveryone() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.personFilter = .person("anna")
        #expect(Self.card(model, .addresses)?.items.first?.people == ["erik", "anna"])
        #expect(Self.card(model, .phones)?.items.map(\.people) == [["anna"]])
        model.personFilter = .household
        #expect(model.contactCards.isEmpty, "the household is nobody's contact")
    }

    @Test func theKindsChoiceShowsThemUnderContactAndHidesThemUnderAnyOtherGroup() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.kindFilter = "travel"
        #expect(model.contactCards.isEmpty)
        model.kindFilter = VaultGroups.contact
        #expect(model.contactCards.count == 3)
        #expect(model.cards.isEmpty, "no ID is in the Contact group")
        #expect(model.contactCount == 4, "one address, two phones, one email")
        model.kindFilter = nil
        model.geoFilter = .india
        #expect(model.contactCards.isEmpty, "a US address is not India's")
        model.geoFilter = .all
        model.tab = .other
        #expect(model.contactCards.isEmpty)
    }

    // MARK: Search

    @Test func aSearchMatchesStreetCityZIPPhoneDigitsAndEmailOnEveryTab() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.query = "palo alto"
        #expect(model.contactItems.map(\.value) == [Self.alma.oneLine], "a past address, found from Current")
        model.query = "95132"
        #expect(model.contactItems.map(\.value) == [Self.larkspur.oneLine])
        model.query = "555-0142"
        #expect(model.contactItems.map(\.value) == ["(408) 555-0142"], "a phone's digits, however typed")
        model.query = "4085550142"
        #expect(model.contactItems.map(\.value) == ["(408) 555-0142"], "the digits alone find it as shown")
        model.query = "0187"
        #expect(model.contactItems.map(\.people) == [["erik"]])
        model.query = "anna@"
        #expect(model.contactItems.map(\.value) == ["anna@example.com"])
        model.query = "Erik"
        #expect(Set(model.contactItems.map(\.kind)) == [.addresses, .phones], "a name finds what is theirs")
        model.query = "D1234567"
        #expect(model.contactItems.isEmpty, "never an ID's number")
    }

    // MARK: The arrow keys

    @Test func theArrowsWalkEveryRowInTheOrderDrawn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.layout = .cards
        let contacts = model.contactItems.map { VaultWalkStop.contact($0.id) }
        #expect(Array(model.walkStops.suffix(4)) == contacts, "Contact last, as its group is")
        var groups = model.groups
        groups.move(VaultGroups.contact, by: -10)
        model.setGroups(groups)
        #expect(Array(model.walkStops.prefix(4)) == contacts, "moved first, its rows are walked first")
        model.toggleFold(.phones)
        #expect(model.walkStops.count == model.walkOrder.count + 2, "a folded card's rows are not on screen")
        model.layout = .list
        #expect(model.walkStops.count == model.walkOrder.count + 4, "the list shows every row, whatever is folded")
        model.layout = .people
        #expect(model.walkStops == model.walkOrder.map(VaultWalkStop.id), "People draws no Contact cards")
    }

    // MARK: Editing from a card

    @Test func correctingASharedAddressPutsItRightForEveryoneThere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let fixed = VaultAddress(street: "2841 Larkspur Lane", unit: "Apt 2", city: "San Jose", state: "CA", zip: "95133")
        #expect(model.setAddress(fixed, for: "erik", alsoFor: ["anna"], replacing: Self.larkspur.key))
        let homes = try #require(Self.card(model, .addresses)).items
        #expect(homes.map(\.value) == [fixed.oneLine] && homes.first?.people == ["erik", "anna"], "\(homes.map(\.value))")
        #expect(model.contacts["anna"]?.notTheirs == [Self.larkspur.key] && model.contacts["erik"]?.notTheirs == [Self.larkspur.key])
    }
}
