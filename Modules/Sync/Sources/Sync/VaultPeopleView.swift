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
        /// Their IDs whose papers print it so, in the cards' order: what “From 5 IDs” counts.
        public var rows: [VaultModel.Row] = []
    }

    /// A home address: the IDs whose papers print it, and how new it is. The newest leads.
    public struct Address: Equatable, Sendable {
        /// As shown: the tidiest printing, tidied (``VaultAddress/tidied``); a typed one as typed.
        public var address: VaultAddress
        /// The newest paper's date, or the day it was typed, whichever is later.
        public var dated: Date?
        /// Their IDs whose papers print it, from either tab; a Household paper's for everyone.
        public var rows: [VaultModel.Row]
        /// Typed in People's tile, by the user.
        public var typed: Bool

        public init(address: VaultAddress, dated: Date?, rows: [VaultModel.Row], typed: Bool) {
            self.address = address
            self.dated = dated
            self.rows = rows
            self.typed = typed
        }
    }

    /// A phone: typed for them, printed on papers under their name, or both.
    public struct Phone: Equatable, Sendable {
        /// As typed; the ten digits when only papers print it.
        public var value: String
        /// "Mobile", "Home", "Work": as typed, or as the paper's label says.
        public var label: String?
        /// Its place among the phones typed for them; nil when only papers print it.
        public var typedIndex: Int?
        /// The IDs whose papers print it under their name, from either tab.
        public var rows: [VaultModel.Row]
        /// The newest paper's date, or the day it was typed, whichever is later.
        public var dated: Date?

        public init(value: String, label: String? = nil, typedIndex: Int? = nil, rows: [VaultModel.Row] = [], dated: Date? = nil) {
            self.value = value
            self.label = label
            self.typedIndex = typedIndex
            self.rows = rows
            self.dated = dated
        }

        public var typed: Bool { typedIndex != nil }
        /// "(408) 555-0142".
        public var shown: String { VaultContacts.phoneShown(value) }
        /// One phone however it is written (``VaultContacts/phoneKey(_:)``).
        public var key: String { VaultContacts.phoneKey(value) }
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
    /// Their home addresses, newest first: the first is where they live now (Current); the rest
    /// are past ones (Archive).
    public var addresses: [Address] = []
    /// A license on Current that still prints a past address: the DMV wants to hear of a move.
    public var licenseDiffers: Address?
    /// Their phones, typed and read, newest first: the first leads.
    public var phones: [Phone] = []
    /// Emails typed for them, the first leading.
    public var emails: [VaultContacts.Typed] = []

    /// Where they live now.
    public var home: Address? { addresses.first }
    /// Where they used to live, newest first.
    public var pastAddresses: [Address] { Array(addresses.dropFirst()) }
    /// Someone in People: who a typed value belongs to. Nil for Household and a name as read.
    public var personID: String? { if case .person(let id) = id { return id } else { return nil } }
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
        filter.peopleSections(rows, visible: visibleRows, people: people, roles: nameRoles, contacts: contacts)
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
    /// A fact's one source line, “From where · when”: the ID's kind when one gives it, “N IDs”
    /// when several do, “you” when it was typed; and for an address, the month of the newest.
    public static func sourceLine(_ rows: [VaultModel.Row], typed: Bool = false, dated: Date? = nil) -> String {
        let place: String
        switch rows.count {
        case 0: place = typed ? "you" : "People"
        // The title's first part: “Driver’s license · CA” is “Driver’s license”, “EBMUD · Account
        // number” is “EBMUD”, so the line's one “·” is the one before its date.
        case 1: place = rows[0].kindTitle.components(separatedBy: " · ").first ?? rows[0].kindTitle
        default: place = "\(rows.count.formatted()) IDs"
        }
        return "From \(place)" + (dated.map { " · " + month($0) } ?? "")
    }

    /// "Oct 2026", as a row gives a month (``VaultReading/monthYear(_:)``).
    public static func month(_ date: Date) -> String { VaultReading.monthYear(date) }

    public static func paperLine(_ name: VaultPersonSection.PrintedName, only: Bool) -> String {
        if name.on.count == 1 { return "On \(name.on[0])" }
        if only { return "On all \(name.on.count) kinds of identity paper" }
        if name.on.count <= 3 { return "On \(ListFormatter.localizedString(byJoining: name.on))" }
        return "On \(name.on.prefix(3).joined(separator: ", ")) and \(name.on.count - 3) more"
    }

    /// What an identity paper is called in "Name on …"; nil for an account's papers.
    static func paper(_ category: VaultCategory) -> String? { category.spec.paper }

    /// "ends 1647"; for a number too short to have an ending, "hidden".
    static func ending(_ value: String) -> String {
        let plain = VaultReading.normalized(value)
        return plain.count > 4 ? "ends \(plain.suffix(4))" : "hidden"
    }
}

extension VaultPersonSection {
    /// A section with only who it is and what was typed for them: what typing a contact from a
    /// Contact card needs, where no section of People is drawn.
    public init(typingFor person: String, title: String, contacts: VaultContacts) {
        self.init(id: .person(person), title: title, names: [], births: [], groups: [], elsewhere: 0)
        phones = contacts.phones.enumerated().map {
            Phone(value: $0.element.value, label: $0.element.label, typedIndex: $0.offset, dated: $0.element.added)
        }
        emails = contacts.emails
    }
}
