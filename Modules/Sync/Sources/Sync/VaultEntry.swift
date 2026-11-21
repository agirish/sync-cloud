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

    /// Its identity for as long as it is kept; only ``reissued()`` gives a copy another.
    public private(set) var id: UUID
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
    /// The document's own date, when it was read: a passport's expiry, an I-94's date of entry.
    public var dated: Date?
    /// Marked older by a build before pins (``pin``). Stored only when set.
    private var older: Bool?
    /// The card it shows on, chosen in the editor. Nil for an entry from before categories, which
    /// goes by its kind (``VaultCategory/from(kind:)``) or by what was read.
    private var chosenCategory: VaultCategory?
    /// What the documents said, when it was read rather than typed: kept so it is weighed against
    /// later reads (a newer passport makes this one older) and its details stay copyable.
    public var facts: VaultReadFacts?
    /// Current or older, as the user chose.
    private var pinned: VaultPin?
    /// Set when the user put it in the household: a number read with someone's name on it, which
    /// ``personID`` nil alone would leave to that name.
    private var household: Bool?
    /// Where it is used, as the user chose (Used In). Nil goes by the document, or Anywhere.
    public var geo: VaultGeo?
    /// The card it goes on when moved from its own (Kind): another account kind or one the
    /// household made. Nil draws it on ``category``'s card, which stays what it was read or typed as.
    public var card: VaultCardID?
    /// The name on its document as the user corrected it (Edit's Name), when the scan misread
    /// it: "Shweta Ravindra Dani" for a card read as "…Dant". What was read stays in ``facts``.
    public var holderName: String?
    /// The copy of its document the user chose to read it from (Read from This Copy), by path,
    /// when another copy of the same document would be: its name and details are shown, and it
    /// opens. Nil lets the Vault choose.
    public var chosenSource: String?

    /// Whose it is, as the user said: the person chosen, the household, or nil to go by the name
    /// the document was read with.
    public var assignment: VaultAssignment? {
        get {
            if household == true { return .household }
            return personID.map { .person($0) }
        }
        set {
            switch newValue {
            case .person(let id)?: personID = id; household = nil
            case .household?: personID = nil; household = true
            case nil: personID = nil; household = nil
            }
        }
    }

    public var category: VaultCategory {
        get { facts?.category ?? chosenCategory ?? VaultCategory.from(kind: kind, title: title) }
        set {
            chosenCategory = newValue
            facts?.category = newValue
            kind = newValue.kind
        }
    }

    public var pin: VaultPin? {
        get { pinned ?? (older == true ? .older : nil) }
        set { pinned = newValue; older = nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, value, personID, note, kind, sourcePath, addedAt, updatedAt, dated, older
        case chosenCategory = "category", facts, pinned = "pin", household, geo, card, holderName, chosenSource
    }

    public init(id: UUID = UUID(), title: String, value: String, personID: String? = nil,
                note: String = "", kind: Kind = .other, sourcePath: String? = nil,
                addedAt: Date, updatedAt: Date? = nil, dated: Date? = nil,
                category: VaultCategory? = nil, facts: VaultReadFacts? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.personID = personID
        self.note = note
        self.kind = category?.kind ?? facts?.category.kind ?? kind
        self.sourcePath = sourcePath ?? facts?.primary?.path
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
        self.dated = dated ?? facts?.dated
        self.chosenCategory = category
        self.facts = facts
    }
}

