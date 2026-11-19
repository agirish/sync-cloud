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
}

extension VaultDocumentReading {
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
    @Published public var personFilter: PersonFilter = .everyone { didSet { keepSelectionVisible() } }
    @Published public var selection: UUID?

    /// How far Read Documents has got.
    public struct ReadingProgress: Equatable, Sendable {
        public var done: Int
        public var total: Int
    }

    /// What the last Read Documents came to.
    public struct ReadingSummary: Equatable, Sendable {
        /// Every document in the chosen folders.
        public var documents: Int
        /// Those opened this time: new, changed, or all of them on a first read.
        public var opened: Int
        public var newNumbers: Int

        public init(documents: Int, opened: Int? = nil, newNumbers: Int) {
            self.documents = documents
            self.opened = opened ?? documents
            self.newNumbers = newNumbers
        }
    }

    /// Numbers read from documents and not yet confirmed. Sealed in Read Documents' own file
    /// between reads, and let go from memory with the entries when the Vault locks.
    @Published public private(set) var finds: [VaultFind] = [] { didSet { rowsRevision &+= 1 } }
    /// To Confirm lists its older numbers only when asked.
    @Published public var showsOlderFinds = false { didSet { keepSelectionVisible() } }
    /// Each file read, by path, against ``VaultDocumentReading/stamp(of:)`` when it was read.
    private var readIndex: [String: String] = [:]
    /// Set while Read Documents runs.
    @Published public private(set) var reading: ReadingProgress?
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
    }

    // MARK: What the list shows

    /// The entries the search and the person filter leave, in list order: by kind, then by name.
    public var visibleEntries: [VaultEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            switch personFilter {
            case .everyone: break
            case .household: if entry.personID != nil { return false }
            case .person(let id): if entry.personID != id { return false }
            }
            guard !needle.isEmpty else { return true }
            // The name, the note and the kind. Never the number: a search that matched on digits
            // would confirm a guess at a locked number one keystroke at a time.
            return entry.title.lowercased().contains(needle) || entry.note.lowercased().contains(needle)
                || entry.kind.title.lowercased().contains(needle)
        }
        .sorted(by: Self.listOrder)
    }

    private static func listOrder(_ a: VaultEntry, _ b: VaultEntry) -> Bool {
        let kinds = VaultEntry.Kind.allCases
        let (ka, kb) = (kinds.firstIndex(of: a.kind) ?? 0, kinds.firstIndex(of: b.kind) ?? 0)
        if ka != kb { return ka < kb }
        // Current numbers first; the older ones kept for reference after them, newest first.
        if a.isOlder != b.isOlder { return !a.isOlder }
        if a.isOlder, a.dated != b.dated { return (a.dated ?? .distantPast) > (b.dated ?? .distantPast) }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.addedAt < b.addedAt
    }

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

    private static func dayStamp(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    private var computedRows: [Row] {
        let folders = VaultReadFolders.folders(in: defaults)
        func withMentions(_ facts: VaultReadFacts?, _ value: String) -> VaultReadFacts? {
            guard var facts else { return nil }
            for source in mentions[VaultReading.normalized(value)] ?? [] { facts.add(source) }
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
        }
        var all: [Item] = entries.map { entry in
            // A saved number's person was chosen in the editor; with none, it goes by its name.
            let chosen = entry.assignment
            var personID: String?
            if case .person(let id)? = chosen { personID = id }
            if chosen == nil { personID = Self.person(named: entry.facts?.holder, among: people) }
            return Item(id: entry.id, title: entry.title, value: entry.value, note: entry.note, category: entry.category,
                        facts: withMentions(readSince(entry), entry.value), isSaved: true, pin: entry.pin,
                        chosen: chosen, personID: personID)
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
                        chosen: find.assignment, personID: personID)
        }
        // A number whose name line was missed, but whose date of birth was read, is the same
        // person's as another number read with both: it borrows that one's name and person.
        var known: [String: (id: String?, holder: String)] = [:]
        for item in all {
            guard let facts = item.facts, let key = facts.personKey, let holder = facts.holder else { continue }
            if known[key]?.id == nil { known[key] = (item.personID, holder) }
        }
        for index in all.indices where all[index].chosen == nil && all[index].personID == nil
            && all[index].facts?.holder == nil {
            if let key = all[index].facts?.personKey, let match = known[key] {
                all[index].personID = match.id
                all[index].facts?.holder = match.holder
            }
        }
        // Grouped by whose it is as best known: the choice, else the matched person, else the
        // name or birth date read. A saved passport and a new read of the same person's meet.
        let standings = VaultStandings.compute(all.map { item in
            let grouping: VaultAssignment? = item.chosen ?? item.personID.map { .person($0) }
            return VaultStandingInput(id: item.id, value: item.value, category: item.category, facts: item.facts,
                                      pin: item.pin, assignment: grouping, isChosen: item.chosen != nil)
        }, now: now, readFolders: folders)
        return all.map { item in
            let isHousehold = item.chosen == .household || (item.facts == nil && item.personID == nil)
            let personName = item.personID.flatMap { id in people.first { $0.id == id }?.displayName }
            let whose = isHousehold ? "Household"
                : personName ?? (item.personID != nil ? "Someone no longer in People" : nil)
                    ?? item.facts?.holder?.split(separator: " ").first.map(String.init) ?? "Unknown"
            return Row(id: item.id, title: item.title, value: item.value, note: item.note, category: item.category,
                       facts: item.facts, standing: standings[item.id] ?? VaultStanding(tab: .current),
                       isSaved: item.isSaved, personID: item.personID, whose: whose, pin: item.pin,
                       assignment: item.chosen, isHousehold: isHousehold)
        }
    }

    /// Belongs To: whose a number is, a person or the household; nil goes by what was read again.
    /// Later reads keep the choice.
    public func assign(_ id: UUID, to assignment: VaultAssignment?) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var changed = entries
            changed[index].assignment = assignment
            _ = write(changed)
        } else if let index = finds.firstIndex(where: { $0.id == id }) {
            finds[index].assignment = assignment
            readingChanged = true
            saveReading()
        }
        keepSelectionVisible()
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The rows the tab, the person filter and the search leave. A search looks in every tab:
    /// a number asked about on a call may be an older one.
    public var visibleRows: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            if needle.isEmpty, row.standing.tab != tab { return false }
            switch personFilter {
            case .everyone: break
            case .household: if !row.isHousehold { return false }
            case .person(let id): if row.personID != id { return false }
            }
            guard !needle.isEmpty else { return true }
            // Names, notes and kinds. Never the number: a search that matched on digits would
            // confirm a guess at a locked number one keystroke at a time.
            return row.title.lowercased().contains(needle) || row.note.lowercased().contains(needle)
                || row.category.title.lowercased().contains(needle) || row.whose.lowercased().contains(needle)
        }
        .sorted(by: Self.rowOrder)
    }

    /// Cards in the main view's order, each with its rows; a kind with nothing is left out.
    public var cards: [(category: VaultCategory, rows: [Row])] {
        let visible = visibleRows
        let order = tab == .other && !searching
            ? Set(visible.map(\.category)).sorted { $0.rawValue < $1.rawValue } : VaultCategory.mainView
        return order.compactMap { category in
            let rows = visible.filter { $0.category == category }
            return rows.isEmpty ? nil : (category, rows)
        }
    }

    /// The main view's kinds with nothing in them yet, for the line under the cards.
    public var emptyCategories: [VaultCategory] {
        // While Read Documents runs, a card with nothing yet may be about to fill: the folders
        // are read in path order, so a Legal folder's licenses come last.
        guard reading == nil else { return [] }
        let used = Set(rows.map(\.category))
        return VaultCategory.mainView.filter { $0 != .other && !used.contains($0) }
    }

    /// How many rows each tab has, as the person filter leaves them.
    public func count(in tab: VaultStanding.Tab) -> Int {
        rows.filter { row in
            guard row.standing.tab == tab else { return false }
            switch personFilter {
            case .everyone: return true
            case .household: return row.isHousehold
            case .person(let id): return row.personID == id
            }
        }.count
    }

    /// By card, then whose, then current before in-use before expired, then newest.
    private static func rowOrder(_ a: Row, _ b: Row) -> Bool {
        let order = VaultCategory.mainView
        let (ca, cb) = (order.firstIndex(of: a.category) ?? 99, order.firstIndex(of: b.category) ?? 99)
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
        cards.filter { showsList || !folded.contains($0.category) }.flatMap { $0.rows.map(\.id) }
    }

    // MARK: Folded cards

    static let foldedKey = "vaultFoldedCards"

    /// The cards folded to their header, kept between opens. In the list, nothing is folded.
    @Published public private(set) var folded: Set<VaultCategory> = []
    /// Set by the panel: the list shows every row whatever is folded.
    public var showsList = false { didSet { keepSelectionVisible() } }

    private func loadFolded() {
        folded = Set((defaults.stringArray(forKey: Self.foldedKey) ?? []).compactMap(VaultCategory.init(rawValue:)))
    }

    /// Folds or opens one card; with `all`, every card, as ⌥-click does.
    public func toggleFold(_ category: VaultCategory, all: Bool = false) {
        let fold = !folded.contains(category)
        if all {
            folded = fold ? Set(VaultCategory.mainView) : []
        } else if fold {
            folded.insert(category)
        } else {
            folded.remove(category)
        }
        saveFolded()
    }

    /// Whether every card on screen is folded: Collapse All then reads Expand All.
    public var allFolded: Bool {
        let shown = cards.map(\.category)
        return !shown.isEmpty && shown.allSatisfy(folded.contains)
    }

    /// Collapse All, or Expand All once everything on screen is folded.
    public func toggleFoldAll() {
        folded = allFolded ? [] : Set(VaultCategory.mainView)
        saveFolded()
    }

    private func saveFolded() {
        defaults.set(folded.map(\.rawValue).sorted(), forKey: Self.foldedKey)
        keepSelectionVisible()
    }

    /// Make Current or Mark as Older: a choice later reads keep. Nil lets the rules decide again.
    public func pin(_ id: UUID, _ pin: VaultPin?) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var changed = entries
            changed[index].pin = pin
            _ = write(changed)
        } else if let index = finds.firstIndex(where: { $0.id == id }) {
            finds[index].pin = pin
            readingChanged = true
            saveReading()
        }
        keepSelectionVisible()
    }

    /// Documents that name a number without being its source, by the number.
    private var mentions: [String: [VaultSource]] = [:] { didSet { rowsRevision &+= 1 } }

    public func count(for filter: PersonFilter) -> Int {
        switch filter {
        case .everyone: return entries.count
        case .household: return entries.filter { $0.personID == nil }.count
        case .person(let id): return entries.filter { $0.personID == id }.count
        }
    }

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

    // MARK: Opening and closing

    /// The panel appeared. Reads the settings again, since Settings may have changed them, loads
    /// the file, and asks for a proof when the lock says to ask as it opens.
    public func opened() async {
        now = clock()
        let settings = VaultLockSettings(defaults: defaults, store: store)
        if settings != lock.settings {
            lock.settings = settings
            lock.lock()
        }
        lock.expire(at: now)
        load()
        guard case .loaded = contents, !entries.isEmpty,
              lock.settings.requiresAuthentication, lock.settings.ask == .whenOpened,
              !lock.isOpen(at: now) else { return }
        await unlock()
    }

    /// The panel went away. Locks if the setting says closing locks, and then lets the numbers go:
    /// a closed, locked Vault holds nothing in memory.
    public func closed() {
        now = clock()
        lock.closed()
        query = ""
        personFilter = .everyone
        notice = nil
        releaseIfLocked()
    }

    /// Lock Now.
    public func lockNow() {
        lock.lock()
        now = clock()
    }

    /// The Mac is going to sleep or its screen locked: lock whatever the setting, and forget.
    public func systemLocked() {
        lock.lock()
        now = clock()
        release()
    }

    /// Once a second while the panel is up.
    public func tick() {
        now = clock()
        lock.expire(at: now)
    }

    private func used() { lock.used(at: clock()) }

    private func releaseIfLocked() {
        guard lock.settings.requiresAuthentication, !lock.isOpen(at: now) else { return }
        release()
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
                    state.finds.filter { $0.pin != nil || $0.assignment != nil }.map {
                        (VaultReading.normalized($0.value), VaultChoice(id: $0.id, pin: $0.pin, assignment: $0.assignment))
                    }, uniquingKeysWith: { a, _ in a })) { a, _ in a }
                readIndex = sameRules && state.generation == VaultSetAside.generation(in: defaults) ? state.read : [:]
                if !sameRules && !state.finds.isEmpty {
                    notice = "The Vault reads documents better in this version. Choose Read Documents to read them again; your choices are kept."
                    readingChanged = true
                }
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
        let proof = await authenticator.prove(reason: reason)
        now = clock()
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
    public func unlock() async {
        guard lock.needsProof(for: nil, at: clock()) else { return }
        // Under "every number" there is nothing to unlock as a whole; the button is not drawn.
        guard lock.settings.ask == .whenOpened else { return }
        await prove("unlock your Vault", for: nil)
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
        var facts = draft.facts
        facts?.category = draft.category
        var entry = VaultEntry(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               value: draft.value.trimmingCharacters(in: .whitespacesAndNewlines),
                               personID: draft.personID,
                               note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                               sourcePath: sourcePath, addedAt: stamp,
                               category: draft.category, facts: facts)
        entry.pin = draft.pin
        entry.assignment = draft.assignment
        guard write(entries + [entry]) else { return nil }
        dropFinds(matching: entry.value)
        selection = entry.id
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
        changed[index].updatedAt = clock()
        used()
        guard write(changed) else { return false }
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
    public func readDocuments(with reader: VaultDocumentReading, again: Bool = false) async {
        guard reading == nil else { return }
        load()
        guard contents == .loaded else { return }
        // Settings ▸ Vault ▸ Forget while the Vault stayed loaded: the record of read files
        // belongs to before it, and every file is read again so the forgotten come back.
        let generation = VaultSetAside.generation(in: defaults)
        if again || generation != readGeneration { readIndex = [:] }
        readGeneration = generation
        reading = ReadingProgress(done: 0, total: 0)
        defer { reading = nil }
        let began = Date()
        let files = await reader.files()
        reading = ReadingProgress(done: 0, total: files.count)
        // Counts only, here and below. A file's name can hold the very number it carries.
        Logger.shared.info("Vault: reading \(files.count) document(s)" + (again || readIndex.isEmpty ? ", every one" : ", new and changed ones"))
        var tally = VaultReadTally()
        tally.documents = files.count
        func stopped(at index: Int) {
            Logger.shared.info("Vault: read stopped at \(index) of \(files.count) document(s), \(tally.opened) opened; "
                               + "the Vault closed or locked, and what was read is kept")
        }
        for (index, file) in files.enumerated() {
            // The panel closed or the Mac locked, letting the numbers go. What was
            // read so far was sealed as it went.
            if Task.isCancelled || contents != .loaded { return stopped(at: index) }
            let stamp = reader.stamp(of: file)
            if let stamp, readIndex[file.path] == stamp {
                reading = ReadingProgress(done: index + 1, total: files.count)
                continue
            }
            let pages = await reader.pages(in: file)
            guard contents == .loaded else { return stopped(at: index) }
            // A changed file is read afresh: what it said before is let go first. A number it
            // still carries keeps its row and any choice made about it, as does one chosen
            // about under an older build's rules.
            var before = Dictionary(finds.filter { $0.facts.sources.contains { $0.path == file.path } }
                .map { (VaultReading.normalized($0.value), VaultChoice(id: $0.id, pin: $0.pin, assignment: $0.assignment)) },
                uniquingKeysWith: { a, _ in a })
            forgetSource(file.path)
            let read = VaultReading.read(pages: pages, from: file.path)
            tally.record(pages, read)
            for var find in read.finds {
                let key = VaultReading.normalized(find.value)
                if before[key] == nil, !finds.contains(where: { VaultReading.normalized($0.value) == key }),
                   let carried = choices.removeValue(forKey: key) {
                    before[key] = carried
                }
                if let choice = before[key] {
                    find = VaultFind(id: choice.id, title: find.title, value: find.value, note: find.note,
                                     facts: find.facts, pin: choice.pin, assignment: choice.assignment)
                }
                if take(find), before[key] == nil { tally.added += 1 }
            }
            for mention in read.mentions {
                mentions[VaultReading.normalized(mention.value), default: []].append(mention.source)
            }
            if let stamp { readIndex[file.path] = stamp }
            readingChanged = true
            reading = ReadingProgress(done: index + 1, total: files.count)
            // Sealed every so often, so a read stopped halfway keeps what it had.
            if tally.opened % 25 == 0 { saveReading() }
            if tally.opened % 250 == 0 {
                Logger.shared.debug("Vault: \(index + 1) of \(files.count) document(s) looked at, \(tally.opened) opened")
            }
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
        choices = [:]
        readingChanged = true
        saveReading()
        lastReading = ReadingSummary(documents: files.count, opened: tally.opened, newNumbers: tally.added)
        Logger.shared.info(tally.summary(seconds: Date().timeIntervalSince(began)))
        if selection.flatMap(row) == nil { selection = visibleIDs.first }
    }

    /// The read folders this read saw into: each that gave at least one file. With no folders
    /// listed (a reader handed its own files), the whole disk counts as seen when any file was.
    nonisolated static func reachedFolders(_ folders: [String], files: Set<String>) -> [String] {
        guard !files.isEmpty else { return [] }
        guard !folders.isEmpty else { return [""] }
        return folders.filter { folder in files.contains { $0.hasPrefix(folder + "/") } }
    }

    /// Whether `incoming`'s document, carrying a number already read, should speak for it: the
    /// more trusted kind of document first, so a form that only quotes an Aadhaar number never
    /// lends it the form's own issue date; between documents trusted alike, the newer, so a
    /// license renewed under the same number shows the new card's dates, not those of the card
    /// it replaced; and a dated one over an undated one.
    nonisolated static func supersedes(_ incoming: VaultReadFacts, _ held: VaultReadFacts) -> Bool {
        let (ra, rb) = (incoming.primary?.rank ?? 0, held.primary?.rank ?? 0)
        if ra != rb { return ra > rb }
        switch (incoming.validUntil ?? incoming.dated, held.validUntil ?? held.dated) {
        case let (a?, b?): return a > b
        case (_?, nil): return true
        default: return false
        }
    }

    /// One number as every document that carries it says, rebuilt from those documents alone:
    /// the best document speaks (``supersedes(_:_:)``), every one is listed, and what the best is
    /// silent on comes from the next that says it. A receipt notice names the person, its
    /// approval says how long the case is good for.
    ///
    /// Rebuilt rather than merged into, so a file that is changed or gone takes what it said
    /// with it: a misread expiry does not outlive the scan it came from.
    nonisolated static func merged(_ copies: [VaultFind]) -> VaultFind? {
        let ordered = copies.sorted { a, b in
            if supersedes(a.facts, b.facts) { return true }
            if supersedes(b.facts, a.facts) { return false }
            return a.sourcePath < b.sourcePath
        }
        guard var best = ordered.first else { return nil }
        for copy in ordered.dropFirst() {
            for source in copy.facts.sources { best.facts.add(source) }
            best.facts.holder = fuller(best.facts.holder, copy.facts.holder)
            best.facts.born = best.facts.born ?? copy.facts.born
            best.facts.form = best.facts.form ?? copy.facts.form
            best.facts.validUntil = best.facts.validUntil ?? copy.facts.validUntil
            best.facts.pending = best.facts.pending && copy.facts.pending
        }
        return best
    }

    /// The name to keep of two read for one number: the one present, and of two that start
    /// alike, the longer, so "Abhishek" read off a license front gives way to "Abhishek Girish"
    /// from its barcode.
    nonisolated static func fuller(_ kept: String?, _ other: String?) -> String? {
        guard let kept else { return other }
        guard let other else { return kept }
        let (k, o) = (kept.split(separator: " "), other.split(separator: " "))
        return o.count > k.count && o.first?.lowercased() == k.first?.lowercased() ? other : kept
    }

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
                         facts: merged.facts, pin: find.pin, assignment: find.assignment)
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
        for key in Array(mentions.keys) {
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
        guard readingChanged, let store else { return }
        let state = VaultReadingState(generation: readGeneration, finds: finds, read: readIndex,
                                      mentions: mentions, copies: copies, choices: choices)
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
