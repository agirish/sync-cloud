import CryptoKit
import Events
import Foundation

/// Where Read Documents gets its pages: the app's Vision reader, or a stand-in in tests.
public protocol VaultDocumentReading: Sendable {
    /// The files in the chosen folders that could hold a number.
    func files() async -> [URL]
    /// One file's pages, each as its recognised lines; empty when it cannot be read. Pages are kept
    /// apart so a name line on one page is never paired with a number on another.
    func pages(in file: URL) async -> [[String]]
    /// What says a file has changed since it was read: its size and modification date. Nil reads
    /// it every time.
    func stamp(of file: URL) -> String?
    /// The files, and the folders under the chosen ones that could not be opened: what was read
    /// in those is kept, not taken for deleted.
    func walk() async -> (files: [URL], unreachable: [String])
    /// When a file was last changed: which year it is for, when neither a year folder nor its
    /// name says, and which of a year's files is newest.
    func modified(of file: URL) -> Date?
    /// Whether only the files ``VaultReadPlan`` picks are opened. The app's reader does; a
    /// stand-in in a test reads every file it is handed unless it says otherwise.
    var followsReadPlan: Bool { get }
    /// Whether a document an ID was read from is still where it was: what Refresh asks before
    /// it opens anything.
    func exists(_ file: URL) -> Bool
}

extension VaultDocumentReading {
    public func walk() async -> (files: [URL], unreachable: [String]) { (await files(), []) }

    public var followsReadPlan: Bool { false }

    public func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    public func modified(of file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    public func stamp(of file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value):\(Int64(modified.timeIntervalSince1970 * 1000))"
    }
}

/// The Vault panel's state: what is in it, whether it is open, and what the list is showing.
///
/// Here rather than in the app so its rules are tested without a window: the store is a file in a
/// temporary folder, the proof is a stand-in for Touch ID, and the clock and the pasteboard are
/// handed in.
@MainActor
public final class VaultModel: ObservableObject {
    /// Whether the sealed file has been read.
    public enum Contents: Equatable, Sendable {
        /// Not read yet, or let go when the Vault locked.
        case notLoaded
        case loaded
        /// It could not be read. The panel says why; nothing is written until that is settled.
        case unreadable(VaultError)
    }

    /// Whose numbers the list is showing.
    public enum PersonFilter: Hashable, Sendable {
        case everyone
        /// Numbers nobody in particular owns: the mortgage, the electricity account.
        case household
        case person(String)
    }

    /// What the editor hands back: everything about an entry the user types.
    public struct Draft: Equatable, Sendable {
        public var title: String
        public var value: String
        public var personID: String?
        public var note: String
        /// The card it goes on. The editor's Kind picker.
        public var category: VaultCategory
        /// What was read with it, carried from a find so its details and documents stay; not edited.
        public var facts: VaultReadFacts?
        public var pin: VaultPin?
        /// Household chosen for it. With no person and this off, a read number goes by the name
        /// on its document.
        public var isHousehold = false
        /// Where it is used, as chosen (Used In); nil goes by the document.
        public var geo: VaultGeo?
        /// The card chosen for it with Kind (``VaultCardID``); nil draws it on its category's card.
        public var card: VaultCardID?

        public var kind: VaultEntry.Kind { category.kind }

        /// What Belongs To says: the person, the household, or nil to go by the document.
        public var assignment: VaultAssignment? {
            if isHousehold { return .household }
            return personID.map { .person($0) }
        }

        public init(title: String = "", value: String = "", personID: String? = nil,
                    note: String = "", category: VaultCategory = .other, facts: VaultReadFacts? = nil,
                    pin: VaultPin? = nil) {
            self.title = title
            self.value = value
            self.personID = personID
            self.note = note
            self.category = category
            self.facts = facts
            self.pin = pin
        }

        /// The earlier shape, by kind.
        public init(title: String, value: String, personID: String? = nil, note: String = "",
                    kind: VaultEntry.Kind) {
            self.init(title: title, value: value, personID: personID, note: note,
                      category: VaultCategory.from(kind: kind))
        }

        public init(_ entry: VaultEntry) {
            self.init(title: entry.title, value: entry.value, personID: entry.personID,
                      note: entry.note, category: entry.category, facts: entry.facts, pin: entry.pin)
            isHousehold = entry.assignment == .household
            geo = entry.geo
            card = entry.card
        }

        /// A read number, for the editor to confirm. Whose it is is suggested from the name the
        /// document is made out to, when exactly one person in the household answers to it.
        public init(_ find: VaultFind, people: [Person] = []) {
            // The person chosen for it, if any; else the one its name answers to.
            let personID: String?
            switch find.assignment {
            case .person(let id)?: personID = id
            case .household?: personID = nil
            case nil: personID = VaultModel.person(named: find.holder, among: people)
            }
            self.init(title: find.title, value: find.value, personID: personID,
                      note: find.note, category: find.category, facts: find.facts, pin: find.pin)
            isHousehold = find.assignment == .household
            geo = find.geo
            card = find.card
        }

        /// A name and a number are the least an entry can be.
        public var isComplete: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @Published public private(set) var entries: [VaultEntry] = [] { didSet { rowsRevision &+= 1 } }
    @Published public private(set) var contents: Contents = .notLoaded
    @Published public private(set) var lock: VaultLock
    /// The time the panel last drew at. Published so the countdown and a number's thirty seconds
    /// redraw; advanced by ``tick()``.
    @Published public private(set) var now: Date
    /// A proof prompt is on screen. The panel dims its own buttons rather than queue a second one.
    @Published public private(set) var isAsking = false
    /// The last thing that went wrong, in words: a refused proof, a failed save.
    @Published public var notice: String?
    @Published public var query = "" { didSet { keepSelectionVisible() } }
    @Published public var personFilter: PersonFilter = .everyone {
        didSet { savePersonFilter(); keepSelectionVisible() }
    }
    /// Which countries the list shows. Kept between opens, as the person is.
    @Published public var geoFilter: VaultGeoFilter = .all {
        didSet { defaults.set(geoFilter.rawValue, forKey: Self.geoFilterKey); keepSelectionVisible() }
    }
    /// Which group of kinds the list shows; nil for every kind.
    @Published public var kindFilter: VaultGroups.ID? = nil {
        didSet { defaults.set(kindFilter, forKey: Self.kindFilterKey); keepSelectionVisible() }
    }
    /// The Kinds choice's groups: the app's, as the user customized them.
    @Published public private(set) var groups = VaultGroups.default
    /// Which card is drawn in which color (``VaultColors``), kept with the groups.
    @Published public private(set) var colors = VaultColors()
    @Published public var selection: UUID?

    /// How far Read Documents has got.
    public struct ReadingProgress: Equatable, Sendable {
        public var done: Int
        public var total: Int
        /// What is being read: the folders, or only the documents IDs came from.
        public var scope: VaultReadScope

        public init(done: Int, total: Int, scope: VaultReadScope = .discover) {
            self.done = done
            self.total = total
            self.scope = scope
        }
    }

    /// What the last Read Documents came to.
    public struct ReadingSummary: Equatable, Sendable {
        /// Every document in the chosen folders.
        public var documents: Int
        /// Those opened this time: new, changed, or all of them on a first read.
        public var opened: Int
        public var newNumbers: Int
        /// What was read: the folders, or (Refresh) only the documents IDs came from, in which
        /// case `documents` counts those.
        public var scope: VaultReadScope
        /// Refresh: IDs whose dates or details read differently now.
        public var updated: Int
        /// Refresh: documents that were not where they had been.
        public var missing: Int
        /// Refresh: waiting IDs their documents no longer give.
        public var gone: Int

        public init(documents: Int, opened: Int? = nil, newNumbers: Int, scope: VaultReadScope = .discover,
                    updated: Int = 0, missing: Int = 0, gone: Int = 0) {
            self.documents = documents
            self.opened = opened ?? documents
            self.newNumbers = newNumbers
            self.scope = scope
            self.updated = updated
            self.missing = missing
            self.gone = gone
        }
    }

    /// What the last refresh changed about each ID, until the Vault is let go: its row says
    /// Updated, and its details say what from and to.
    @Published public private(set) var changes: [UUID: [VaultChange]] = [:]
    /// A saved ID whose document now reads as another number, by the waiting ID that reading
    /// made. The saved one is never changed for it: the panel asks.
    @Published public private(set) var rereads: [UUID: UUID] = [:]
    /// Documents an ID was read from that were not found where they had been. The ID is kept;
    /// Discover More finds a moved document again by its number.
    @Published public private(set) var missingDocuments: Set<String> = [] { didSet { rowsRevision &+= 1 } }
    /// A refresh has brought the IDs up to this build's rules, and the rest of the folders have
    /// not been read with them: the panel offers Discover More, once.
    @Published public private(set) var needsDiscover = false
    @Published public private(set) var lastRefreshed: Date?
    @Published public private(set) var lastDiscovered: Date?
    /// Documents an older build read IDs from, for the refresh that follows a change of rules.
    private var staleSources: Set<String> = []

    /// Numbers read from documents and not yet confirmed. Sealed in Read Documents' own file
    /// between reads, and let go from memory with the entries when the Vault locks.
    @Published public private(set) var finds: [VaultFind] = [] { didSet { rowsRevision &+= 1 } }
    /// To Confirm lists its older numbers only when asked.
    @Published public var showsOlderFinds = false { didSet { keepSelectionVisible() } }
    /// Each file read, by path, against ``VaultDocumentReading/stamp(of:)`` when it was read.
    private var readIndex: [String: String] = [:]
    /// Set while Read Documents runs.
    @Published public private(set) var reading: ReadingProgress?
    /// What an older build read was let go with its rules, and no full read has run since: the
    /// panel says so above the cards, with Read Again, until one does.
    @Published public private(set) var needsReadAgain = false
    @Published public private(set) var lastReading: ReadingSummary?
    /// Numbers set aside while the Keychain would not give a fingerprint, as plain hashes, kept
    /// for this run only. Normally they go to ``VaultSetAside`` and outlive the app.
    private var setAsideThisRun = Set<String>()

    private let store: VaultStore?
    private let authenticator: VaultAuthenticating
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    /// Puts a number on the pasteboard. The app's version marks it concealed and clears it later.
    private let copyToPasteboard: @MainActor (String) -> Void

    public init(store: VaultStore?, authenticator: VaultAuthenticating,
                defaults: UserDefaults = .standard,
                clock: @escaping @Sendable () -> Date = { Date() },
                copyToPasteboard: @escaping @MainActor (String) -> Void) {
        self.store = store
        self.authenticator = authenticator
        self.defaults = defaults
        self.clock = clock
        self.copyToPasteboard = copyToPasteboard
        lock = VaultLock(settings: VaultLockSettings(defaults: defaults, store: store))
        now = clock()
        loadFolded()
        loadFilters()
    }

    // MARK: What the list shows

