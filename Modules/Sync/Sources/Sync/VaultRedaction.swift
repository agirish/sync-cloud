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
