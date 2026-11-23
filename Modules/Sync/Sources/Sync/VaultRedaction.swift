import Foundation

// Every Vault type that holds a number, a holder's name or a document's path prints without
// them: `print`, string interpolation, a debugger's `po` and `dump` all go through these. One
// careless log line is then a line of counts and kinds, never what the Vault guards. A file's
// path can hold the very number it carries ("Passport A38291647.pdf").

extension VaultReadFacts: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "VaultReadFacts(\(category.rawValue), \(sources.count) document(s), \(details.count) detail(s))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultSource: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultSource(\(role), rank \(rank))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultDetail: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultDetail(\(label))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultMention: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultMention(\(category.rawValue), \(VaultMask.masked(value)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension MachineZone: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "MachineZone(\(kind), \(VaultMask.masked(number)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultStandingInput: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultStandingInput(\(category.rawValue), \(VaultMask.masked(value)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultChoices: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Which choices were made, never what: a copy's path can hold its number, and whose names
    /// a person.
    public var description: String {
        let made = [pin.map { "pin \($0.rawValue)" }, assignment.map { _ in "whose" }, geo.map { "used in \($0.rawValue)" },
                    card.map { _ in "card" }, source.map { _ in "copy" }].compactMap { $0 }
        return "VaultChoices(\(made.isEmpty ? "none" : made.joined(separator: ", ")))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultChoice: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultChoice(\(pin?.rawValue ?? "no pin"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultModel.Row: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultModel.Row(\(category.rawValue), \(VaultMask.masked(value)), \(standing.tab.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultModel.Draft: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultModel.Draft(\(category.rawValue), \(VaultMask.masked(value)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultReadTally: CustomReflectable {
    /// The numbers it has counted are kept, normalised, to count each once: never shown.
    public var customMirror: Mirror {
        Mirror(self, children: ["documents": documents, "opened": opened, "added": added])
    }
}

// Held in full and printed nowhere (VT28): a detail's value, what a refresh changed, a person's
// section with its names and dates of birth, and what Read Documents keeps.

extension VaultDetail.Value: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .text: return "VaultDetail.Value(text)"
        case .date: return "VaultDetail.Value(date)"
        case .number(let number): return "VaultDetail.Value(\(VaultMask.masked(number)))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultChange: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultChange(\(label))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultPersonSection: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultPersonSection(\(rows.count) ID(s), \(names.count) name(s), \(births.count) date(s) of birth)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

// A section's parts too: a name as printed, a date of birth. (`Owner` prints as it is: People
// sorts its sections by it, and it holds a name only for one nobody answers to.)
extension VaultPersonSection.PrintedName: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultPersonSection.PrintedName(\(on.count) kind(s))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultPersonSection.Birth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultPersonSection.Birth(\(rows.count) ID(s))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

// A card's values, a number corrected by hand, and the household's contact details (the 2026-11-23
// review): printed as what they are, never what they hold.

extension VaultCardValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultCardValue(\(label), \(VaultMask.masked(value)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultReadAs: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultReadAs(\(VaultMask.masked(reads)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultAddress: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultAddress(\(state))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultContacts: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "VaultContacts(\(phones.count) phone(s), \(emails.count) email(s), \(addresses.count) address(es))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultContacts.Typed: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultContacts.Typed(\(label ?? "no label"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultContacts.TypedAddress: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultContacts.TypedAddress(\(address))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultContactCard: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultContactCard(\(kind.rawValue), \(items.count) item(s))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultContactCard.Item: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultContactCard.Item(\(kind.rawValue), \(people.count) person(s))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultPersonSection.Address: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultPersonSection.Address(\(address), \(rows.count) ID(s))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultPersonSection.Phone: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultPersonSection.Phone(\(label ?? "no label"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultBackupContents: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "VaultBackupContents(\(entries.count) ID(s), \(contacts?.count ?? 0) person(s)' contacts)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