    public var selectedEntry: VaultEntry? { entries.first { $0.id == selection } }

    public var selectedFind: VaultFind? { finds.first { $0.id == selection } }

    // MARK: Rows, tabs and cards

    /// The household's people, from Settings ▸ Organize: who a read number belongs to, and the
    /// person filter's names. Set by the panel.
    public var people: [Person] = [] { didSet { rowsRevision &+= 1; keepSelectionVisible() } }

    /// Current, Archive or Other Finds.
    @Published public var tab: VaultStanding.Tab = .current { didSet { keepSelectionVisible() } }

    /// One number on the panel: saved, or read and waiting to be confirmed.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var title: String
        public var value: String
        public var note: String
        public var category: VaultCategory
        /// Nil for a number typed in by hand.
        public var facts: VaultReadFacts?
        public var standing: VaultStanding
        /// In the Vault, rather than read and waiting.
        public var isSaved: Bool
        /// Whose it is: the person chosen, or the person a read name matches.
        public var personID: String?
        /// The name to show for whose it is.
        public var whose: String
        public var pin: VaultPin?
        /// Whose the user said it is, if they did. Nil goes by what was read.
        public var assignment: VaultAssignment?
        /// The household's own: put there, or typed in for nobody in particular.
        public var isHousehold: Bool
        /// Where it is used: the user's choice, else what its document says.
        public var geo: VaultGeo = .anywhere
        /// How that is known: "A US license", "You chose it".
        public var geoReason: String = ""
        /// Where the user said it is used, if they did. Nil goes by the document.
        public var chosenGeo: VaultGeo?
        /// The card it is drawn on: ``category``'s, or the one chosen for it or learned for its
        /// folder. ``category`` follows a move to another app kind; a custom kind leaves it as read.
        public var card: VaultCardID = .builtIn(.other)
        /// What it was read or typed as, whatever card it is on now: never lost, and As Read puts
        /// it back.
        public var readAs: VaultCategory = .other
        /// The card chosen for this number with Kind, if one was.
        public var chosenCard: VaultCardID?
        /// The folder whose lesson put it on ``card``, when no choice of its own did.
        public var learnedFrom: String?
        /// The document it was read from is not where it was (``VaultModel/missingDocuments``).
        /// The ID is kept; Discover More finds a moved document again.
        public var documentMissing = false

        /// Every document carrying the number, the one it was read from first.
        public var documents: [VaultSource] { facts?.orderedSources ?? [] }
        public var isTypedIn: Bool { facts == nil }
    }

    /// A saved number's facts as its documents now say: a newer document of the same kind, such
    /// as a license renewed under the same number, speaks for it, keeping the kind it was saved
    /// as; otherwise what was saved stands, with every document read since listed under it.
    private func readSince(_ entry: VaultEntry) -> VaultReadFacts? {
        guard var saved = entry.facts else { return nil }
        guard let read = copies[VaultReading.normalized(entry.value)].flatMap({ Self.merged(Array($0.values)) }) else {
            return saved
        }
        if Self.supersedes(read.facts, saved) {
            var newer = read.facts
            newer.category = saved.category
            for source in saved.sources { newer.add(source) }
            return newer
        }
        for source in read.facts.sources { saved.add(source) }
        return saved
    }

    /// The person in the household a printed name answers to, when exactly one does.
    public nonisolated static func person(named holder: String?, among people: [Person]) -> String? {
        guard let holder, !people.isEmpty else { return nil }
        let named = PersonRegistry(people: people).detect(in: holder)
        return named.count == 1 ? named.first : nil
    }