/// An entry never prints its number. A log line, an assertion message or a `dump` that takes one
/// shows the title and the ending, the same as a locked row (``EditorPDFSecret`` is the model).
extension VaultEntry {
    /// The same record under a new identity: for one restored from a backup when another record
    /// here already has its id.
    func reissued() -> VaultEntry {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

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

    /// A document's name with any number in it cut to its ending. People name a scan after what
    /// is on it ("Passport A38291647.pdf"), so a file's name can hold the very number the Vault
    /// is hiding. A run of five or more letters and digits, four or more of them digits, counts as
    /// a number; a year or a page number does not.
    ///
    /// A number is often written with spaces or dashes ("WAC 26 901 23456"), so letters and digits
    /// joined by single separators are judged as one run: five or more of them, four or more
    /// digits. A date ("2024-03-01", "01.04.2024") is not a number.
    public static func fileName(_ path: String) -> String {
        name((path as NSString).lastPathComponent)
    }

    /// A folder path, each folder's name masked as a file's is: people name a folder after what
    /// is in it, too ("Passport A38291647/").
    public static func folder(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { name(String($0)) }.joined(separator: "/")
    }

    /// Letters and digits joined by up to three separators: "123 - 45 - 6789", "(123) 45 6789",
    /// "2345,6789,0123" are each one number written out.
    /// Letters and digits, any script's, joined by up to six of anything else but a folder's
    /// slash: "123 - 45 - 6789", "123–45–6789" with an en dash, "1234    5678    9012", groups
    /// joined by a non-breaking space, an ampersand or an apostrophe are each one number.
    private static let joinedRun = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:[^\p{L}\p{N}/]{1,6}[\p{L}\p{N}]+)*"#)
    private static func isSeparator(_ c: Character) -> Bool { !(c.isLetter || c.isNumber) }
    private static let dateLike = try! NSRegularExpression(
        pattern: #"^(?:(?:19|20)\d{2}[._-]\d{1,2}(?:[._-]\d{1,2})?|\d{1,2}[._-]\d{1,2}[._-](?:19|20)?\d{2}|(?:19|20)\d{2}[ ._-]+(?:19|20)\d{2})$"#)

    private static func name(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        // Right to left, so earlier ranges stay put as later ones are replaced.
        for match in joinedRun.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let whole = ns.substring(with: match.range)
            // Judge each stretch of the run that holds digits: words around a number stay.
            let words = whole.split(omittingEmptySubsequences: false, whereSeparator: isSeparator)
            var masked = whole
            var start: Int?
            func judge(_ from: Int, _ to: Int) {
                let stretch = words[from...to].joined(separator: " ")
                let alnum = stretch.filter { $0.isLetter || $0.isNumber }
                let digits = alnum.filter(\.isNumber).count
                let piece = Self.piece(of: whole, words: words, from: from, to: to)
                let isDate = dateLike.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) != nil
                guard alnum.count >= 5, digits >= 4, !isDate else { return }
                masked = masked.replacingOccurrences(of: piece, with: Self.masked(piece))
            }
            // Digit groups, and a short capital prefix such as "WAC", join into one stretch; a word
            // mixing letters and digits ("V9416925", "797A") is judged on its own.
            // Two separators side by side ("123 - 45") leave an empty word between them, which
            // neither ends a stretch nor belongs to one.
            var last = 0
            for (index, word) in words.enumerated() {
                if word.isEmpty { continue }
                let digitsOnly = word.allSatisfy(\.isNumber)
                // A short run of capitals beside digits is part of the number: "WAC", a PAN's
                // "ABCDE" and its last letter.
                let prefix = word.count <= 5 && word.allSatisfy { $0.isUppercase }
                let mixed = word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
                let stretchDigits = start.map { s in words[s...last].reduce(0) { $0 + $1.filter(\.isNumber).count } } ?? 0
                if digitsOnly || prefix || (mixed && stretchDigits >= 4) {
                    // A word mixing letters and digits after a stretch that is already a number
                    // ("A1234 B5678") is more of it.
                    start = start ?? index
                    last = index
                } else {
                    if let s = start { judge(s, last); start = nil }
                    // Otherwise a word mixing letters and digits starts a stretch of its own: the
                    // digit groups after it are the rest of it ("D123 4567 8901"), and a stretch
                    // before it is judged apart ("I-797A" stays).
                    if mixed { start = index; last = index }
                }
            }
            if let s = start { judge(s, last) }
            out = (out as NSString).replacingCharacters(in: match.range, with: masked)
        }
        return out
    }

    /// The text of `words[from...to]` as it stands in `whole`, separators included.
    private static func piece(of whole: String, words: [Substring], from: Int, to: Int) -> String {
        let start = words[from].startIndex
        let end = words[to].endIndex
        return String(whole[start..<end])
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

    /// `value` in the groups its document prints, for Large Type, so it can be checked against
    /// the card: as written where the value has its own spaces or dashes (`(408) 555-0142`,
    /// `KA05 20090001234`), a written run of more than six cut in fours; else the kind's own
    /// pattern where it has one and the length fits (a Social Security number 3-2-4, a PAN 5-4-1);
    /// else fours.
    public static func printed(_ value: String, as category: VaultCategory?) -> [String] {
        let written = value.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if written.count > 1 {
            return written.flatMap { $0.count > 6 ? groups($0) : [$0] }
        }
        let pattern: [Int]
        switch category {
        case .ssn?: pattern = [3, 2, 4]
        case .pan?: pattern = [5, 4, 1]
        default: return groups(value)
        }
        let significant = Array(value.filter { $0.isLetter || $0.isNumber })
        guard significant.count == pattern.reduce(0, +) else { return groups(value) }
        var start = 0
        return pattern.map { size in
            defer { start += size }
            return String(significant[start..<start + size])
        }
    }
}
