import Foundation

/// The kinds of number the Vault's main view shows, each as a card, in this order. A number read
/// from a document is one of the first four; a number typed in takes whichever the editor chose.
/// Anything read that is none of these goes to Other Finds, never the main view.
public enum VaultCategory: String, Codable, CaseIterable, Sendable {
    case passport, usVisa, i94, uscisCase, driversLicense, ssn, pan, aadhaar, voterID, health, utilities, loans, other

    public var title: String {
        switch self {
        case .passport: return "Passports"
        case .usVisa: return "US Visas"
        case .i94: return "I-94 Records"
        case .uscisCase: return "USCIS Cases"
        case .driversLicense: return "Driver’s Licenses"
        case .ssn: return "Social Security & ITIN"
        case .pan: return "PAN Cards"
        case .aadhaar: return "Aadhaar"
        case .voterID: return "Voter IDs"
        case .health: return "Health & Medical"
        case .utilities: return "Utilities & Phone"
        case .loans: return "Loans & Mortgage"
        case .other: return "Other"
        }
    }

    /// What one number of this kind is called, in the editor's picker and a row's title.
    public var singular: String {
        switch self {
        case .passport: return "Passport"
        case .usVisa: return "US visa"
        case .i94: return "I-94 admission number"
        case .uscisCase: return "USCIS receipt number"
        case .driversLicense: return "Driver’s license"
        case .ssn: return "Social Security number or ITIN"
        case .pan: return "PAN (India)"
        case .aadhaar: return "Aadhaar number"
        case .voterID: return "Voter ID (EPIC)"
        case .health: return "Health or medical number"
        case .utilities: return "Utility or phone account"
        case .loans: return "Loan or mortgage number"
        case .other: return "Other number"
        }
    }

    public var symbol: String {
        switch self {
        case .passport: return "globe"
        case .usVisa: return "airplane"
        case .i94: return "airplane.arrival"
        case .uscisCase: return "doc.text"
        case .driversLicense: return "car"
        case .ssn: return "person.text.rectangle"
        case .pan: return "indianrupeesign.circle"
        case .aadhaar: return "person.crop.rectangle"
        case .voterID: return "checkmark.seal"
        case .health: return "heart"
        case .utilities: return "bolt"
        case .loans: return "house"
        case .other: return "number"
        }
    }

    /// The entry kind a number of this category is saved as, for the parts of the Vault that
    /// still group by kind.
    public var kind: VaultEntry.Kind {
        switch self {
        case .passport, .usVisa, .i94, .uscisCase, .driversLicense, .ssn, .pan, .aadhaar, .voterID: return .identity
        case .health: return .health
        case .utilities: return .phone
        case .loans: return .home
        case .other: return .other
        }
    }

    /// A number typed in before categories existed, by the kind it was saved as. "Identity and
    /// Travel" covered several cards, so its name decides which.
    public static func from(kind: VaultEntry.Kind, title: String = "") -> VaultCategory {
        switch kind {
        case .identity:
            let name = title.lowercased()
            if name.contains("passport") { return .passport }
            if name.contains("visa") { return .usVisa }
            if name.contains("i-94") || name.contains("i94") { return .i94 }
            if name.contains("receipt") || name.contains("uscis") { return .uscisCase }
            if name.contains("licen") { return .driversLicense }
            if name.contains("social security") || name.contains("ssn") || name.contains("itin") { return .ssn }
            if name.contains("aadha") { return .aadhaar }
            if name.contains("voter") || name.contains("epic") { return .voterID }
            if name.range(of: #"\bpan\b"#, options: .regularExpression) != nil || name.contains("permanent account") { return .pan }
            return .other
        case .health: return .health
        case .phone: return .utilities
        case .home, .money: return .loans
        case .other: return .other
        }
    }
}

/// One detail beside a number, each copied on its own: an expiry, an issuing country, a class.
public struct VaultDetail: Codable, Equatable, Sendable {
    public enum Value: Codable, Equatable, Sendable {
        case text(String)
        /// A calendar day, made in UTC (``VaultReading/calendarDate(year:month:day:)``).
        case date(Date)
        /// A number in its own right, such as the passport a visa is in: hidden and copied like
        /// the Vault's numbers.
        case number(String)
    }

    public var label: String
    public var value: Value

    public init(_ label: String, _ value: Value) {
        self.label = label
        self.value = value
    }

