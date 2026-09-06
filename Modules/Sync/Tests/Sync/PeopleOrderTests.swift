import Foundation
import Testing
@testable import Sync

/// The default order of the roster, and the store's promise to keep the user's own order once
/// they have made one.
@MainActor
struct PeopleOrderTests {

    /// The real roster as `people.json` had it — alphabetical, which put the daughter first and
    /// the owner of the Mac fifth.
    static func alphabetical() -> [Person] {
        [Person(id: "abhishek", displayName: "Abhishek", relationship: "me"),
         Person(id: "aditi", displayName: "Aditi", relationship: "daughter"),
         Person(id: "anuraag", displayName: "Anuraag", relationship: "brother"),
         Person(id: "divit", displayName: "Divit", relationship: "son"),
         Person(id: "girish", displayName: "Girish", relationship: "father"),
         Person(id: "muktha", displayName: "Muktha", relationship: "mother"),
         Person(id: "shweta", displayName: "Shweta", relationship: "wife")]
    }

    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("order-\(UUID().uuidString)")
    }

    /// Yourself, spouse, children, parents, siblings — the order that was asked for, and
    /// alphabetical inside a tier so the two children and the two parents do not swap between runs.
    @Test func theDefaultOrderIsByRelationship() {
        #expect(PeopleOrder.arranged(Self.alphabetical()).map(\.id)
                == ["abhishek", "shweta", "aditi", "divit", "girish", "muktha", "anuraag"])
    }

    /// Every word the tiers accept, and the ways a relationship is written that must not matter.
    @Test func eachTierKnowsItsWords() {
        #expect(PeopleOrder.tier(of: "me") == .yourself)
        #expect(PeopleOrder.tier(of: "Self") == .yourself)
        #expect(PeopleOrder.tier(of: "primary") == .yourself)
        #expect(PeopleOrder.tier(of: "wife") == .spouse)
        #expect(PeopleOrder.tier(of: "Husband") == .spouse)
        #expect(PeopleOrder.tier(of: "my partner") == .spouse)
        #expect(PeopleOrder.tier(of: "son") == .children)
        #expect(PeopleOrder.tier(of: "daughter ") == .children)
        #expect(PeopleOrder.tier(of: "mother") == .parents)
        #expect(PeopleOrder.tier(of: "Dad") == .parents)
        #expect(PeopleOrder.tier(of: "amma") == .parents)
        #expect(PeopleOrder.tier(of: "brother") == .siblings)
        #expect(PeopleOrder.tier(of: "sister") == .siblings)
    }

    /// The tiers are the user's own household, so a qualified relationship is everyone else: an
    /// in-law says "mother" and is not a parent. Nothing at all, and words the rule does not know,
    /// land last too — which is where a work roster would sit entirely.
    @Test func qualifiedAndUnknownRelationshipsLandLast() {
        #expect(PeopleOrder.tier(of: "mother-in-law") == .others)
        #expect(PeopleOrder.tier(of: "step son") == .others)
        #expect(PeopleOrder.tier(of: "grandmother") == .others)
        #expect(PeopleOrder.tier(of: "ex-wife") == .others)
        #expect(PeopleOrder.tier(of: "friend") == .others)
        #expect(PeopleOrder.tier(of: "colleague") == .others)
        #expect(PeopleOrder.tier(of: nil) == .others)
        #expect(PeopleOrder.tier(of: "") == .others)
    }

    /// The rule is a default: a file written before it existed comes up in relationship order,
    /// and an add re-sorts, because nobody has said otherwise yet.
    @Test func aFileWithNoOrderOfItsOwnComesUpInDefaultOrder() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = PeopleStore(directory: dir, profileId: "t", profile: nil)
        for p in Self.alphabetical() {
            seed.add(displayName: p.displayName, relationship: p.relationship)
        }
        let store = PeopleStore(directory: dir, profileId: "t", profile: nil)
        #expect(!store.orderIsCustom)
        #expect(store.people.map(\.id) == ["abhishek", "shweta", "aditi", "divit", "girish", "muktha", "anuraag"])

        store.add(displayName: "Rhea", relationship: "daughter")
        #expect(store.people.map(\.id) == ["abhishek", "shweta", "aditi", "divit", "rhea", "girish", "muktha", "anuraag"],
                "a new child should join the children, not the end")
    }

    /// **A relaunch is the only proof an arrangement was saved**, and the store must stop
    /// re-sorting the moment the user has arranged anything — an add after that appends.
    @Test func movingSomeoneIsKeptAcrossARelaunchAndStopsTheDefaultSort() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "t", profile: nil)
        for p in Self.alphabetical() { store.add(displayName: p.displayName, relationship: p.relationship) }

        #expect(store.move(id: "anuraag", up: true))
        #expect(store.orderIsCustom)
        #expect(store.people.map(\.id) == ["abhishek", "shweta", "aditi", "divit", "girish", "anuraag", "muktha"])

        let reopened = PeopleStore(directory: dir, profileId: "t", profile: nil)
        #expect(reopened.orderIsCustom, "the file did not record that the order is the user's")
        #expect(reopened.people.map(\.id) == ["abhishek", "shweta", "aditi", "divit", "girish", "anuraag", "muktha"])

        reopened.add(displayName: "Rhea", relationship: "daughter")
        #expect(reopened.people.last?.id == "rhea", "an add into a hand-arranged list must not re-sort it")

        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(object["order"] as? String == "custom")
    }

    /// The ends are the ends: a refused move changes nothing and writes nothing. (The in-memory
    /// store arranges too, so the ends are the arranged ends — Abhishek first, Anuraag last.)
    @Test func aMoveOffEitherEndIsRefused() {
        let store = PeopleStore(people: Self.alphabetical())
        let before = store.people
        #expect(before.first?.id == "abhishek" && before.last?.id == "anuraag",
                "the in-memory store no longer arranges — the ends below are the wrong ends")
        #expect(!store.move(id: "abhishek", up: true))
        #expect(!store.move(id: "anuraag", up: false))
        #expect(!store.move(id: "nobody", up: true))
        #expect(store.people == before)
        #expect(!store.orderIsCustom, "a refused move must not claim the order as the user's")
    }

    /// The way back: the default order returns, and the file stops claiming a custom one.
    @Test func theDefaultOrderCanBeRestored() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "t", profile: nil)
        for p in Self.alphabetical() { store.add(displayName: p.displayName, relationship: p.relationship) }
        store.move(id: "muktha", up: true)
        store.useDefaultOrder()
        #expect(!store.orderIsCustom)
        #expect(store.people.map(\.id) == ["abhishek", "shweta", "aditi", "divit", "girish", "muktha", "anuraag"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(object["order"] == nil, "a default order is the absence of the key, not a value")
        #expect(!PeopleStore(directory: dir, profileId: "t", profile: nil).orderIsCustom)
    }
}
