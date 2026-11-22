import Foundation

/// How the panel lays its IDs out.
public enum VaultLayout: String, CaseIterable, Sendable {
    /// One card per kind, the person on each row.
    case cards
    /// The same rows in one column, under each kind's name.
    case list
    /// One section per person, the kind on each row, opening with what a form asks first.
    case people
}

/// One person's part of the People view: who they are as their documents say it, and their IDs.
public struct VaultPersonSection: Identifiable, Equatable, Sendable {
    public enum Owner: Hashable, Sendable {
        case person(String)
        /// A name read from documents that nobody in People answers to.
        case unnamed(String)
        /// What nobody in particular owns: the utilities, the mortgage.
        case household
    }

    /// A name as documents print it, and the kinds of document that print it that way: forms ask
    /// for a name "exactly as on your passport", and a license may print it differently.
    public struct PrintedName: Equatable, Sendable {
        public var name: String
        /// "passport", "driver’s license": lowercase, in the cards' order.
        public var on: [String]
        /// What this spelling is to them: chosen, or the Vault's guess.
        public var role: VaultNameRole = .alsoUsed
        /// One or two letters from the legal name on a single kind of paper, and not kept as real:
        /// worth a look. A guess shown, never acted on.
        public var looksMisread = false
    }

    /// A date of birth, and the IDs whose documents give it: where it was found, so a wrong one
    /// can be traced to the ID to remove or to give to whoever it belongs to.
    public struct Birth: Equatable, Sendable {
        public var date: Date
        /// Their IDs that carry this date, in the cards' order, from either tab and whatever the
        /// filters hide.
        public var rows: [VaultModel.Row]
    }

    /// The person's IDs of one group (Travel & Immigration, Legal & IDs, …), drawn under its name.
    public struct KindGroup: Equatable, Sendable {
        /// Nil for kinds listed under no group.
        public var id: VaultGroups.ID?
        public var name: String
        public var rows: [VaultModel.Row]
    }

    public var id: Owner
    /// The person's name in People, "Household", or the name as read.
    public var title: String
    public var names: [PrintedName]
    /// The birth dates their documents give: one, unless two documents disagree. The date most of
    /// their IDs give comes first, so a lone misreading is the one listed under it.
    public var births: [Birth]
    /// The dates alone.
    public var born: [Date] { births.map(\.date) }
    /// Their IDs on the tab being shown, group by group: the order they are drawn and walked in.
    public var rows: [VaultModel.Row] { groups.flatMap(\.rows) }
    /// Their IDs on the tab being shown under each group, in the groups' order, then the cards'.
    public var groups: [KindGroup]
    /// How many more they have on the other tab (Archive while Current is shown, and the reverse).
    public var elsewhere: Int
}

extension VaultModel {
    /// The People view: every person with an ID the tab, filters and search leave, in People's
    /// order; then names nobody in People answers to; the household last.
    ///
    /// A person's names and birth date come from all their documents, on either tab and whatever
    /// the filters hide: they are facts about the person, not about one ID.
    public var peopleSections: [VaultPersonSection] {
        peopleSections(computing: computedPeopleSections)
    }

    var computedPeopleSections: [VaultPersonSection] {
        func owner(_ row: Row) -> VaultPersonSection.Owner {
            if row.isHousehold { return .household }
            if let id = row.personID { return .person(id) }
            return .unnamed(row.facts?.holder ?? row.whose)
        }
        let all = Dictionary(grouping: rows, by: owner)
        let shown = Dictionary(grouping: visibleRows, by: owner)
        func section(_ id: VaultPersonSection.Owner, _ title: String) -> VaultPersonSection? {
            guard let rows = shown[id], !rows.isEmpty else { return nil }
            let theirs = all[id] ?? []
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
                } else {
                    names.append(.init(name: holder, on: [kind]))
                }
            }
            names = roled(names, for: id)
            // Each date with the IDs it was read from: a second date is one ID's reading, and the
            // ID is where it is put right.
            let dated = id == .household ? [] : papers.filter { $0.facts?.born != nil }
            let births = Dictionary(grouping: dated) { $0.facts?.born ?? .distantPast }
                .map { VaultPersonSection.Birth(date: $0.key, rows: $0.value) }
                .sorted { ($0.rows.count, $1.date) > ($1.rows.count, $0.date) }
            let onThisTab = Set(rows.map(\.id))
            return VaultPersonSection(id: id, title: title, names: names, births: births, groups: grouped(rows),
                                      elsewhere: theirs.filter { !onThisTab.contains($0.id) && $0.standing.tab != tab && $0.standing.tab != .other }.count)
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

