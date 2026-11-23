import Foundation

/// Where a number is used: the United States, India, or anywhere, as a passport is.
public enum VaultGeo: String, Codable, CaseIterable, Sendable {
    case us, india, anywhere

    public var title: String {
        switch self {
        case .us: return "United States"
        case .india: return "India"
        case .anywhere: return "Every Country"
        }
    }

    /// The two letters a row carries in the All view; none for Every Country.
    public var code: String? {
        switch self {
        case .us: return "US"
        case .india: return "IN"
        case .anywhere: return nil
        }
    }

    /// Where a number is used, as its document says, and how that is known. A passport is carried
    /// across borders, so it is anywhere; a number typed in is anywhere until a country is chosen.
    public static func read(_ category: VaultCategory, facts: VaultReadFacts?) -> (geo: VaultGeo, reason: String) {
        switch category {
        case .passport: return (.anywhere, "A passport is carried in every country")
        // Where the visa lets its holder in: the country that issued it.
        case .usVisa:
            switch facts?.issuer {
            case "USA"?: return (.us, "A US visa")
            case "IND"?: return (.india, facts?.form == "OCI" ? "An OCI card" : "An Indian visa")
            case nil where facts == nil || facts?.form == nil: return (.us, "A US visa")
            default: return (.anywhere, "Another country’s visa")
            }
        case .i94: return (.us, "A US admission record")
        case .uscisCase: return (.us, "A US immigration case")
        case .ssn: return (.us, facts?.form == "ITIN" ? "An IRS number" : "A Social Security card")
        case .pan: return (.india, "An Indian PAN")
        case .aadhaar: return (.india, "An Aadhaar number")
        case .voterID: return (.india, "An Election Commission card")
        case .driversLicense:
            switch facts?.issuer {
            case "USA": return (.us, "A US license")
            case "IND": return (.india, "An Indian license")
            case "CAN": return (.anywhere, "A Canadian license")
            default: return (.anywhere, facts == nil ? "Typed in; no country chosen yet" : "Its country was not read")
            }
        case .health, .utilities, .loans, .other:
            return (.anywhere, facts == nil ? "Typed in; no country chosen yet" : "Its country was not read")
        }
    }
}

/// Which countries the list shows.
public enum VaultGeoFilter: String, CaseIterable, Sendable {
    case us, india, all

    public var title: String {
        switch self {
        case .us: return "United States"
        case .india: return "India"
        case .all: return "Every Country"
        }
    }

    public var geo: VaultGeo? {
        switch self {
        case .us: return .us
        case .india: return .india
        case .all: return nil
        }
    }

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

    public static let `default` = VaultGroups(
        names: ["travel": "Travel & Immigration", "legal": "Legal & IDs", "health": "Health", "home": "Home & Money",
                "contact": "Contact"],
        groupOf: [.passport: "travel", .usVisa: "travel", .i94: "travel", .uscisCase: "travel",
                  .driversLicense: "legal", .ssn: "legal", .pan: "legal", .aadhaar: "legal", .voterID: "legal",
                  .health: "health", .utilities: "home", .loans: "home", .other: "home"],
        // Contact last: its cards come after every ID's (``VaultContactCard``).
        order: ["travel", "legal", "health", "home", "contact"])

    public func name(_ id: ID) -> String { names[id] ?? Self.default.names[id] ?? id }

    public func group(of category: VaultCategory) -> ID? { groupOf[category] ?? Self.default.groupOf[category] }

    static let namesKey = "vaultGroupNames"
    static let membersKey = "vaultGroupMembers"

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
        return groups
    }

    public func save(to defaults: UserDefaults) {
        let names = self.names.filter { Self.default.names[$0.key] != $0.value }
        let members = Dictionary(uniqueKeysWithValues: groupOf.filter { Self.default.groupOf[$0.key] != $0.value }
            .map { ($0.key.rawValue, $0.value) })
        if names.isEmpty { defaults.removeObject(forKey: Self.namesKey) } else { defaults.set(names, forKey: Self.namesKey) }
        if members.isEmpty { defaults.removeObject(forKey: Self.membersKey) } else { defaults.set(members, forKey: Self.membersKey) }
    }
}
