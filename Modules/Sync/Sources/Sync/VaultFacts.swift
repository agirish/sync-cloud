import Foundation

/// The kinds of number the Vault's main view shows, each as a card, in this order. A number read
/// from a document takes the kind its reader says; a number typed in takes whichever the editor
/// chose. Every kind is on the main view (``mainView``); the Other Finds tab is for a kind left
/// off it, and is not drawn while it holds nothing.
public enum VaultCategory: String, Codable, CaseIterable, Sendable {
    case passport, usVisa, i94, uscisCase, driversLicense, ssn, pan, aadhaar, voterID, health, utilities, loans, other

    /// The kind's row: every rule about it (``VaultKindSpec``).
    public var spec: VaultKindSpec { VaultKindSpec.of(self) }

    public var title: String { spec.title }

    /// What one number of this kind is called, in the editor's picker and a row's title.
    public var singular: String { spec.singular }

    public var symbol: String { spec.symbol }

    /// Whether even this kind's ending is a secret while it is hidden (``VaultKindSpec/hidesEnding``).
    public var hidesEnding: Bool { spec.hidesEnding }

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
    /// The home address the document is mailed to or printed with, and its date: a license's,
    /// or an account paper's mailing block. Kept on the source, not the number, so the twelve
    /// bills of one account each give theirs.
    public var address: VaultPrintedAddress?
    /// The phones the document prints under a name in People, each with whose. Nil when none.
    public var phones: [VaultPrintedPhone]?

