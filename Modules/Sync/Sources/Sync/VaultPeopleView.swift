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
    }

    public var id: Owner
    /// The person's name in People, "Household", or the name as read.
    public var title: String
    public var names: [PrintedName]
    /// The birth dates their documents give: one, unless two documents disagree.
    public var born: [Date]
    /// Their IDs on the tab being shown, in the cards' order.
    public var rows: [VaultModel.Row]
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
                guard let holder = row.facts?.holder, !holder.isEmpty, let kind = VaultPersonText.paper(row.category) else { continue }
                if let index = names.firstIndex(where: { $0.name.caseInsensitiveCompare(holder) == .orderedSame }) {
                    if !names[index].on.contains(kind) { names[index].on.append(kind) }
                } else {
                    names.append(.init(name: holder, on: [kind]))
                }
            }
            let born = Set(theirs.compactMap { id == .household ? nil : $0.facts?.born }).sorted()
            let onThisTab = Set(rows.map(\.id))
            return VaultPersonSection(id: id, title: title, names: names, born: born, rows: rows,
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
        for name in section.names {
            lines.append("Name on \(ListFormatter.localizedString(byJoining: name.on)): \(name.name)")
        }
        if numbers {
            for date in section.born { lines.append("Date of birth: \(VaultReading.formDate(date))") }
        }
        for row in section.rows {
            let title = row.isTypedIn ? row.title : row.title.replacingOccurrences(of: " case", with: "")
            // A summary is made to be passed on: a kind whose ending is itself a secret gives none.
            var line = "\(title): \(numbers ? row.value : row.category.hidesEnding ? "hidden" : ending(row.value))"
            if let until = row.facts?.validUntil {
                line += ", valid to \(numbers ? VaultReading.formDate(until) : VaultReading.monthYear(until))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
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
