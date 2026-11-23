import Foundation

/// What the panel's lists are worked out from beyond the rows (VT7 d): the search, the tab, the
/// person, country and kind choices, and the kinds and groups. Each list (the visible rows, the
/// cards, the counts) is a function of the rows and this value alone, and People's sections of
/// those and the household's people and their names' roles, so the rules are tested with no
/// model, and the model works a list out again only when one of them moved (VT9).
struct VaultRowFilter: Equatable {
    var query: String
    var tab: VaultStanding.Tab
    var person: VaultModel.PersonFilter
    var geo: VaultGeoFilter
    var kind: VaultGroups.ID?
    var kinds: VaultKinds
    var groups: VaultGroups

    typealias Row = VaultModel.Row

    var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The rows the tab, the person filter and the search leave. A search looks in every tab:
    /// a number asked about on a call may be an older one.
    func visible(_ rows: [Row]) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            // A search looks past the filters, as past the tabs: a number asked about on a call may
            // be another country's, another person's or another kind.
            guard needle.isEmpty else {
                return row.title.lowercased().contains(needle) || row.note.lowercased().contains(needle)
                    || row.category.title.lowercased().contains(needle) || row.whose.lowercased().contains(needle)
                    || kinds.title(of: row.card).lowercased().contains(needle)
                    || row.readAs.title.lowercased().contains(needle)
            }
            return row.standing.tab == tab && passes(row)
        }
        .sorted { [place = cardPlace] in order($0, $1, place: place) }
    }

    /// Whether `row` is one the person, country and kind choices leave, with any of the three
    /// given here in place of the one chosen. Names, notes and kinds are what a search matches,
    /// never the number: a search that matched on digits would confirm a guess at a locked number
    /// one keystroke at a time.
    func passes(_ row: Row, person: VaultModel.PersonFilter? = nil, geo: VaultGeoFilter? = nil,
                kind: VaultGroups.ID?? = nil) -> Bool {
        switch person ?? self.person {
        case .everyone: break
        case .household: if !row.isHousehold { return false }
        case .person(let id): if row.personID != id { return false }
        }
        guard (geo ?? self.geo).shows(row.geo) else { return false }
        if let group = kind ?? self.kind, kinds.group(of: row.card, in: groups) != group { return false }
        return true
    }

    /// How many of `rows` on `tab` (the one shown, unless another is given) the choices leave,
    /// with any of the three given here in place of the one chosen.
    func count(_ rows: [Row], in tab: VaultStanding.Tab? = nil, person: VaultModel.PersonFilter? = nil,
               geo: VaultGeoFilter? = nil, kind: VaultGroups.ID?? = nil) -> Int {
        let tab = tab ?? self.tab
        return rows.filter { $0.standing.tab == tab && passes($0, person: person, geo: geo, kind: kind) }.count
    }

    /// The same kind in another country, for "2 more in India" at the foot of its card: only
    /// while one country is chosen, and only what the person and kind choices would show there.
    func elsewhere(_ card: VaultCardID, in rows: [Row]) -> (filter: VaultGeoFilter, count: Int)? {
        guard !searching, geo != .all else { return nil }
        return elsewhere(rows.filter { $0.card == card && $0.standing.tab == tab })
    }

    /// The first other country, in the Where choice's order, that `rows` hold any of the person
    /// and kind choices would show there, and how many.
    private func elsewhere(_ rows: [Row]) -> (filter: VaultGeoFilter, count: Int)? {
        for country in VaultGeo.countries where country != geo.geo {
            guard let there = VaultGeoFilter.showing(country) else { continue }
            let count = rows.filter { $0.geo == country && passes($0, geo: there) }.count
            if count > 0 { return (there, count) }
        }
        return nil
    }

    /// Kinds that have nothing in this country but some in another: one line under the cards,
    /// since no card of theirs is drawn to carry "N more in …". `visible` is ``visible(_:)``'s.
    func elsewhereKinds(_ rows: [Row], visible: [Row]) -> (filter: VaultGeoFilter, count: Int)? {
        guard !searching, geo != .all else { return nil }
        let shown = Set(visible.map(\.card))
        return elsewhere(rows.filter { $0.standing.tab == tab && !shown.contains($0.card) })
    }

    /// Cards in the groups' order, each with its rows (``VaultKinds/order(by:)``).
    /// A kind with nothing is left out. `visible` is ``visible(_:)``'s.
    func cards(_ visible: [Row]) -> [(card: VaultCardID, rows: [Row])] {
        let order = tab == .other && !searching
            ? Set(visible.map(\.card)).sorted { $0.key < $1.key } : kinds.order(by: groups)
        return order.compactMap { card in
            let rows = visible.filter { $0.card == card }
            return rows.isEmpty ? nil : (card, rows)
        }
    }

    /// Each card's place in ``VaultKinds/order(by:)``: worked out once per sort, not per pair.
    var cardPlace: [VaultCardID: Int] {
        Dictionary(kinds.order(by: groups).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    /// By card, then whose, then current before in-use before expired, then newest.
    func order(_ a: Row, _ b: Row, place: [VaultCardID: Int]? = nil) -> Bool {
        let place = place ?? cardPlace
        let (ca, cb) = (place[a.card] ?? 999, place[b.card] ?? 999)
        if ca != cb { return ca < cb }
        if a.whose != b.whose { return a.whose.localizedStandardCompare(b.whose) == .orderedAscending }
        func weight(_ s: VaultStanding) -> Int { s.inUse ? 1 : s.expired ? 2 : 0 }
        if weight(a.standing) != weight(b.standing) { return weight(a.standing) < weight(b.standing) }
        let (da, db) = (a.facts?.dated ?? .distantPast, b.facts?.dated ?? .distantPast)
        if da != db { return da > db }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    // MARK: People

    /// The People view: every person with an ID the tab, filters and search leave, in People's
    /// order; then names nobody in People answers to; the household last. `visible` is
    /// ``visible(_:)``'s; `roles` are the roles chosen for each person's spellings; `contacts`
    /// what was typed for each person.
    ///
    /// A person's names and birth date come from all their documents, on either tab and whatever
    /// the filters hide: they are facts about the person, not about one ID.
    func peopleSections(_ rows: [Row], visible: [Row], people: [Person],
                        roles: [String: VaultNameRoles], contacts: [String: VaultContacts] = [:]) -> [VaultPersonSection] {
        func owner(_ row: Row) -> VaultPersonSection.Owner {
            if row.isHousehold { return .household }
            if let id = row.personID { return .person(id) }
            return .unnamed(row.facts?.holder ?? row.whose)
        }
        let all = Dictionary(grouping: rows, by: owner)
        let shown = Dictionary(grouping: visible, by: owner)
        func section(_ id: VaultPersonSection.Owner, _ title: String) -> VaultPersonSection? {
            let theirs = all[id] ?? []
            var typed = VaultContacts()
            if case .person(let person) = id { typed = contacts[person] ?? VaultContacts() }
            // A person's home is also what the household's own papers print (the utility bills),
            // unless their own papers or what they typed say something newer.
            var mailed = theirs
            if case .person = id { mailed += all[.household] ?? [] }
            let addresses = Self.addresses(on: mailed, typed: typed.addresses, notTheirs: Set(typed.notTheirs))
            let rows = shown[id] ?? []
            // On Archive, someone with past addresses is shown though no ID of theirs is there:
            // a past address is never out of reach. Not under a search or a filter that hides them.
            guard !rows.isEmpty || (tab == .archive && addresses.count > 1 && showsWithoutIDs(id)) else { return nil }
            // Names by how they are printed, each with the kinds that print it so.
            var names: [VaultPersonSection.PrintedName] = []
            let order = VaultCategory.mainView
            let papers = theirs.sorted { (order.firstIndex(of: $0.category) ?? 99) < (order.firstIndex(of: $1.category) ?? 99) }
            for row in papers where id != .household {
                // An identity paper's name: an account's holder line is the plan's, not the form's.
                guard let holder = row.facts?.holder.map(VaultPersonText.tidied), !holder.isEmpty,
                      let kind = VaultPersonText.paper(row.category) else { continue }
                if let index = names.firstIndex(where: { $0.name.caseInsensitiveCompare(holder) == .orderedSame }) {
                    if !names[index].on.contains(kind) { names[index].on.append(kind) }
                    names[index].rows.append(row)
                } else {
                    names.append(.init(name: holder, on: [kind], rows: [row]))
                }
            }
            names = roled(names, for: id, roles: roles)
            // Each date with the IDs it was read from: a second date is one ID's reading, and the
            // ID is where it is put right.
            let dated = id == .household ? [] : papers.filter { $0.facts?.born != nil }
            let births = Dictionary(grouping: dated) { $0.facts?.born ?? .distantPast }
                .map { VaultPersonSection.Birth(date: $0.key, rows: $0.value) }
                .sorted { ($0.rows.count, $1.date) > ($1.rows.count, $0.date) }
            let onThisTab = Set(rows.map(\.id))
            var made = VaultPersonSection(id: id, title: title, names: names, births: births, groups: grouped(rows),
                                          elsewhere: theirs.filter { !onThisTab.contains($0.id) && $0.standing.tab != tab && $0.standing.tab != .other }.count)
            made.addresses = addresses
            made.phones = typed.phones
            made.emails = typed.emails
            // A license still good that prints an address they have since left.
            if let home = addresses.first {
                let licenses = theirs.filter { $0.category == .driversLicense && $0.standing.tab == .current }
                let printed = Set(licenses.flatMap { ($0.facts?.sources ?? []).compactMap { $0.address?.address.key } })
                made.licenseDiffers = printed.contains(home.address.key) ? nil
                    : addresses.dropFirst().first { printed.contains($0.address.key) }
            }
            return made
        }
        var sections = people.compactMap { section(.person($0.id), $0.displayName) }
        // Someone removed from People keeps their IDs, under the words their rows already use.
        let known = Set(people.map(\.id))
        for case .person(let id) in shown.keys.sorted(by: { "\($0)" < "\($1)" }) where !known.contains(id) {
            if let gone = section(.person(id), "Someone no longer in People") { sections.append(gone) }
        }
        let unnamed = shown.keys.compactMap { key -> String? in
            if case .unnamed(let name) = key { return name }
            return nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        sections += unnamed.compactMap { section(.unnamed($0), $0) }
        if let household = section(.household, "Household") { sections.append(household) }
        return sections
    }

    /// Whether a section with no ID on the tab may still be shown (Archive's past addresses): no
    /// search, no kind filter, a view that shows the household's home country
    /// (``VaultGeo/home``), and a person filter that leaves them.
    func showsWithoutIDs(_ owner: VaultPersonSection.Owner) -> Bool {
        guard !searching, kind == nil, geo.shows(.home) else { return false }
        switch person {
        case .everyone: return true
        case .household: return owner == .household
        case .person(let id): return owner == .person(id)
        }
    }

    /// The home addresses `papers` print and the ones typed, one per address however printed
    /// (``VaultAddress/key``), newest first. One said not to be theirs is left out.
    static func addresses(on papers: [Row], typed: [VaultContacts.TypedAddress], notTheirs: Set<String>) -> [VaultPersonSection.Address] {
        var byKey: [String: VaultPersonSection.Address] = [:]
        var order: [String] = []
        func later(_ a: Date?, _ b: Date?) -> Date? {
            guard let a else { return b }
            guard let b else { return a }
            return max(a, b)
        }
        for row in papers {
            for source in row.facts?.sources ?? [] {
                guard let printed = source.address else { continue }
                let key = printed.address.key
                guard !notTheirs.contains(key) else { continue }
                guard var known = byKey[key] else {
                    byKey[key] = .init(address: printed.address, dated: printed.dated, rows: [row], typed: false)
                    order.append(key)
                    continue
                }
                if !known.typed, printed.address.isTidier(than: known.address) { known.address = printed.address }
                known.dated = later(known.dated, printed.dated)
                if !known.rows.contains(where: { $0.id == row.id }) { known.rows.append(row) }
                byKey[key] = known
            }
        }
        for entry in typed {
            let key = entry.address.key
            if byKey[key] == nil { order.append(key) }
            var known = byKey[key] ?? .init(address: entry.address, dated: nil, rows: [], typed: true)
            // What was typed is shown as typed.
            known.address = entry.address
            known.typed = true
            known.dated = later(known.dated, entry.added)
            byKey[key] = known
        }
        let made = order.compactMap { key -> VaultPersonSection.Address? in
            guard var address = byKey[key] else { return nil }
            if !address.typed { address.address = address.address.tidied }
            return address
        }
        // Newest first; one with no date after every dated one; then by how many papers print it.
        return made.enumerated().sorted { a, b in
            switch (a.element.dated, b.element.dated) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.element.rows.count, -a.offset) > (b.element.rows.count, -b.offset)
            }
        }.map(\.element)
    }

    /// `names` with their roles, legal name first, then the one they go by, then the rest by how
    /// many papers print them. Roles are chosen for someone in People; a name nobody answers to
    /// gets the Vault's guess alone.
    func roled(_ names: [VaultPersonSection.PrintedName], for owner: VaultPersonSection.Owner,
               roles: [String: VaultNameRoles]) -> [VaultPersonSection.PrintedName] {
        guard !names.isEmpty else { return names }
        var names = names
        let chosen: VaultNameRoles
        if case .person(let id) = owner { chosen = roles[id] ?? VaultNameRoles() } else { chosen = VaultNameRoles() }
        let keys = names.map { VaultReading.spellingKey($0.name) }
        let goesBy = chosen.goesBy.flatMap { keys.firstIndex(of: $0) }
        let legal = chosen.legal.flatMap { keys.firstIndex(of: $0) }
            ?? VaultNameGuess.legal(names, excluding: goesBy.map { keys[$0] })
        for index in names.indices {
            names[index].role = index == legal ? .legal : index == goesBy ? .goesBy : .alsoUsed
            if let legal, names[index].role == .alsoUsed, !chosen.kept.contains(keys[index]) {
                names[index].looksMisread = VaultNameGuess.looksMisread(names[index], legal: names[legal].name)
            }
        }
        let rank: (VaultPersonSection.PrintedName) -> Int = { $0.role == .legal ? 0 : $0.role == .goesBy ? 1 : 2 }
        return names.enumerated().sorted { a, b in
            (rank(a.element), -a.element.on.count, a.offset) < (rank(b.element), -b.element.on.count, b.offset)
        }.map(\.element)
    }

    /// `rows` under the groups their cards are listed in, in the groups' order and, within one, the
    /// cards' order; kinds in no group last, under Other.
    func grouped(_ rows: [Row]) -> [VaultPersonSection.KindGroup] {
        // Each card's place in the order, its first if listed twice: looked up once (VT103).
        let place = Dictionary(kinds.order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let sorted = rows.enumerated().sorted { a, b in
            let (x, y) = (place[a.element.card] ?? .max, place[b.element.card] ?? .max)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        let byGroup = Dictionary(grouping: sorted) { kinds.group(of: $0.card, in: groups) }
        var out = groups.order.compactMap { id -> VaultPersonSection.KindGroup? in
            guard let rows = byGroup[id], !rows.isEmpty else { return nil }
            return .init(id: id, name: groups.name(id), rows: rows)
        }
        let placed = Set(out.flatMap { $0.rows.map(\.id) })
        let rest = sorted.filter { !placed.contains($0.id) }
        if !rest.isEmpty { out.append(.init(id: nil, name: "Other", rows: rest)) }
        return out
    }
}
