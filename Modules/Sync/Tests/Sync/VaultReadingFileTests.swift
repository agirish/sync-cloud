import Foundation
import Testing
@testable import Sync

/// What a load takes from the sealed reading file, as a plain function of it (VT7 b), and the
/// model sealing again exactly what it took. Every number and name is made up.
@Suite struct VaultReadingFileTests {
    static let root = "/Users/anna/Documents"
    static let card = root + "/Health/Dental/ID Cards/card.pdf"
    static let copy = root + "/Health/Dental/ID Cards/copy.pdf"
    static let named = root + "/Health/Dental/letter.pdf"
    static let people = [Person(id: "anna", displayName: "Anna", fullNames: ["Anna Maria Eriksson"])]

    /// One waiting number read from two copies, a document naming it, a choice made about another
    /// number under older rules, and the user's own corrections, roles and lessons.
    static func sealed(version: Int = VaultReading.version, generation: Int = 3) -> VaultReadingState {
        let lines = ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"]
        let first = VaultReading.finds(in: lines, from: card)[0]
        let second = VaultReading.finds(in: lines, from: copy)[0]
        var waiting = first
        waiting.pin = .older
        let value = VaultReading.normalized(first.value)
        return VaultReadingState(
            version: version, generation: generation, finds: [waiting], read: [card: "1 2", copy: "3 4"],
            mentions: [value: [VaultSource(path: named, role: "Letter", rank: VaultReading.Rank.mention)]],
            copies: [value: [card: first, copy: second]],
            choices: ["KP12345678": VaultChoice(id: UUID(), choices: VaultChoices(geo: .india))],
            lessons: [root + "/Health/Dental": .builtIn(.other)], staleSources: [root + "/old.pdf"],
            notFound: [root + "/gone.pdf"], needsDiscover: true, lastRefreshed: VaultRig.t0,
            names: ["anna eriksson": "Anna Maria Eriksson"],
            nameRoles: ["anna": VaultNameRoles(legal: "annamariaeriksson")])
    }

    @Test func underTheSameRulesWhatWasReadIsKeptAndEachWaitingNumberRebuilt() throws {
        let state = Self.sealed()
        let (open, changed) = state.opened(generation: 3, people: Self.people)
        #expect(!changed)
        #expect(open.read == state.read)
        #expect(open.copies == state.copies)
        #expect(open.mentions == state.mentions)
        #expect(open.choices == state.choices)
        #expect(open.staleSources == state.staleSources)
        #expect(open.needsReadAgain == false)
        let find = try #require(open.finds.first)
        #expect(open.finds.count == 1)
        #expect(find.id == state.finds[0].id, "the waiting row stays the same row")
        #expect(find.pin == .older, "and keeps what was chosen about it")
        #expect(Set(find.facts.sources.map(\.path)) == [Self.card, Self.copy], "rebuilt from both copies")
        #expect(find.facts.holder == "Anna Eriksson")
    }

    @Test func aForgetSinceLetsGoOfWhatWasMarkedReadAlone() {
        let state = Self.sealed()
        let (open, changed) = state.opened(generation: 4, people: Self.people)
        #expect(!changed)
        #expect(open.read.isEmpty)
        #expect(open.generation == 4, "sealed again under the generation in force")
        #expect(open.finds.map(\.id) == state.finds.map(\.id))
        #expect(open.copies == state.copies)
    }

