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
