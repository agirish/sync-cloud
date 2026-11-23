import Foundation

/// The card an ID goes on: one of the app's kinds, or one the household made
/// (``VaultCustomKind``).
///
/// Only an account's kind can change (``VaultKinds/changeable``): a passport, a visa or a license
/// is known by its reader, which checked the number for what it is, and stays on its card. An ID
/// moved to another card keeps the kind it was read as, which the panel names beside the choice,
/// and As Read puts it back.
public enum VaultCardID: Hashable, Sendable, Codable {
    case builtIn(VaultCategory)
    case custom(VaultCustomKind.ID)

    /// How a card is stored: an app kind by its own name ("health"), as the folded cards were
    /// stored before custom kinds, or "custom:" and the kind's id.
    public var key: String {
        switch self {
        case .builtIn(let category): return category.rawValue
        // A later build's card this one could not read is written back as it was found.
        case .custom(let id) where id.hasPrefix(Self.unknown): return String(id.dropFirst(Self.unknown.count))
        case .custom(let id): return "custom:" + id
        }
    }

    private static let unknown = "unknown:"

    public init?(key: String) {
        if key.hasPrefix("custom:") {
            let id = String(key.dropFirst(7))
            guard !id.isEmpty else { return nil }
            self = .custom(id)
        } else if let category = VaultCategory(rawValue: key) {
            self = .builtIn(category)
        } else {
            return nil
        }
    }

    /// Never fails: a card this build does not know (a later build's kind) reads as a custom kind
    /// that is not kept, which draws as read. A whole sealed Vault must never fail to open for one.
    public init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        self = VaultCardID(key: key) ?? .custom(Self.unknown + key)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

/// A kind the household named: "Memberships", "Kids' School". It holds accounts as Other does:
/// nothing about it is checked, and it is weighed like any account.
public struct VaultCustomKind: Codable, Equatable, Identifiable, Sendable {
    public typealias ID = String
    public let id: ID
    public var name: String
    /// The group the Kinds choice lists it under (``VaultGroups``).
    public var group: VaultGroups.ID

    public init(id: ID = UUID().uuidString, name: String, group: VaultGroups.ID) {
        self.id = id
        self.name = name
        self.group = group
    }
}

/// The household's own kinds, in the order they were made. Kept in UserDefaults beside the
/// groups: names only, never a number.
public struct VaultKinds: Equatable, Sendable {
    public var custom: [VaultCustomKind] = []

    public init(custom: [VaultCustomKind] = []) { self.custom = custom }

    /// The kinds an account can be moved between, and the only ones an ID can be moved from:
    /// what a reader checks the number of (a passport, a visa) stays where it was read.
    public static let changeable: [VaultCategory] = VaultKindSpec.all.filter(\.isAccount).map(\.category)

    public static func canChange(from category: VaultCategory) -> Bool { changeable.contains(category) }

    /// The app kind a name is, by its title: "Passports", "utilities & phone".
    public static func appKind(named name: String) -> VaultCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return VaultCategory.mainView.first {
            $0.title.caseInsensitiveCompare(trimmed) == .orderedSame || $0.singular.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    public func kind(_ id: VaultCustomKind.ID) -> VaultCustomKind? { custom.first { $0.id == id } }

    /// Whether a card can be drawn: an app kind always, a custom kind while it is kept.
    public func exists(_ card: VaultCardID) -> Bool {
        switch card {
        case .builtIn: return true
        case .custom(let id): return kind(id) != nil
        }
    }

    /// Whether an account can be put on `card`: an account kind, or a custom kind still kept.
    /// Never an identity kind's card, whatever was stored.
    public func canHold(_ card: VaultCardID) -> Bool {
        switch card {
        case .builtIn(let category): return Self.canChange(from: category)
        case .custom(let id): return kind(id) != nil
        }
    }

    /// A card's row, for its title and symbol: an app kind's own, or the household's kind drawn
    /// as Other (``VaultKindSpec/custom(_:)``).
    func spec(of card: VaultCardID) -> VaultKindSpec {
        switch card {
        case .builtIn(let category): return category.spec
        case .custom(let id): return VaultKindSpec.custom(kind(id))
        }
    }

    public func title(of card: VaultCardID) -> String { spec(of: card).title }

    public func symbol(of card: VaultCardID) -> String { spec(of: card).symbol }

    /// The group a card is listed under in the Kinds choice.
    public func group(of card: VaultCardID, in groups: VaultGroups) -> VaultGroups.ID? {
        switch card {
        case .builtIn(let category): return groups.group(of: category)
        case .custom(let id): return kind(id)?.group ?? groups.group(of: .other)
        }
    }

    /// Every card in the order the main view draws them: the app's, then the household's.
    public var order: [VaultCardID] {
        VaultCategory.mainView.map(VaultCardID.builtIn) + custom.map { .custom($0.id) }
    }

    /// Where a new kind goes, and the cards an account can be moved to.
    public var targets: [VaultCardID] {
        Self.changeable.map(VaultCardID.builtIn) + custom.map { .custom($0.id) }
    }

    static let key = "vaultCustomKinds"

    public static func load(from defaults: UserDefaults) -> VaultKinds {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([Lenient].self, from: data) else { return VaultKinds() }
        return VaultKinds(custom: stored.compactMap(\.kind).filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    public func save(to defaults: UserDefaults) {
        if custom.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(custom) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// One stored kind, or nothing when it cannot be read.
    private struct Lenient: Decodable {
        let kind: VaultCustomKind?
        init(from decoder: Decoder) throws { kind = try? VaultCustomKind(from: decoder) }
    }

    /// The folder an account's papers are filed in, years taken out (a year's folder too, "2023 -
    /// Anna"): what a choice of kind is learned for. `Home/Utilities/EBMUD/2024/March.pdf`
    /// teaches `Home/Utilities/EBMUD`.
    public static func lessonFolder(of path: String) -> String {
        let folders = (path as NSString).deletingLastPathComponent.split(separator: "/").filter { !isYear($0) }
        return "/" + folders.joined(separator: "/")
    }

    /// A folder named for a year (`2024`, `2024 Tax`), as a lesson is learnt without: what the
    /// pattern `^(?:19|20)[0-9]{2}(?![0-9])` matched, without compiling it per folder (VT66).
    static func isYear(_ folder: Substring) -> Bool {
        let digits = Array(folder.utf8.prefix(5))
        guard digits.count >= 4, digits[0] == UInt8(ascii: "1") && digits[1] == UInt8(ascii: "9")
                || digits[0] == UInt8(ascii: "2") && digits[1] == UInt8(ascii: "0") else { return false }
        let isDigit = { (b: UInt8) in (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) }
        guard isDigit(digits[2]), isDigit(digits[3]) else { return false }
        return digits.count == 4 || !isDigit(digits[4])
    }

    /// Whether a paper's folder is one account's, deep enough to learn for: below a kind of
    /// account (`Home/Utilities/EBMUD`, `Vehicles/Tesla/Supercharging`), never the area or its
    /// first folder (`Home/Utilities`), where loose papers of many accounts sit together.
    public static func teaches(_ path: String, under roots: [String]) -> Bool {
        let place = VaultReadPlan.place(of: path, under: roots).filter { !isYear(Substring($0)) }
        return place.count >= 3 && VaultReadPlan.area(of: path, under: roots) == .accounts
    }
}
