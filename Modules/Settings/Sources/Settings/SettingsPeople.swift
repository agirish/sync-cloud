import Foundation
import Sync

/// People on an Ask Claude card: a person's fields, their place in the list, and Add Person,
/// through the `PeopleStore` Settings edits.
///
/// A person is one value: an edit, its undo and its Changed from Chat line hold the whole person
/// (`encode`), so an undo puts back exactly who they were, and only while they are still who the
/// card made them. The list's order is one value too: its ids, in order.
@MainActor
public struct SettingsPeople {
    public var store: PeopleStore?

    public init(store: PeopleStore?) {
        self.store = store
    }

    /// Why people can't be changed here, in Settings' words; nil when they can.
    public var refusal: String? {
        guard let store else { return "People can’t be changed until the folder survey has run." }
        if store.rosterIsUnreadable { return "Can’t change people: people.json is unreadable." }
        if !store.repeatedRosterIds.isEmpty { return "Can’t change people: people.json repeats an ID." }
        return nil
    }

    public var people: [Person] { store?.people ?? [] }

    /// The person a card names, by id or by name.
    public func person(named target: String) -> Person? {
        people.first { $0.id == target } ?? people.first { $0.displayName.compare(target, options: .caseInsensitive) == .orderedSame }
    }

    // MARK: Values, for undo and the record

    /// A person as one stored value; "" when there is no such person. Keys sorted, because older
    /// Foundations can order them differently per encode and an unchanged person would read as
    /// changed.
    public static func encode(_ person: Person?) -> String {
        guard let person else { return "" }
        let fields = Fields(displayName: person.displayName, relationship: person.relationship,
                            fullNames: person.fullNames, aliases: person.aliases)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(fields)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Whether two stored values are the same person, by their fields, so a value recorded with
    /// its keys in another order still matches. Anything that isn't a person (an order) compares
    /// as text.
    public static func same(_ a: String, _ b: String) -> Bool {
        let decoder = JSONDecoder()
        guard let first = try? decoder.decode(Fields.self, from: Data(a.utf8)),
              let second = try? decoder.decode(Fields.self, from: Data(b.utf8)) else { return a == b }
        return first == second
    }

    /// The order as one stored value: whether it is Settings' default arrangement or their own,
    /// then the ids. Without the first line, an undone move would leave the list in a "custom"
    /// order that only looks like the default.
    public var order: String {
        ([store?.orderIsCustom == true ? "custom" : "default"] + people.map(\.id)).joined(separator: "\n")
    }

    /// `people.edit` with a person's id is that person; with none, the order. `people.add` with
    /// an id is whether the card's added person is there.
    public func value(_ id: String, target: String?) -> SettingValue? {
        guard store != nil else { return nil }
        guard let target else { return id == "people.edit" ? .string(order) : nil }
        return .string(Self.encode(people.first { $0.id == target }))
    }

    /// Puts back a value `value(_:target:)` gave.
    public func set(_ id: String, target: String?, _ value: SettingValue) -> SettingsWriter.Outcome {
        if let refusal { return .refused(refusal) }
        guard case .string(let text) = value, let store else { return .refused("That isn’t a person.") }
        guard let target else { return setOrder(text) }
        if text.isEmpty {
            guard store.person(id: target) != nil else { return .done }
            store.remove(id: target)
            return .done
        }
        guard let fields = try? JSONDecoder().decode(Fields.self, from: Data(text.utf8)) else { return .refused("That isn’t a person.") }
        if store.person(id: target) != nil {
            return update(Person(id: target, displayName: fields.displayName, relationship: fields.relationship,
                                 fullNames: fields.fullNames, aliases: fields.aliases))
        }
        // Back after an undone Add: added again, as Add Person adds.
        return store.add(displayName: fields.displayName, relationship: fields.relationship,
                         fullNames: fields.fullNames, aliases: fields.aliases) == nil ? .refused("A person needs a name.") : .done
    }

    // MARK: Edits

    /// Saves a person's fields, as Settings' editor does. A name can't be blank.
    public func update(_ person: Person) -> SettingsWriter.Outcome {
        if let refusal { return .refused(refusal) }
        guard let store, store.person(id: person.id) != nil else { return .refused("That person isn’t in the list any more.") }
        guard !person.displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return .refused("A person needs a name.") }
        store.update(person)
        return .done
    }

    /// Add Person, in the card: the same fields Settings' sheet has.
    /// - Returns: The person as stored, or why not.
    public func add(name: String, relationship: String?, fullNames: [String], aliases: [String]) -> (person: Person?, refusal: String?) {
        if let refusal { return (nil, refusal) }
        guard let added = store?.add(displayName: name, relationship: relationship, fullNames: fullNames, aliases: aliases) else {
            return (nil, "A person needs a name.")
        }
        return (added, nil)
    }

    /// Move Up or Move Down; refused at either end.
    public func move(_ id: String, up: Bool) -> SettingsWriter.Outcome {
        if let refusal { return .refused(refusal) }
        return store?.move(id: id, up: up) == true ? .done : .refused("They’re already at the \(up ? "top" : "bottom").")
    }

    /// The list in `order`'s order: back to the default arrangement as Use Default Order makes it,
    /// or one move at a time, as the buttons would.
    private func setOrder(_ order: String) -> SettingsWriter.Outcome {
        var lines = order.split(separator: "\n").map(String.init)
        let kind = lines.first == "custom" || lines.first == "default" ? lines.removeFirst() : "custom"
        let ids = lines
        guard let store, Set(ids) == Set(people.map(\.id)) else { return .refused("The list has changed since.") }
        if kind == "default" {
            store.useDefaultOrder()
            return .done
        }
        // Each person moves up to their place: at most as many moves as places above them, so a
        // move that didn't move anyone can't keep this going.
        for (place, id) in ids.enumerated() {
            guard let now = people.firstIndex(where: { $0.id == id }) else { return .refused("The list has changed since.") }
            for _ in 0..<max(0, now - place) {
                guard store.move(id: id, up: true) else { return .refused("The list has changed since.") }
            }
        }
        return people.map(\.id) == ids ? .done : .refused("The list has changed since.")
    }

    /// "Jane · sister · also Janie": a person in words, for the card, the record and Claude.
    public static func words(_ value: String) -> String {
        guard let fields = try? JSONDecoder().decode(Fields.self, from: Data(value.utf8)) else { return value.isEmpty ? "no one" : value }
        var parts = [fields.displayName]
        if let relationship = fields.relationship { parts.append(relationship) }
        if !fields.fullNames.isEmpty { parts.append(fields.fullNames.joined(separator: ", ")) }
        if !fields.aliases.isEmpty { parts.append("also " + fields.aliases.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private struct Fields: Codable, Equatable {
        let displayName: String
        let relationship: String?
        let fullNames: [String]
        let aliases: [String]
    }
}
