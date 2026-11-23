import Foundation
import Testing
@testable import Sync

/// The user's choices as one value (VT69): carried whole by every record that holds them, stored
/// flat under the keys each always used, and kept by a re-read.
@Suite struct VaultChoicesTests {
    /// Every choice made. Each test below carries every field of it, so a choice a record drops
    /// fails here once it is set in `all`.
    static let all = VaultChoices(pin: .older, assignment: .person("pat"), geo: .india, card: .custom("k1"),
                                  source: "/papers/copy.pdf")
    static let facts = VaultReadFacts(category: .passport, holder: "Pat Q", sources: [VaultSource(path: "/papers/p.pdf", role: "Passport", rank: 1)])

    /// A tripwire, since its mirror is empty (it can hold a path): a choice added at the end of
    /// ``VaultChoices`` makes it bigger (fields are laid out in order). Set the new choice in
    /// `all`, then this size. (112 since a place is a country's code and names, VT4.)
    @Test func aNewChoiceIsSetInAll() {
        #expect(MemoryLayout<VaultChoices>.size == 112)
    }

    @Test func eachRecordCarriesEveryChoiceThroughItsStore() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let find = VaultFind(title: "Passport", value: "Z0000001", facts: Self.facts, choices: Self.all)
        #expect(try decoder.decode(VaultFind.self, from: encoder.encode(find)).choices == Self.all)
        let choice = VaultChoice(find)
        #expect(choice.choices == Self.all && choice.isChosen)
        #expect(try decoder.decode(VaultChoice.self, from: encoder.encode(choice)).choices == Self.all)
        var entry = VaultEntry(title: "Passport", value: "Z0000001", addedAt: Date(timeIntervalSince1970: 0))
        entry.choices = Self.all
        #expect(entry.choices == Self.all)
        #expect(try decoder.decode(VaultEntry.self, from: encoder.encode(entry)).choices == Self.all)
        entry.choices = VaultChoices()
        #expect(entry.choices == VaultChoices() && entry.assignment == nil && entry.personID == nil)
        // The editor's draft, and a find being confirmed with the copy it was read from.
        var draft = VaultModel.Draft(title: "Passport", value: "Z0000001", personID: "pat", pin: .older)
        draft.geo = .india
        draft.card = .custom("k1")
        draft.chosenSource = "/papers/copy.pdf"
        #expect(draft.choices == Self.all)
    }

    /// A saved ID's row and a waiting one's start with every choice made about it.
    @Test func aRowStartsWithEveryChoice() {
        let reading: VaultRowSource.ChosenReading = (Self.facts, nil, nil, [])
        var entry = VaultEntry(title: "Passport", value: "Z0000001", addedAt: Date(timeIntervalSince1970: 0))
        entry.choices = Self.all
        let find = VaultFind(title: "Passport", value: "Z0000001", facts: Self.facts, choices: Self.all)
        for row in [VaultModel.Row(entry: entry, facts: Self.facts, personID: nil, readHolder: nil, reading: reading),
                    VaultModel.Row(find: find, facts: Self.facts, personID: nil, readHolder: nil, reading: reading)] {
            #expect(row.pin == .older && row.assignment == .person("pat") && row.chosenGeo == .india
                    && row.chosenCard == .custom("k1"))
        }
    }

    /// As an older build sealed them: the keys read are the ones it wrote.
    @Test func whatAnOlderBuildSealedOpensWithItsChoices() throws {
        let facts = String(decoding: try JSONEncoder().encode(Self.facts), as: UTF8.self)
        let find = #"{"id":"00000000-0000-0000-0000-000000000001","title":"Passport","value":"Z0000001","note":"","facts":FACTS,"pin":"older","assignment":{"person":{"_0":"pat"}},"geo":"india","card":"custom:k1","chosenSource":"/papers/copy.pdf"}"#
            .replacingOccurrences(of: "FACTS", with: facts)
        #expect(try JSONDecoder().decode(VaultFind.self, from: Data(find.utf8)).choices == Self.all)
        let choice = #"{"id":"00000000-0000-0000-0000-000000000001","pin":"older","assignment":{"person":{"_0":"pat"}},"geo":"india","card":"custom:k1","source":"/papers/copy.pdf"}"#
        #expect(try JSONDecoder().decode(VaultChoice.self, from: Data(choice.utf8)).choices == Self.all)
    }

    /// Setting the choices sets only those that changed: an older build's `older`, and a person
    /// stored beside the household, stay as stored.
    @Test func settingTheChoicesKeepsHowAnOlderBuildStoredTheRest() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000009","title":"Old","value":"Z9","note":"","kind":"identity","addedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","older":true,"household":true,"personID":"pat"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var entry = try decoder.decode(VaultEntry.self, from: Data(json.utf8))
        entry.choices.card = .custom("k1")
        let stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(stored["older"] as? Bool == true && stored["pin"] == nil)
        #expect(stored["household"] as? Bool == true && stored["personID"] as? String == "pat")
        #expect(entry.choices.pin == .older && entry.choices.assignment == .household)
    }

    /// Flat, beside the record's own fields, under the keys sealed files already hold: a find's
    /// copy is `chosenSource`, a waiting choice's `source`.
    @Test func theChoicesAreStoredFlatUnderTheirOldKeys() throws {
        func keys(_ data: Data) throws -> Set<String> {
            Set(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        }
        let find = VaultFind(title: "Passport", value: "Z0000001", facts: Self.facts, choices: Self.all)
        #expect(try keys(JSONEncoder().encode(find))
                == ["id", "title", "value", "note", "facts", "pin", "assignment", "geo", "card", "chosenSource"])
        #expect(try keys(JSONEncoder().encode(VaultChoice(find))) == ["id", "pin", "assignment", "geo", "card", "source"])
        let bare = VaultFind(title: "Passport", value: "Z0000001", facts: Self.facts)
        #expect(try keys(JSONEncoder().encode(bare)) == ["id", "title", "value", "note", "facts"], "a choice not made is not written")
        #expect(!VaultChoice(bare).isChosen)
    }

    @Test func eachChoiceMadeWinsAndTheRestComeFromTheOther() {
        let made = VaultChoices(pin: .current, geo: .us)
        let merged = made.or(Self.all)
        #expect(merged == VaultChoices(pin: .current, assignment: .person("pat"), geo: .us, card: .custom("k1"),
                                       source: "/papers/copy.pdf"))
        #expect(made.or(nil) == made)
        let other = VaultChoices(pin: .current, assignment: .household, geo: .anywhere, card: .builtIn(.health), source: "/papers/other.pdf")
        #expect(Self.all.or(other) == Self.all, "every choice made here wins")
        #expect(VaultChoices().or(Self.all) == Self.all)
    }

    @Test func aReReadKeepsTheIdAndTheChoicesAndTakesWhatItRead() {
        let kept = VaultChoice(id: UUID(), choices: Self.all)
        var read = Self.facts
        read.holder = "Pat Quill"
        let fresh = VaultFind(title: "Passport book", value: "Z0000001", note: "Pat Quill", facts: read)
        let carried = fresh.keepingChoices(of: kept)
        #expect(carried.id == kept.id && carried.choices == Self.all)
        #expect(carried.title == "Passport book" && carried.note == "Pat Quill" && carried.facts == read)
    }
}