    /// `names` with their roles, legal name first, then the one they go by, then the rest by how
    /// many papers print them. Roles are chosen for someone in People; a name nobody answers to
    /// gets the Vault's guess alone.
    func roled(_ names: [VaultPersonSection.PrintedName], for owner: VaultPersonSection.Owner) -> [VaultPersonSection.PrintedName] {
        guard !names.isEmpty else { return names }
        var names = names
        let chosen: VaultNameRoles
        if case .person(let id) = owner { chosen = nameRoles[id] ?? VaultNameRoles() } else { chosen = VaultNameRoles() }
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
        let cards = kinds.order
        let sorted = rows.enumerated().sorted { a, b in
            let (x, y) = (cards.firstIndex(of: a.element.card) ?? .max, cards.firstIndex(of: b.element.card) ?? .max)
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

    /// Whether a person's birth date may be drawn: when one of their IDs may be. It is as private
    /// as a number, so it stays behind the same proof.
    public func canShowBirth(in section: VaultPersonSection) -> Bool {
        section.rows.contains { lock.canShow($0.id, at: now) }
    }
}

/// A person's section as text, for a note or a message.
public enum VaultPersonText {
    /// The section in lines: who, each name as printed, then one line per ID.
    ///
    /// Without `numbers` an ID is its ending, as its row already draws it, and the birth date is
    /// left out; with them every ID is in full and the birth date is given, which is why the
    /// panel asks for a proof first.
    public static func text(_ section: VaultPersonSection, numbers: Bool) -> String {
        var lines = [section.title]
        // The name they go by leads, then the legal one forms ask for, then other real spellings.
        if let goesBy = section.names.first(where: { $0.role == .goesBy }) { lines.append("Goes by: \(goesBy.name)") }
        if let legal = section.names.first(where: { $0.role == .legal }) { lines.append("Legal name: \(legal.name)") }
        let others = section.names.filter { $0.role == .alsoUsed && !$0.looksMisread }.map(\.name)
        if !others.isEmpty { lines.append("Also printed as: \(others.joined(separator: "; "))") }
        if numbers {
            for date in section.born { lines.append("Date of birth: \(VaultReading.formDate(date))") }
        }
        for row in section.rows {
            let title = row.kindTitle
            // A summary is made to be passed on: a kind whose ending is itself a secret gives none.
            var line = "\(title): \(numbers ? row.value : row.category.hidesEnding ? "hidden" : ending(row.value))"
            if let until = row.facts?.validUntil {
                line += ", valid to \(numbers ? VaultReading.formDate(until) : VaultReading.monthYear(until))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A name as it is drawn and compared: one line, single spaces. A scan can read a name with
    /// a line break or a run of spaces in it, which would draw on a second line and pass for a
    /// different name from the same one read cleanly.
    static func tidied(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Where a name is printed, in a line: "On passport", "On all 9 kinds of identity paper" when
    /// it is their only spelling, else the papers that print it this way, the first three named.
    public static func paperLine(_ name: VaultPersonSection.PrintedName, only: Bool) -> String {
        if name.on.count == 1 { return "On \(name.on[0])" }
        if only { return "On all \(name.on.count) kinds of identity paper" }
        if name.on.count <= 3 { return "On \(ListFormatter.localizedString(byJoining: name.on))" }
        return "On \(name.on.prefix(3).joined(separator: ", ")) and \(name.on.count - 3) more"
    }

    /// What an identity paper is called in "Name on …"; nil for an account's papers.
    static func paper(_ category: VaultCategory) -> String? {
        switch category {
        case .passport: return "passport"
        case .usVisa: return "visa"
        case .i94: return "I-94"
        case .uscisCase: return "USCIS notice"
        case .driversLicense: return "driver’s license"
        case .ssn: return "Social Security card"
        case .pan: return "PAN card"
        case .aadhaar: return "Aadhaar"
        case .voterID: return "voter ID"
        case .health, .utilities, .loans, .other: return nil
        }
    }

    /// "ends 1647"; for a number too short to have an ending, "hidden".
    static func ending(_ value: String) -> String {
        let plain = VaultReading.normalized(value)
        return plain.count > 4 ? "ends \(plain.suffix(4))" : "hidden"
    }
}