    public init(path: String, role: String, rank: Int, address: VaultPrintedAddress? = nil,
                phones: [VaultPrintedPhone]? = nil) {
        self.path = path
        self.role = role
        self.rank = rank
        self.address = address
        self.phones = phones.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// How fitting a home the file's folders are for a number of `category`, among copies of one
    /// page: `…/Immigration/Passport/Shweta` for a passport is where it lives; a copy attached to
    /// a petition or an application ("Supporting Documents", "Petition", "Evidence") is a copy;
    /// one in an Archive or Backup folder is an old copy, and one not yet filed (TODO, TMP) ranks
    /// below a filed one too.
    public func placement(for category: VaultCategory) -> Int {
        let folders = (path as NSString).deletingLastPathComponent.lowercased()
            .split(separator: "/").map(String.init)
        var score = 0
        if folders.contains(where: Self.homes(for: category).contains) { score += 2 }
        if folders.contains(where: Self.copyFolders.contains) { score -= 2 }
        if folders.contains(where: VaultReading.ranksBelowFiled) {
            score -= 1
        }
        return score
    }

    /// The folders a kind of ID is filed in when it is the original.
    static func homes(for category: VaultCategory) -> [String] { category.spec.homes }

    /// Every kind's own folders, for ordering files before their kind is known.
    static let homeFolders: Set<String> = Set(VaultCategory.allCases.flatMap { homes(for: $0) })
    /// Folders of copies: what a packet, an application or evidence holds.
    static let copyFolders: Set<String> = ["supporting documents", "supporting docs", "petition", "petitions", "application",
                                           "applications", "evidence", "exhibits", "attachments", "packet"]
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
    /// The document whose reading this is, when several were merged (``VaultCopies/merged(_:speaking:)``):
    /// the one ``primary`` names. Nil for a reading made before it was kept, which goes by
    /// ``orderedSources`` alone.
    public var spokenBy: String?
    /// The number was printed beside a subscriber's label ("Subscriber ID") on a paper whose name
    /// was not read as the subscriber's: on a dependent's card it is another person's number, so
    /// the name says nothing about whose it is (``VaultModel``'s copies of one number). Nil
    /// otherwise.
    public var printedForSubscriber: Bool?

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

    /// The document it was read from: the one whose reading this is (``spokenBy``), so the
    /// document named is the one whose dates and details are shown. With none kept, the most
    /// trusted of its sources, and among copies trusted alike, the one filed where that kind of
    /// document lives.
    /// ``orderedSources``' first, in one pass: the earliest of the best, as the sort keeps it.
    public var primary: VaultSource? {
        let (placed, before) = sourceOrder
        return placed.min(by: before)?.source
    }

    /// Sources best first, the primary at the top: the one it was read from (``spokenBy``), then
    /// by how far the document is trusted, then by where it is filed
    /// (``VaultSource/placement(for:)``), then by name.
    public var orderedSources: [VaultSource] {
        let (placed, before) = sourceOrder
        return placed.sorted(by: before).map(\.source)
    }

    /// Each source with where it is filed, worked out once (VT66), and the order between two.
    private var sourceOrder: (placed: [(source: VaultSource, placement: Int)],
                              before: ((source: VaultSource, placement: Int), (source: VaultSource, placement: Int)) -> Bool) {
        let speaker = spokenBy.flatMap { path in sources.contains { $0.path == path } ? path : nil }
        let placed = sources.map { (source: $0, placement: $0.placement(for: category)) }
        return (placed, { a, b in
            if let speaker, (a.source.path == speaker) != (b.source.path == speaker) { return a.source.path == speaker }
            if a.source.rank != b.source.rank { return a.source.rank > b.source.rank }
            if a.placement != b.placement { return a.placement > b.placement }
            return a.source.path < b.source.path
        })
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
        let words = VaultReading.letterWords(holder)
        guard let first = words.first else { return nil }
        return "name:" + first + " " + (words.count > 1 ? words.last! : "")
    }

    /// Whose word stands on a file's address and phones when ``add(_:contacts:)`` meets a file
    /// already listed.
    public enum ContactsFrom: Sendable {
        /// Whichever gave them: two readings of one build.
        case either
        /// `source`'s, even none: it is today's reading of the file, and a saved ID's source
        /// keeps what an older build's rules read only until the file is read again.
        case incoming
        /// The one already listed: it is today's reading, and `source` a saved ID's.
        case existing
    }

    /// Adds `source`, keeping one entry per file and its best role. The file's address and
    /// phones come as `contacts` says: today's reading of a file speaks for it, so a saved ID
    /// takes them from it, and loses one a stricter rule no longer reads.
    public mutating func add(_ source: VaultSource, contacts: ContactsFrom = .either) {
        if let index = sources.firstIndex(where: { $0.path == source.path }) {
            let mine = sources[index]
            let address: VaultPrintedAddress?
            let phones: [VaultPrintedPhone]?
            switch contacts {
            case .either: (address, phones) = (source.address ?? mine.address, source.phones ?? mine.phones)
            case .incoming: (address, phones) = (source.address, source.phones)
            case .existing: (address, phones) = (mine.address, mine.phones)
            }
            if source.rank > mine.rank { sources[index] = source }
            sources[index].address = address
            sources[index].phones = phones
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
    /// Why it is in its tab, in words for its row: "Expired Jan 2014 · replaced", or
    /// ``movedByYou``. Nil for one in Current by the Vault's own choice.
    public var reason: String?

    /// The reason for a tab the user chose, either way.
    public static let movedByYou = "You moved it here"

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
    /// The card it is drawn on (``VaultCardID/key``), when not its category's: a custom kind's
    /// numbers are weighed against each other, never against Other's.
    public var card: String?

    public init(id: UUID, value: String, category: VaultCategory, facts: VaultReadFacts?, pin: VaultPin?,
                assignment: VaultAssignment? = nil, isChosen: Bool = false, card: String? = nil) {
        self.id = id
        self.value = value
        self.category = category
        self.facts = facts
        self.pin = pin
        self.assignment = assignment
        self.isChosen = isChosen
        self.card = card
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
/// that would put two birth dates, two people the household knows apart, or two first names in
/// one: twins share a birth date and nothing else.
struct VaultPeopleClusters {
    private var parent: [Int]
    private var borns: [Set<String>]
    private var people: [Set<String>]
    private var firstNames: [Set<String>]

    /// Placeholders a document prints where a name is unknown ("FNU", first name unknown).
    static let noName: Set<String> = ["fnu", "lnu", "unk"]

    /// Whether two first names read off documents can be one person's: the same; an initial
    /// and the name it starts ("G" and "Girish"); or one letter misread in a name of four or more
    /// ("Abhlshek" and "Abhishek"). Twins' names differ by more than that.
    static func sameFirstName(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count == 1 || b.count == 1 { return a.first == b.first }
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a), Array(b)) <= 1
    }

    /// Whether `names` hold two that cannot be one person's.
    static func differ(_ names: Set<String>) -> Bool {
        let list = Array(names)
        for i in list.indices { for j in list.indices where j > i && !sameFirstName(list[i], list[j]) { return true } }
        return false
    }

    /// Letters to change, add or drop to turn one word into the other.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    init(_ keys: [[String]]) {
        parent = Array(keys.indices)
        borns = keys.map { Set($0.filter { $0.hasPrefix("born:") }) }
        people = keys.map { Set($0.filter { $0.hasPrefix("assigned:") || $0 == "household" }) }
        firstNames = keys.map { list in
            Set(list.filter { $0.hasPrefix("name:") }.compactMap { key -> String? in
                let first = key.dropFirst(5).split(separator: " ").first.map(String.init)
                return first.flatMap { Self.noName.contains($0) ? nil : $0 }
            })
        }
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
        let namesClash = !firstNames[ra].isEmpty && !firstNames[rb].isEmpty
            && !firstNames[ra].contains { a in firstNames[rb].contains { b in Self.sameFirstName(a, b) } }
        guard !bornsClash, !peopleClash, !namesClash else { return }
        parent[rb] = ra
        borns[ra].formUnion(borns[rb])
        people[ra].formUnion(people[rb])
        firstNames[ra].formUnion(firstNames[rb])
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
                                             reason: item.pin == nil ? nil : VaultStanding.movedByYou)
                continue
            }
            if !VaultCategory.mainView.contains(facts.category) {
                out[item.id] = VaultStanding(tab: .other)
                continue
            }
            read.append((item, facts))
        }