    /// How it is drawn: "16 May 2032" for a date; a number with only its ending unless `shown`.
    public func drawn(shown: Bool) -> String {
        switch value {
        case .text(let text): return text
        case .date(let date): return VaultReading.spelled(date)
        case .number(let number): return shown ? number : VaultMask.masked(number)
        }
    }

    /// What Copy puts on the clipboard. A date as MM/DD/YYYY, the way US forms ask for it.
    public var copied: String {
        switch value {
        case .text(let text): return text
        case .date(let date): return VaultReading.formDate(date)
        case .number(let number): return number
        }
    }

    public var isNumber: Bool {
        if case .number = value { return true }
        return false
    }
}

/// A document that carries a number, and what part it plays.
public struct VaultSource: Codable, Equatable, Hashable, Sendable {
    public var path: String
    /// What the document is, as its tag says: "Passport photo page", "I-797A approval".
    public var role: String
    /// How much it is trusted as the number's source. The highest is the one it was read from.
    public var rank: Int

    public init(path: String, role: String, rank: Int) {
        self.path = path
        self.role = role
        self.rank = rank
    }

    /// How fitting a home the file's folders are for a number of `category`, among copies of one
    /// page: `…/Immigration/Passport/Shweta` for a passport is where it lives; a copy attached to
    /// a petition or an application ("Supporting Documents", "Petition", "Evidence") is a copy;
    /// one in an Archive folder is an old copy.
    public func placement(for category: VaultCategory) -> Int {
        let folders = (path as NSString).deletingLastPathComponent.lowercased()
            .split(separator: "/").map(String.init)
        let homes: [String]
        switch category {
        case .passport: homes = ["passport", "passports"]
        case .usVisa: homes = ["visa", "visas"]
        case .i94: homes = ["form i-94", "i-94", "i94", "form i94"]
        case .uscisCase: homes = ["approval", "approvals", "approval notice", "receipt", "receipts", "notices"]
        case .driversLicense: homes = ["driver license", "driver licenses", "drivers license", "driver’s license",
                                       "driving license", "dl", "license", "licenses"]
        case .ssn: homes = ["ssn", "social security", "itin"]
        case .pan: homes = ["pan", "pan card"]
        case .aadhaar: homes = ["aadhaar", "aadhar"]
        case .voterID: homes = ["voter id", "voter ids", "voter", "epic"]
        default: homes = []
        }
        let copies = ["supporting documents", "supporting docs", "petition", "petitions", "application",
                      "applications", "evidence", "exhibits", "attachments", "packet"]
        var score = 0
        if folders.contains(where: homes.contains) { score += 2 }
        if folders.contains(where: copies.contains) { score -= 2 }
        if folders.contains(where: { ["archive", "archived", "archives", "old", "older", "expired"].contains($0) }) { score -= 1 }
        return score
    }
}

/// What a document said about a number besides the number itself.
public struct VaultReadFacts: Codable, Equatable, Sendable {
    public var category: VaultCategory
    /// The name the document is made out to, as printed, in reading order.
    public var holder: String?
    /// The holder's date of birth, from the passport zone or the I-94. Used only to tell family
    /// members apart; never drawn or copied.
    public var born: Date?
    /// The country that issued a passport or a visa, as its three-letter code.
    public var issuer: String?
    /// The USCIS form a case is for: "I-129".
    public var form: String?
    /// The date that orders documents of one kind: a passport's expiry, an I-94's entry, a
    /// notice's date.
    public var dated: Date?
    /// When the document stops being good.
    public var validUntil: Date?
    /// A case with only a receipt notice so far.
    public var pending: Bool
    /// The passport number printed on a visa foil, which says which passport the visa is in.
    public var inPassport: String?
    public var details: [VaultDetail]
    /// Every document carrying the number, best first.
    public var sources: [VaultSource]

    public init(category: VaultCategory, holder: String? = nil, born: Date? = nil, issuer: String? = nil,
                form: String? = nil, dated: Date? = nil, validUntil: Date? = nil, pending: Bool = false,
                inPassport: String? = nil, details: [VaultDetail] = [], sources: [VaultSource] = []) {
        self.category = category
        self.holder = holder
        self.born = born
        self.issuer = issuer
        self.form = form
        self.dated = dated
        self.validUntil = validUntil
        self.pending = pending
        self.inPassport = inPassport
        self.details = details
        self.sources = sources
    }

    /// The document it was read from: the most trusted of its sources, and among copies trusted
    /// alike, the one filed where that kind of document lives.
    public var primary: VaultSource? { orderedSources.first }