    /// The person whose folder a document is filed in: the deepest folder below the read folder
    /// that names one of the household's people and no one else (`Health/Medical/Shweta`, never
    /// `Visitor Insurance/2021 - Girish, Muktha and Anuraag`). Never a folder above the read
    /// folder: the home folder is named for whoever's Mac it is.
    public nonisolated static func person(inPath path: String, under readFolders: [String], among people: [Person]) -> String? {
        guard !people.isEmpty,
              let root = readFolders.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return nil }
        let registry = PersonRegistry(people: people)
        let below = String(path.dropFirst(root.count + 1))
        for folder in (below as NSString).deletingLastPathComponent.split(separator: "/").reversed() {
            let named = registry.detect(in: String(folder))
            if named.count == 1 { return named.first }
            if named.count > 1 { return nil }
        }
        return nil
    }

    /// Every number, saved and waiting, each with where it stands. Worked out afresh each time,
    /// so a saved passport and a newer one read today are weighed together.
    public var rows: [Row] {
        let key = RowsKey(revision: rowsRevision, day: Self.dayStamp(now), folders: VaultReadFolders.folders(in: defaults))
        if let cached = rowsCache, cached.key == key { return cached.rows }
        let rows = computedRows
        rowsCache = (key, rows)
        return rows
    }

    /// What `rows` was last worked out from: the numbers, documents and people (counted by every
    /// change to them), the day, since a document runs out at midnight, and the folders read. The
    /// panel redraws every second and asks for the rows many times a draw; they are worked out
    /// again only when one of these moved.
    private struct RowsKey: Equatable {
        var revision: Int
        var day: Int
        var folders: [String]
    }
    private var rowsRevision = 0
    private var rowsCache: (key: RowsKey, rows: [Row])?
    /// Moves on whenever access ends by hand or by the system (close, Lock Now, sleep, new
    /// settings), so a proof asked for before it cannot open the Vault after it.
    private var lockEpoch = 0
    /// Whether the panel is up: a closed Vault left open by its setting lets its numbers go once
    /// its idle limit passes, though no tick runs then.
    private var panelUp = false
    private var releaseWhenIdle: Task<Void, Never>?
    private var lastPanelActivity = Date.distantPast
    /// Read Documents, owned here so it outlives the panel.
    private(set) var readingTask: Task<Void, Never>?
    /// The Vault locked while a read was going on: its numbers go once the read ends.
    private var releaseAfterReading = false
    private var spansCache: (key: RowsKey, spans: Bool)?

    private static func dayStamp(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    private var computedRows: [Row] {
        let folders = VaultReadFolders.folders(in: defaults)
        func withMentions(_ facts: VaultReadFacts?, _ value: String) -> VaultReadFacts? {
            guard var facts else { return nil }
            for source in mentions[VaultReading.normalized(value)] ?? [] { facts.add(source) }
            // A document that is not where it was is passed over while another carries the ID:
            // a scan moved and found again is simply read from where it is now.
            if !missingDocuments.isEmpty {
                let found = facts.sources.filter { !missingDocuments.contains($0.path) }
                if !found.isEmpty { facts.sources = found }
            }
            return facts
        }
        /// One number before its standing is known.
        struct Item {
            var id: UUID, title: String, value: String, note: String, category: VaultCategory
            var facts: VaultReadFacts?, isSaved: Bool, pin: VaultPin?
            /// The user's choice, if any.
            var chosen: VaultAssignment?
            /// The person it belongs to: the choice, else the person its name matches.
            var personID: String?
            /// Where the user said it is used.
            var chosenGeo: VaultGeo?
            /// The card chosen for it.
            var card: VaultCardID?
            /// What it was read or typed as, before a move to another app kind.
            var readAs: VaultCategory = .other
            var drawnOn: VaultCardID = .builtIn(.other)
            var learnedFrom: String?
        }
        var all: [Item] = entries.map { entry in
            // A saved number's person was chosen in the editor; with none, it goes by its name.
            let chosen = entry.assignment
            var personID: String?
            if case .person(let id)? = chosen { personID = id }
            if chosen == nil { personID = Self.person(named: entry.facts?.holder, among: people) }
            return Item(id: entry.id, title: entry.title, value: entry.value, note: entry.note, category: entry.category,
                        facts: withMentions(readSince(entry), entry.value), isSaved: true, pin: entry.pin,
                        chosen: chosen, personID: personID, chosenGeo: entry.geo, card: entry.card)
        }
        all += finds.map { find in
            var personID: String?
            switch find.assignment {
            case .person(let id)?: personID = id
            case .household?: personID = nil
            case nil: personID = Self.person(named: find.holder, among: people)
            }
            return Item(id: find.id, title: find.title, value: find.value, note: find.note, category: find.category,
                        facts: withMentions(find.facts, find.value), isSaved: false, pin: find.pin,
                        chosen: find.assignment, personID: personID, chosenGeo: find.geo, card: find.card)
        }
        // The card each goes on (Kind), before anything weighs it: moved to another app kind, it is
        // weighed, and its household and country found, as that kind.
        for index in all.indices {
            let item = all[index]
            let (card, learned) = drawnCard(for: item.category, chosen: item.card, path: item.facts?.primary?.path)
            all[index].readAs = item.category
            all[index].drawnOn = card
            all[index].learnedFrom = learned
            if case .builtIn(let category) = card, category != item.category {
                all[index].category = category
                all[index].facts?.category = category
            }
        }
        // A number whose name line was missed, but whose date of birth was read, is the same
        // person's as another number read with both: it borrows that one's name and person. Not
        // when two people share that birth date (twins): then it is nobody's in particular.
        var known: [String: (id: String?, holder: String)] = [:]
        var firstNames: [String: Set<String>] = [:]
        for item in all {
            guard let facts = item.facts, let key = facts.personKey, let holder = facts.holder else { continue }
            if known[key]?.id == nil { known[key] = (item.personID, holder) }
            if let first = holder.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init),
               !VaultPeopleClusters.noName.contains(first) {
                firstNames[key, default: []].insert(first)
            }
        }
        for index in all.indices where all[index].chosen == nil && all[index].personID == nil
            && all[index].facts?.holder == nil {
            if let key = all[index].facts?.personKey, let match = known[key],
               !VaultPeopleClusters.differ(firstNames[key] ?? []) {
                all[index].personID = match.id
                all[index].facts?.holder = match.holder
            }
        }
        // A visa that prints no name, an Indian e-Visa, is whoever's passport it is in: the
        // passport's person, and its name when one was read.
        var passports: [String: (id: String?, holder: String?)] = [:]
        for item in all where item.category == .passport && (item.personID != nil || item.facts?.holder != nil) {
            passports[VaultReading.normalized(item.value)] = (item.personID, item.facts?.holder)
        }
        for index in all.indices where all[index].chosen == nil && all[index].personID == nil
            && all[index].facts?.holder == nil {
            if let passport = all[index].facts?.inPassport, let match = passports[VaultReading.normalized(passport)] {
                all[index].personID = match.id
                all[index].facts?.holder = match.holder
            }
        }
        // A paper that prints no name is whoever's folder it is filed in: `Health/Medical/Shweta`.
        for index in all.indices where all[index].chosen == nil && all[index].personID == nil
            && all[index].facts?.holder == nil {
            if let path = all[index].facts?.primary?.path,
               let id = Self.person(inPath: path, under: folders, among: people) {
                all[index].personID = id
            }
        }
        // Grouped by whose it is as best known: the choice, else the matched person, else the
        // name or birth date read. A saved passport and a new read of the same person's meet.
        let standings = VaultStandings.compute(all.map { item in
            let grouping: VaultAssignment? = item.chosen ?? item.personID.map { .person($0) }
            return VaultStandingInput(id: item.id, value: item.value, category: item.category, facts: item.facts,
                                      pin: item.pin, assignment: grouping, isChosen: item.chosen != nil,
                                      card: item.drawnOn.key)
        }, now: now, readFolders: folders)
        return all.map { item in
            // Nobody's in particular: typed in for no one, or a utility or a loan read with no
            // person, which is the household's.
            let isHousehold = item.chosen == .household || (item.facts == nil && item.personID == nil)
                || (item.chosen == nil && item.personID == nil && item.facts?.holder == nil
                    && [.utilities, .loans].contains(item.category))
            let personName = item.personID.flatMap { id in people.first { $0.id == id }?.displayName }
            let whose = isHousehold ? "Household"
                : personName ?? (item.personID != nil ? "Someone no longer in People" : nil)
                    ?? item.facts?.holder?.split(separator: " ").first.map(String.init) ?? "Unknown"
            let read = VaultGeo.read(item.category, facts: item.facts)
            return Row(id: item.id, title: item.title, value: item.value, note: item.note, category: item.category,
                       facts: item.facts, standing: standings[item.id] ?? VaultStanding(tab: .current),
                       isSaved: item.isSaved, personID: item.personID, whose: whose, pin: item.pin,
                       assignment: item.chosen, isHousehold: isHousehold,
                       geo: item.chosenGeo ?? read.geo, geoReason: item.chosenGeo == nil ? read.reason : "You chose it",
                       chosenGeo: item.chosenGeo, card: item.drawnOn, readAs: item.readAs,
                       chosenCard: item.card.flatMap { kinds.exists($0) ? $0 : nil }, learnedFrom: item.learnedFrom,
                       documentMissing: item.facts?.primary.map { missingDocuments.contains($0.path) } ?? false)
        }
    }

    /// Belongs To: whose a number is, a person or the household; nil goes by what was read again.
    /// Later reads keep the choice.
    public func assign(_ id: UUID, to assignment: VaultAssignment?) {
        let before = visibleIDs
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var changed = entries
            changed[index].assignment = assignment
            _ = write(changed)
        } else if let index = finds.firstIndex(where: { $0.id == id }) {
            finds[index].assignment = assignment
            readingChanged = true
            saveReading()
        }
        keepSelection(near: before)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The rows the tab, the person filter and the search leave. A search looks in every tab:
    /// a number asked about on a call may be an older one.
    public var visibleRows: [Row] {
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
            return row.standing.tab == tab && passesFilters(row)
        }
        .sorted(by: rowOrder)
    }

    /// Whether `row` is one the person, country and kind choices leave. Names, notes and kinds
    /// are what a search matches, never the number: a search that matched on digits would confirm
    /// a guess at a locked number one keystroke at a time.
    public func passesFilters(_ row: Row, person: PersonFilter? = nil, geo: VaultGeoFilter? = nil,
                              kind: VaultGroups.ID?? = nil) -> Bool {
        switch person ?? personFilter {
        case .everyone: break
        case .household: if !row.isHousehold { return false }
        case .person(let id): if row.personID != id { return false }
        }
        guard (geo ?? geoFilter).shows(row.geo) else { return false }
        if let group = kind ?? kindFilter, kinds.group(of: row.card, in: groups) != group { return false }
        return true
    }

    /// How many current rows each choice would show, the others as they stand: the counts beside
    /// each choice while it is being made.
    public func count(person: PersonFilter? = nil, geo: VaultGeoFilter? = nil, kind: VaultGroups.ID?? = nil) -> Int {
        rows.filter { $0.standing.tab == tab && passesFilters($0, person: person, geo: geo, kind: kind) }.count
    }

    /// The same kind in the other country, for "2 more in India" at the foot of its card: only
    /// while one country is chosen, and only what the person and kind choices would show there.
    public func elsewhere(_ card: VaultCardID) -> (filter: VaultGeoFilter, count: Int)? {
        guard !searching, geoFilter != .all else { return nil }
        let other: VaultGeoFilter = geoFilter == .us ? .india : .us
        let count = rows.filter {
            $0.card == card && $0.standing.tab == tab && $0.geo != .anywhere
                && passesFilters($0, geo: other) && !geoFilter.shows($0.geo)
        }.count
        return count > 0 ? (other, count) : nil
    }

    /// Whether the numbers span more than one country: the Where choice is offered only then.
    public var spansCountries: Bool {
        let key = RowsKey(revision: rowsRevision, day: Self.dayStamp(now), folders: VaultReadFolders.folders(in: defaults))
        if let cached = spansCache, cached.key == key { return cached.spans }
        let geos = Set(rows.map(\.geo))
        let spans = geos.contains(.us) && geos.contains(.india)
        spansCache = (key, spans)
        return spans
    }

    /// Back to every country, everyone and every kind: the empty list's way out.
    public func resetFilters() {
        personFilter = .everyone
        geoFilter = .all
        kindFilter = nil
    }

    /// A number just added or confirmed that the choices would hide is shown anyway: those of
    /// the three that hide it go back to all.
    /// Each of the three is tested alone, the other two let through, so only the ones that hide it
    /// are reset; and the tab it is on is shown, so it is never chosen out of sight.
    private func showEvenIfFiltered(_ id: UUID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        if !passesFilters(row, geo: .all, kind: .some(nil)) { personFilter = .everyone }
        if !geoFilter.shows(row.geo) { geoFilter = .all }
        if let group = kindFilter, kinds.group(of: row.card, in: groups) != group { kindFilter = nil }
        if row.standing.tab != tab { tab = row.standing.tab }
        selection = id
    }

    /// Kinds that have nothing in this country but some in the other: one line under the cards,
    /// since no card of theirs is drawn to carry "N more in …".
    public var elsewhereKinds: (filter: VaultGeoFilter, count: Int)? {
        guard !searching, geoFilter != .all else { return nil }
        let other: VaultGeoFilter = geoFilter == .us ? .india : .us
        let shown = Set(visibleRows.map(\.card))
        let count = rows.filter {
            $0.standing.tab == tab && !shown.contains($0.card) && $0.geo != .anywhere
                && passesFilters($0, geo: other)
        }.count
        return count > 0 ? (other, count) : nil
    }

    /// Used In: where a number is used; nil goes by its document again. Later reads keep it.
    public func setGeo(_ id: UUID, to geo: VaultGeo?) {
        let before = visibleIDs
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var changed = entries
            changed[index].geo = geo
            _ = write(changed)
        } else if let index = finds.firstIndex(where: { $0.id == id }) {
            finds[index].geo = geo
            readingChanged = true
            saveReading()
        }
        keepSelection(near: before)
    }

    /// Customize Groups: the groups as the user left them, kept for the next open.
    public func setGroups(_ new: VaultGroups) {
        groups = new
        new.save(to: defaults)
        if let chosen = kindFilter, !kinds.order.contains(where: { kinds.group(of: $0, in: new) == chosen }) {
            kindFilter = nil
        }
        rowsRevision &+= 1
        keepSelectionVisible()
    }

    /// Customize Groups, or a card's Color menu: the colors as the user left them, kept for the
    /// next open. A color of a kind no longer kept is let go.
    public func setColors(_ new: VaultColors) {
        var new = new
        new.prune(keeping: kinds)
        colors = new
        new.save(to: defaults)
    }

    /// One card's own color; nil has it follow its group again.
    public func setColor(_ color: VaultCardColor?, of card: VaultCardID) {
        var changed = colors
        changed.cards[card.key] = color
        setColors(changed)
    }

    /// The tint a card is drawn in on this tab, or nil for the window's hue. Other Finds holds
    /// kinds the main view does not show yet, which have no group and so no color.
    public func tint(of card: VaultCardID) -> VaultTint? {
        tab == .other ? nil : colors.tint(of: card, kinds: kinds, groups: groups)
    }

    static let geoFilterKey = "vaultGeoFilter"
    static let kindFilterKey = "vaultKindFilter"
    static let personFilterKey = "vaultPersonFilter"

    private func savePersonFilter() {
        switch personFilter {
        case .everyone: defaults.removeObject(forKey: Self.personFilterKey)
        case .household: defaults.set("household", forKey: Self.personFilterKey)
        case .person(let id): defaults.set("person:" + id, forKey: Self.personFilterKey)
        }
    }

    /// The choices as they were left, read once when the model is made.
    private func loadFilters() {
        geoFilter = defaults.string(forKey: Self.geoFilterKey).flatMap(VaultGeoFilter.init(rawValue:)) ?? .all
        groups = VaultGroups.load(from: defaults)
        kinds = VaultKinds.load(from: defaults)
        colors = VaultColors.load(from: defaults)
        kindFilter = defaults.string(forKey: Self.kindFilterKey).flatMap { groups.order.contains($0) ? $0 : nil }
        switch defaults.string(forKey: Self.personFilterKey) {
        case "household"?: personFilter = .household
        case let saved? where saved.hasPrefix("person:"): personFilter = .person(String(saved.dropFirst(7)))
        default: personFilter = .everyone
        }
    }

    /// Cards in the main view's order, each with its rows: the app's kinds, then the household's.
    /// A kind with nothing is left out.
    public var cards: [(card: VaultCardID, rows: [Row])] {
        let visible = visibleRows
        let order = tab == .other && !searching
            ? Set(visible.map(\.card)).sorted { $0.key < $1.key } : kinds.order
        return order.compactMap { card in
            let rows = visible.filter { $0.card == card }
            return rows.isEmpty ? nil : (card, rows)
        }
    }

    /// The main view's kinds with nothing in them yet, for the line under the cards.
    public var emptyCategories: [VaultCategory] {
        // While Read Documents runs, a card with nothing yet may be about to fill: the folders
        // are read in path order, so a Legal folder's licenses come last.
        guard reading == nil else { return [] }
        let used = Set(rows.map(\.card))
        return VaultCategory.mainView.filter { $0 != .other && !used.contains(.builtIn($0)) }
    }

    /// How many rows each tab has, as the person filter leaves them.
    public func count(in tab: VaultStanding.Tab) -> Int {
        rows.filter { $0.standing.tab == tab && passesFilters($0) }.count
    }

    /// By card, then whose, then current before in-use before expired, then newest.
    private func rowOrder(_ a: Row, _ b: Row) -> Bool {
        let order = kinds.order
        let (ca, cb) = (order.firstIndex(of: a.card) ?? 999, order.firstIndex(of: b.card) ?? 999)
        if ca != cb { return ca < cb }
        if a.whose != b.whose { return a.whose.localizedStandardCompare(b.whose) == .orderedAscending }
        func weight(_ s: VaultStanding) -> Int { s.inUse ? 1 : s.expired ? 2 : 0 }
        if weight(a.standing) != weight(b.standing) { return weight(a.standing) < weight(b.standing) }
        let (da, db) = (a.facts?.dated ?? .distantPast, b.facts?.dated ?? .distantPast)
        if da != db { return da > db }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    public var selectedRow: Row? { rows.first { $0.id == selection } }

    /// Every row in the order it is drawn: what the arrow keys walk.
    /// A folded card's rows are passed over: they are not on screen.
    private var visibleIDs: [UUID] {
        switch layout {
        case .people: return peopleSections.flatMap { $0.rows.map(\.id) }
        case .cards, .list: return cards.filter { showsList || !folded.contains($0.card.key) }.flatMap { $0.rows.map(\.id) }
        }
    }

    // MARK: Folded cards

    static let foldedKey = "vaultFoldedCards"

    /// The cards folded to their header, by ``VaultCardID/key``, kept between opens: an app kind's
    /// key is its name, as before custom kinds. In the list, nothing is folded.
    @Published public private(set) var folded: Set<String> = []
    /// Set by the panel: the list shows every row whatever is folded.
    public var showsList: Bool {
        get { layout == .list }
        set { layout = newValue ? .list : .cards }
    }
    /// Set by the panel: cards by kind, one list, or sections by person. It decides which rows
    /// are on screen and in what order the arrow keys walk them.
    public var layout: VaultLayout = .cards { didSet { keepSelectionVisible() } }

    /// Copies a person's section of the People view as text (``VaultPersonText``). With
    /// `numbers` every ID is in full and the birth date is given, so a proof is asked first when
    /// one is owed; without, only what the rows already draw.
    @discardableResult
    public func copyPerson(_ owner: VaultPersonSection.Owner, numbers: Bool) async -> Bool {
        guard let title = peopleSections.first(where: { $0.id == owner })?.title else { return false }
        if numbers, lock.settings.requiresAuthentication, !lock.isOpen(at: clock()) {
            guard await prove("copy \(title)’s IDs", for: nil) else { return false }
        }
        // Looked up again after the proof: the panel may have closed and let the numbers go.
        guard contents == .loaded, let section = peopleSections.first(where: { $0.id == owner }) else { return false }
        copyToPasteboard(VaultPersonText.text(section, numbers: numbers))
        used()
        return true
    }

    /// Copies a person's birth date as MM/DD/YYYY, behind the proof of one of their IDs: it is as
    /// private as a number, and cleared from the clipboard the same way.
    @discardableResult
    public func copyBirth(_ date: Date, in section: VaultPersonSection) async -> Bool {
        guard let id = section.rows.first?.id else { return false }
        return await copy(VaultReading.formDate(date), for: id)
    }

    private func loadFolded() {
        folded = Set((defaults.stringArray(forKey: Self.foldedKey) ?? []).filter { VaultCardID(key: $0) != nil })
    }

    public func isFolded(_ card: VaultCardID) -> Bool { folded.contains(card.key) }

    /// Folds or opens one card; with `all`, every card, as ⌥-click does.
    public func toggleFold(_ card: VaultCardID, all: Bool = false) {
        let fold = !folded.contains(card.key)
        if all {
            folded = fold ? Set(kinds.order.map(\.key)) : []
        } else if fold {
            folded.insert(card.key)
        } else {
            folded.remove(card.key)
        }
        saveFolded()
    }

    /// Whether every card on screen is folded: Collapse All then reads Expand All.
    public var allFolded: Bool {
        let shown = cards.map(\.card.key)
        return !shown.isEmpty && shown.allSatisfy(folded.contains)
    }

    /// Collapse All, or Expand All once everything on screen is folded.
    public func toggleFoldAll() {
        folded = allFolded ? [] : Set(kinds.order.map(\.key))
        saveFolded()
    }

    private func saveFolded() {
        defaults.set(folded.sorted(), forKey: Self.foldedKey)
        keepSelectionVisible()
    }

    // MARK: Kinds

    /// The household's own kinds (``VaultKinds``), kept in UserDefaults beside the groups.
    @Published public private(set) var kinds = VaultKinds()
    /// What choosing a kind for a read account taught, by its folder (``VaultKinds/lessonFolder(of:)``):
    /// numbers read from that folder with no kind of their own go on that card, now and on later
    /// reads. Sealed with what was read.
    private var lessons: [String: VaultCardID] = [:] { didSet { rowsRevision &+= 1 } }

    /// The card a number goes on, and the folder that taught it when that did: its own choice,
    /// else its folder's lesson, else its own kind's card. Only an account's kind moves
    /// (``VaultKinds/changeable``), and a custom kind no longer kept is as if never chosen.
    private func drawnCard(for category: VaultCategory, chosen: VaultCardID?, path: String?) -> (VaultCardID, String?) {
        guard VaultKinds.canChange(from: category) else { return (.builtIn(category), nil) }
        if let chosen, kinds.canHold(chosen) { return (chosen, nil) }
        if let path {
            let folder = VaultKinds.lessonFolder(of: path)
            if let lesson = lessons[folder], kinds.canHold(lesson) { return (lesson, folder) }
        }
        return (.builtIn(category), nil)
    }

    /// Kind: moves a number to another card. A number read from an account's folder teaches that
    /// folder too: its other numbers, and those later reads find there, follow unless they have a
    /// kind of their own (``forgetLesson(_:)`` unteaches it).
    ///
    /// Nil, or the kind it was read as, is As Read: this number alone goes back, and stays there
    /// whatever its folder taught or later teaches. The folder keeps its lesson.
    public func setKind(_ id: UUID, to card: VaultCardID?) {
        guard let row = rows.first(where: { $0.id == id }), VaultKinds.canChange(from: row.readAs) else { return }
        if let card, !kinds.canHold(card) { return }
        let asRead = card == nil || card == .builtIn(row.readAs)
        let path = row.facts?.primary?.path
        let folder = path.flatMap { path in
            VaultKinds.teaches(path, under: VaultReadFolders.folders(in: defaults)) ? VaultKinds.lessonFolder(of: path) : nil
        }
        // Kept as a choice of its own even As Read, so no lesson moves it: not its folder's now,
        // nor another's should a later read find it first elsewhere.
        let chosen: VaultCardID = card ?? .builtIn(row.readAs)
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var changed = entries
            changed[index].card = chosen
            guard write(changed) else { return }
        } else if let index = finds.firstIndex(where: { $0.id == id }) {
            finds[index].card = chosen
        } else {
            return
        }
        if let folder, !asRead { lessons[folder] = chosen }
        readingChanged = true
        saveReading()
        rowsRevision &+= 1
        showEvenIfFiltered(id)
    }

    /// Forgets what one folder taught: its numbers go back to their own kinds, but for those
    /// given one of their own.
    public func forgetLesson(_ folder: String) {
        guard lessons[folder] != nil else { return }
        lessons[folder] = nil
        readingChanged = true
        saveReading()
        keepSelectionVisible()
    }

    /// A kind of the household's own, listed under `group` (Other's group when none). A name an
    /// app kind or another custom kind already has gives that one back rather than a second.
    @discardableResult
    public func addKind(named name: String, group: VaultGroups.ID? = nil) -> VaultCardID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // An app kind's name is that kind: an account's to move to, a checked ID's never.
        if let same = VaultKinds.appKind(named: trimmed) {
            return VaultKinds.canChange(from: same) ? .builtIn(same) : nil
        }
        if let same = kinds.custom.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .custom(same.id)
        }
        let kind = VaultCustomKind(name: trimmed, group: group ?? groups.group(of: .other) ?? "home")
        var changed = kinds
        changed.custom.append(kind)
        setKinds(changed)
        return .custom(kind.id)
    }

    /// The household's kinds as Customize Groups left them: renamed, moved to another group, or
    /// removed. A removed kind's numbers go back to what they were read or typed as.
    public func setKinds(_ new: VaultKinds) {
        let kept = Set(new.custom.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
        let gone = kinds.custom.filter { !kept.contains($0.id) }.map { VaultCardID.custom($0.id) }
        kinds = VaultKinds(custom: new.custom.compactMap { kind in
            var kind = kind
            kind.name = kind.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return kind.name.isEmpty ? nil : kind
        })
        kinds.save(to: defaults)
        // A removed kind's color goes with it.
        if !gone.isEmpty { setColors(colors) }
        if !gone.isEmpty {
            folded.subtract(gone.map(\.key))
            saveFolded()
            if contents == .loaded {
                let before = lessons
                lessons = lessons.filter { !gone.contains($0.value) }
                if lessons != before { readingChanged = true; saveReading() }
            }
        }
        if let chosen = kindFilter, !kinds.order.contains(where: { kinds.group(of: $0, in: groups) == chosen }) {
            kindFilter = nil
        }
        rowsRevision &+= 1
        keepSelectionVisible()
    }

    /// Make Current or Mark as Older: a choice later reads keep. Nil lets the rules decide again.
    public func pin(_ id: UUID, _ pin: VaultPin?) {
        let before = visibleIDs
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var changed = entries
            changed[index].pin = pin
            _ = write(changed)
        } else if let index = finds.firstIndex(where: { $0.id == id }) {
            finds[index].pin = pin
            readingChanged = true
            saveReading()
        }
        keepSelection(near: before)
    }

    /// Documents that name a number without being its source, by the number.
    private var mentions: [String: [VaultSource]] = [:] { didSet { rowsRevision &+= 1 } }

    /// The number as it may be drawn now: in full, or with only its ending.
    public func drawn(_ entry: VaultEntry) -> String {
        lock.canShow(entry.id, at: now) ? entry.value : VaultMask.masked(entry.value)
    }

    public func canShow(_ entry: VaultEntry) -> Bool { lock.canShow(entry.id, at: now) }

    public func drawn(_ find: VaultFind) -> String {
        lock.canShow(find.id, at: now) ? find.value : VaultMask.masked(find.value)
    }

    public func canShow(_ find: VaultFind) -> Bool { lock.canShow(find.id, at: now) }
    public var isOpen: Bool { lock.isOpen(at: now) }
    public var secondsLeft: Int? { lock.secondsLeft(at: now) }

    /// How near the lock is when the panel starts counting it down.
    public static let lockWarning = 10

    /// The seconds before an unlocked Vault locks, only in its last ``lockWarning`` seconds: a
    /// clock ticking all the time the Vault is in use is a distraction, and the lock restarts with
    /// every use anyway. Nil otherwise.
    public var secondsBeforeLock: Int? {
        guard let left = secondsLeft, left <= Self.lockWarning else { return nil }
        return left
    }

    /// Moves the selection one row up or down the visible list, stopping at its ends.
    public func moveSelection(by step: Int) {
        let visible = visibleIDs
        guard !visible.isEmpty else { return }
        guard let index = visible.firstIndex(where: { $0 == selection }) else {
            selection = visible.first
            return
        }
        selection = visible[min(max(index + step, 0), visible.count - 1)]
        used()
    }

    private func keepSelectionVisible() {
        let visible = visibleIDs
        if !visible.contains(where: { $0 == selection }) { selection = visible.first }
    }

    /// After a change that takes the chosen row out of view (Mark as Older, Make Current, a person
    /// or country the choices hide): the row that came after it, else the one before, as Mail
    /// moves on when a message leaves the list. `before` is the rows on screen before the change.
    private func keepSelection(near before: [UUID]) {
        let visible = Set(visibleIDs)
        guard let chosen = selection, !visible.contains(chosen) else { return }
        guard let index = before.firstIndex(of: chosen) else { return keepSelectionVisible() }
        selection = before[(index + 1)...].first(where: visible.contains)
            ?? before[..<index].last(where: visible.contains) ?? visibleIDs.first
    }

    // MARK: Opening and closing

    /// The panel appeared. Reads the settings again, since Settings may have changed them, loads
    /// the file, and asks for a proof when the lock says to ask as it opens.
    public func opened() async {
        now = clock()
        panelUp = true
        releaseWhenIdle?.cancel()
        // Opened again before a read that outlived the last close ended: the panel holds the
        // numbers now, under its lock, so the read's end has nothing to let go.
        releaseAfterReading = false
        let settings = VaultLockSettings(defaults: defaults, store: store)
        if settings != lock.settings {
            lockEpoch &+= 1
            lock.settings = settings
            lock.lock()
        }
        lock.expire(at: now)
        hasSomethingSealed = store.map { $0.hasFile || FileManager.default.fileExists(atPath: $0.readingURL.path) } ?? false
        // Locked means locked: under "As soon as Vault opens" nothing is read from disk for the
        // panel until the owner has proved it, so a locked Vault holds nothing to show. A Vault
        // with nothing sealed yet has nothing to guard: it is read without asking, for its
        // empty state.
        if lock.hidesEverything(at: now), hasSomethingSealed {
            // A Vault whose key is not on this Mac cannot be opened by any proof: it is said so
            // at once, rather than asked for first.
            guard store?.hasFile != true || store?.fingerprint("") != nil else {
                load()
                return
            }
            await unlock()
            return
        }
        load()
    }

    /// Whether anything had been sealed on this Mac, the Vault's file or what was read, when the
    /// panel opened: asked then, without the key. With nothing sealed there is nothing to guard:
    /// the panel draws its empty state and not its lock, and what is typed in or read in that
    /// sitting is drawn as rows are (a name and an ending) until the panel closes. From the next
    /// open it is behind the lock.
    @Published public private(set) var hasSomethingSealed = false

    /// Whether the panel shows only its lock (``VaultLock/hidesEverything(at:)``), with something
    /// behind it.
    public var isSealedShut: Bool { hasSomethingSealed && lock.hidesEverything(at: now) }

    /// A row's number as its row draws it while hidden: its ending, or for a kind whose ending is
    /// itself a secret (``VaultCategory/hidesEnding``) nothing at all until the number may be shown.
    public func masked(_ row: Row) -> String {
        VaultMask.masked(row.value, keep: row.category.hidesEnding && !lock.canShow(row.id, at: now) ? 0 : 4)
    }

    /// The panel went away. Locks if the setting says closing locks, and then lets the numbers go:
    /// a closed, locked Vault holds nothing in memory.
    public func closed() {
        now = clock()
        lockEpoch &+= 1
        panelUp = false
        lock.closed()
        query = ""
        notice = nil
        releaseIfLocked()
        // Left open by "After N minutes, even if closed": let go when that runs out.
        releaseWhenIdle?.cancel()
        if let seconds = lock.secondsLeft(at: now) {
            releaseWhenIdle = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(seconds) + 1))
                guard let self, !Task.isCancelled, !self.panelUp else { return }
                self.now = self.clock()
                self.lock.expire(at: self.now)
                self.releaseIfLocked()
            }
        }
    }

    /// Lock Now.
    public func lockNow() {
        lockEpoch &+= 1
        lock.lock()
        now = clock()
        // Locked, the panel holds nothing: the numbers go now, not when it closes.
        releaseIfSealedShut()
    }

    /// Lets the numbers go when the lock that hides everything has closed with the panel up:
    /// Lock Now, or the idle limit passing. A read in progress keeps them until it ends.
    private func releaseIfSealedShut() {
        guard contents == .loaded, isSealedShut else { return }
        releaseIfLocked()
    }

    /// The Mac is going to sleep or its screen locked: lock whatever the setting, and forget.
    public func systemLocked() {
        lockEpoch &+= 1
        lock.lock()
        now = clock()
        // Whoever comes to the Mac next is a stranger until they prove otherwise: a read in
        // progress stops too, keeping what it sealed so far.
        readingTask?.cancel()
        readingTask = nil
        releaseAfterReading = false
        release()
    }

    /// Once a second while the panel is up.
    public func tick() {
        now = clock()
        lock.expire(at: now)
        releaseIfSealedShut()
    }

    private func used() { lock.used(at: clock()) }

    /// Use the panel sees and the model does not: typing in the editor, stepping Large Type's
    /// lines. It keeps an open Vault open as any other use does, and under "every number" keeps
    /// the number being worked on shown; it never opens a locked one.
    public func noteActivity() {
        used()
        lock.keepShown(at: clock())
    }

    /// Any use of the panel at all: a click, a key, a scroll, the pointer moving over it. An open
    /// Vault then locks only after the idle time its setting allows, never mid-use. Taken at most
    /// once a second, so a moving pointer does not redraw the panel. Unlike ``noteActivity()``, it
    /// never keeps a number shown under "every number": that number's thirty seconds are its own.
    public func panelActivity() {
        let time = clock()
        guard time.timeIntervalSince(lastPanelActivity) >= 1 else { return }
        lastPanelActivity = time
        used()
    }

    /// Chooses `id` and shows it: its tab, and back to all for whichever filter would hide it.
    public func reveal(_ id: UUID) { showEvenIfFiltered(id) }

    /// Lets the numbers go once the Vault is locked, or, while Read Documents is still reading,
    /// once it finishes: a read carries on with the panel closed, and needs what it has read so far
    /// to seal it. Nothing is shown meanwhile; the lock has already locked.
    private func releaseIfLocked() {
        guard lock.settings.requiresAuthentication, !lock.isOpen(at: now) else { return }
        guard reading == nil else {
            releaseAfterReading = true
            return
        }
        release()
    }

    /// Read Documents, run by the model so it goes on when the panel closes. One at a time.
    public func startReading(with reader: VaultDocumentReading, again: Bool = false, scope: VaultReadScope? = nil) {
        guard reading == nil, readingTask == nil else { return }
        readingTask = Task { [weak self] in
            await self?.readDocuments(with: reader, again: again, scope: scope)
            self?.readingTask = nil
        }
    }

    /// Stop, on the banner of a refresh that is running: what was read so far is kept, and the
    /// next one carries on.
    public func stopReading() {
        readingTask?.cancel()
    }

    /// The Vault opened: Refresh runs by itself when the setting allows (it only opens documents
    /// IDs were already read from), so a changed scan or an app update needs no click.
    public func refreshIfWanted(with reader: VaultDocumentReading) {
        guard VaultRefresh.isAutomatic(in: defaults), contents == .loaded,
              needsReadAgain || !refreshSources.isEmpty else { return }
        startReading(with: reader, scope: .refresh())
    }

    /// Every document an ID was read from, saved or waiting: what Refresh looks at. Not the
    /// documents that only name an ID; those come back with Discover More.
    public var refreshSources: Set<String> {
        var paths = staleSources
        for entry in entries {
            if let path = entry.sourcePath { paths.insert(path) }
            for source in entry.facts?.sources ?? [] { paths.insert(source.path) }
        }
        for find in finds { for source in find.facts.sources { paths.insert(source.path) } }
        for byFile in copies.values { paths.formUnion(byFile.keys) }
        return paths
    }

    /// Not Now, on the banner that offers Discover More after an update: it is not offered again
    /// until the next one. The menu still has it.
    public func dismissDiscover() {
        guard needsDiscover else { return }
        needsDiscover = false
        readingChanged = true
        saveReading()
    }

    /// Keep Mine: the saved ID stands, and the other reading of its document is set aside.
    public func keepSaved(_ id: UUID) {
        guard let find = rereads[id] else { return }
        rereads[id] = nil
        setAside(find)
    }

    /// Use the New Reading: the saved ID takes the number its document now reads, after a proof
    /// when one is owed, as any change to a number does.
    @discardableResult
    public func useReread(_ id: UUID) async -> Bool {
        guard let findID = rereads[id], let find = finds.first(where: { $0.id == findID }),
              let entry = entries.first(where: { $0.id == id }) else { return false }
        var draft = Draft(entry)
        draft.value = find.value
        guard await update(id, to: draft) else { return false }
        rereads[id] = nil
        return true
    }

    /// Lets every number go from memory. To Confirm is sealed first, so the next unlock brings it
    /// back without reading anything again.
    private func release() {
        if contents == .loaded { saveReading() }
        entries = []
        finds = []
        readIndex = [:]
        mentions = [:]
        copies = [:]
        choices = [:]
        lessons = [:]
        staleSources = []
        missingDocuments = []
        // What a refresh changed holds numbers too, and is news only while the Vault is up.
        changes = [:]
        rereads = [:]
        // The rows hold every number in full: a closed, locked Vault holds none of them.
        rowsCache = nil
        contents = .notLoaded
        selection = nil
    }

    private func load() {
        guard contents != .loaded else { keepSelectionVisible(); return }
        guard let store else { contents = .unreadable(.unreadableFile); return }
        do {
            entries = try store.load()
            contents = .loaded
            readGeneration = VaultSetAside.generation(in: defaults)
            if let state = store.loadReading() {
                // Another build's rules, or a Forget since: read every file again next time.
                // What another build read is let go with it, as its finds were made by older
                // rules; what the user chose about them is carried onto the next read's.
                let sameRules = state.version == VaultReading.version
                finds = sameRules ? state.finds : []
                mentions = sameRules ? state.mentions : [:]
                copies = sameRules ? state.copies : [:]
                choices = sameRules ? state.choices : state.choices.merging(Dictionary(
                    state.finds.filter { $0.pin != nil || $0.assignment != nil || $0.geo != nil || $0.card != nil }.map {
                        (VaultReading.normalized($0.value), VaultChoice($0))
                    }, uniquingKeysWith: { a, _ in a })) { a, _ in a }
                readIndex = sameRules && state.generation == VaultSetAside.generation(in: defaults) ? state.read : [:]
                lessons = state.lessons
                // What another build read IDs from is where Refresh looks first: remembered,
                // though what it read there is let go.
                staleSources = Set(state.staleSources ?? [])
                if !sameRules {
                    staleSources.formUnion(state.finds.flatMap { $0.facts.sources.map(\.path) })
                    staleSources.formUnion(state.copies.values.flatMap(\.keys))
                }
                missingDocuments = Set(state.notFound ?? [])
                needsDiscover = state.needsDiscover ?? false
                lastRefreshed = state.lastRefreshed
                lastDiscovered = state.lastDiscovered
                // Asked for whenever anything read is let go: waiting finds, and also what saved
                // numbers took from their documents (a renewed license's expiry), which a Vault
                // with nothing left to confirm would otherwise lose without a word.
                needsReadAgain = state.needsReadAgain
                    || (!sameRules && !(state.finds.isEmpty && state.copies.isEmpty && state.read.isEmpty))
                if !sameRules { readingChanged = true }
            }
            keepSelectionVisible()
        } catch let error as VaultError {
            entries = []
            contents = .unreadable(error)
        } catch {
            entries = []
            contents = .unreadable(.unreadableFile)
        }
    }

    // MARK: Proving it

    /// Asks the owner to prove it and records the answer. False when they did not, with the
    /// reason in ``notice`` unless they simply cancelled.
    @discardableResult
    private func prove(_ reason: String, for id: UUID?) async -> Bool {
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        let epoch = lockEpoch
        let proof = await authenticator.prove(reason: reason)
        now = clock()
        // The panel closed, Lock Now was chosen or the Mac locked while the prompt was up: an
        // answer given after that opens nothing, and nothing is shown or copied for it.
        guard epoch == lockEpoch else { return false }
        switch proof {
        case .allowed:
            notice = nil
            lock.proved(for: id, at: now)
            return true
        case .cancelled:
            return false
        case .unavailable(let message), .failed(let message):
            notice = message
            return false
        }
    }

    /// Unlock: the header's button, and what opening does by itself.
    /// True when the Vault is open afterwards. Opening it reads it: nothing was loaded for a
    /// locked panel.
    @discardableResult
    public func unlock() async -> Bool {
        guard lock.needsProof(for: nil, at: clock()) else {
            load()
            return true
        }
        // Under "every number" there is nothing to unlock as a whole; the button is not drawn.
        guard lock.settings.ask == .whenOpened else { return false }
        guard await prove("unlock your Vault", for: nil) else { return false }
        load()
        return true
    }

    /// Show: draws `id`'s number in full, after a proof when one is owed.
    @discardableResult
    public func show(_ id: UUID) async -> Bool {
        guard let row = row(id) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("show \(row.title)", for: id) else { return false }
        }
        used()
        return lock.canShow(id, at: clock())
    }

    /// Copy: puts `id`'s number on the pasteboard, after a proof when one is owed.
    @discardableResult
    public func copy(_ id: UUID) async -> Bool {
        guard let row = row(id) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("copy \(row.title)", for: id) else { return false }
        }
        guard lock.canShow(id, at: clock()) else { return false }
        copyToPasteboard(row.value)
        used()
        return true
    }

    /// Copies a number that is a detail of `id`'s, such as the passport a visa is in: the same
    /// proof as the row's own number, and the same concealed, cleared clipboard.
    @discardableResult
    public func copy(_ detailNumber: String, for id: UUID) async -> Bool {
        guard let row = row(id) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("copy a detail of \(row.title)", for: id) else { return false }
        }
        guard lock.canShow(id, at: clock()) else { return false }
        copyToPasteboard(detailNumber)
        used()
        return true
    }

    /// An entry or a find, by id: what Show and Copy act on.
    private func row(_ id: UUID) -> (title: String, value: String)? {
        if let entry = entries.first(where: { $0.id == id }) { return (entry.title, entry.value) }
        if let find = finds.first(where: { $0.id == id }) { return (find.title, find.value) }
        return nil
    }

    // MARK: Editing

    /// Adds a number. No proof: the person typing it already has it in hand.
    @discardableResult
    public func add(_ draft: Draft) -> UUID? { add(draft, sourcePath: nil) }

    private func add(_ draft: Draft, sourcePath: String?) -> UUID? {
        guard draft.isComplete, contents == .loaded || contents == .notLoaded else { return nil }
        if contents == .notLoaded { load() }
        guard contents == .loaded else { return nil }
        let stamp = clock()
        // Typed in while it waits in To Confirm: what was read for it, and the choices made
        // about it, come with it rather than being let go.
        let waiting = draft.facts == nil
            ? finds.first { VaultReading.normalized($0.value) == VaultReading.normalized(draft.value) } : nil
        var facts = draft.facts ?? waiting?.facts
        facts?.category = draft.category
        var entry = VaultEntry(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               value: draft.value.trimmingCharacters(in: .whitespacesAndNewlines),
                               personID: draft.personID,
                               note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                               sourcePath: sourcePath, addedAt: stamp,
                               category: draft.category, facts: facts)
        entry.pin = draft.pin ?? waiting?.pin
        entry.assignment = draft.assignment ?? waiting?.assignment
        entry.geo = draft.geo ?? waiting?.geo
        entry.card = draft.card ?? waiting?.card
        guard write(entries + [entry]) else { return nil }
        dropFinds(matching: entry.value)
        selection = entry.id
        showEvenIfFiltered(entry.id)
        return entry.id
    }

    /// Changes an entry, after a proof when its number is not already showing: the editor draws
    /// it in full.
    @discardableResult
    public func update(_ id: UUID, to draft: Draft) async -> Bool {
        guard draft.isComplete, let title = entries.first(where: { $0.id == id })?.title else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("change \(title)", for: id) else { return false }
        }
        // Looked up again after the proof: while it was asked, the panel may have closed and let
        // the numbers go, or another number may have been removed and moved this one.
        guard contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        var changed = entries
        changed[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].assignment = draft.assignment
        changed[index].note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].category = draft.category
        changed[index].pin = draft.pin
        changed[index].geo = draft.geo
        changed[index].card = draft.card
        changed[index].updatedAt = clock()
        used()
        let before = entries[index]
        guard write(changed) else { return false }
        // A read number corrected by hand: the misreading is set aside, as Confirm does, so the
        // next read does not offer it again.
        if before.facts != nil, VaultReading.normalized(before.value) != VaultReading.normalized(changed[index].value) {
            remember(before.value)
            copies[VaultReading.normalized(before.value)] = nil
            readingChanged = true
            saveReading()
        }
        dropFinds(matching: changed[index].value)
        return true
    }

    /// A number now saved is no longer waiting: the find that carried it would show it twice.
    /// Its documents stay with it as documents of the saved number.
    private func dropFinds(matching value: String) {
        let key = VaultReading.normalized(value)
        let matching = finds.filter { VaultReading.normalized($0.value) == key }
        guard !matching.isEmpty else { return }
        for find in matching { for source in find.facts.sources { mentions[key, default: []].append(source) } }
        finds.removeAll { VaultReading.normalized($0.value) == key }
        readingChanged = true
        saveReading()
    }

    /// Removes an entry for good, after a proof when one is owed. There is no Trash for a number.
    /// One that was read from a document is set aside too, so the next read does not offer back
    /// what was just removed.
    @discardableResult
    public func delete(_ id: UUID) async -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("remove \(entry.title)", for: id) else { return false }
        }
        // While the proof was asked, the panel may have closed and let the numbers go: saving
        // "everything but this one" from an emptied list would write an empty Vault.
        guard contents == .loaded, entries.contains(where: { $0.id == id }) else { return false }
        used()
        guard write(entries.filter { $0.id != id }) else { return false }
        if entry.sourcePath != nil { remember(entry.value) }
        keepSelectionVisible()
        return true
    }

    /// Saves `changed` and, only once the disk has it, shows it. A refused save leaves the list as
    /// it was, so the panel never shows a number that would be gone at the next launch.
    private func write(_ changed: [VaultEntry]) -> Bool {
        guard let store else { notice = Self.message(for: .notWritten); return false }
        // Only over what was loaded: a list held while the Vault was let go is not the Vault.
        guard contents == .loaded else { return false }
        do {
            try store.save(changed)
            entries = changed
            notice = nil
            return true
        } catch let error as VaultError {
            notice = Self.message(for: error)
            return false
        } catch {
            notice = Self.message(for: .notWritten)
            return false
        }
    }

    // MARK: Reading documents

    /// Read Documents: every file the reader offers, read for the numbers ``VaultReading``
    /// trusts. A number already in the Vault, already waiting, or set aside is not offered again.
    ///
    /// No proof is asked: like typing a number in, reading a document needs the document, and
    /// what it finds is drawn with only its ending until someone proves it is theirs.
    ///
    /// Only files that are new or changed since they were last read are opened, so a second read
    /// of a large folder is quick, and a read that was stopped carries on where it stopped.
    /// `again` opens every file, as after a change to what the Vault reads.
    ///
    /// `scope` says what is looked at (``VaultReadScope``): the folders, as above, or with
    /// `.refresh` only the documents an ID was already read from, without walking any folder.
    /// A refresh opens those that changed since they were read (all of them after a change of
    /// rules), marks what it changed, and never lets an ID go because its document moved.
    public func readDocuments(with reader: VaultDocumentReading, again: Bool = false,
                              scope: VaultReadScope? = nil) async {
        let scope = scope ?? (again ? .everything : .discover)
        // Stopped before it began (the Mac locked first): nothing is loaded for it.
        guard reading == nil, !Task.isCancelled else { return }
        load()
        guard contents == .loaded else { return }
        // Settings ▸ Vault ▸ Forget while the Vault stayed loaded: the record of read files
        // belongs to before it, and every file is read again so the forgotten come back.
        let generation = VaultSetAside.generation(in: defaults)
        if scope == .everything || generation != readGeneration { readIndex = [:] }
        readGeneration = generation
        let began = Date()
        // A refresh that follows a change of rules has nothing to compare against: what the
        // older rules read was let go, so nothing it reads now is "changed".
        let afterNewRules = needsReadAgain
        var refreshFiles: [URL] = []
        var refreshMissing = Set<String>()
        var refreshKnown = 0
        if case .refresh(let only) = scope {
            let known = only.map { id in rows.first { $0.id == id }?.documents.map(\.path) ?? [] } ?? refreshSources.sorted()
            refreshKnown = known.count
            // One ID's documents are read whether or not they changed: it was asked for.
            let index = only == nil ? readIndex : [:]
            // Asked off the main actor: a file's size and date, for a few hundred files.
            let look = await Task.detached { () -> (changed: [URL], missing: [String]) in
                var changed: [URL] = [], missing: [String] = []
                for path in known {
                    let url = URL(fileURLWithPath: path)
                    guard reader.exists(url) else { missing.append(path); continue }
                    if let stamp = reader.stamp(of: url), index[path] == stamp { continue }
                    changed.append(url)
                }
                return (changed, missing)
            }.value
            guard !Task.isCancelled, contents == .loaded, reading == nil else { return }
            refreshMissing = Set(look.missing)
            let missing = missingDocuments.subtracting(known).union(refreshMissing)
            if missing != missingDocuments {
                missingDocuments = missing
                readingChanged = true
            }
            refreshFiles = look.changed
            // Asked for by name: its documents are opened though nothing says they changed.
            if only != nil { for file in refreshFiles { readIndex[file.path] = nil } }
            // Nothing to open: no progress to show. What it found missing is sealed, and that it
            // looked is remembered for the footer.
            if refreshFiles.isEmpty {
                finishRefresh(only: only, afterNewRules: afterNewRules)
                if !refreshMissing.isEmpty || lastReading?.scope.isRefresh == true {
                    lastReading = ReadingSummary(documents: refreshKnown, opened: 0, newNumbers: 0, scope: scope,
                                                 missing: refreshMissing.count)
                }
                saveReading()
                return
            }
        }
        reading = ReadingProgress(done: 0, total: 0, scope: scope)
        defer {
            reading = nil
            // The Vault closed while this read went on, and kept the numbers for it: let them go
            // now, as closing would have, however the read ended.
            // Or it was read while the panel showed only its lock: nothing was drawn, and what
            // was loaded to read into goes too.
            if releaseAfterReading || (panelUp && hasSomethingSealed && lock.hidesEverything(at: clock())) {
                releaseAfterReading = false
                now = clock()
                lock.expire(at: now)
                releaseIfLocked()
            }
        }
        var files = refreshFiles
        var unreachable: [String] = []
        if !scope.isRefresh {
            (files, unreachable) = await reader.walk()
            // The Mac locked during the walk, letting the numbers go: nothing to read into.
            guard !Task.isCancelled, contents == .loaded else {
                Logger.shared.info("Vault: read stopped before any document was opened; the Vault locked")
                return
            }
        }
        let roots = VaultReadFolders.folders(in: defaults)
        // Which files to open, by their paths alone (``VaultReadPlan``): a small share of what is
        // on disk. The rest are still present: what was read from them before stays.
        // A refresh opens every changed document an ID came from; the plan chooses among the
        // folders' files, which is Discover More's question.
        let steps: [VaultReadPlan.Step]
        if !reader.followsReadPlan {
            steps = files.map { VaultReadPlan.Step(file: $0, account: nil) }
        } else if scope.isRefresh {
            steps = VaultReadPlan.every(files, under: roots, modified: { reader.modified(of: $0) })
        } else {
            steps = VaultReadPlan(files: files, under: roots, modified: { reader.modified(of: $0) }).steps
        }
        reading = ReadingProgress(done: 0, total: steps.count, scope: scope)
        // Counts only, here and below. A file's name can hold the very number it carries.
        if scope.isRefresh {
            Logger.shared.info("Vault: refresh, \(refreshKnown) document(s) IDs were read from, \(steps.count) to open"
                               + (afterNewRules ? ", every one after a change of rules" : ", changed since they were read")
                               + (refreshMissing.isEmpty ? "" : ", \(refreshMissing.count) not found"))
        } else {
            Logger.shared.info("Vault: \(files.count) document(s) in the read folders, \(steps.count) to look at"
                               + (scope == .everything || readIndex.isEmpty ? ", every one" : ", new and changed ones"))
        }
        // What each ID read as before, for what a refresh changed; and what was waiting.
        let rowsBefore: [UUID: Row] = scope.isRefresh && !afterNewRules
            ? Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        let waitingBefore = Set(finds.map(\.id))
        var readNow: [String: [VaultFind]] = [:]
        var tally = VaultReadTally()
        tally.documents = files.count
        func stopped(at index: Int) {
            Logger.shared.info("Vault: read stopped at \(index) of \(steps.count) document(s), \(tally.opened) opened; "
                               + "the Vault closed or locked, and what was read is kept")
        }
        // An account is read newest year first, and no further once two of its years agree on
        // its numbers: the older years would only say the same again.
        var lastNumbers: [String: Set<String>] = [:]
        var emptyYears: [String: Int] = [:]
        var bareSeen: [String: [String: String]] = [:]
        var settled = Set<String>()
        func accountNumbers(in path: String) -> Set<String> {
            let found = finds.filter { find in
                VaultReading.accountCategories.contains(find.category) && find.facts.sources.contains { $0.path == path }
            }.map { VaultReading.normalized($0.value) }
            let saved = copies.filter { $0.value[path].map { VaultReading.accountCategories.contains($0.category) } ?? false }.keys
            return Set(found).union(saved)
        }
        // Two years that agree settle an account, and so do its three newest giving nothing:
        // papers of that kind carry no number the readers know. Three, not two: a phone bill that
        // stopped labelling its number in 2025 still did in 2024.
        func settle(_ step: VaultReadPlan.Step) {
            guard let account = step.account else { return }
            let numbers = accountNumbers(in: step.file.path)
            if numbers.isEmpty {
                if lastNumbers[account] == nil, emptyYears[account, default: 0] + 1 >= 3 { settled.insert(account) }
                emptyYears[account, default: 0] += 1
                return
            }
            if lastNumbers[account] == numbers { settled.insert(account) }
            lastNumbers[account] = numbers
        }
        for (index, step) in steps.enumerated() {
            let file = step.file
            // The panel closed or the Mac locked, letting the numbers go. What was
            // read so far was sealed as it went.
            if Task.isCancelled || contents != .loaded { return stopped(at: index) }
            if !scope.isRefresh, let account = step.account, settled.contains(account) {
                reading = ReadingProgress(done: index + 1, total: steps.count)
                continue
            }
            let stamp = reader.stamp(of: file)
            if let stamp, readIndex[file.path] == stamp {
                settle(step)
                reading = ReadingProgress(done: index + 1, total: steps.count)
                continue
            }
            let pages = await reader.pages(in: file)
            // Locked meanwhile, even if opened again since: this read was stopped.
            guard !Task.isCancelled, contents == .loaded else { return stopped(at: index) }
            // Nothing came back: locked, damaged, or not there for a moment. What it gave before,
            // and the choices made about it, stay; it is not marked read, so the next read tries again.
            guard !pages.isEmpty else {
                tally.record(pages, ([], []))
                reading = ReadingProgress(done: index + 1, total: steps.count)
                continue
            }
            // A changed file is read afresh: what it said before is let go first. A number it
            // still carries keeps its row and any choice made about it, as does one chosen
            // about under an older build's rules.
            var before = Dictionary(finds.filter { $0.facts.sources.contains { $0.path == file.path } }
                .map { (VaultReading.normalized($0.value), VaultChoice($0)) },
                uniquingKeysWith: { a, _ in a })
            forgetSource(file.path)
            let read = VaultReading.read(pages: pages, from: file.path, under: roots, people: people)
            readNow[file.path] = read.finds
            tally.record(pages, read)
            for var find in read.finds {
                let key = VaultReading.normalized(find.value)
                if before[key] == nil, !finds.contains(where: { VaultReading.normalized($0.value) == key }),
                   let carried = choices.removeValue(forKey: key) {
                    before[key] = carried
                }
                if let choice = before[key] {
                    find = VaultFind(id: choice.id, title: find.title, value: find.value, note: find.note,
                                     facts: find.facts, pin: choice.pin, assignment: choice.assignment, geo: choice.geo,
                                     card: choice.card)
                }
                if take(find), before[key] == nil { tally.added += 1 }
            }
            for mention in read.mentions {
                mentions[VaultReading.normalized(mention.value), default: []].append(mention.source)
            }
            // An account whose papers print its number with no label (a phone bill's header): a
            // number standing alone that a second year of the same account prints too.
            if let account = step.account, lastNumbers[account] == nil, accountNumbers(in: file.path).isEmpty {
                let printed = PrintedPage(pages.flatMap { $0 })
                let bare = VaultReading.bareAccountNumbers(on: printed, from: file.path, under: roots)
                // Exactly one number both years print: two (a customer service line the readers
                // took for a number, say) leave the account unread rather than guessed at.
                let repeated = bare.filter { bareSeen[account]?[$0] != nil }
                if repeated.count == 1, let value = repeated.first, let earlier = bareSeen[account]?[value] {
                    var find = VaultReading.bareAccountFind(value, on: printed, from: file.path, under: roots, people: people)
                    find.facts.add(VaultSource(path: earlier, role: "Account paper", rank: VaultReading.IDRank.letter))
                    if take(find) { tally.added += 1 }
                    settled.insert(account)
                } else {
                    for value in bare where bareSeen[account]?[value] == nil { bareSeen[account, default: [:]][value] = file.path }
                }
            }
            if let stamp { readIndex[file.path] = stamp }
            settle(step)
            readingChanged = true
            reading = ReadingProgress(done: index + 1, total: steps.count)
            // Sealed every so often, so a read stopped halfway keeps what it had.
            if tally.opened % 25 == 0 { saveReading() }
            if tally.opened % 250 == 0 {
                Logger.shared.debug("Vault: \(index + 1) of \(steps.count) document(s) looked at, \(tally.opened) opened")
            }
        }
        if case .refresh(let only) = scope {
            // What reads differently now, per ID: its row says Updated and its details say how.
            var updated = 0
            for row in rows {
                guard let old = rowsBefore[row.id] else { continue }
                let changed = VaultRefresh.changes(from: old.facts, to: row.facts)
                guard !changed.isEmpty else { continue }
                changes[row.id] = changed
                updated += 1
            }
            // A saved ID whose own document was opened and no longer gives its number, but
            // gives one other of its kind: the saved one stands, and the panel asks.
            for entry in entries {
                guard let path = entry.sourcePath ?? entry.facts?.primary?.path, let found = readNow[path] else { continue }
                let own = VaultReading.normalized(entry.value)
                guard !found.contains(where: { VaultReading.normalized($0.value) == own }) else { continue }
                let others = found.filter { find in
                    find.category == entry.category
                        && !entries.contains { VaultReading.normalized($0.value) == VaultReading.normalized(find.value) }
                }
                if others.count == 1, let other = others.first,
                   let waiting = finds.first(where: { VaultReading.normalized($0.value) == VaultReading.normalized(other.value) }) {
                    rereads[entry.id] = waiting.id
                }
            }
            let gone = waitingBefore.subtracting(finds.map(\.id)).count
            finishRefresh(only: only, afterNewRules: afterNewRules)
            readingChanged = true
            saveReading()
            lastReading = ReadingSummary(documents: refreshKnown, opened: tally.opened, newNumbers: tally.added,
                                         scope: scope, updated: updated, missing: refreshMissing.count, gone: gone)
            Logger.shared.info("Vault: refreshed \(refreshKnown) document(s), \(tally.opened) opened, \(updated) ID(s) updated, "
                               + "\(tally.added) new, \(gone) no longer read, \(refreshMissing.count) not found, in "
                               + String(format: "%.1f", Date().timeIntervalSince(began)) + " s")
            if selection.flatMap(row) == nil { selection = visibleIDs.first }
            return
        }
        // A file gone from the folders is forgotten, so one put back is read again; a number
        // whose every document is gone is let go, rather than pointing at nothing. Only under a
        // folder this read could see into: one that gave no files at all is unmounted, renamed
        // or not yet allowed (macOS asks before the first look into Documents), and what was
        // read from it is kept until it can be seen again.
        let present = Set(files.map(\.path))
        let folders = VaultReadFolders.folders(in: defaults)
        let reached = Self.reachedFolders(folders, files: present)
        func isGone(_ path: String) -> Bool {
            guard !present.contains(path) else { return false }
            // Under a folder the walk could not open: not seen, so not gone.
            if unreachable.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
            // A folder taken off the list: what was read in it goes with it.
            if !folders.isEmpty, !folders.contains(where: { path.hasPrefix($0 + "/") }) { return true }
            return reached.contains { path.hasPrefix($0 + "/") }
        }
        readIndex = readIndex.filter { !isGone($0.key) }
        let documents = Set(finds.flatMap { $0.facts.sources.map(\.path) } + mentions.values.flatMap { $0.map(\.path) }
                            + copies.values.flatMap(\.keys))
        for path in documents where isGone(path) {
            forgetSource(path)
        }
        // A choice not found again is let go once every folder was read; one for a folder that
        // was out of reach waits for it.
        if unreachable.isEmpty, folders.isEmpty || reached.count == folders.count { choices = [:] }
        needsReadAgain = false
        // The folders have been read with this build's rules: nothing is left to offer.
        needsDiscover = false
        staleSources = []
        lastDiscovered = clock()
        // A document a saved ID points at that the folders no longer hold is marked, and one
        // found again is not. The ID stays either way; its row says so.
        var pointedAt = missingDocuments
        for entry in entries {
            if let path = entry.sourcePath { pointedAt.insert(path) }
            for source in entry.facts?.sources ?? [] { pointedAt.insert(source.path) }
        }
        missingDocuments = pointedAt.filter { !present.contains($0) && !reader.exists(URL(fileURLWithPath: $0)) }
        readingChanged = true
        saveReading()
        lastReading = ReadingSummary(documents: files.count, opened: tally.opened, newNumbers: tally.added, scope: scope)
        Logger.shared.info(tally.summary(seconds: Date().timeIntervalSince(began)))
        if selection.flatMap(row) == nil { selection = visibleIDs.first }
    }

    /// A refresh of every ID is done: the older build's documents have been read again, and
    /// after a change of rules the rest of the folders are still to be looked at.
    private func finishRefresh(only: UUID?, afterNewRules: Bool) {
        guard only == nil else { return }
        if !staleSources.isEmpty { staleSources = []; readingChanged = true }
        if afterNewRules {
            needsReadAgain = false
            needsDiscover = true
            readingChanged = true
        }
        lastRefreshed = clock()
    }

    /// The read folders this read saw into: each that gave at least one file. With no folders
    /// listed (a reader handed its own files), the whole disk counts as seen when any file was.
    nonisolated static func reachedFolders(_ folders: [String], files: Set<String>) -> [String] {
        guard !files.isEmpty else { return [] }
        guard !folders.isEmpty else { return [""] }
        return folders.filter { folder in files.contains { $0.hasPrefix(folder + "/") } }
    }

    /// The rules for one number read from several documents (``VaultCopies``), here for the
    /// model's callers and tests.
    nonisolated static func supersedes(_ incoming: VaultReadFacts, _ held: VaultReadFacts) -> Bool {
        VaultCopies.supersedes(incoming, held)
    }

    nonisolated static func merged(_ copies: [VaultFind]) -> VaultFind? { VaultCopies.merged(copies) }

    nonisolated static func fuller(_ kept: String?, _ other: String?) -> String? { VaultCopies.fuller(kept, other) }

    /// Adds what one document said about a number. A number already waiting is rebuilt with it
    /// (``merged(_:)``), keeping its row and the choices made about it; a saved number keeps it
    /// for its documents and dates (``rows``); a new one goes to To Confirm unless it was set
    /// aside. True when it was new.
    private func take(_ find: VaultFind) -> Bool {
        let value = VaultReading.normalized(find.value)
        let path = find.sourcePath
        if let index = finds.firstIndex(where: { VaultReading.normalized($0.value) == value }) {
            copies[value, default: [:]][path] = find
            finds[index] = rebuilt(finds[index], value)
            return false
        }
        if entries.contains(where: { VaultReading.normalized($0.value) == value }) {
            copies[value, default: [:]][path] = find
            return false
        }
        guard isNew(find) else { return false }
        copies[value, default: [:]][path] = find
        finds.append(rebuilt(find, value))
        return true
    }

    /// `find` as all its documents now say, keeping its id and the user's choices.
    private func rebuilt(_ find: VaultFind, _ value: String) -> VaultFind {
        guard let merged = Self.merged(Array((copies[value] ?? [:]).values)) else { return find }
        return VaultFind(id: find.id, title: merged.title, value: find.value, note: merged.note,
                         facts: merged.facts, pin: find.pin, assignment: find.assignment, geo: find.geo, card: find.card)
    }

    /// Lets go of what `path` said: as a source of a waiting number (the number goes when it was
    /// its only document, and is rebuilt from the others when it was not) and as a document
    /// naming one.
    private func forgetSource(_ path: String) {
        var changed = Set<String>()
        for value in Array(copies.keys) where copies[value]?[path] != nil {
            copies[value]?[path] = nil
            if copies[value]?.isEmpty == true { copies[value] = nil }
            changed.insert(value)
        }
        for index in finds.indices.reversed() {
            let value = VaultReading.normalized(finds[index].value)
            if copies[value] != nil {
                if changed.contains(value) { finds[index] = rebuilt(finds[index], value) }
            } else {
                finds[index].facts.sources.removeAll { $0.path == path }
                if finds[index].facts.sources.isEmpty { finds.remove(at: index) }
            }
        }
        for key in Array(mentions.keys) where mentions[key]?.contains(where: { $0.path == path }) == true {
            mentions[key]?.removeAll { $0.path == path }
            if mentions[key]?.isEmpty == true { mentions[key] = nil }
        }
    }

    /// What each document said about each number, by number and then by file: what a waiting
    /// number is rebuilt from, and what keeps a saved one's dates current.
    private var copies: [String: [String: VaultFind]] = [:] { didSet { rowsRevision &+= 1 } }
    /// Choices about waiting numbers made under an older build's rules, by number, until a read
    /// finds those numbers again.
    private var choices: [String: VaultChoice] = [:]
    /// The Forget generation the record of read files belongs to.
    private var readGeneration = 0

    /// Something in To Confirm or the record of read files changed since it was last sealed.
    private var readingChanged = false

    /// Seals To Confirm and the record of read files. A refusal is logged and otherwise let go:
    /// the next read rebuilds whatever was lost.
    private func saveReading() {
        // Never once the numbers are let go: what is in memory then is nothing, and sealing it
        // would write that over what was read.
        guard readingChanged, contents == .loaded, let store else { return }
        let state = VaultReadingState(generation: readGeneration, finds: finds, read: readIndex,
                                      mentions: mentions, copies: copies, choices: choices,
                                      needsReadAgain: needsReadAgain, lessons: lessons,
                                      staleSources: staleSources.isEmpty ? nil : staleSources.sorted(),
                                      notFound: missingDocuments.isEmpty ? nil : missingDocuments.sorted(),
                                      needsDiscover: needsDiscover ? true : nil,
                                      lastRefreshed: lastRefreshed, lastDiscovered: lastDiscovered)
        do {
            try store.saveReading(state)
            readingChanged = false
        } catch {
            Logger.shared.warning("Vault: To Confirm could not be sealed; the next read finds it again")
        }
    }

    /// Adds a find as an entry, as the editor left it, and takes it out of To Confirm.
    @discardableResult
    public func confirm(_ findID: UUID, as draft: Draft) -> UUID? {
        guard let find = finds.first(where: { $0.id == findID }) else { return nil }
        var draft = draft
        // What was read stays with the number, whatever the editor changed about its name.
        if draft.facts == nil { draft.facts = find.facts }
        guard let id = add(draft, sourcePath: find.sourcePath) else { return nil }
        if VaultReading.normalized(draft.value) != VaultReading.normalized(find.value) {
            remember(find.value)
            copies[VaultReading.normalized(find.value)] = nil
        }
        finds.removeAll { $0.id == findID }
        readingChanged = true
        saveReading()
        return id
    }

    /// Not This: takes a find out of To Confirm and keeps it out of later reads, across launches,
    /// until Settings ▸ Vault forgets the numbers set aside.
    public func setAside(_ findID: UUID) {
        guard let find = finds.first(where: { $0.id == findID }) else { return }
        remember(find.value)
        finds.removeAll { $0.id == findID }
        copies[VaultReading.normalized(find.value)] = nil
        readingChanged = true
        saveReading()
        keepSelectionVisible()
    }

    /// Records a number as not to be offered again: its keyed fingerprint in UserDefaults, or,
    /// when the Keychain will not give one, a hash for this run.
    private func remember(_ value: String) {
        if let fingerprint = store?.fingerprint(value, makingKey: true) {
            VaultSetAside.add(fingerprint, in: defaults)
        } else {
            setAsideThisRun.insert(Self.hash(value))
        }
    }

    private func isNew(_ find: VaultFind) -> Bool {
        let value = VaultReading.normalized(find.value)
        if entries.contains(where: { VaultReading.normalized($0.value) == value }) { return false }
        if finds.contains(where: { VaultReading.normalized($0.value) == value }) { return false }
        if setAsideThisRun.contains(Self.hash(find.value)) { return false }
        guard let fingerprint = store?.fingerprint(find.value) else { return true }
        return !VaultSetAside.fingerprints(in: defaults).contains(fingerprint)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(VaultReading.normalized(value).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Settings

    /// The lock's settings changed while the panel was up. Anything tighter or simply different
    /// locks; nothing loosens an existing proof.
    public func settingsChanged() {
        let settings = VaultLockSettings(defaults: defaults, store: store)
        guard settings != lock.settings else { return }
        lockEpoch &+= 1
        lock.settings = settings
        lock.lock()
        now = clock()
    }

    // MARK: Words

    /// What the panel says for each way reading or writing can fail.
    public static func message(for error: VaultError) -> String {
        switch error {
        case .keyMissing:
            return "This Vault was sealed with a key that isn’t in this Mac’s Keychain, so it can’t be opened here."
        case .keyUnreadable(let status):
            return "The Keychain wouldn’t release the Vault’s key (status \(status)). Unlock your login keychain and try again."
        case .keyNotSaved(let status):
            return "The Keychain wouldn’t keep the Vault’s key (status \(status)), so nothing was saved."
        case .unreadableFile:
            return "The Vault’s file isn’t one this version of SyncCloud can read."
        case .wrongKeyOrDamaged:
            return "The Vault’s file didn’t open with this Mac’s key. It is damaged, or it came from another Mac."
        case .notWritten:
            return "The Vault couldn’t be saved, so that change wasn’t kept."
        }
    }
}
