import Foundation

/// One number the Vault keeps: a passport number, a member ID, a loan number.
///
/// The first place this app holds a number in full past the moment it reads it. Everything else it
/// saves is an ending or a salted hash (``FilingCorpus``, the learned accounts), and that rule
/// stands for them: an entry is written only inside ``VaultFile``'s sealed bytes, and never to a
/// log, to UserDefaults or to Claude.
public struct VaultEntry: Sendable, Equatable, Identifiable, Codable {
    /// What the number belongs to, which groups the list.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case identity, health, phone, home, money, other

        /// The list's group heading.
        public var title: String {
            switch self {
            case .identity: return "Identity and Travel"
            case .health: return "Health"
            case .phone: return "Phone and Utilities"
            case .home: return "Home and Auto"
            case .money: return "Money"
            case .other: return "Other"
            }
        }

        public var symbol: String {
            switch self {
            case .identity: return "globe"
            case .health: return "heart"
            case .phone: return "phone"
            case .home: return "house"
            case .money: return "banknote"
            case .other: return "number"
            }
        }
    }

    public let id: UUID
    /// What it is, in the user's words: "Mortgage loan number".
    public var title: String
    /// The number in full, as typed or read, spaces and dashes included.
    public var value: String
    /// Whose it is: a ``Person/id``, or nil for one the household shares.
    public var personID: String?
    /// The issuer, or anything else worth a line: "Home loan servicer".
    public var note: String
    public var kind: Kind
    /// The document it came from, when it was read rather than typed.
    public var sourcePath: String?
    public var addedAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, value: String, personID: String? = nil,
                note: String = "", kind: Kind = .other, sourcePath: String? = nil,
                addedAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.personID = personID
        self.note = note
        self.kind = kind
        self.sourcePath = sourcePath
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
    }
}

/// An entry never prints its number. A log line, an assertion message or a `dump` that takes one
/// shows the title and the ending, the same as a locked row (``EditorPDFSecret`` is the model).
extension VaultEntry: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultEntry(\(title), \(VaultMask.masked(value)))" }
    public var debugDescription: String { description }
    /// No children, so `dump`, a debugger's `p` and a test's expanded failure show none either.
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// How a number is drawn when it may not be shown in full.
public enum VaultMask {
    /// What stands in for a hidden letter or digit.
    public static let dot: Character = "•"

    /// `value` with every letter and digit but the last `keep` replaced by a dot. Spaces, dashes
    /// and brackets stay, so `(408) 555-0142` still reads as a phone number: `(•••) •••-0142`.
    ///
    /// Four is what the rest of the app already shows (`Mortgage 7365`, `••7863`). A value of four
    /// characters or fewer is hidden whole: its ending would be all of it.
    public static func masked(_ value: String, keep: Int = 4) -> String {
        let significant = value.filter { $0.isLetter || $0.isNumber }.count
        var toHide = significant > keep ? significant - keep : significant
        return String(value.map { character -> Character in
            guard character.isLetter || character.isNumber, toHide > 0 else { return character }
            toHide -= 1
            return dot
        })
    }

    /// The letters and digits in groups of `size`, for reading a number out loud: Large Type
    /// draws these with air between them. Separators are dropped; they are not said.
    public static func groups(_ value: String, size: Int = 4) -> [String] {
        let significant = Array(value.filter { $0.isLetter || $0.isNumber })
        guard size > 0 else { return [String(significant)] }
        return stride(from: 0, to: significant.count, by: size).map {
            String(significant[$0..<min($0 + size, significant.count)])
        }
    }
}