    /// Sources best first, the primary at the top: by how far the document is trusted, then by
    /// where it is filed (``VaultSource/placement(for:)``), then by name.
    public var orderedSources: [VaultSource] {
        sources.sorted { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            let (pa, pb) = (a.placement(for: category), b.placement(for: category))
            if pa != pb { return pa > pb }
            return a.path < b.path
        }
    }

    /// Whose it is, as far as the document says: the date of birth when it was read, which tells
    /// two people apart even when a name line was missed; else the name. Nil when neither was
    /// read, and then the number stands alone rather than being grouped by its folder.
    public var personKey: String? {
        if let born { return "born:" + VaultReading.formDate(born) }
        return nameKey
    }

    /// Whose it is by name alone: first given name and last word, as middle names come and go
    /// between documents.
    public var nameKey: String? {
        guard let holder else { return nil }
        let words = holder.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = words.first else { return nil }
        return "name:" + first + " " + (words.count > 1 ? words.last! : "")
    }

    /// Adds `source`, keeping one entry per file and its best role.
    public mutating func add(_ source: VaultSource) {
        if let index = sources.firstIndex(where: { $0.path == source.path }) {
            if source.rank > sources[index].rank { sources[index] = source }
        } else {
            sources.append(source)
        }
    }
}

/// A choice the user made about where a number belongs, which later reads keep.
public enum VaultPin: String, Codable, Sendable {
    case current, older
}

/// Whose a number is, as the user said: one of the household's people, or the household itself.
/// It wins over the name a document was read with, and later reads keep it.
public enum VaultAssignment: Codable, Equatable, Hashable, Sendable {
    case person(String)
    case household

    /// How the standing rules group it: by this choice, not by the name read.
    var groupKey: String {
        switch self {
        case .person(let id): return "assigned:" + id
        case .household: return "household"
        }
    }
}

/// Which tab a number is on, and the badges its row carries.
public struct VaultStanding: Equatable, Sendable {
    public enum Tab: String, Sendable { case current, archive, other }

    public var tab: Tab
    /// Its document has run out, and it is still the newest of its kind for the person.
    public var expired = false
    /// An older passport that holds a visa still good: needed at the border with the new one.
    public var inUse = false
    /// A USCIS case with only a receipt notice.
    public var pending = false
    /// Why it is in Archive, in words for its row: "Expired Jan 2014 · replaced".
    public var reason: String?

    public init(tab: Tab, expired: Bool = false, inUse: Bool = false, pending: Bool = false, reason: String? = nil) {
        self.tab = tab
        self.expired = expired
        self.inUse = inUse
        self.pending = pending
        self.reason = reason
    }
}

/// One number as the standing rules see it: a find or a saved entry.
public struct VaultStandingInput: Sendable {
    public var id: UUID
    public var value: String
    public var category: VaultCategory
    /// Nil for a number typed in by hand.
    public var facts: VaultReadFacts?
    public var pin: VaultPin?
    /// Whose it is: the person its name matched in People, or what the user said.
    public var assignment: VaultAssignment?
    /// The user said whose it is (Belongs To), so it is grouped by that alone, never joined to
    /// another person's documents by the birth date or name it was read with.
    public var isChosen: Bool

    public init(id: UUID, value: String, category: VaultCategory, facts: VaultReadFacts?, pin: VaultPin?,
                assignment: VaultAssignment? = nil, isChosen: Bool = false) {
        self.id = id
        self.value = value
        self.category = category
        self.facts = facts
        self.pin = pin
        self.assignment = assignment
        self.isChosen = isChosen
    }

    /// What tells whose it is: what the user chose alone; otherwise the person matched, the birth
    /// date and the name read, any of which joins it to another document of the same person.
    var personKeys: [String] {
        if isChosen, let assignment { return [assignment.groupKey] }
        guard let facts else { return assignment.map { [$0.groupKey] } ?? [] }
        return [assignment?.groupKey, facts.born.map { "born:" + VaultReading.formDate($0) }, facts.nameKey]
            .compactMap { $0 }
    }
}

/// Which numbers belong to one person, joined by any key two of them share: a printout read
/// with a birth date and a notice read with the same name are one person's. Never joined when
/// that would put two birth dates, or two people the household knows apart, in one.
struct VaultPeopleClusters {
    private var parent: [Int]
    private var borns: [Set<String>]
    private var people: [Set<String>]

