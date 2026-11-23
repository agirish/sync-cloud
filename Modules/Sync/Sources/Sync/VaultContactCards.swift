import Foundation

/// The Contact group's cards in Cards and List: everyone's home addresses, phones and emails, as
/// People shows them one person at a time. Their rows are not IDs: never masked, never to
/// confirm, never counted beside the IDs, and never in ``VaultModel/rows``.
public struct VaultContactCard: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case addresses, phones, emails

        public var title: String {
            switch self {
            case .addresses: return "Home Addresses"
            case .phones: return "Phones"
            case .emails: return "Emails"
            }
        }

        public var symbol: String {
            switch self {
            case .addresses: return "house"
            case .phones: return "phone"
            case .emails: return "envelope"
            }
        }
    }

    /// One row: an address with everyone who lives there, or one person's phone or email.
    public struct Item: Equatable, Identifiable, Sendable {
        public var id: String
        public var kind: Kind
        /// Whose it is, by People's id, in People's order: everyone at an address.
        public var people: [String]
        /// As shown: the address on one line, the phone the US way, the email as typed.
        public var value: String
        /// The address, with the papers that print it and how new it is.
        public var address: VaultPersonSection.Address?
        /// The phone or email as typed, and its place among the person's.
        public var typed: VaultContacts.Typed?
        public var index: Int?
        /// The phone, typed or read, with the papers that print it.
        public var phone: VaultPersonSection.Phone?
        /// A past address: where they used to live (Archive).
        public var past = false
        /// On Current, someone here has a license that still prints a past address.
        public var licenseDiffers = false
    }

    public var kind: Kind
    public var items: [Item]
    public var id: Kind { kind }
}

extension VaultGroups {
    /// The Contact group: its cards are the household's addresses, phones and emails, not kinds
    /// of ID, so no kind is ever moved into it.
    public static let contact: ID = "contact"

    /// The groups a kind of ID can be listed under: every group but Contact.
    public var idGroups: [ID] { order.filter { $0 != Self.contact } }
}

extension VaultModel {
    /// The Contact group's cards for the tab, choices and search: Home Addresses (where they live
    /// now on Current, where they lived on Archive), then Phones and Emails on Current. A shared
    /// address is one row naming everyone there.
    ///
    /// A search looks past the tab and the choices, as it does for IDs, and matches a street, a
    /// city, a ZIP, a phone's digits and an email: they are shown plainly, unlike an ID's number.
    public var contactCards: [VaultContactCard] {
        Self.contactCards(rows: rows, people: people, contacts: contacts, tab: tab, query: query,
                          person: personFilter, geo: geoFilter, kind: kindFilter)
    }

