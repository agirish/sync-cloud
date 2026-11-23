import Foundation

/// Where a number is used: a country, or anywhere, as a passport is. Stored by its raw value
/// ("us", "india", "anywhere"). The logic goes by ``countries`` and never assumes two (VT4); a new
/// country is a case here with its code and title, its place in ``countries``, a case of
/// ``VaultGeoFilter`` (`VaultKindSpecTests` checks every country has one), and the kinds' place
/// rules that should send papers there (``VaultKindSpec``'s `place`).
public enum VaultGeo: String, Codable, CaseIterable, Sendable {
    case us, india, anywhere

    /// The countries a number can be used in, in the order the Where choice lists them.
    public static let countries: [VaultGeo] = [.us, .india]

    /// Where the household lives: its addresses, phones and emails are used there, so the
    /// Contact cards show in that country's view (``VaultContactCard``).
    public static let home: VaultGeo = .us

    public var title: String {
        switch self {
        case .us: return "United States"
        case .india: return "India"
        case .anywhere: return "Every Country"
        }
    }

    /// The country's two letters ("US"), which a row carries in the All view; nil for anywhere.
    public var code: String? {
        switch self {
        case .us: return "US"
        case .india: return "IN"
        case .anywhere: return nil
        }
    }

    /// The country with these two letters.
    public init?(code: String) {
        guard let known = Self.countries.first(where: { $0.code == code }) else { return nil }
        self = known
    }

    /// Where a number is used, as its document says, and how that is known
    /// (``VaultKindSpec``'s `place`). A passport is carried across borders, so it is anywhere; a
    /// number typed in is anywhere until a country is chosen.
    public static func read(_ category: VaultCategory, facts: VaultReadFacts?) -> (geo: VaultGeo, reason: String) {
        category.spec.place(facts)
    }
}

/// Which countries the list shows: one, or all of them. Stored by its raw value.
public enum VaultGeoFilter: String, CaseIterable, Sendable {
    case us, india, all

    /// The one country shown; nil for all.
    public var geo: VaultGeo? {
        switch self {
        case .us: return .us
        case .india: return .india
        case .all: return nil
        }
    }

    /// The view of one country; nil for anywhere, which is no country's.
    public static func showing(_ country: VaultGeo) -> VaultGeoFilter? {
        allCases.first { $0.geo == country }
    }

    public var title: String { geo?.title ?? "Every Country" }

    /// A number used anywhere shows in every country's view.
    public func shows(_ geo: VaultGeo) -> Bool {
        guard let only = self.geo else { return true }
        return geo == .anywhere || geo == only
    }
}

/// The groups the Kinds choice offers: the app's to start, which the user can rename and move a
/// kind between (Customize Groups). Kept in UserDefaults: names of kinds and groups only.
public struct VaultGroups: Equatable, Sendable {
    /// A group's id, stable across renames.
    public typealias ID = String

    public var names: [ID: String]
    public var groupOf: [VaultCategory: ID]
    /// The groups in the order the choices list them.
    public var order: [ID]

    /// The app's groups (``VaultGroupSpec``), and each kind in the one its row starts it in.
    public static let `default` = VaultGroups(
        names: Dictionary(uniqueKeysWithValues: VaultGroupSpec.all.map { ($0.id, $0.name) }),
        groupOf: Dictionary(uniqueKeysWithValues: VaultKindSpec.all.map { ($0.category, $0.group) }),
        order: VaultGroupSpec.all.map(\.id))

    public func name(_ id: ID) -> String { names[id] ?? Self.default.names[id] ?? id }

    public func group(of category: VaultCategory) -> ID? { groupOf[category] ?? Self.default.groupOf[category] }

    static let namesKey = "vaultGroupNames"
    static let membersKey = "vaultGroupMembers"
    /// The groups' order, where it is not the app's: ids, first to last.
    static let orderKey = "vaultGroupOrder"

    /// Moves a group `step` places up (negative) or down; at either end it stays.
    public mutating func move(_ id: ID, by step: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        let to = min(max(from + step, 0), order.count - 1)
        guard to != from else { return }
        order.insert(order.remove(at: from), at: to)
    }

    /// Moves groups as a drag in a list does.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { order[$0] }
        var rest = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let at = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(at, 0), rest.count))
        order = rest
    }

    /// Whether `id` can move up, or down.
    public func canMove(_ id: ID, by step: Int) -> Bool {
        guard let at = order.firstIndex(of: id) else { return false }
        return order.indices.contains(at + step)
    }

    /// The saved groups over the app's: a kind or a name never customized keeps the app's.
    public static func load(from defaults: UserDefaults) -> VaultGroups {
        var groups = VaultGroups.default
        for (id, name) in defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        where groups.order.contains(id) && !name.trimmingCharacters(in: .whitespaces).isEmpty {
            groups.names[id] = name
        }
        for (raw, id) in defaults.dictionary(forKey: membersKey) as? [String: String] ?? [:] {
            // Never into Contact: it holds the household's addresses, phones and emails, not IDs.
            if let category = VaultCategory(rawValue: raw), groups.idGroups.contains(id) { groups.groupOf[category] = id }
        }
        // The order saved, of the groups this build knows; one a later build added keeps its
        // place after them.
        if let saved = defaults.stringArray(forKey: orderKey) {
            let known = saved.filter { groups.order.contains($0) }
            groups.order = known + groups.order.filter { !known.contains($0) }
        }
        return groups
    }

    public func save(to defaults: UserDefaults) {
        let names = self.names.filter { Self.default.names[$0.key] != $0.value }
        let members = Dictionary(uniqueKeysWithValues: groupOf.filter { Self.default.groupOf[$0.key] != $0.value }
            .map { ($0.key.rawValue, $0.value) })
        if names.isEmpty { defaults.removeObject(forKey: Self.namesKey) } else { defaults.set(names, forKey: Self.namesKey) }
        if members.isEmpty { defaults.removeObject(forKey: Self.membersKey) } else { defaults.set(members, forKey: Self.membersKey) }
        if order == Self.default.order { defaults.removeObject(forKey: Self.orderKey) } else { defaults.set(order, forKey: Self.orderKey) }
    }
}