        /// Filed in an Archive folder: every copy of its most trusted kind of document is, so the
        /// household moved the number there. Not the one it was read from alone, which can be a
        /// copy kept in Archive beside one that is not, or a copy the user chose to read it from.
        func archived(_ facts: VaultReadFacts) -> Bool {
            guard let top = facts.sources.map(\.rank).max() else { return false }
            return facts.sources.filter { $0.rank == top }
                .allSatisfy { VaultReading.isArchivePath($0.path, under: readFolders) }
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

        // A name two birth dates share, or a birth date two first names share (twins), says
        // nothing on its own: a number read with only that one is nobody's in particular.
        var namesBorn: [String: Set<String>] = [:]
        var bornsNamed: [String: Set<String>] = [:]
        for (item, facts) in read where !item.isChosen {
            guard let name = facts.nameKey, let born = facts.born else { continue }
            namesBorn[name, default: []].insert(VaultReading.formDate(born))
            if let first = facts.holder.flatMap({ VaultReading.letterWords($0).first }),
               !VaultPeopleClusters.noName.contains(first) {
                bornsNamed["born:" + VaultReading.formDate(born), default: []].insert(first)
            }
        }
        let keys = read.map { pair -> [String] in
            let (item, facts) = pair
            guard !item.isChosen else { return item.personKeys }
            if facts.born == nil, let name = facts.nameKey, (namesBorn[name]?.count ?? 0) > 1 {
                return item.personKeys.filter { $0 != name }
            }
            if facts.nameKey == nil, let born = facts.born.map({ "born:" + VaultReading.formDate($0) }),
               VaultPeopleClusters.differ(bornsNamed[born] ?? []) {
                return item.personKeys.filter { $0 != born }
            }
            return item.personKeys
        }
        var clusters = VaultPeopleClusters(keys)
        let person = read.indices.map { keys[$0].isEmpty ? nil : "person:\(clusters.root($0))" }
        let groups = Dictionary(grouping: read.indices) { index -> String in
            let (item, facts) = read[index]
            // Whose the user said it is wins over the name it was read with.
            guard let person = person[index] else {
                return "alone:" + VaultReading.normalized(item.value)
            }
            // Each kind weighs by what its row says (``VaultKindSpec/weighing``); an account is
            // weighed against the same issuer's for the same person: a dental plan's member ID
            // never sends a vision plan's to Archive.
            if let weighing = facts.category.spec.weighing {
                let (kind, by) = weighing(facts, item.value)
                return "\(kind)|\(person)|\(by)"
            }
            let issuer = facts.details.first { $0.label == "Issued by" }
                .map { VaultReading.normalized($0.drawn(shown: true)) } ?? ""
            return "\(item.card ?? facts.category.rawValue)|\(person)|\(issuer)"
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
                    switch facts.category.spec.newest(facts, ranOut) {
                    case .current(let expired): standing.expired = expired
                    case .archive(let reason):
                        standing.tab = .archive
                        standing.reason = reason
                    }
                } else if archived(facts) && !isNewest {
                    standing.reason = "In an Archive folder"
                } else if !anyOutside {
                    standing.reason = "In an Archive folder"
                } else {
                    standing.reason = (ranOut ? facts.category.spec.endedWord
                        + VaultReading.monthYear(facts.validUntil) + " · replaced" : "Replaced by a newer one")
                }
                if let pin = item.pin {
                    standing.tab = pin == .current ? .current : .archive
                    standing.reason = VaultStanding.movedByYou
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
    public static let mainView: [VaultCategory] = VaultKindSpec.all.map(\.category)
    /// What the editor offers for a number typed in.
    public static let typedIn: [VaultCategory] = mainView
}

/// One number read from several documents: which document speaks for it, and how the rest
/// fill in what it is silent on. Pure, so a reader can merge two pages of one file the way the
/// Vault merges two files.
public enum VaultCopies {
    /// Whether `incoming`'s document, carrying a number already read, should speak for it: the
    /// more trusted kind of document first, so a form that only quotes an Aadhaar number never
    /// lends it the form's own issue date; between documents trusted alike, the newer, so a
    /// license renewed under the same number shows the new card's dates, not those of the card
    /// it replaced; and a dated one over an undated one.
    ///
    /// Between documents trusted alike, one filed outside an Archive folder over one inside: the
    /// household files a replaced card there, so a renewal whose own expiry was not read still
    /// speaks over the card it replaced, whose expiry runs past the renewal's issue. (Both filed
    /// alike, the old card's later expiry wins, and the row shows it until the renewal's expiry
    /// is read.) Then newer by expiry, else the document's own date: an I-94 printout's
    /// admit-until, an approval's validity. Not the document's date first: a copy's date can be
    /// only its file name's, and a scan with a later name but fewer fields would speak for the
    /// number (tried on 2026-11-19: five I-94s lost their admit-until). Between two readings of
    /// one card (its front and its barcode), the one that says more. Then the newer by its own
    /// date, then by its expiry: two approvals good for the same years, the later notice. Last,
    /// between copies of one document saying as much, the one filed where that kind of document
    /// lives (``VaultSource/placement(for:)``): the passport's own folder over a petition's copy.
    /// One key, compared in order, so sorting by this is consistent.
    static func supersedes(_ incoming: VaultReadFacts, _ held: VaultReadFacts) -> Bool {
        let (ra, rb) = (incoming.primary?.rank ?? 0, held.primary?.rank ?? 0)
        if ra != rb { return ra > rb }
        let (aa, ab) = (incoming.primary.map { VaultReading.isOldCopyPath($0.path) } ?? false,
                        held.primary.map { VaultReading.isOldCopyPath($0.path) } ?? false)
        if aa != ab { return !aa }
        switch (incoming.validUntil ?? incoming.dated, held.validUntil ?? held.dated) {
        case let (a?, b?) where a != b: return a > b
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if incoming.details.count != held.details.count { return incoming.details.count > held.details.count }
        if incoming.dated != held.dated { return (incoming.dated ?? .distantPast) > (held.dated ?? .distantPast) }
        if incoming.validUntil != held.validUntil {
            return (incoming.validUntil ?? .distantPast) > (held.validUntil ?? .distantPast)
        }
        let (pa, pb) = (incoming.primary?.placement(for: incoming.category) ?? 0,
                        held.primary?.placement(for: held.category) ?? 0)
        return pa > pb
    }

    /// Whether two readings of one number are copies of one document, as alike as the Vault can
    /// tell: the same kind of document, filed in an Archive folder or not alike, with the same
    /// date and the same expiry. Either can speak for the number without changing its dates, so
    /// the one shown is the user's to choose (``merged(_:speaking:)``).
    static func sameCopy(_ a: VaultReadFacts, _ b: VaultReadFacts) -> Bool {
        guard let pa = a.primary, let pb = b.primary else { return false }
        return pa.rank == pb.rank && pa.rank > VaultReading.Rank.mention
            && VaultReading.isOldCopyPath(pa.path) == VaultReading.isOldCopyPath(pb.path)
            && a.dated == b.dated && a.validUntil == b.validUntil
    }

    /// `copies` best first (``supersedes(_:_:)``), then by name.
    static func ordered(_ copies: [VaultFind]) -> [VaultFind] {
        copies.sorted { a, b in
            if supersedes(a.facts, b.facts) { return true }
            if supersedes(b.facts, a.facts) { return false }
            return a.sourcePath < b.sourcePath
        }
    }

    /// The documents among `copies` that could speak for the number in place of the one that
    /// does (``sameCopy(_:_:)``), as their paths: what Read from This Copy offers.
    static func choices(_ copies: [VaultFind]) -> [String] {
        let ordered = Self.ordered(copies)
        guard let best = ordered.first else { return [] }
        return ordered.dropFirst().filter { sameCopy($0.facts, best.facts) }.map(\.sourcePath)
    }

    /// Whether two readings of one number are of the same document, not a renewal under the same
    /// number or another kind of paper that quotes it: the same expiry, or, with none, the same date.
    static func sameDocument(_ a: VaultReadFacts, _ b: VaultReadFacts) -> Bool {
        if let until = a.validUntil { return until == b.validUntil }
        return b.validUntil == nil && a.dated != nil && a.dated == b.dated
    }

    /// One number as every document that carries it says, rebuilt from those documents alone:
    /// the best document speaks (``supersedes(_:_:)``), every one is listed, and what the best is
    /// silent on comes from the next that says it. A receipt notice names the person, its
    /// approval says how long the case is good for.
    ///
    /// Rebuilt rather than merged into, so a file that is changed or gone takes what it said
    /// with it: a misread expiry does not outlive the scan it came from.
    ///
    /// `chosen`, the document the user chose to read it from, speaks instead when it is a copy
    /// of the one that would (``sameCopy(_:_:)``); otherwise, as when a renewal under the same
    /// number has come since, the choice is passed over. The result names its speaker
    /// (``VaultReadFacts/spokenBy``).
    static func merged(_ copies: [VaultFind], speaking chosen: String? = nil) -> VaultFind? {
        var ordered = Self.ordered(copies)
        guard let first = ordered.first else { return nil }
        if let chosen, let index = ordered.firstIndex(where: { $0.sourcePath == chosen }), index > 0,
           sameCopy(ordered[index].facts, first.facts) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        var best = ordered[0]
        // An account number read as Other ("Account Number" on a cover sheet) and as one account
        // kind elsewhere ("Loan Number" on the next page) is that kind, as that kind's paper names
        // it: Other is no kind, only its absence (VT53). The speaker keeps who issued it, so the
        // title is its issuer and the kind's name ("Insurance · Loan number"). Two kinds that
        // disagree, or an identity kind, leave it as the best reading says.
        let kinds = Set(ordered.map(\.facts.category)).subtracting([.other])
        if best.facts.category == .other, kinds.count == 1, let kind = kinds.first, VaultReading.accountCategories.contains(kind),
           let kindReading = ordered.first(where: { $0.facts.category == kind }), let form = kindReading.facts.form {
            best.facts.category = kind
            best.facts.form = form
            let issuer = best.facts.details.first { $0.label == "Issued by" }.flatMap { detail -> String? in
                if case .text(let text) = detail.value { return text } else { return nil }
            }
            best.title = issuer.map { "\($0) · \(form)" } ?? form
        }
        best.facts.spokenBy = best.sourcePath
        // What the best document itself said, before anything is borrowed into it.
        let speaker = best.facts
        for copy in ordered.dropFirst() {
            for source in copy.facts.sources { best.facts.add(source) }
            best.facts.holder = fuller(best.facts.holder, copy.facts.holder)
            best.facts.born = best.facts.born ?? copy.facts.born
            best.facts.form = best.facts.form ?? copy.facts.form
            // Whether this copy is a document no older than the one speaking: an I-94's extension
            // notice is, beside its printout; the card a renewal replaced is not. By its own date;
            // with none read, a document of another, lesser kind (a tear-off beside its printout)
            // by whether it runs past the speaker's date. Another undated scan of the same kind
            // of card says nothing about which card it is, and lends nothing.
            let lesserKind = (copy.facts.primary?.rank ?? 0) < (speaker.primary?.rank ?? 0)
            let newer: Bool? = speaker.dated.flatMap { own in
                if let date = copy.facts.dated { return date >= own }
                return lesserKind ? copy.facts.validUntil.map { $0 > own } : nil
            }
            // An expiry the best is silent on, from a document no older than it: an older one under
            // the same number is the card it replaced, whose expiry is not the renewal's. A copy
            // that cannot be placed lends only to a speaker with no date of its own either.
            if best.facts.validUntil == nil, let until = copy.facts.validUntil, newer ?? (speaker.dated == nil) {
                best.facts.validUntil = until
            }
            best.facts.pending = best.facts.pending && copy.facts.pending
            // A detail only another reading of the same card has (the barcode's issue date, the
            // front's state), or a newer document (the extension's admit-until), placed after the
            // detail it follows there. Never one from an older document.
            guard sameDocument(speaker, copy.facts) || newer == true else { continue }
            lend(copy.facts.details, to: &best.facts.details)
        }
        return best
    }

    /// Each of `details` that `kept` has no detail of its label for, placed after the detail it
    /// follows in `details`.
    private static func lend(_ details: [VaultDetail], to kept: inout [VaultDetail]) {
        for (index, detail) in details.enumerated() where !kept.contains(where: { $0.label == detail.label }) {
            let before = details[..<index].reversed().first { prior in kept.contains { $0.label == prior.label } }
            let at = before.flatMap { prior in kept.firstIndex { $0.label == prior.label } }.map { $0 + 1 } ?? 0
            kept.insert(detail, at: at)
        }
    }

    /// One number as a page's text layer and its picture both read it (``VaultPageOrigin``):
    /// merged as two documents are (``merged(_:speaking:)``), with whose it is, its holder and
    /// birth date, as typed (VT88). A scan's picture misreads a name the layer has exactly
    /// ("Anma" for "Anna"), and spoke whenever it read a date or a detail more. A name the
    /// picture reads fuller, starting alike, is still taken (``fuller(_:_:)``).
    static func filled(_ typed: VaultFind, from picture: VaultFind) -> VaultFind {
        // Merged as any two readings are, so what each prints (a notice date, a status, a form)
        // is weighed as ever; only whose it is comes from the typed layer, which no misread
        // spoils. The typed reading had spoken for every field, and its stand-ins (a date from
        // the file's name, a "Notice" status) beat what the picture printed (the 2026-11-25 review).
        guard var out = merged([typed, picture]) else { return typed }
        if typed.facts.holder != nil { out.facts.holder = fuller(typed.facts.holder, picture.facts.holder) }
        if let born = typed.facts.born { out.facts.born = born }
        return out
    }

    /// Whether a page's text layer reads a number it shares with the picture with other words
    /// about whose it is: another name, or another birth date. Only then is a layer that says
    /// nothing more than the picture kept beside it, to speak for the number (``filled(_:from:)``).
    static func readsOtherwise(_ typed: VaultReadFacts, _ picture: VaultReadFacts) -> Bool {
        if let a = typed.holder, let b = picture.holder,
           VaultReading.spellingKey(a) != VaultReading.spellingKey(b), fuller(a, b) == a { return true }
        if let a = typed.born, let b = picture.born, a != b { return true }
        return false
    }

    /// The name to keep of two read for one number: the one present, and of two that start
    /// alike, the longer, so "Abhishek" read off a license front gives way to "Abhishek Girish"
    /// from its barcode.
    static func fuller(_ kept: String?, _ other: String?) -> String? {
        guard let kept else { return other }
        guard let other else { return kept }
        let (k, o) = (kept.split(separator: " "), other.split(separator: " "))
        return o.count > k.count && o.first?.lowercased() == k.first?.lowercased() ? other : kept
    }
}