    init(_ keys: [[String]]) {
        parent = Array(keys.indices)
        borns = keys.map { Set($0.filter { $0.hasPrefix("born:") }) }
        people = keys.map { Set($0.filter { $0.hasPrefix("assigned:") || $0 == "household" }) }
        var owner: [String: Int] = [:]
        for (index, list) in keys.enumerated() {
            for key in list {
                if let other = owner[key] { join(index, other) } else { owner[key] = index }
            }
        }
    }

    mutating func root(_ i: Int) -> Int {
        var i = i
        while parent[i] != i {
            parent[i] = parent[parent[i]]
            i = parent[i]
        }
        return i
    }

    private mutating func join(_ a: Int, _ b: Int) {
        let (ra, rb) = (root(a), root(b))
        guard ra != rb else { return }
        let bornsClash = !borns[ra].isEmpty && !borns[rb].isEmpty && borns[ra].isDisjoint(with: borns[rb])
        let peopleClash = !people[ra].isEmpty && !people[rb].isEmpty && people[ra].isDisjoint(with: people[rb])
        guard !bornsClash, !peopleClash else { return }
        parent[rb] = ra
        borns[ra].formUnion(borns[rb])
        people[ra].formUnion(people[rb])
    }
}

/// Which numbers are current, over everything the Vault holds and has read, worked out afresh
/// each time so a saved number and a new read are weighed together.
public enum VaultStandings {

