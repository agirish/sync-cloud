import Foundation

/// What one spelling of a person's name is to them.
public enum VaultNameRole: String, Codable, Sendable, CaseIterable {
    /// The name forms ask for "as on your passport". One per person.
    case legal
    /// The name they use day to day.
    case goesBy
    /// A real spelling some of their papers print.
    case alsoUsed
    /// A scan got it wrong: corrected to the legal name on every ID read with it.
    case misread

    public var title: String {
        switch self {
        case .legal: return "Legal name"
        case .goesBy: return "Goes by"
        case .alsoUsed: return "Also used"
        case .misread: return "Misread"
        }
    }
}

/// The roles chosen for one person's spellings, by ``VaultReading/spellingKey(_:)``. Sealed with
/// what was read, beside the corrections Edit makes: names never go to preferences.
public struct VaultNameRoles: Codable, Equatable, Sendable {
    /// The spelling chosen as their legal name; nil goes by the Vault's guess.
    public var legal: String?
    public var goesBy: String?
    /// Spellings kept as real ones (Also used, or Not a Misreading): never flagged as misread.
    public var kept: [String]

    public init(legal: String? = nil, goesBy: String? = nil, kept: [String] = []) {
        self.legal = legal
        self.goesBy = goesBy
        self.kept = kept
    }

    var isEmpty: Bool { legal == nil && goesBy == nil && kept.isEmpty }
}

enum VaultNameGuess {
    /// The legal name before one is chosen: the passport's spelling (the one most papers share
    /// among those the passport prints), else the one most papers print. Never `excluding`.
    static func legal(_ names: [VaultPersonSection.PrintedName], excluding: String?) -> Int? {
        let candidates = names.indices.filter { VaultReading.spellingKey(names[$0].name) != excluding }
        func best(_ indices: [Int]) -> Int? {
            indices.max { a, b in
                (names[a].on.count, names[a].name.count) < (names[b].on.count, names[b].name.count)
            }
        }
        return best(candidates.filter { names[$0].on.contains("passport") }) ?? best(candidates)
    }

    /// Whether `name` looks like a misreading of `legal`: printed on one kind of paper only, and
    /// one or two letters from it. A guess to show, never to act on.
    static func looksMisread(_ name: VaultPersonSection.PrintedName, legal: String) -> Bool {
        guard name.on.count == 1 else { return false }
        let (a, b) = (VaultReading.spellingKey(name.name), VaultReading.spellingKey(legal))
        guard a != b else { return false }
        return (1...2).contains(distance(Array(a), Array(b)))
    }

    /// Letters to add, drop or change to turn one into the other.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let held = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = held
            }
        }
        return row[b.count]
    }
}

extension VaultModel {
    /// Gives `name` a role among `person`'s spellings. Misread corrects it to their legal name on
    /// every ID read with it, as Edit's Everywhere does, and answers how many IDs that changed.
    @discardableResult
    public func setRole(_ role: VaultNameRole, of name: String, for person: String) -> Int {
        let key = VaultReading.spellingKey(name)
        guard !key.isEmpty, contents == .loaded else { return 0 }
        var roles = nameRoles[person] ?? VaultNameRoles()
        var changed = 0
        switch role {
        case .legal:
            roles.legal = key
            if roles.goesBy == key { roles.goesBy = nil }
        case .goesBy:
            roles.goesBy = key
            if roles.legal == key { roles.legal = nil }
        case .alsoUsed:
            if roles.legal == key { roles.legal = nil }
            if roles.goesBy == key { roles.goesBy = nil }
            if !roles.kept.contains(key) { roles.kept.append(key) }
        case .misread:
            guard let section = peopleSections.first(where: { $0.id == .person(person) }),
                  let legal = section.names.first(where: { $0.role == .legal })?.name,
                  VaultReading.spellingKey(legal) != key else { return 0 }
            changed = rows.filter { $0.ownHolderName == nil && $0.holderAsRead.map(VaultReading.spellingKey) == key }.count
            roles.kept.removeAll { $0 == key }
            if roles.goesBy == key { roles.goesBy = nil }
            correctEverywhere(key, to: legal)
        }
        nameRoles[person] = roles.isEmpty ? nil : roles
        readingChanged = true
        saveReading()
        return changed
    }

    /// Takes back a Misread: IDs read with `name` show it as read again.
    public func undoMisread(_ name: String) {
        correctEverywhere(VaultReading.spellingKey(name), to: nil)
        readingChanged = true
        saveReading()
    }
}
