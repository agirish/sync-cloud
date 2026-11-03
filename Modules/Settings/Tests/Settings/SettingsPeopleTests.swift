import Foundation
import Testing
import Sync
@testable import Settings

/// TE290 step 9, part 2: People on a card, through the store Settings edits — a person as one
/// value for undo, the order as one value, and Settings' own refusals.
@MainActor
@Suite struct SettingsPeopleTests {

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("settings-people-\(UUID().uuidString)")
    }

    @Test func withoutTheSurveyNothingChanges() {
        let people = SettingsPeople(store: nil)
        #expect(people.refusal == "People can’t be changed until the folder survey has run.")
        #expect(people.value("people.edit", target: nil) == nil)
        #expect(people.add(name: "Jane", relationship: nil, fullNames: [], aliases: []).refusal != nil)
    }

    @Test func anEditIsUndoneByPuttingThePersonBack() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let people = SettingsPeople(store: PeopleStore(directory: dir, profileId: "t", profile: nil))
        let jane = try #require(people.add(name: "Jane", relationship: "wife", fullNames: ["Jane Doe"], aliases: []).person)
        let before = try #require(people.value("people.edit", target: jane.id))

        var edited = jane
        edited.aliases = ["Janie"]
        #expect(people.update(edited) == .done)
        #expect(people.person(named: "jane")?.aliases == ["Janie"])
        #expect(people.value("people.edit", target: jane.id) != before)
        #expect(people.set("people.edit", target: jane.id, before) == .done)
        #expect(people.person(named: jane.id)?.aliases == [])

        var blank = jane
        blank.displayName = "  "
        #expect(people.update(blank) == .refused("A person needs a name."))
        guard case .string(let text) = before else { Issue.record("not a string"); return }
        #expect(SettingsPeople.words(text) == "Jane · wife · Jane Doe")
    }

    @Test func anUndoneAddRemovesThePersonAndARedoAddsThemBack() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let people = SettingsPeople(store: PeopleStore(directory: dir, profileId: "t", profile: nil))
        let son = try #require(people.add(name: "Son", relationship: "son", fullNames: [], aliases: ["Kid"]).person)
        let added = try #require(people.value("people.add", target: son.id))
        #expect(people.set("people.add", target: son.id, .string("")) == .done)
        #expect(people.people.isEmpty)
        #expect(people.set("people.add", target: son.id, added) == .done)
        #expect(people.person(named: "Son")?.aliases == ["Kid"])
    }

    @Test func aMoveIsUndoneByPuttingTheOrderBack() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let people = SettingsPeople(store: PeopleStore(directory: dir, profileId: "t", profile: nil))
        for name in ["Ann", "Ben", "Cat"] { _ = people.add(name: name, relationship: nil, fullNames: [], aliases: []) }
        let before = try #require(people.value("people.edit", target: nil))
        let last = try #require(people.people.last)
        #expect(people.move(last.id, up: true) == .done)
        #expect(people.value("people.edit", target: nil) != before)
        #expect(people.set("people.edit", target: nil, before) == .done)
        #expect(people.value("people.edit", target: nil) == before)
        // The default arrangement comes back as the default, not a custom order that looks like it.
        #expect(people.store?.orderIsCustom == false)
        let first = try #require(people.people.first)
        #expect(people.move(first.id, up: true) == .refused("They’re already at the top."))
    }

    @Test func anUnreadableRosterChangesNothing() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"), withIntermediateDirectories: true)
        // JSON, but not a roster: what the store protects from being written over.
        try Data(#"{"people": "not a list"}"#.utf8).write(to: dir.appendingPathComponent("t/people.json"))
        let people = SettingsPeople(store: PeopleStore(directory: dir, profileId: "t", profile: nil))
        #expect(people.refusal == "Can’t change people: people.json is unreadable.")
        #expect(people.add(name: "Jane", relationship: nil, fullNames: [], aliases: []).person == nil)
    }

    @Test func aPersonsValueIsTheSameWhateverItsKeyOrder() {
        let person = Person(id: "jane", displayName: "Jane", relationship: "sister", fullNames: ["Jane Doe"], aliases: ["Janie"])
        let stored = SettingsPeople.encode(person)
        #expect(stored == #"{"aliases":["Janie"],"displayName":"Jane","fullNames":["Jane Doe"],"relationship":"sister"}"#)
        let shuffled = #"{"relationship":"sister","fullNames":["Jane Doe"],"displayName":"Jane","aliases":["Janie"]}"#
        #expect(SettingsPeople.same(stored, shuffled))
        #expect(!SettingsPeople.same(stored, shuffled.replacingOccurrences(of: "Janie", with: "JJ")))
        #expect(SettingsPeople.same("default\njane", "default\njane"))
        #expect(!SettingsPeople.same("default\njane", "custom\njane"))
    }
}