    @Test func underOtherRulesWhatWasReadGoesAndTheUsersOwnStays() {
        let state = Self.sealed(version: VaultReading.version - 1)
        let (open, changed) = state.opened(generation: 3, people: Self.people)
        #expect(changed, "sealed again at once")
        #expect(open.version == VaultReading.version)
        #expect(open.finds.isEmpty && open.copies.isEmpty && open.mentions.isEmpty && open.read.isEmpty)
        #expect(open.needsReadAgain)
        // What was chosen about a waiting number is carried onto the next read's.
        #expect(open.choices[VaultReading.normalized(state.finds[0].value)]?.pin == .older)
        #expect(open.choices["KP12345678"] == state.choices["KP12345678"])
        // A choice already carried from an earlier change of rules stands over the find's.
        var twice = state
        let carried = VaultChoice(id: UUID(), choices: VaultChoices(geo: .us))
        twice.choices[VaultReading.normalized(state.finds[0].value)] = carried
        #expect(twice.opened(generation: 3, people: Self.people).state.choices[VaultReading.normalized(state.finds[0].value)] == carried)
        // Where the older rules read is where Refresh looks first.
        #expect(open.staleSources == [Self.root + "/old.pdf", Self.card, Self.copy].sorted())
        #expect(open.names == state.names)
        #expect(open.nameRoles == state.nameRoles)
        #expect(open.lessons == state.lessons)
        #expect(open.notFound == state.notFound)
        #expect(open.needsDiscover == true)
        #expect(open.lastRefreshed == VaultRig.t0)
    }

    @Test func underOtherRulesWithNothingReadNoReadIsAskedFor() {
        var state = Self.sealed(version: VaultReading.version - 1)
        state.finds = []
        state.copies = [:]
        state.read = [:]
        #expect(state.opened(generation: 3, people: Self.people).state.needsReadAgain == false)
        state.needsReadAgain = true
        #expect(state.opened(generation: 3, people: Self.people).state.needsReadAgain, "one already owed stays owed")
        state.read = [Self.card: "1 2"]
        state.needsReadAgain = false
        #expect(state.opened(generation: 3, people: Self.people).state.needsReadAgain, "a document read is reason enough")
    }

    @Test func aWaitingNumberIsRebuiltFromItsOwnPersonsCopiesAsCorrected() throws {
        // Anna's card, and a copy printing the number for someone read as "Bo Lind": corrected
        // everywhere to Erik, it is Erik's paper, which names Anna's number and never speaks for it.
        let erik = Person(id: "erik", displayName: "Erik", fullNames: ["Erik Johan Eriksson"])
        let anna = VaultReading.finds(in: ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"], from: Self.card)[0]
        let other = VaultReading.finds(in: ["Delta Dental", "Member Name: BO LIND", "Member ID: XZB123456789"], from: Self.copy)[0]
        var waiting = anna
        waiting.assignment = .person("anna")
        let value = VaultReading.normalized(anna.value)
        var state = VaultReadingState(generation: 3, finds: [waiting], copies: [value: [Self.card: anna, Self.copy: other]])
        func rank(of path: String, people: [Person], names: [String: String]) throws -> Int? {
            state.names = names
            let find = try #require(state.opened(generation: 3, people: people).state.finds.first)
            return find.facts.sources.first { $0.path == path }?.rank
        }
        let corrected = [VaultReading.spellingKey("BO LIND"): "Erik Johan Eriksson"]
        #expect(try rank(of: Self.copy, people: Self.people + [erik], names: corrected) == VaultReading.Rank.mention)
        #expect(try rank(of: Self.copy, people: Self.people + [erik], names: [:]) != VaultReading.Rank.mention,
                "read as nobody's, the copy is Anna's own")
        #expect(try rank(of: Self.copy, people: [], names: corrected) != VaultReading.Rank.mention,
                "with no people, there is no one else's paper")
    }

    @MainActor @Test(arguments: [0, -1])
    func theModelSealsAgainExactlyWhatItTook(rulesBack: Int) async throws {
        let rig = try VaultRig(); defer { rig.cleanUp() }
        let generation = VaultSetAside.generation(in: rig.defaults)
        var state = Self.sealed(version: VaultReading.version + rulesBack, generation: generation)
        // Every field the model holds set, a later build's among them, so none is left behind.
        state.lastDiscovered = VaultRig.t0.addingTimeInterval(-86_400)
        state.laterFields = Data(#"{"aLaterBuildsField":[1,2]}"#.utf8)
        try rig.store.saveReading(state)
        let sealed = try #require(rig.store.loadReading())
        let model = rig.model()
        model.people = Self.people
        await model.opened()
        #expect(sealed.laterFields != nil && sealed.lastDiscovered != nil)
        #expect(model.sealedReading == sealed.opened(generation: generation, people: Self.people).state)
        #expect(model.readingChanged == (rulesBack != 0))
    }
}