    static func contactCards(rows: [Row], people: [Person], contacts: [String: VaultContacts], tab: VaultStanding.Tab,
                             query: String, person: PersonFilter, geo: VaultGeoFilter, kind: VaultGroups.ID?) -> [VaultContactCard] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searching = !needle.isEmpty
        if !searching {
            guard tab != .other, person != .household, geo.shows(.home) else { return [] }
            if let kind, kind != VaultGroups.contact { return [] }
        }
        let names = Dictionary(people.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let household = rows.filter(\.isHousehold)
        // Every address of everyone, so a shared one names all who live there.
        var addresses: [String: VaultContactCard.Item] = [:]
        var order: [String] = []
        for someone in people {
            let theirs = rows.filter { !$0.isHousehold && $0.personID == someone.id }
            let typed = contacts[someone.id] ?? VaultContacts()
            let all = VaultRowFilter.addresses(on: theirs + household, typed: typed.addresses, notTheirs: Set(typed.notTheirs))
            guard let home = all.first else { continue }
            let licenses = theirs.filter { $0.category == .driversLicense && $0.standing.tab == .current }
            let printed = Set(licenses.flatMap { ($0.facts?.sources ?? []).compactMap { $0.address?.address.key } })
            let differs = !printed.contains(home.address.key) && all.dropFirst().contains { printed.contains($0.address.key) }
            for (place, address) in all.enumerated() {
                let past = place > 0
                if !searching && past != (tab == .archive) { continue }
                let id = "address:\(past ? "past" : "home"):\(address.address.key)"
                if var known = addresses[id] {
                    known.people.append(someone.id)
                    known.licenseDiffers = known.licenseDiffers || (!past && differs)
                    var merged = known.address ?? address
                    if let a = merged.dated, let b = address.dated { merged.dated = max(a, b) } else { merged.dated = merged.dated ?? address.dated }
                    for row in address.rows where !merged.rows.contains(where: { $0.id == row.id }) { merged.rows.append(row) }
                    merged.typed = merged.typed || address.typed
                    known.address = merged
                    addresses[id] = known
                } else {
                    addresses[id] = .init(id: id, kind: .addresses, people: [someone.id], value: address.address.oneLine,
                                          address: address, past: past, licenseDiffers: !past && differs)
                    order.append(id)
                }
            }
        }
        var homes = order.compactMap { addresses[$0] }
        homes.sort { a, b in
            if a.past != b.past { return !a.past }
            switch (a.address?.dated, b.address?.dated) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            default: return false
            }
        }
        var phones: [VaultContactCard.Item] = []
        var emails: [VaultContactCard.Item] = []
        // Phones and emails have no past: they are on Current, or found by a search.
        if searching || tab == .current {
            for someone in people {
                let theirs = contacts[someone.id] ?? VaultContacts()
                let all = VaultRowFilter.phones(of: someone.id, on: rows, typed: theirs.phones,
                                                notTheirs: Set(theirs.notTheirPhones))
                for phone in all {
                    phones.append(.init(id: "phone:\(someone.id):\(phone.key)", kind: .phones, people: [someone.id],
                                        value: phone.shown, typed: phone.typedIndex.map { theirs.phones[$0] },
                                        index: phone.typedIndex, phone: phone))
                }
                for (index, email) in theirs.emails.enumerated() {
                    emails.append(.init(id: "email:\(someone.id):\(index)", kind: .emails, people: [someone.id],
                                        value: email.value, typed: email, index: index))
                }
            }
        }
        func keeps(_ item: VaultContactCard.Item) -> Bool {
            if searching { return matches(item, needle, names: names) }
            if case .person(let id) = person { return item.people.contains(id) }
            return true
        }
        return [VaultContactCard(kind: .addresses, items: homes.filter(keeps)),
                VaultContactCard(kind: .phones, items: phones.filter(keeps)),
                VaultContactCard(kind: .emails, items: emails.filter(keeps))]
            .filter { !$0.items.isEmpty }
    }

    /// Whether a search finds `item`: its value or a part of its address, a phone's digits, or
    /// the name of someone it is theirs.
    static func matches(_ item: VaultContactCard.Item, _ needle: String, names: [String: String]) -> Bool {
        var texts = [item.value] + item.people.compactMap { names[$0] }
        if let a = item.address?.address { texts += [a.street, a.unit ?? "", a.city, a.state, a.zip] }
        if texts.contains(where: { $0.lowercased().contains(needle) }) { return true }
        let digits = needle.filter(\.isNumber)
        guard item.kind == .phones, digits.count >= 3, digits.count == needle.filter({ !$0.isWhitespace && $0 != "-" && $0 != "(" && $0 != ")" }).count
        else { return false }
        return item.value.filter(\.isNumber).contains(digits)
    }

    /// How many rows the Contact group holds for the person and country chosen: the Kinds
    /// choice's count beside its name.
    public var contactCount: Int {
        Self.contactCards(rows: rows, people: people, contacts: contacts, tab: tab, query: "",
                          person: personFilter, geo: geoFilter, kind: VaultGroups.contact).reduce(0) { $0 + $1.items.count }
    }

    /// The Contact cards' rows, all of them, in the order they are drawn.
    public var contactItems: [VaultContactCard.Item] { contactCards.flatMap(\.items) }
}