    /// - A number typed in is current unless marked older.
    /// - Numbers read are grouped by kind and person: passports also by issuing country, so a
    ///   dual citizen keeps both; USCIS cases also by form. With no person read, a number stands
    ///   alone. Never grouped by folder.
    /// - In each group the newest is current (an I-94 by its admitted-until date, so an
    ///   extension without travel beats an older printout), and any dated the same day. The
    ///   rest go to Archive.
    /// - A copy filed in an Archive folder inside a read folder goes to Archive unless its date
    ///   is the newest. A group filed only in Archive folders is all Archive.
    /// - The newest passport, visa or I-94 that has run out stays current, marked expired: it is
    ///   the person's latest. A USCIS case that has run out goes to Archive unless pending.
    /// - An older passport holding a visa still good is current, marked in use.
    /// - A choice the user pinned wins over all of this.
    public static func compute(_ items: [VaultStandingInput], now: Date = Date(),
                               readFolders: [String] = []) -> [UUID: VaultStanding] {
        var out: [UUID: VaultStanding] = [:]
        var read: [(VaultStandingInput, VaultReadFacts)] = []
        for item in items {
            guard let facts = item.facts else {
                out[item.id] = VaultStanding(tab: item.pin == .older ? .archive : .current,
                                             reason: item.pin == .older ? "Marked older" : nil)
                continue
            }
            if !VaultCategory.mainView.contains(facts.category) {
                out[item.id] = VaultStanding(tab: .other)
                continue
            }
            read.append((item, facts))
        }

        func archived(_ facts: VaultReadFacts) -> Bool {
            guard let path = facts.primary?.path else { return false }
            return VaultReading.isArchivePath(path, under: readFolders)
        }
        /// What orders one group, latest first: two dates, the second breaking a tie on the first.
        /// Each document's own date (a passport's expiry, an I-94's entry or its extension's
        /// notice, a case's notice), then how long it is good for. Not admit-until first: an
        /// admission "for duration of status" has none, and would sink below an older one.
        struct Ranking: Equatable, Comparable {
            var first: Date
            var second: Date
            static func < (a: Ranking, b: Ranking) -> Bool {
                a.first != b.first ? a.first < b.first : a.second < b.second
            }
        }
        func ranking(_ facts: VaultReadFacts) -> Ranking {
            Ranking(first: facts.dated ?? facts.validUntil ?? .distantPast, second: facts.validUntil ?? .distantPast)
        }

        let keys = read.map { $0.0.personKeys }
        var clusters = VaultPeopleClusters(keys)
        let person = read.indices.map { keys[$0].isEmpty ? nil : "person:\(clusters.root($0))" }
        let groups = Dictionary(grouping: read.indices) { index -> String in
            let (item, facts) = read[index]
            // Whose the user said it is wins over the name it was read with.
            guard let person = person[index] else {
                return "alone:" + VaultReading.normalized(item.value)
            }
            switch facts.category {
            case .passport: return "passport|\(person)|\(facts.issuer ?? "")"
            case .uscisCase: return "case|\(person)|\(facts.form ?? VaultReading.normalized(item.value))"
            // A US license and an Indian one are both kept; a new state's replaces the old.
            case .driversLicense: return "license|\(person)|\(facts.issuer ?? "")"
            // An SSN and an ITIN are weighed apart; an ITIN gives way to an SSN below.
            case .ssn: return "ssn|\(person)|\(facts.form ?? "")"
            default: return "\(facts.category.rawValue)|\(person)"
            }
        }

        for indices in groups.values {
            let sorted = indices.sorted { a, b in
                let (da, db) = (ranking(read[a].1), ranking(read[b].1))
                if da != db { return da > db }
                return !archived(read[a].1) && archived(read[b].1)
            }
            guard let top = sorted.first else { continue }
            let anyOutside = sorted.contains { !archived(read[$0].1) }
            let topDate = ranking(read[top].1)
            for index in indices {
                let (item, facts) = read[index]
                let isNewest = ranking(facts) == topDate
                var standing = VaultStanding(tab: .archive, pending: facts.pending)
                let ranOut = VaultReading.hasRunOut(facts.validUntil, now: now)
                if isNewest && anyOutside {
                    standing.tab = .current
                    switch facts.category {
                    case .uscisCase where !facts.pending:
                        // A case is current while it is pending or still good; a decided case
                        // with no end date, or one that ran out, is history.
                        if ranOut {
                            standing.tab = .archive
                            standing.reason = "Ran out " + VaultReading.monthYear(facts.validUntil)
                        } else if facts.validUntil == nil {
                            standing.tab = .archive
                            standing.reason = "Decided" + (facts.dated.map { " · " + VaultReading.monthYear($0) } ?? "")
                        }
                    case .usVisa where ranOut:
                        // An expired visa is not carried; it is kept for reference.
                        standing.tab = .archive
                        standing.reason = "Expired " + VaultReading.monthYear(facts.validUntil)
                    default:
                        standing.expired = ranOut
                    }
                } else if archived(facts) && !isNewest {
                    standing.reason = "In an Archive folder"
                } else if !anyOutside {
                    standing.reason = "In an Archive folder"
                } else {
                    standing.reason = (ranOut ? ([.passport, .usVisa, .driversLicense].contains(facts.category) ? "Expired " : "Ran out ")
                        + VaultReading.monthYear(facts.validUntil) + " · replaced" : "Replaced by a newer one")
                }
                if let pin = item.pin {
                    standing.tab = pin == .current ? .current : .archive
                    standing.reason = pin == .older ? "Marked older" : nil
                }
                out[item.id] = standing
            }
        }

        // An older passport still holding a visa that is good: current, in use.
        let liveVisaPassports = Set(read.compactMap { pair -> String? in
            let (item, facts) = pair
            guard facts.category == .usVisa, out[item.id]?.tab == .current,
                  !VaultReading.hasRunOut(facts.validUntil, now: now), let passport = facts.inPassport else { return nil }
            return VaultReading.normalized(passport)
        })
        for (item, facts) in read where facts.category == .passport && item.pin == nil
            && out[item.id]?.tab == .archive && liveVisaPassports.contains(VaultReading.normalized(item.value)) {
            out[item.id] = VaultStanding(tab: .current, expired: VaultReading.hasRunOut(facts.validUntil, now: now),
                                         inUse: true)
        }

        // An ITIN is replaced by the same person's SSN: the IRS stops using it once one is issued.
        // The same person as the groups above tell it (a card prints no birth date, and an ITIN
        // notice does); never the household's, which is nobody's in particular.
        func holder(_ index: Int) -> String? {
            read[index].0.assignment == .household ? nil : person[index]
        }
        let ssnHolders = Set(read.indices.compactMap { index -> String? in
            let (item, facts) = read[index]
            guard facts.category == .ssn, facts.form == "SSN", out[item.id]?.tab == .current else { return nil }
            return holder(index)
        })
        for index in read.indices {
            let (item, facts) = read[index]
            guard facts.category == .ssn, facts.form == "ITIN", item.pin == nil, out[item.id]?.tab == .current,
                  let who = holder(index), ssnHolders.contains(who) else { continue }
            out[item.id] = VaultStanding(tab: .archive, reason: "Replaced by an SSN")
        }
        return out
    }
}

extension VaultCategory {
    /// The kinds the main view shows. Everything else read goes to Other Finds.
    public static let mainView: [VaultCategory] = [.passport, .usVisa, .i94, .uscisCase, .driversLicense, .ssn,
                                                   .pan, .aadhaar, .voterID, .health, .utilities, .loans, .other]
    /// What the editor offers for a number typed in.
    public static let typedIn: [VaultCategory] = mainView
}
