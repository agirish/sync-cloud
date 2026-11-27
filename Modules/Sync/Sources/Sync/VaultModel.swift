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
    /// ``pages(in:)``, and whether every page meant to be read was: a page left out (one Vision
    /// could not recognise) keeps the file from being marked read, so the next read tries it
    /// again (VT54). A reader that cannot tell says every page was.
    func reading(_ file: URL) async -> (pages: [[String]], complete: Bool)
    /// ``reading(_:)``, and how it went, counts only (VT25): passed over as locked or unopenable,
    /// pages not recognised, pages read from their picture. A reader that cannot tell notes nothing.
    /// `origins` says which page of the file each page is, and which reading of a page read both
    /// ways (``VaultPageSource/filePages(_:)``); nil when each is the page of its place (VT88).
    func noted(_ file: URL) async -> (pages: [[String]], complete: Bool, notes: VaultReadNotes, origins: [VaultPageOrigin]?)
    /// What a file holds, as a key two files share only when their bytes are the same (its size
    /// and SHA-256): a file whose bytes were read already in this read is not read again, its
    /// pages reused (VT107). Nil when the reader cannot tell, which reads every file.
    func contentKey(of file: URL) async -> String?
    /// A file's size in bytes, which ``contentKey(of:)`` is asked for only when another file to
    /// be read shares it. Nil when unknown.
    func size(of file: URL) -> Int?
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

    public func reading(_ file: URL) async -> (pages: [[String]], complete: Bool) { (await pages(in: file), true) }

    public func noted(_ file: URL) async -> (pages: [[String]], complete: Bool, notes: VaultReadNotes, origins: [VaultPageOrigin]?) {
        let read = await reading(file)
        return (read.pages, read.complete, VaultReadNotes(), nil)
    }

    public func contentKey(of file: URL) async -> String? { nil }

    public func size(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
    }

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
        /// The name on its document as Edit's Name field holds it; nil, empty, or the name as
        /// read go by what was read. ``VaultModel/prepared(_:)`` fills it with the correction in force.
        public var holderName: String?
        /// The correction is every ID's read with the same name, and later reads', not this one's
        /// alone. ``VaultModel/prepared(_:)`` starts it as it stands; only saving with it changes
        /// what the other IDs show.
        public var correctEverywhere = false
        /// The copy of its document a find being confirmed was chosen to be read from: never the
        /// editor's, which offers no such choice.
        var chosenSource: String?
        /// The name a find being confirmed was read with, corrected or not.
        var readHolder: String?

        /// What the user chose about it, in the editor or, for ``chosenSource``, before.
        var choices: VaultChoices {
            VaultChoices(pin: pin, assignment: assignment, geo: geo, card: card, source: chosenSource)
        }

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

        public init(_ entry: VaultEntry) {
            self.init(title: entry.title, value: entry.value, personID: entry.personID,
                      note: entry.note, category: entry.category, facts: entry.facts, pin: entry.pin)
            isHousehold = entry.assignment == .household
            geo = entry.geo
            card = entry.card
            holderName = entry.holderName
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
    /// The lock. A change the panel cannot show (the idle timer restarting while it is far from
    /// running out, a shown number's thirty seconds starting again) redraws nothing (VT9).
    public private(set) var lock: VaultLock {
        get { sessionState.lock }
        set { session.lock = newValue }
    }
    /// The lock, its epoch and the panel (``VaultSession``). A change the panel draws redraws it.
    private var session: VaultSession {
        get { sessionState }
        set {
            if clockface(newValue.lock, at: now) != clockface(sessionState.lock, at: now) { objectWillChange.send() }
            let ended = newValue.epoch != sessionState.epoch
            sessionState = newValue
            // Access ended (a close, Lock Now, the Mac locking or asleep, a restore, new settings):
            // a number copied from the Vault leaves the clipboard with it (the final review).
            if ended { clearCopied() }
        }
    }
    private var sessionState: VaultSession
    /// The time the panel last drew at. Published so the countdown and a number's thirty seconds
    /// redraw; ``tick()`` moves it only when something drawn from it changes (``Clockface``), so
    /// the panel is not redrawn every second (VT9).
    @Published public private(set) var now: Date

    /// Everything the panel draws from the time and the lock: whether the Vault is open or shows
    /// only its lock, the last ten seconds' countdown, the number shown under "every number", the
    /// day (a document's days left, Expired), and how long ago the last Refresh and Discover were,
    /// in the steps their wordings change on (``VaultPanel/ago``): half minutes in the first hour
    /// ("just now", then minutes), half hours to a day (hours, rounded), then days.
    struct Clockface: Equatable {
        var open: Bool
        var hidesEverything: Bool
        var countdown: Int?
        var shown: Set<UUID>
        var settings: VaultLockSettings
        var day: Int
        var refreshed: Int?
        var discovered: Int?
    }

    /// Which step of "how long ago" `seconds` falls in: it changes at least wherever the panel's
    /// wording does (``VaultPanel/ago``).
    public static func agoStep(_ seconds: TimeInterval) -> Int {
        if seconds < 3600 { return Int(seconds / 30) }
        if seconds < 86_400 { return 1_000_000 + Int(seconds / 1800) }
        return 2_000_000 + Int(seconds / 86_400)
    }

    func clockface(_ lock: VaultLock, at time: Date) -> Clockface {
        func step(_ date: Date?) -> Int? { date.map { Self.agoStep(max(0, time.timeIntervalSince($0))) } }
        return Clockface(open: lock.isOpen(at: time), hidesEverything: lock.hidesEverything(at: time),
                         countdown: lock.secondsLeft(at: time).flatMap { $0 <= Self.lockWarning ? $0 : nil },
                         shown: lock.shownIDs(at: time), settings: lock.settings, day: Self.dayStamp(time),
                         refreshed: step(lastRefreshed), discovered: step(lastDiscovered))
    }
    /// A proof prompt is on screen. The panel dims its own buttons rather than queue a second one.
    @Published public private(set) var isAsking = false
    /// The last thing that went wrong, in words: a refused proof, a failed save.
    /// While the Vault is open read-only, clearing it brings back why (a close, a proof and a save
    /// each clear it), so the panel never stops saying so (the second review).
    @Published public var notice: String? {
        didSet { if notice == nil, contents == .loaded, let readOnly { notice = Self.message(for: readOnly) } }
    }
    @Published public var query = "" { didSet { keepSelectionVisible() } }
    @Published public var personFilter: PersonFilter = .everyone {
        didSet { savePersonFilter(); keepSelectionVisible() }
    }
    /// Which countries the list shows. Kept between opens, as the person is.
    @Published public var geoFilter: VaultGeoFilter = .all {
        didSet { defaults.set(geoFilter.rawValue, forKey: Self.geoFilterKey); keepSelectionVisible() }
    }
    /// Which group of kinds the list shows; nil for every kind.
    /// Show Group Headings: Cards and List draw each group's name over its cards. Kept in
    /// UserDefaults; on until turned off. People always shows its groups.
    @Published public var showsGroupHeadings: Bool = true {
        didSet { if showsGroupHeadings != oldValue { defaults.set(showsGroupHeadings, forKey: Self.groupHeadingsKey) } }
    }
    static let groupHeadingsKey = "vaultGroupHeadings"

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
        /// What is being read: the folders, or only the documents IDs came from. Said every
        /// time the progress is made, with no default: left out after each document, it turned
        /// a running refresh into Discover More, and the panel's line with its Stop went.
        public var scope: VaultReadScope

        public init(done: Int, total: Int, scope: VaultReadScope) {
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
    /// not been read with them: the panel offers Discover More, once. Or Refresh found a copy an
    /// ID was read from changed (``copiesChanged``).
    @Published public private(set) var needsDiscover = false
    /// Discover More is offered for copies that changed, not for a change of rules: the banner
    /// says so.
    @Published public private(set) var copiesChanged = false

    /// The read index's mark for a copy Refresh found changed and left for Discover More.
    nonisolated static let noticed = "noticed "

    /// Whether a file's mark in the read index says it was read, or seen, as it now is: read
    /// whole, read with a page left out (VT54), or noticed changed by Refresh (VT107).
    nonisolated static func readAsItIs(_ mark: String?, stamp: String) -> Bool {
        mark == stamp || mark == "partial " + stamp || mark == noticed + stamp
    }
    @Published public private(set) var lastRefreshed: Date?
    @Published public private(set) var lastDiscovered: Date?
    /// Documents an older build read IDs from, for the refresh that follows a change of rules.
    private var staleSources: Set<String> = []
    /// What each copy in a packet gave when last read whole (VT107 step 3): sealed with what was
    /// read, kept across a change of rules.
    private var copyNumbers: [String: VaultCopyNumbers] = [:]

    /// Numbers read from documents and not yet confirmed. Sealed in Read Documents' own file
    /// between reads, and let go from memory with the entries when the Vault locks.
    @Published public private(set) var finds: [VaultFind] = [] { didSet { rowsRevision &+= 1 } }
    /// Each file read, by path, against ``VaultDocumentReading/stamp(of:)`` when it was read.
    private var readIndex: [String: String] = [:]
    /// Set while Read Documents runs.
    @Published public private(set) var reading: ReadingProgress?
    /// What an older build read was let go with its rules, and no full read has run since: the
    /// panel says so above the cards, with Read Again, until one does.
    @Published public private(set) var needsReadAgain = false
    /// Records in the sealed file a later build wrote, which this one keeps as they are and does
    /// not draw (VT30).
    @Published public private(set) var newerRecords = 0
    @Published public private(set) var lastReading: ReadingSummary?
    /// Numbers set aside while the Keychain would not give a fingerprint, as plain hashes, kept
    /// for this run only. Normally they go to ``VaultSetAside`` and outlive the app.
    private var setAsideThisRun = Set<String>()

    private let store: VaultStore?
    private let authenticator: VaultAuthenticating
    private let defaults: UserDefaults
    let clock: @Sendable () -> Date
    /// Puts a number on the pasteboard. The app's version marks it concealed and clears it later.
    private let copyToPasteboard: @MainActor (String) -> Void
    /// Takes a number copied from the Vault off the pasteboard, unless something else was copied
    /// since: at every end of access, which moves the session's epoch.
    private let clearCopied: @MainActor () -> Void
    /// The weekly backup (``backUpIfDue()``): the app's, of the sealed file in Application Support.
    /// None in a test, so a panel drawn there never writes into the owner's backup folder (VT74).
    private let backup: VaultBackup?

    public init(store: VaultStore?, authenticator: VaultAuthenticating,
                defaults: UserDefaults = .standard,
                clock: @escaping @Sendable () -> Date = { Date() },
                activity: VaultActivityStore? = nil,
                backup: VaultBackup? = nil,
                copyToPasteboard: @escaping @MainActor (String) -> Void,
                clearCopied: @escaping @MainActor () -> Void = {}) {
        self.activity = activity
        self.backup = backup
        self.store = store
        self.authenticator = authenticator
        self.defaults = defaults
        self.clock = clock
        self.copyToPasteboard = copyToPasteboard
        self.clearCopied = clearCopied
        sessionState = VaultSession(lock: VaultLock(settings: VaultLockSettings(defaults: defaults)))
        now = clock()
        // Read, not chosen: set past the observer, which would save it.
        _layout = Published(initialValue: Self.storedLayout(in: defaults))
        // A restore from a backup wrote the Vault's file behind this model: what it holds is
        // no longer the Vault, and must not be written back over it.
        let path = store?.fileURL.path
        restoreWatch = NotificationCenter.default.addObserver(forName: VaultBackup.didRestore, object: nil, queue: .main) { [weak self] note in
            guard let path, note.userInfo?[VaultBackup.restoredPathKey] as? String == path else { return }
            MainActor.assumeIsolated { self?.vaultWasRestored() }
        }
        // On the posting thread, never queued: a queue would make every background write wait for
        // main ("A main-queue defaults observer parks every scratch-suite wipe on the main thread").
        defaultsWatch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.followStoredLayout() }
            } else {
                Task { @MainActor in self?.followStoredLayout() }
            }
        }
        loadFolded()
        loadFilters()
    }

    // MARK: What the list shows

    public var selectedEntry: VaultEntry? { entry(id: selection) }

    public var selectedFind: VaultFind? { find(id: selection) }

    /// The saved ID with this id, if there is one.
    public func entry(id: UUID?) -> VaultEntry? { entries.first { $0.id == id } }

    /// The find with this id, if there is one.
    public func find(id: UUID?) -> VaultFind? { finds.first { $0.id == id } }

    // MARK: Rows, tabs and cards

    /// The household's people, from Settings ▸ Organize: who a read number belongs to, and the
    /// person filter's names. Set by the window's `VaultHost` from its first frame, and by Add to
    /// People ahead of the store; the panel draws from it, so a change is published.
    public var people: [Person] = [] {
        willSet { if newValue != people { objectWillChange.send() } }
        didSet {
            rowsRevision &+= 1
            resplitWaiting()
            keepSelectionVisible()
        }
    }

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
        /// The name its document was read with, when that was corrected (Edit's Name): never
        /// lost, so the detail says what was read.
        public var readHolder: String?
        /// The name as its document was read, corrected or not.
        public var holderAsRead: String? { readHolder ?? facts?.holder }
        /// A name chosen for this ID alone, which no correction made everywhere changes.
        public var ownHolderName: String?
        /// The document the Vault itself would read it from: where it is filed, for its Kind's
        /// folder lesson and its person's folder, whichever copy it is read from.
        public var appSource: String?
        /// The copy the user chose to read it from, while it is in force (Read from This Copy).
        public var chosenSource: String?
        /// The other copies of the document it is read from, any of which it could be read from
        /// instead without its dates changing: where Read from This Copy is offered.
        public var sourceChoices: [String] = []

        /// Every document carrying the number, the one it was read from first.
        public var documents: [VaultSource] { facts?.orderedSources ?? [] }
        public var isTypedIn: Bool { facts == nil }
    }

    /// How many merges the last rows rebuild made, for a test that each is made once.
    private(set) var rowsMerges = 0

    /// The person in the household a printed name answers to, when exactly one does.
    public nonisolated static func person(named holder: String?, among people: [Person]) -> String? {
        guard !people.isEmpty else { return nil }
        return person(named: holder, in: PersonRegistry(people: people))
    }

    /// ``person(named:among:)`` with the household's registry made once, as the rows are built:
    /// making one tokenises every person's names (VT66).
    nonisolated static func person(named holder: String?, in registry: PersonRegistry?) -> String? {
        guard let holder, let registry else { return nil }
        let named = registry.detect(in: holder)
        return named.count == 1 ? named.first : nil
    }

    /// The person whose folder a document is filed in: the deepest folder below the read folder
    /// that names one of the household's people and no one else (`Health/Medical/Sigrid`, never
    /// `Visitor Insurance/2021 - Lindqvist, Greta and Mattias`). Never a folder above the read
    /// folder: the home folder is named for whoever's Mac it is.
    public nonisolated static func person(inPath path: String, under readFolders: [String], among people: [Person]) -> String? {
        guard !people.isEmpty else { return nil }
        return person(inPath: path, under: readFolders, in: PersonRegistry(people: people))
    }

    nonisolated static func person(inPath path: String, under readFolders: [String], in registry: PersonRegistry?) -> String? {
        guard let registry,
              let root = readFolders.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return nil }
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
        let key = rowsKey
        if let cached = rowsCache, cached.key == key { return cached.rows }
        let rows = computedRows
        rowsCache = (key, rows)
        return rows
    }

    /// What `rows` was last worked out from: the numbers, documents and people (counted by every
    /// change to them), the day, since a document runs out at midnight, and the folders read. The
    /// panel asks for the rows many times a draw; they are worked out again only when one of these
    /// moved.
    private struct RowsKey: Equatable {
        var revision: Int
        var day: Int
        var folders: [String]
    }
    /// Internal to read, so tests can see which changes rebuild the rows (VT71, VT101).
    private(set) var rowsRevision = 0
    private var rowsCache: (key: RowsKey, rows: [Row])?
    private var rowsKey: RowsKey {
        RowsKey(revision: rowsRevision, day: Self.dayStamp(now), folders: readFolders)
    }

    /// What the panel's lists are worked out from beyond the rows: the search, the tab, the
    /// filters and the kinds. The panel asks for them many times a draw; they are worked out again
    /// only when one of these moved (VT9).
    private struct ViewKey: Equatable {
        var rows: RowsKey
        var filter: VaultRowFilter
    }
    private var viewKey: ViewKey { ViewKey(rows: rowsKey, filter: filter) }
    /// The search, the tab and the choices as they stand now.
    var filter: VaultRowFilter {
        VaultRowFilter(query: query, tab: tab, person: personFilter, geo: geoFilter, kind: kindFilter,
                       kinds: kinds, groups: groups)
    }
    private var visibleCache: (key: ViewKey, rows: [Row])?
    private var cardsCache: (key: ViewKey, cards: [(card: VaultCardID, rows: [Row])])?
    private var tabCountsCache: (key: ViewKey, counts: [VaultStanding.Tab: Int])?
    private var peopleCache: (key: ViewKey, people: [Person], roles: [String: VaultNameRoles], contacts: [String: VaultContacts],
                              sections: [VaultPersonSection])?
    private var sourcesCache: (revision: Int, stale: Set<String>, own: Set<String>, others: Set<String>)?
    /// ``peopleSections``, worked out again only when what they are made of moved.
    func peopleSections(computing compute: @autoclosure () -> [VaultPersonSection]) -> [VaultPersonSection] {
        let key = viewKey
        // Typed contacts are part of a section: a phone added shows at once.
        if let cached = peopleCache, cached.key == key, cached.people == people, cached.roles == nameRoles,
           cached.contacts == contacts {
            return cached.sections
        }
        let sections = compute()
        peopleCache = (key, people, nameRoles, contacts, sections)
        viewComputations += 1
        return sections
    }
    /// The rows worked out afresh, past the cache: what a test compares the cached ones with (VT71).
    var rowsWorkedOutAfresh: [Row] { computedRows }

    /// How often the visible rows were worked out: a test's measure of VT9.
    private(set) var visibleComputations = 0
    /// How often any of the panel's lists was worked out (visible rows, cards, tab counts,
    /// people, refresh sources): a test's measure of VT9.
    private(set) var viewComputations = 0
    /// Whether any list the panel draws is held: none is once the numbers are let go.
    var holdsViewCaches: Bool {
        rowsCache != nil || visibleCache != nil || cardsCache != nil || tabCountsCache != nil
            || peopleCache != nil || sourcesCache != nil
    }
    /// Lets a Vault left open by its setting go once its idle limit passes, though no tick runs
    /// with the panel closed.
    private var releaseWhenIdle: Task<Void, Never>?
    /// Read Documents, owned here so it outlives the panel.
    private(set) var readingTask: Task<Void, Never>?
    private var spansCache: (key: RowsKey, spans: Bool)?

    private static func dayStamp(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// What the rows are worked out from, as they stand now.
    private var rowSource: VaultRowSource {
        VaultRowSource(entries: entries, finds: finds, copies: copies, mentions: mentions,
                       missingDocuments: missingDocuments, holders: holders, lessons: lessons, kinds: kinds,
                       folders: readFolders, now: now)
    }

    /// Whose a number's papers are, as the names and people stand now.
    private var holders: VaultHolders { VaultHolders(names: names, people: people) }

    private var computedRows: [Row] {
        let built = rowSource.rows()
        rowsMerges = built.merges
        return built.rows
    }

    /// Belongs To: whose a number is, a person or the household; nil goes by what was read again.
    /// Later reads keep the choice.
    public func assign(_ id: UUID, to assignment: VaultAssignment?) {
        let before = visibleIDs
        choose(.assignment(assignment), for: id)
        keepSelection(near: before)
    }

    /// The rows the tab, the person filter and the search leave. A search looks in every tab:
    /// a number asked about on a call may be an older one.
    public var visibleRows: [Row] {
        let key = viewKey
        if let cached = visibleCache, cached.key == key { return cached.rows }
        let visible = computedVisibleRows
        visibleCache = (key, visible)
        visibleComputations += 1
        viewComputations += 1
        return visible
    }

    private var computedVisibleRows: [Row] { filter.visible(rows) }

    /// Whether `row` is one the person, country and kind choices leave (``VaultRowFilter/passes(_:person:geo:kind:)``).
    public func passesFilters(_ row: Row, person: PersonFilter? = nil, geo: VaultGeoFilter? = nil,
                              kind: VaultGroups.ID?? = nil) -> Bool {
        filter.passes(row, person: person, geo: geo, kind: kind)
    }

    /// How many current rows each choice would show, the others as they stand: the counts beside
    /// each choice while it is being made.
    public func count(person: PersonFilter? = nil, geo: VaultGeoFilter? = nil, kind: VaultGroups.ID?? = nil) -> Int {
        filter.count(rows, person: person, geo: geo, kind: kind)
    }

    /// The same kind in another country, for "2 more in India" at the foot of its card: only
    /// while one country is chosen, and only what the person and kind choices would show there.
    public func elsewhere(_ card: VaultCardID) -> (filter: VaultGeoFilter, count: Int)? {
        // Asked for by every card as it draws: the rows only when one country is chosen.
        let filter = self.filter
        guard !filter.searching, filter.geo != .all else { return nil }
        return filter.elsewhere(card, in: rows)
    }

    /// Whether the numbers span more than one country: the Where choice is offered only then.
    public var spansCountries: Bool {
        let key = RowsKey(revision: rowsRevision, day: Self.dayStamp(now), folders: readFolders)
        if let cached = spansCache, cached.key == key { return cached.spans }
        let spans = Set(rows.map(\.geo)).subtracting([.anywhere]).count > 1
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

    /// Kinds that have nothing in this country but some in another: one line under the cards,
    /// since no card of theirs is drawn to carry "N more in …".
    public var elsewhereKinds: (filter: VaultGeoFilter, count: Int)? {
        let filter = self.filter
        guard !filter.searching, filter.geo != .all else { return nil }
        return filter.elsewhereKinds(rows, visible: visibleRows)
    }

    /// Used In: where a number is used; nil goes by its document again. Later reads keep it.
    public func setGeo(_ id: UUID, to geo: VaultGeo?) {
        let before = visibleIDs
        choose(.geo(geo), for: id)
        keepSelection(near: before)
    }

    /// Customize Groups: the groups as the user left them, kept for the next open.
    public func setGroups(_ new: VaultGroups) {
        groups = new
        new.save(to: defaults)
        // Contact holds no kind of ID, yet is a group to choose (``VaultContactCard``).
        if let chosen = kindFilter, chosen != VaultGroups.contact,
           !kinds.order.contains(where: { kinds.group(of: $0, in: new) == chosen }) {
            kindFilter = nil
        }
        rowsRevision &+= 1
        keepSelectionVisible()
    }

    /// Customize Groups, or a card's Color menu: the colors as the user left them, kept for the
    /// next open. A color of a kind no longer kept is let go.
    public func setColors(_ new: VaultColors) {
        var new = new
        // Only against kinds this model knows: a document's own kinds are unknown until it opens,
        // and pruning against none would drop every custom kind's color from the preferences.
        // Read-only, the kinds may be a newer build's, read leniently: nothing is pruned.
        if !(documentMode && contents != .loaded), readOnly == nil { new.prune(keeping: kinds) }
        colors = new
        new.save(to: defaults)
    }

    /// One card's own color; nil has it follow its group again.
    public func setColor(_ color: VaultCardColor?, of card: VaultCardID) {
        var changed = colors
        changed.cards[card.key] = color
        setColors(changed)
    }

    /// A whole group's color, set from one of its cards: every card listed under the group that
    /// has no color of its own follows it.
    public func setColor(_ color: VaultCardColor, ofGroup group: VaultGroups.ID) {
        var changed = colors
        changed.groups[group] = color
        setColors(changed)
    }

    /// What the Color choice for `card` shows: the card's own color and its group's, apart.
    public func colorChoice(for card: VaultCardID) -> VaultColorChoice {
        let group = kinds.group(of: card, in: groups)
        let sharing = group.map { id in kinds.order.filter { $0 != card && kinds.group(of: $0, in: groups) == id } } ?? []
        return VaultColorChoice(card: card, title: kinds.title(of: card), own: colors.own(card), group: group,
                                groupName: group.map(groups.name), groupColor: group.map(colors.color(ofGroup:)),
                                others: sharing.filter { colors.own($0) == nil }.map(kinds.title(of:)), isOn: colors.isOn)
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
        showsGroupHeadings = defaults.object(forKey: Self.groupHeadingsKey) as? Bool ?? true
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
        let key = viewKey
        if let cached = cardsCache, cached.key == key { return cached.cards }
        let cards = computedCards
        cardsCache = (key, cards)
        viewComputations += 1
        return cards
    }

    private var computedCards: [(card: VaultCardID, rows: [Row])] { filter.cards(visibleRows) }

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
        let key = viewKey
        if let cached = tabCountsCache, cached.key == key, let count = cached.counts[tab] { return count }
        let count = filter.count(rows, in: tab)
        viewComputations += 1
        var counts = tabCountsCache?.key == key ? tabCountsCache!.counts : [:]
        counts[tab] = count
        tabCountsCache = (key, counts)
        return count
    }

    public var selectedRow: Row? { rows.first { $0.id == selection } }

    /// The IDs the arrow keys walk, in the order they are drawn (``walkStops`` adds the Contact rows).
    public var walkOrder: [UUID] { visibleIDs }


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
    /// Cards by kind, one list, or sections by person, as last chosen: kept for the next open
    /// (VT76). It decides which rows are on screen and in what order the arrow keys walk them.
    @Published public var layout: VaultLayout = .cards {
        didSet {
            if !followingStoredLayout { defaults.set(layout.rawValue, forKey: Self.layoutKey) }
            keepSelectionVisible()
        }
    }
    /// The layout is being taken from what is saved, which it then is not saved over.
    private var followingStoredLayout = false

    /// The saved layout changed behind the model (Settings ▸ Advanced ▸ Reset All, say): it is
    /// followed, as the panel's own storage once followed it, though the model outlives the panel.
    private func followStoredLayout() {
        let stored = Self.storedLayout(in: defaults)
        guard stored != layout else { return }
        followingStoredLayout = true
        defer { followingStoredLayout = false }
        layout = stored
    }
    private var defaultsWatch: NSObjectProtocol?
    static let layoutKey = "vaultLayout"
    /// The choice from before People was a layout: Cards or List.
    static let showedListKey = "vaultShowsList"

    /// The layout as last chosen; Cards when none was.
    static func storedLayout(in defaults: UserDefaults) -> VaultLayout {
        defaults.string(forKey: layoutKey).flatMap(VaultLayout.init(rawValue:))
            ?? (defaults.bool(forKey: showedListKey) ? .list : .cards)
    }

    /// Copies a person's section of the People view as text (``VaultPersonText``). With
    /// `numbers` every ID is in full and the birth date is given, so a proof is asked first when
    /// one is owed; without, only what the rows already draw.
    @discardableResult
    public func copyPerson(_ owner: VaultPersonSection.Owner, numbers: Bool) async -> Bool {
        guard let before = peopleSections.first(where: { $0.id == owner }) else { return false }
        if numbers, !lock.isOpen(at: clock()) {
            // A proof for the person's IDs, as an editor's for several: under "For every ID"
            // it shows those, never unlocks the whole Vault, nor lists "Unlocked" (the second review).
            let ids = lock.settings.ask == .everyNumber ? Set(before.rows.map(\.id)) : []
            guard await prove("copy \(before.title)’s IDs", forEach: ids) else { return false }
        }
        // Looked up again after the proof: the panel may have closed and let the numbers go.
        guard contents == .loaded, let section = peopleSections.first(where: { $0.id == owner }) else { return false }
        copyToPasteboard(VaultPersonText.text(section, numbers: numbers))
        used()
        // Every ID in full is a copy worth a line (VT23); without numbers it holds only endings.
        if numbers { record(.copied, "every ID in full", whose: Self.listedAs(section)) }
        return true
    }

    /// Copies a person's birth date as MM/DD/YYYY, behind the proof of one of their IDs: it is as
    /// private as a number, and cleared from the clipboard the same way.
    @discardableResult
    public func copyBirth(_ date: Date, in section: VaultPersonSection) async -> Bool {
        guard let id = section.rows.first?.id, row(id) != nil else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("copy \(Self.listedAs(section))’s date of birth", for: id) else { return false }
        }
        guard lock.canShow(id, at: clock()) else { return false }
        copyToPasteboard(VaultReading.formDate(date))
        used()
        // Named as what it is, the person's, not after the ID whose proof it rides on (VT23).
        record(.copied, "date of birth", whose: Self.listedAs(section))
        return true
    }

    /// A section as Activity and the Touch ID prompt name it: someone in People by their name, the
    /// household as itself, and a name nobody in People answers to never by its spelling.
    nonisolated static func listedAs(_ section: VaultPersonSection) -> String {
        if case .unnamed = section.id { return "someone not in People" }
        return section.title
    }

    private func loadFolded() {
        folded = Set((defaults.stringArray(forKey: Self.foldedKey) ?? [])
            .filter { VaultCardID(key: $0) != nil || Self.contactFoldKeys.contains($0) })
    }

    public func isFolded(_ card: VaultCardID) -> Bool { folded.contains(card.key) }

    /// A Contact card's fold, kept with the cards': "contact:addresses", and the like.
    nonisolated static func foldKey(_ kind: VaultContactCard.Kind) -> String { "contact:" + kind.rawValue }
    nonisolated static let contactFoldKeys = Set(VaultContactCard.Kind.allCases.map { "contact:" + $0.rawValue })

    public func isFolded(_ kind: VaultContactCard.Kind) -> Bool { folded.contains(Self.foldKey(kind)) }

    /// Folds or opens a Contact card; with `all`, every card, as ⌥-click does.
    public func toggleFold(_ kind: VaultContactCard.Kind, all: Bool = false) {
        let key = Self.foldKey(kind)
        let fold = !folded.contains(key)
        if all {
            folded = fold ? Set(kinds.order.map(\.key)).union(Self.contactFoldKeys) : []
        } else if fold {
            folded.insert(key)
        } else {
            folded.remove(key)
        }
        saveFolded()
    }

    /// Folds or opens one card; with `all`, every card, as ⌥-click does.
    public func toggleFold(_ card: VaultCardID, all: Bool = false) {
        let fold = !folded.contains(card.key)
        if all {
            folded = fold ? Set(kinds.order.map(\.key)).union(Self.contactFoldKeys) : []
        } else if fold {
            folded.insert(card.key)
        } else {
            folded.remove(card.key)
        }
        saveFolded()
    }

    /// Whether every card on screen is folded: Collapse All then reads Expand All.
    public var allFolded: Bool {
        let shown = cards.map(\.card.key) + contactCards.map { Self.foldKey($0.kind) }
        return !shown.isEmpty && shown.allSatisfy(folded.contains)
    }

    /// Collapse All, or Expand All once everything on screen is folded.
    public func toggleFoldAll() {
        folded = allFolded ? [] : Set(kinds.order.map(\.key)).union(Self.contactFoldKeys)
        saveFolded()
    }

    private func saveFolded() {
        defaults.set(folded.sorted(), forKey: Self.foldedKey)
        keepSelectionVisible()
    }

    /// Folds exactly `keys`, and keeps them.
    func setFolded(_ keys: Set<String>) {
        folded = keys
        saveFolded()
    }

    // MARK: Kinds

    /// The household's own kinds (``VaultKinds``), kept in UserDefaults beside the groups.
    @Published public private(set) var kinds = VaultKinds()
    /// What choosing a kind for a read account taught, by its folder (``VaultKinds/lessonFolder(of:)``):
    /// numbers read from that folder with no kind of their own go on that card, now and on later
    /// reads. Sealed with what was read.
    private var lessons: [String: VaultCardID] = [:] { didSet { rowsRevision &+= 1 } }

    /// Where a number's folder lesson is looked for: the folder of the document the Vault reads it
    /// from, then those of its other documents of that kind, so a lesson taught where an
    /// account's papers are filed still holds when its newest statement is filed elsewhere.
    nonisolated static func lessonPaths(_ facts: VaultReadFacts?, app: String?) -> [String] {
        guard let facts, let first = app ?? facts.primary?.path else { return [] }
        let rank = facts.sources.first { $0.path == first }?.rank
        return [first] + facts.orderedSources.filter { $0.path != first && $0.rank == rank }.map(\.path)
    }

    /// Kind: moves a number to another card. A number read from an account's folder teaches that
    /// folder too: its other numbers, and those later reads find there, follow unless they have a
    /// kind of their own (``forgetLesson(_:)`` unteaches it).
    ///
    /// Nil, or the kind it was read as, is As Read: this number alone goes back, and stays there
    /// whatever its folder taught or later teaches. The folder keeps its lesson.
    public func setKind(_ id: UUID, to card: VaultCardID?) {
        if refusedReadOnly() { return }
        guard let row = rows.first(where: { $0.id == id }), VaultKinds.canChange(from: row.readAs) else { return }
        if let card, !kinds.canHold(card) { return }
        let asRead = card == nil || card == .builtIn(row.readAs)
        let path = row.appSource ?? row.facts?.primary?.path
        let folder = path.flatMap { path in
            VaultKinds.teaches(path, under: readFolders) ? VaultKinds.lessonFolder(of: path) : nil
        }
        // Kept as a choice of its own even As Read, so no lesson moves it: not its folder's now,
        // nor another's should a later read find it first elsewhere.
        let chosen: VaultCardID = card ?? .builtIn(row.readAs)
        // The lesson is held before the choice, so a saved ID's one write carries both (the final
        // review); a waiting ID's is sealed below, with the lesson. Let go if the choice is refused.
        let lessonBefore = folder.map { lessons[$0] }
        if let folder, !asRead { lessons[folder] = chosen }
        // Let go if refused, before a refusal's merge with another copy seals what is held (the
        // second review), and only while it is still this change's.
        let letGo = { [weak self] in
            guard let self, let folder, let lessonBefore, self.lessons[folder] == chosen, !asRead else { return }
            self.lessons[folder] = lessonBefore
        }
        refusedWriteLetsGo = letGo
        defer { refusedWriteLetsGo = nil }
        guard choose(.card(chosen), for: id, sealingWaiting: false) else {
            letGo()
            return
        }
        readingChanged = true
        saveReading()
        rowsRevision &+= 1
        showEvenIfFiltered(id)
    }

    // MARK: Read from

    /// Read from This Copy: reads a number from another copy of the document it is read from
    /// (``Row/sourceChoices``), whose name and details are then shown and which opens; nil, or
    /// the Vault's own pick, is Let the Vault Choose. Its dates, tab and card stay as they are.
    /// Later reads keep the choice while the copy is still one of the number's; a renewal under
    /// the same number, a document with other dates, speaks for it in its place.
    public func readFrom(_ id: UUID, copy path: String?) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        let chosen = path == row.appSource ? nil : path
        if let chosen, !row.sourceChoices.contains(chosen) { return }
        guard chosen != row.chosenSource, choose(.source(chosen), for: id) else { return }
        rowsRevision &+= 1
        showEvenIfFiltered(id)
    }

    // MARK: Names

    /// Names corrected everywhere (``Draft/correctEverywhere``): the name as read, by
    /// ``VaultReading/spellingKey(_:)``, and as it should be. Sealed with what was read.
    /// Published, so People's Misread and its undo show at once (VT99).
    @Published private var names: [String: String] = [:] { didSet { rowsRevision &+= 1 } }

    /// The roles chosen for each person's spellings (``VaultNameRoles``), by person. Published,
    /// so a chosen role shows at once (VT99). Rows never read it, so it does not move
    /// ``rowsRevision`` (VT101): only ``peopleSections`` does.
    @Published var nameRoles: [String: VaultNameRoles] = [:]
    /// What the user typed for each person (``VaultContacts``), by person: kept in the reading
    /// file beside ``nameRoles``, and in a backup.
    @Published public internal(set) var contacts: [String: VaultContacts] = [:]

    /// Corrects the name read as `key` to `name` on every ID read with it, or with nil, lets it
    /// be as read again. The People view's Misread; Edit's Everywhere does the same.
    /// The name a spelling is corrected to everywhere, if it is.
    func correction(of key: String) -> String? { names[key] }

    func correctEverywhere(_ key: String, to name: String?) {
        if refusedReadOnly() { return }
        guard !key.isEmpty else { return }
        names[key] = name
        resplitWaiting()
    }

    /// A waiting ID as Add to Vault opens it: whose it is, when nobody chose, goes by the name as
    /// corrected, as its row does, not as printed (VT70, owner): a person the corrected name answers
    /// to is proposed, and saved, as one the printed name answered to always was. The rows' other
    /// answers (a folder's person, a birth date, the household for a nameless account) stay the
    /// Vault's guesses, worked out again after Confirm as before: saved as choices they would rank
    /// the ID otherwise (a household account grouped with others, the older one archived).
    public func confirmationDraft(_ find: VaultFind) -> Draft {
        var draft = Draft(find, people: people)
        if find.assignment == nil, draft.personID == nil,
           let corrected = rows.first(where: { $0.id == find.id })?.facts?.holder,
           let person = VaultModel.person(named: corrected, among: people) {
            draft.personID = person
        }
        return prepared(draft, for: find.id)
    }

    /// `draft` as Edit opens it: its Name holding the correction in force (this ID's own, else
    /// one made everywhere), and Everywhere ticked when that is where it comes from. Saving it
    /// unchanged changes nothing for any other ID. With `id`, the name compared is the one that
    /// ID's document is read with now, which can be another copy's than the saved reading's.
    public func prepared(_ draft: Draft, for id: UUID? = nil) -> Draft {
        var draft = draft
        guard let read = id.flatMap({ id in rows.first { $0.id == id }?.holderAsRead }) ?? draft.facts?.holder else { return draft }
        // The editor's Name compares against what it shows as read.
        draft.facts?.holder = read
        let everywhere = names[VaultReading.spellingKey(read)]
        draft.holderName = draft.holderName ?? everywhere
        draft.correctEverywhere = draft.holderName != nil && draft.holderName == everywhere
        return draft
    }

    /// What a saved ID keeps as its own name, from Edit: with Everywhere, nothing (it follows the
    /// correction, which this save makes, changes or, put back as read, unmakes); without, the
    /// name typed, or, typed back as read where a correction made everywhere would change it,
    /// the name as read, so it stays as read.
    ///
    /// A correction made everywhere comes back as `everywhere`, not made: the caller makes it with
    /// ``apply(_:)`` only once the save it belongs to is on disk, so a refused save renames no
    /// other ID (VT63).
    private func storedName(for draft: Draft, read: String?) -> (own: String?, everywhere: NameCorrection?) {
        let typed = draft.holderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = typed.flatMap { $0.isEmpty || $0 == read ? nil : $0 }
        guard let read else { return (wanted, nil) }
        let key = VaultReading.spellingKey(read)
        // While the reading file is held (VT24) a correction made everywhere could not be sealed:
        // the name is kept on this ID instead, so it is not lost at the next launch.
        if draft.correctEverywhere, !key.isEmpty, !readingHeld {
            return (nil, names[key] != wanted ? NameCorrection(key: key, name: wanted) : nil)
        }
        return (wanted ?? (names[key] != nil ? read : nil), nil)
    }

    /// A correction made everywhere, waiting on the save it belongs to.
    private struct NameCorrection {
        let key: String
        let name: String?
    }

    /// Makes and seals `correction`, after the save it came with.
    private func apply(_ correction: NameCorrection?) {
        guard let correction else { return }
        names[correction.key] = correction.name
        resplitWaiting()
        readingChanged = true
        saveReading()
    }

    /// How many IDs other than `id` a correction made everywhere for `name` would change: those
    /// read with it and given no name of their own.
    public func otherIDs(readAs name: String, excluding id: UUID) -> Int {
        let key = VaultReading.spellingKey(name)
        return rows.filter {
            $0.id != id && $0.ownHolderName == nil && $0.holderAsRead.map(VaultReading.spellingKey) == key
        }.count
    }

    /// Forgets what one folder taught: its numbers go back to their own kinds, but for those
    /// given one of their own.
    public func forgetLesson(_ folder: String) {
        if refusedReadOnly() { return }
        guard lessons[folder] != nil else { return }
        // The lessons are not published: the row leaves the card it learned at once.
        objectWillChange.send()
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
        // Refused while the document is not open or may not be written: no kind to answer with.
        return kinds.custom.contains { $0.id == kind.id } ? .custom(kind.id) : nil
    }

    /// The household's kinds as Customize Groups left them: renamed, moved to another group, or
    /// removed. A removed kind's numbers go back to what they were read or typed as.
    public func setKinds(_ new: VaultKinds) {
        // Kept in the document (VT6): only while it is loaded and may be written, so a change is
        // never held where the next load would drop it.
        // Read-only, nothing at all.
        if refusedReadOnly() || documentMode && contents != .loaded { return }
        let kept = Set(new.custom.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
        let gone = kinds.custom.filter { !kept.contains($0.id) }.map { VaultCardID.custom($0.id) }
        kinds = VaultKinds(custom: new.custom.compactMap { kind in
            var kind = kind
            kind.name = kind.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return kind.name.isEmpty ? nil : kind
        })
        if documentMode {
            readingChanged = true
            saveReading()
        } else {
            kinds.save(to: defaults)
        }
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
        if let chosen = kindFilter, chosen != VaultGroups.contact, !kinds.order.contains(where: { kinds.group(of: $0, in: groups) == chosen }) {
            kindFilter = nil
        }
        rowsRevision &+= 1
        keepSelectionVisible()
    }

    /// Move to Current or Move to Archive: a choice later reads keep. Nil lets the rules decide again.
    public func pin(_ id: UUID, _ pin: VaultPin?) {
        let before = visibleIDs
        choose(.pin(pin), for: id)
        keepSelection(near: before)
    }

    /// One choice about an ID, kept where the ID is (VT1): a saved one's written to the Vault, a
    /// waiting one's to the reading file, sealed unless the caller seals it later
    /// (`sealingWaiting` off: Kind, with its lesson). A waiting ID whose person is chosen is
    /// rebuilt from its copies, so that person's papers speak for it
    /// (``VaultHolders/split(_:owner:)``). False when no ID has `id`, or a saved one's write failed.
    @discardableResult
    private func choose(_ change: VaultChoiceChange, for id: UUID, sealingWaiting: Bool = true) -> Bool {
        if refusedReadOnly() { return false }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var changed = entries
            changed[index].apply(change)
            // The choice already in force: nothing written, nothing listed.
            guard changed[index] != entries[index] else { return true }
            guard write(changed) else { return false }
            recordChoice(change, for: id)
            return true
        }
        guard let index = finds.firstIndex(where: { $0.id == id }) else { return false }
        var find = finds[index]
        find.apply(change)
        guard find != finds[index] else { return true }
        finds[index].apply(change)
        if case .assignment = change {
            finds[index] = rebuilt(finds[index], VaultReading.normalized(finds[index].value))
        }
        if sealingWaiting {
            readingChanged = true
            saveReading()
        }
        recordChoice(change, for: id)
        return true
    }

    /// A name's Activity line (VT23): whose name, never the spelling.
    func recordNameChange(_ what: String, for person: String?) {
        record(.changed, what, whose: person.flatMap { id in people.first { $0.id == id }?.displayName })
    }

    /// A choice's Activity line (VT23), naming the ID as its row does and whose it is now.
    private func recordChoice(_ change: VaultChoiceChange, for id: UUID) {
        guard activity != nil, VaultActivitySettings.keeps(in: defaults), let row = rows.first(where: { $0.id == id }) else { return }
        let name = row.kindTitle
        var whose: String? = row.whose
        let what: String
        func place(_ geo: VaultGeo) -> String {
            switch geo {
            case .us: return "the United States"
            case .india: return "India"
            case .anywhere: return "every country"
            }
        }
        switch change {
        case .pin(let pin):
            what = pin == .older ? "Moved \(name) to Archive" : pin == .current ? "Moved \(name) to Current"
                : "Let the Vault choose Current or Archive for \(name)"
        case .assignment(let assignment):
            switch assignment {
            case .person(let person)?:
                what = "Gave \(name) to \(people.first { $0.id == person }?.displayName ?? "someone in People")"
                whose = nil
            case .household?:
                what = "Gave \(name) to the Household"
                whose = nil
            case nil: what = "Set whose \(name) is back to what its document says"
            }
        case .geo(let geo):
            if let geo { what = "Marked \(name) used in \(place(geo))" }
            else if row.isTypedIn { what = "Marked \(name) used in every country" }
            else { what = "Set where \(name) is used back to what its document says" }
        case .card(let card):
            // As Read is the kind it was read as, chosen again.
            if card == nil || card == .builtIn(row.readAs) {
                what = "Set \(name)’s kind back to \(row.isTypedIn ? "As Typed" : "As Read")"
            } else {
                what = "Set \(name)’s kind to \(card.map { kinds.title(of: $0) } ?? "")"
            }
        case .source(let path):
            what = path == nil ? "Let the Vault choose which copy \(name) is read from" : "Read \(name) from another copy"
        }
        record(.changed, what, whose: whose, hidesEnding: row.category.hidesEnding)
    }

    /// Documents that name a number without being its source, by the number.
    private var mentions: [String: [VaultSource]] = [:] { didSet { rowsRevision &+= 1 } }

    public func canShow(_ entry: VaultEntry) -> Bool { lock.canShow(entry.id, at: now) }

    public func canShow(_ find: VaultFind) -> Bool { lock.canShow(find.id, at: now) }

    /// Whether a row's number may be drawn in full now.
    public func canShow(row: Row) -> Bool { lock.canShow(row.id, at: now) }
    public var isOpen: Bool { lock.isOpen(at: now) }
    /// Seconds before an open Vault locks, by the clock: no view draws it whole, only its last
    /// ten seconds (``secondsBeforeLock``), so ``now`` is not moved for it every second.
    public var secondsLeft: Int? { lock.secondsLeft(at: clock()) }

    /// How near the lock is when the panel starts counting it down.
    public static let lockWarning = 10

    /// The seconds before an unlocked Vault locks, only in its last ``lockWarning`` seconds: a
    /// clock ticking all the time the Vault is in use is a distraction, and the lock restarts with
    /// every use anyway. Nil otherwise.
    public var secondsBeforeLock: Int? {
        guard let left = lock.secondsLeft(at: now), left <= Self.lockWarning else { return nil }
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
        // A Contact card's row chosen in place of an ID stays chosen: replaced by the first ID, the
        // pane would show that ID in full, and Return copy it (the second review).
        if selection == nil, showsAContact { return }
        let visible = visibleIDs
        if !visible.contains(where: { $0 == selection }), selection != visible.first { selection = visible.first }
    }

    /// Whether the panel's details show a Contact card's row (a phone, an address), chosen in
    /// place of an ID. Set by the panel.
    public var showsAContact = false

    /// After a change that takes the chosen row out of view (a move to another tab, a person
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
        // Touch ID not set up on this Mac: the Vault is not used at all. Nothing is loaded, read or
        // asked for; the panel says how to set it up (owner, 2026-11-24).
        guard touchIDReady() else { return }
        let before = now
        now = clock()
        // Left open by "even if closed" and run out before the timer said so: locked now, said once.
        if lock.isOpen(at: before), !lock.isOpen(at: now) { logLocked("idle, while closed", wasOpen: true) }
        // Opened again before a read that outlived the last close ended: the panel holds the
        // numbers now, under its lock, so the read's end has nothing to let go.
        session.panelOpened()
        releaseWhenIdle?.cancel()
        let settings = VaultLockSettings(defaults: defaults)
        if settings != lock.settings {
            logLocked("the lock’s settings changed")
            // The settings, then the lock: each is its own change to what the panel draws.
            lock.settings = settings
            session.lockAll()
        }
        lock.expire(at: now)
        hasSomethingSealed = store.map { $0.hasFile || $0.hasReadingFile } ?? false
        // Locked means locked: under "As soon as Vault opens" nothing is read from disk for the
        // panel until the owner has proved it, so a locked Vault holds nothing to show. A Vault
        // with nothing sealed yet has nothing to guard: it is read without asking, for its
        // empty state.
        if lock.hidesEverything(at: now), hasSomethingSealed {
            // A Vault whose key is not on this Mac cannot be opened by any proof: it is said so
            // at once, rather than asked for first.
            guard store?.hasFile != true || store?.fingerprint("") != nil || store?.keyNeedsProof == true else {
                load()
                return
            }
            await unlock()
            return
        }
        // Read without a proof of the whole ("For every ID", or nothing sealed yet): a key kept
        // behind Touch ID asks for one touch first, which opens nothing else (VT31).
        guard await keyReady("open the Vault") else { return }
        load()
    }

    /// The key, kept behind Touch ID since VT31, ready for a change made with the Vault locked
    /// (Add, Discover More, the "For every ID" open): one touch when it needs one, which reads the
    /// key and opens nothing else. True when the key can be read, or there is none to read yet.
    public func keyReady(_ reason: String) async -> Bool {
        guard store?.keyNeedsProof == true else { return true }
        return await prove(reason, forEach: [], opens: false)
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
        if lock.settings.relock.locksOnClose { logLocked("closed") }
        session.panelClosed()
        query = ""
        notice = nil
        releaseIfLocked()
        // Left open by "After N minutes, even if closed": let go when that runs out.
        releaseWhenIdle?.cancel()
        if let seconds = lock.secondsLeft(at: now) {
            releaseWhenIdle = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(seconds) + 1))
                guard let self, !Task.isCancelled, !self.session.panelUp else { return }
                self.now = self.clock()
                if !self.lock.isOpen(at: self.now) { self.logLocked("idle, while closed", wasOpen: true) }
                self.lock.expire(at: self.now)
                self.releaseIfLocked()
            }
        }
    }

    /// How the lock is set, in Settings ▸ Vault's words, for the log.
    /// The menu's short labels leave out that an idle choice also locks on close (the setting's
    /// help says it once); the log says it, so a line read alone is the whole rule.
    static func lockMode(_ settings: VaultLockSettings) -> String {
        let relock = settings.relock
        let alsoOnClose = relock.locksOnClose && relock != .whenClosed ? ", or when vault closes" : ""
        return "asks " + settings.ask.label.lowercased()
            + (settings.ask == .whenOpened ? ", locks " + relock.label.lowercased() + alsoOnClose : "")
    }

    /// Says the Vault locked and why (VT22): only an open Vault holding its numbers locks, which is
    /// only ever one under "As soon as Vault opens". `wasOpen` is for a caller that has already seen
    /// the lock run out.
    private func logLocked(_ why: String, wasOpen: Bool? = nil) {
        guard contents == .loaded, wasOpen ?? lock.isOpen(at: clock()) else { return }
        logSession("Vault: locked (\(why))")
    }

    /// Each session line as it is logged (VT22), for a test to read this model's own: the log's
    /// capture sees every suite running beside it.
    var sessionLine: ((String) -> Void)?

    private func logSession(_ line: String) {
        Logger.shared.info(line)
        sessionLine?(line)
    }

    /// Lock Now.
    public func lockNow() {
        logLocked("Lock Now")
        session.lockAll()
        cardReadings = [:]
        now = clock()
        // Locked, the panel holds nothing: the numbers go now, not when it closes.
        releaseIfSealedShut()
    }

    private var restoreWatch: NSObjectProtocol?

    // MARK: Activity

    /// Where what is done here is listed (``VaultActivityStore``); nil keeps no list.
    private let activity: VaultActivityStore?

    /// Adds a line to the activity list, when Settings ▸ Vault keeps one. `what` is a name or a
    /// label, with any number in it cut to its ending: a title can be typed with one in it.
    /// `hidesEnding`: the line is about an ID whose ending is itself a secret, so a number in
    /// its title is hidden whole (VT34).
    private func record(_ kind: VaultActivityEvent.Kind, _ what: String = "", whose: String? = nil,
                        hidesEnding: Bool = false) {
        guard let activity, VaultActivitySettings.keeps(in: defaults) else { return }
        let at = clock()
        let line = VaultMask.text(what, keep: hidesEnding ? 0 : 4)
        activity.append([VaultActivityEvent(at: at, kind: kind, what: line, whose: whose)], now: at)
    }

    /// The same for one ID, named as its row names it.
    private func record(_ kind: VaultActivityEvent.Kind, id: UUID, detail: String? = nil) {
        guard activity != nil else { return }
        let row = rows.first { $0.id == id }
        let name = row.map(\.kindTitle)
            ?? entry(id: id)?.title ?? find(id: id)?.title ?? "an ID"
        let category = row?.category ?? entry(id: id)?.category ?? find(id: id)?.category
        record(kind, detail.map { "\($0) of \(name)" } ?? name, whose: row?.whose,
               hidesEnding: category?.hidesEnding ?? false)
    }

    /// The Vault's file was replaced by a restore: lock, stop any read, and let go of what was
    /// loaded without sealing it over what the restore wrote. The next unlock reads the new file.
    private func vaultWasRestored() {
        logLocked("restored from a backup")
        session.lockAll()
        now = clock()
        readingTask?.cancel()
        readingTask = nil
        session.readStopped()
        readingChanged = false
        hasSomethingSealed = true
        release()
    }

    /// Set It Aside and Start New, offered when the sealed file cannot be opened on this Mac: the
    /// file (and what was read) is renamed and kept, never deleted, and the panel starts over
    /// with an empty Vault. Not for a Keychain that is only refusing for now: that Vault is fine.
    @discardableResult
    public func setAsideAndStartNew() -> Bool {
        guard case .unreadable(let error) = contents, let store else { return false }
        if case .keyUnreadable = error { return false }
        guard store.setAside(at: clock()) else {
            notice = Self.message(for: .notWritten)
            return false
        }
        Logger.shared.info("Vault: a sealed file this Mac could not open was set aside; a new Vault starts")
        notice = nil
        hasSomethingSealed = false
        contents = .notLoaded
        load()
        return contents == .loaded
    }

    /// Settings ▸ Vault ▸ Read, from this model's settings: the panel's list and the
    /// folders a read looks in are always the same one (VT74).
    public var readFolders: [String] { VaultReadFolders.folders(in: defaults) }

    /// Adds folders to read, as ``VaultReadFolders/add(_:in:)`` does.
    public func addReadFolders(_ paths: [String]) {
        for path in paths { VaultReadFolders.add(path, in: defaults) }
    }

    /// Stop Reading This Folder.
    public func removeReadFolder(_ path: String) { VaultReadFolders.remove(path, in: defaults) }

    /// The weekly backup, when one is owed (``VaultBackup/isDue``): made from the IDs already in
    /// hand once the Vault is open, so it asks for nothing. A failure is logged and tried again
    /// at the next open.
    /// Answers the backup's task, for a caller that waits on it; the panel does not.
    @discardableResult
    public func backUpIfDue() -> Task<Void, Never>? {
        // One at a time: it is due until its write lands, and the panel asks twice as it opens
        // unlocked (on open, and as the lock lifts).
        if let backingUp { return backingUp }
        guard let backup, contents == .loaded, !isSealedShut, !entries.isEmpty, backup.isDue else { return nil }
        // Only after Touch ID since the Vault loaded (VT114): "For every ID" loads it with
        // none, and a backup is every ID in it.
        guard provedSinceLoad else { return nil }
        // A later build's document is not this build's to back up: it would leave out what it
        // cannot read.
        if keepsDocument, readOnly == .newerFormat { return nil }
        let entries = entries
        let contacts = contacts
        // The whole document, as it would be sealed now, while the Vault is kept as one (v2).
        let document = keepsDocument ? currentDocument() : nil
        // Sealed off the main actor (VT58), so the panel draws while the key is derived.
        let task = Task {
            if let document {
                _ = try? await backup.write(document: document)
            } else {
                _ = try? await backup.write(entries, contacts: contacts)
            }
            backingUp = nil
        }
        backingUp = task
        return task
    }

    /// The fingerprints enrolled at the last proof, as ``VaultAuthenticating/enrolledFingerprints()``
    /// digests them: a change is said, and listed in Activity (the owner, 2026-11-26: warn only).
    static let enrolledKey = "vaultTouchIDEnrolled"

    private func noticeNewFingerprints() {
        guard let enrolled = authenticator.enrolledFingerprints() else { return }
        if let before = defaults.string(forKey: Self.enrolledKey), before != enrolled {
            notice = Self.fingerprintsChanged
            record(.other, "Touch ID’s fingerprints changed since the last proof")
            Logger.shared.warning("Vault: Touch ID’s enrolled fingerprints changed since the last proof")
        }
        defaults.set(enrolled, forKey: Self.enrolledKey)
    }

    public static let fingerprintsChanged = "A fingerprint was added to or removed from Touch ID since the Vault last asked for one. If you didn’t change them, check System Settings ▸ Touch ID & Password."

    /// Touch ID was given since the Vault last loaded: to open it, or for a number. What the weekly
    /// backup waits for (VT114).
    private var provedSinceLoad = false

    /// The weekly backup being written, if one is.
    private(set) var backingUp: Task<Void, Never>?

    /// Lets the numbers go when the lock that hides everything has closed with the panel up:
    /// Lock Now, or the idle limit passing. A read in progress keeps them until it ends.
    private func releaseIfSealedShut() {
        guard contents == .loaded, isSealedShut else { return }
        releaseIfLocked()
    }

    /// The Mac is going to sleep or its screen locked: lock whatever the setting, and forget.
    public func systemLocked() {
        // Also what the window closing does (`VaultHost`'s `onDisappear`).
        logLocked("the Mac locked or slept, or the window closed")
        session.lockAll()
        now = clock()
        // Whoever comes to the Mac next is a stranger until they prove otherwise: a read in
        // progress stops too, keeping what it sealed so far.
        readingTask?.cancel()
        readingTask = nil
        session.readStopped()
        release()
    }

    /// Once a second while the panel is up.
    public func tick() {
        let time = clock()
        var next = sessionState.lock
        next.expire(at: time)
        // Moved only when something drawn changes: then the panel redraws, and what reads the
        // time sees it. Otherwise everything drawn from the older time is the same.
        if clockface(next, at: time) != clockface(sessionState.lock, at: now) {
            if sessionState.lock.isOpen(at: now), !next.isOpen(at: time) { logLocked("idle", wasOpen: true) }
            now = time
        }
        sessionState.lock = next
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
        guard session.panelActivity(at: clock()) else { return }
        used()
    }

    /// Chooses `id` and shows it: its tab, and back to all for whichever filter would hide it.
    public func reveal(_ id: UUID) { showEvenIfFiltered(id) }

    /// Lets the numbers go once the Vault is locked, or, while Read Documents is still reading,
    /// once it finishes: a read carries on with the panel closed, and needs what it has read so far
    /// to seal it. Nothing is shown meanwhile; the lock has already locked.
    private func releaseIfLocked() {
        if session.releasesNow(reading: reading != nil, at: now) { release() }
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

    /// The document each ID is read from, saved or waiting, and those an older build read IDs
    /// from: what Refresh opens. Not an ID's other copies (VT107, owner): Refresh only checks
    /// those, and one that changed is left for Discover More (``otherSources``). Nor the
    /// documents that only name an ID; those come back with Discover More too.
    public var refreshSources: Set<String> { sources.own }

    /// Every other document an ID was read from: a copy filed in a packet or a second folder.
    /// Refresh asks only whether each is still there and unchanged.
    var otherSources: Set<String> { sources.others }

    /// The document a saved ID is read from: the copy chosen with Read from This Copy, else the
    /// one it was saved from, else its most trusted (the 2026-11-25 review).
    static func ownDocument(of entry: VaultEntry) -> String? {
        entry.chosenSource ?? entry.savedFrom ?? entry.facts?.primary?.path
    }

    private var sources: (own: Set<String>, others: Set<String>) {
        if let cached = sourcesCache, cached.revision == rowsRevision, cached.stale == staleSources {
            return (cached.own, cached.others)
        }
        var own = staleSources, all = Set<String>()
        for entry in entries {
            if let path = Self.ownDocument(of: entry) { own.insert(path) }
            for source in entry.facts?.sources ?? [] { all.insert(source.path) }
        }
        for find in finds {
            if let path = find.chosenSource ?? find.facts.primary?.path { own.insert(path) }
            for source in find.facts.sources { all.insert(source.path) }
        }
        for byFile in copies.values { all.formUnion(byFile.keys) }
        let others = all.subtracting(own)
        sourcesCache = (rowsRevision, staleSources, own, others)
        viewComputations += 1
        return (own, others)
    }

    /// Not Now, on the banner that offers Discover More after an update: it is not offered again
    /// until the next one. The menu still has it.
    public func dismissDiscover() {
        guard needsDiscover else { return }
        needsDiscover = false
        copiesChanged = false
        readingChanged = true
        saveReading()
    }

    /// Keep Mine: the saved ID stands, and the other reading of its document is set aside.
    public func keepSaved(_ id: UUID) {
        guard let find = rereads[id], !refusedReadOnly() else { return }
        rereads[id] = nil
        setAside(find)
    }

    /// Use the New Reading: the saved ID takes the number its document now reads, after a proof
    /// when one is owed, as any change to a number does.
    @discardableResult
    public func useReread(_ id: UUID) async -> Bool {
        guard let findID = rereads[id], let find = find(id: findID),
              let entry = entry(id: id) else { return false }
        var draft = Draft(entry)
        draft.value = find.value
        guard await update(id, to: draft) else { return false }
        rereads[id] = nil
        return true
    }

    /// Lets every number go from memory. To Confirm is sealed first, so the next unlock brings it
    /// back without reading anything again.
    private func release() {
        if contents == .loaded {
            logSession("Vault: let go of \(entries.count) saved ID(s) and \(finds.count) to confirm from memory")
        }
        // Sealed whatever action is running: what is let go next cannot be sealed after.
        if contents == .loaded {
            let depth = sealDepth
            sealDepth = 0
            saveReading()
            sealDepth = depth
        }
        // The key held since the proof goes with the numbers (VT10): the next read needs a touch.
        store?.letGoOfKey()
        entries = []
        finds = []
        provedSinceLoad = false
        cardReadings = [:]
        correctionUndo = nil
        lastCorrection = nil
        readIndex = [:]
        mentions = [:]
        copies = [:]
        choices = [:]
        lessons = [:]
        staleSources = []
        copyNumbers = [:]
        missingDocuments = []
        // What a refresh changed holds numbers too, and is news only while the Vault is up.
        changes = [:]
        rereads = [:]
        names = [:]
        nameRoles = [:]
        contacts = [:]
        readingLaterFields = nil
        readingUnreadFields = nil
        readingHeld = false
        onDisk = nil
        editedElsewhereIDs = []
        readingOnDisk = nil
        readingBase = nil
        documentBase = nil
        cacheWritten = nil
        cacheOnDisk = nil
        refreshBaseline = [:]
        setAsideFingerprints = []
        fingerprintsFromDefaults = []
        removeMovedKeysOnWrite = false
        // The rows hold every number in full: a closed, locked Vault holds none of them.
        rowsCache = nil
        // The panel's lists hold the rows, dates of birth and paths too: let go with them.
        visibleCache = nil
        cardsCache = nil
        tabCountsCache = nil
        peopleCache = nil
        sourcesCache = nil
        contents = .notLoaded
        selection = nil
    }

    /// Why the Vault cannot be used on this Mac: Touch ID is not set up. Nil when it is, or before
    /// the panel first asked.
    @Published public private(set) var touchIDMissing: String?

    /// Asks whether this Mac has Touch ID set up, and keeps the answer for the panel. Asked at
    /// every open and before anything is loaded, so setting it up while the app runs is enough.
    ///
    /// Found gone while the Vault is loaded (a fingerprint removed with it unlocked, or kept open
    /// under "even if closed"): it locks, any read stops, and the numbers go, as when the Mac locks.
    private func touchIDReady() -> Bool {
        if case .notSetUp(let why) = authenticator.touchID {
            if touchIDMissing != why {
                touchIDMissing = why
                logSession("Vault: not used, Touch ID is not set up on this Mac")
            }
            if contents == .loaded {
                session.lockAll()
                now = clock()
                readingTask?.cancel()
                readingTask = nil
                session.readStopped()
                release()
            }
            return false
        }
        touchIDMissing = nil
        return true
    }

    /// The app came back to the front: Touch ID asked again, so setting it up in System Settings
    /// opens the Vault without closing the panel, and removing it lets the Vault go.
    public func touchIDMayHaveChanged() async {
        let wasMissing = touchIDMissing != nil
        guard touchIDReady() else { return }
        if wasMissing { await opened() }
    }

    private func load() {
        guard contents != .loaded else { keepSelectionVisible(); return }
        guard touchIDReady() else { return }
        guard let store else { contents = .unreadable(.unreadableFile); return }
        if readOnly != nil { readOnly = nil }
        // The v1 files become the document first (gated, VT6). Refused while another SyncCloud
        // runs, which would go on writing them: the Vault opens, and nothing is written.
        if store.needsMigration(defaults: defaults),
           case .refused(.anotherCopyRunning) = store.migrate(defaults: defaults, people: people, folders: readFolders) {
            readOnly = .anotherCopyRunning
        }
        keepsDocument = store.keepsDocument
        if keepsDocument {
            loadDocument(from: store)
            return
        }
        do {
            let (records, state) = try store.loadRecordsAndState()
            entries = records.entries
            newerRecords = records.newer.count
            onDisk = state
            contents = .loaded
            readGeneration = VaultSetAside.generation(in: defaults)
            let (reading, readingState) = store.openReadingAndState()
            readingOnDisk = readingState
            switch reading {
            case .none: break
            case .keyRefused:
                // The Keychain would not give the key just now: what the file holds is unknown,
                // so nothing is sealed over it this run.
                readingHeld = true
            case .damaged:
                // A fresh start, as it always was: with nothing marked read, the next Refresh or
                // Read finds what was waiting again, and no banner says otherwise. The file is
                // kept out of the next save's way, never sealed over: what it holds (name
                // corrections, roles, lessons) is the user's own. One that would not move holds
                // every seal this run.
                // Read-only, nothing is moved either: it is held, as one that would not move.
                if readOnly != nil || store.setAsideReading() == nil, store.hasReadingFile {
                    readingHeld = true
                    Logger.shared.warning("Vault: the reading file that did not open stays where it is, and nothing read this time is sealed")
                } else {
                    readingOnDisk = .absent
                }
            case .loaded(let sealed):
                let opened = sealed.opened(generation: readGeneration, people: people)
                hold(opened.state)
                if opened.changed { readingChanged = true }
                readingBase = OwnReading(sealed)
                dropOrphanedCopies(laterFields: !records.laterFields.isEmpty || !records.stored.isEmpty)
            }
            // Counts and the lock's settings only (VT22): never a title.
            logSession("Vault: loaded, \(entries.count) saved ID(s) and \(finds.count) to confirm; "
                       + Self.lockMode(lock.settings))
            keepSelectionVisible()
        } catch let error as VaultError {
            entries = []
            newerRecords = 0
            contents = .unreadable(error)
        } catch {
            entries = []
            newerRecords = 0
            contents = .unreadable(.unreadableFile)
        }
    }

    // MARK: Proving it

    /// Asks the owner to prove it and records the answer. False when they did not, with the
    /// reason in ``notice`` unless they simply cancelled.
    @discardableResult
    private func prove(_ reason: String, for id: UUID?) async -> Bool {
        await prove(reason, forEach: id.map { [$0] } ?? [])
    }

    /// Shows every one of `ids` in full for one proof, when any of them needs one: what an editor
    /// drawing several IDs (a card's others beside the one being changed) asks before it opens.
    /// Under "For every ID" they show together and hide together; otherwise one proof opens
    /// the Vault as any other does. True when all of them may be drawn.
    @discardableResult
    public func showTogether(_ ids: [UUID], reason: String) async -> Bool {
        let at = clock()
        guard ids.contains(where: { lock.needsProof(for: $0, at: at) }) else { return true }
        return await prove(reason, forEach: Set(ids))
    }

    /// Whether any of `ids` is of a kind whose ending is itself a secret.
    private func secretEnding(_ ids: Set<UUID>) -> Bool {
        rows.contains { ids.contains($0.id) && $0.category.hidesEnding }
    }

    /// ``prove(_:for:)`` for several IDs at once; none is a proof to open the Vault.
    /// `opens` false for a proof that only lets the key be read (``keyReady(_:)``): the lock stays
    /// as it was, and nothing is listed as unlocked.
    private func prove(_ reason: String, forEach ids: Set<UUID>, opens: Bool = true) async -> Bool {
        guard !isAsking, touchIDReady() else { return false }
        isAsking = true
        defer { isAsking = false }
        let epoch = session.epoch
        // macOS draws the reason in its own prompt, over whatever is on screen: a number typed
        // into an ID's title is cut to its ending there, or hidden whole for a kind whose ending
        // is a secret, as the Activity line is (VT34).
        let reason = VaultMask.text(reason, keep: secretEnding(ids) ? 0 : 4)
        let proof = await authenticator.prove(reason: reason)
        now = clock()
        // What was asked for, never for which ID or person (VT22).
        let asked = ids.count > 1 ? "a proof for \(ids.count) IDs" : !ids.isEmpty ? "a proof for one ID" : reason == Self.unlockReason ? "a proof to unlock" : "a proof for a person’s IDs"
        // The panel closed, Lock Now was chosen or the Mac locked while the prompt was up: an
        // answer given after that opens nothing, and nothing is shown or copied for it.
        guard session.stands(epoch) else {
            logSession("Vault: \(asked) was answered after the Vault closed or locked, and set aside")
            return false
        }
        switch proof {
        case .allowed: logSession("Vault: \(asked) was given")
        case .cancelled: logSession("Vault: \(asked) was canceled")
        case .unavailable: logSession("Vault: \(asked) could not be asked on this Mac")
        case .failed: logSession("Vault: \(asked) failed")
        }
        switch proof {
        case .allowed:
            notice = nil
            if opens { lock.proved(for: ids, at: now) }
            if ids.isEmpty, opens { record(.unlocked) }
            // Activity lines written while the key could not be read are sealed now (VT31).
            activity?.sealWaiting(now: now)
            noticeNewFingerprints()
            provedSinceLoad = true
            // "For every ID": the weekly backup waits for the first proof (VT114).
            if !ids.isEmpty { backUpIfDue() }
            return true
        case .cancelled:
            // Someone asked and did not prove it: worth a line, since it may not have been the owner.
            record(.proofRefused, reason, hidesEnding: secretEnding(ids))
            return false
        case .unavailable(let message), .failed(let message):
            notice = message
            record(.proofRefused, reason, hidesEnding: secretEnding(ids))
            return false
        }
    }

    /// What the unlock prompt says after "SyncCloud is trying to".
    static let unlockReason = "unlock your Vault"

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
        guard await prove(Self.unlockReason, for: nil) else { return false }
        load()
        return true
    }

    /// Show: draws `id`'s number in full, after a proof when one is owed.
    @discardableResult
    public func show(_ id: UUID) async -> Bool {
        guard let row = row(id) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("show \(row.title)", for: id) else { return false }
            record(.shown, id: id)
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
        record(.copied, id: id)
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
        record(.copied, id: id, detail: "A detail")
        return true
    }

    /// An entry or a find, by id: what Show and Copy act on.
    private func row(_ id: UUID) -> (title: String, value: String)? {
        if let entry = entry(id: id) { return (entry.title, entry.value) }
        if let find = find(id: id) { return (find.title, find.value) }
        return nil
    }

    // MARK: Editing

    /// Adds a number. No proof: the person typing it already has it in hand.
    @discardableResult
    public func add(_ draft: Draft) -> UUID? {
        sealingOnce {
            guard let id = add(draft, savedFrom: nil) else { return nil }
            record(.added, id: id)
            return id
        }
    }

    private func add(_ draft: Draft, savedFrom: String?, droppingFind: UUID? = nil) -> UUID? {
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
                               savedFrom: savedFrom ?? facts?.primary?.path, addedAt: stamp,
                               category: draft.category, facts: facts)
        entry.choices = draft.choices.or(waiting?.choices)
        let name = draft.facts == nil ? (own: nil, everywhere: nil) : storedName(for: draft, read: draft.readHolder ?? facts?.holder)
        entry.holderName = name.own
        guard write(entries + [entry], droppingFind: droppingFind, naming: name.everywhere) else { return nil }
        apply(name.everywhere)
        dropFinds(matching: entry.value)
        selection = entry.id
        showEvenIfFiltered(entry.id)
        return entry.id
    }

    /// Changes an entry, after a proof when its number is not already showing: the editor draws
    /// it in full.
    @discardableResult
    public func update(_ id: UUID, to draft: Draft, editedFrom: VaultEntry? = nil) async -> Bool {
        guard draft.isComplete, let title = entry(id: id)?.title else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("change \(title)", for: id) else { return false }
        }
        // `editedFrom`: the ID as the editor opened it. Another SyncCloud on this Mac saved an edit
        // of a field the editor shows since (it came in with a reread): nothing is saved, and the
        // panel says so; the editor keeps what was typed, and saving again replaces it (VT112).
        // This copy's own changes (a row's menu) never refuse it.
        if refusesOverEditElsewhere(id, editedFrom) { return false }
        let saved = sealingOnce { updating(id, to: draft) }
        // Refused by the file (VT108): if the reread brought that copy's edit of this very ID, say so
        // now, so the next Save is the deliberate one.
        if saved { editedElsewhereIDs.remove(id) } else { _ = refusesOverEditElsewhere(id, editedFrom) }
        return saved
    }

    /// Whether another copy's edit of `id`, read in since `editedFrom`, stands in the way.
    private func refusesOverEditElsewhere(_ id: UUID, _ editedFrom: VaultEntry?) -> Bool {
        guard let editedFrom, editedElsewhereIDs.contains(id), let now = entry(id: id),
              EditedFields(now) != EditedFields(editedFrom) else { return false }
        editedElsewhereIDs.remove(id)
        notice = Self.editedElsewhere
        return true
    }

    /// Saved IDs a reread found edited by another SyncCloud (``reloadSavedIDs()``), in a field the
    /// editor shows: an editor open on one is told once before its save replaces that edit.
    private var editedElsewhereIDs: Set<UUID> = []

    /// What the editor shows and changes about an ID. Nothing else counts as edited meanwhile: a
    /// correction's note or a read's details land on the same ID without the user editing it, and
    /// the pin and place are kept as they are by an edit.
    private struct EditedFields: Equatable {
        let title, value, note: String
        let category: VaultCategory
        let assignment: VaultAssignment?
        let card: VaultCardID?
        let holderName: String?

        init(_ entry: VaultEntry) {
            (title, value, note, category) = (entry.title, entry.value, entry.note, entry.category)
            (assignment, card, holderName) = (entry.assignment, entry.card, entry.holderName)
        }
    }

    /// Said when an edit was refused because the ID changed since the editor opened (VT112).
    public static let editedElsewhere = "Another SyncCloud on this Mac changed this ID while you were editing it, so your change wasn’t saved. Save again to replace its change with yours, or Cancel to keep it."

    /// ``update(_:to:)`` once its proof is had: nothing here waits, so its seals are one.
    private func updating(_ id: UUID, to draft: Draft) -> Bool {
        // Looked up again after the proof: while it was asked, the panel may have closed and let
        // the numbers go, or another number may have been removed and moved this one.
        guard contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        var changed = entries
        changed[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].assignment = draft.assignment
        changed[index].note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].category = draft.category
        // The editor shows neither: kept as they are now, so a Move to Archive or a place chosen
        // from the row's menu while the editor is open is not undone by its save.

        changed[index].card = draft.card
        let shownRead = rows.first { $0.id == id }?.holderAsRead
        let name = changed[index].facts == nil ? (own: nil, everywhere: nil)
            : storedName(for: draft, read: shownRead ?? changed[index].facts?.holder)
        changed[index].holderName = name.own
        changed[index].updatedAt = clock()
        used()
        let before = entries[index]
        guard write(changed, naming: name.everywhere) else { return false }
        apply(name.everywhere)
        record(.edited, id: id)
        // A read number corrected by hand: its documents keep a note of what they read for it,
        // as Add to Vault does, so the next read gives them to this ID rather than offering the
        // misreading again.
        let correcting = before.facts != nil
            && VaultReading.normalized(before.value) != VaultReading.normalized(changed[index].value)
        if correcting {
            corrected(before.value, to: changed[index].value, for: id, owned: before.readAs ?? [], before: before, find: nil)
        }
        // A typed number changed: the old one is let go as a removed typed number is, and its
        // documents read again, so papers that print it offer it in To Confirm (VT109, owner).
        // Typed means nothing read went into it: no reading, no source, and no note of a reading
        // merged into it, whose documents would then give that misreading to the new number.
        if before.facts == nil, before.savedFrom == nil, (before.readAs ?? []).isEmpty,
           VaultReading.normalized(before.value) != VaultReading.normalized(changed[index].value) {
            forgetReading(of: before.value, readAgain: true)
        }
        dropFinds(matching: changed[index].value)
        if correcting { correctionSettled() }
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
    /// what was just removed. What its documents said goes with it (``forgetReading(of:)``).
    @discardableResult
    public func delete(_ id: UUID) async -> Bool {
        guard let entry = entry(id: id) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("remove \(entry.title)", for: id) else { return false }
        }
        // While the proof was asked, the panel may have closed and let the numbers go: saving
        // "everything but this one" from an emptied list would write an empty Vault.
        guard contents == .loaded, entries.contains(where: { $0.id == id }) else { return false }
        used()
        // Named before it goes: a removed ID has no row to be named by.
        let whose = rows.first { $0.id == id }?.whose
        // In the document, the number is set aside in the same write that removes it.
        let fingerprint = keepsDocument && entry.savedFrom != nil ? store?.fingerprint(entry.value, makingKey: true) : nil
        guard write(entries.filter { $0.id != id }, fingerprint: fingerprint) else { return false }
        record(.removed, entry.title, whose: whose, hidesEnding: entry.category.hidesEnding)
        if entry.savedFrom != nil {
            if !keepsDocument { remember(entry.value) } else if fingerprint == nil { setAsideThisRun.insert(Self.hash(entry.value)) }
        }
        forgetReading(of: entry.value, readAgain: entry.savedFrom == nil)
        keepSelectionVisible()
        return true
    }

    /// What documents said about numbers no saved or waiting ID has, let go as the reading file
    /// opens (VT110): IDs removed before ``forgetReading(of:readAgain:)`` left theirs, and Refresh
    /// went on counting and opening those documents. Sealed at the next seal, with the rest; one
    /// that never lands is simply done again at the next open. Documents stay marked read, so a
    /// typed ID removed back then is not offered again until its document changes.
    ///
    /// Not while anything here was written by a later build, whose numbers this one cannot see:
    /// its records, its fields on a record (`laterFields`) or in the reading file. Nor while the
    /// Vault holds no ID: a missing Vault file beside its reading file is no sign the IDs are gone.
    /// Mentions stay: a number never saved is named in documents too.
    private func dropOrphanedCopies(laterFields: Bool) {
        guard newerRecords == 0, !laterFields, readingLaterFields == nil, !entries.isEmpty else { return }
        let held = Set(entries.map { VaultReading.normalized($0.value) } + finds.map { VaultReading.normalized($0.value) })
        let orphaned = copies.keys.filter { !held.contains($0) }
        guard !orphaned.isEmpty else { return }
        for key in orphaned { copies[key] = nil }
        readingChanged = true
        // A count only: the numbers are never logged.
        Logger.shared.info("Vault: let go of what documents said about \(orphaned.count) number(s) no ID has")
    }

    /// Lets go of what documents said about a removed number, and seals that (VT64): kept, Refresh
    /// would go on counting and opening the documents it was read from, the reading file would go
    /// on holding the number, and another ID corrected into it later would take those copies.
    /// Kept while another saved or waiting ID has the number.
    ///
    /// `readAgain`, for a number typed in: its documents are no longer marked read, so the next
    /// Discover More opens them and offers it in To Confirm, as for any number read but not saved.
    /// One read from a document is set aside, and opening its documents again would find nothing.
    private func forgetReading(of value: String, readAgain: Bool) {
        let key = VaultReading.normalized(value)
        guard copies[key] != nil || mentions[key] != nil,
              !entries.contains(where: { VaultReading.normalized($0.value) == key }),
              !finds.contains(where: { VaultReading.normalized($0.value) == key }) else { return }
        if readAgain, let byFile = copies[key] { for path in byFile.keys { readIndex[path] = nil; copyNumbers[path] = nil } }
        copies[key] = nil
        mentions[key] = nil
        readingChanged = true
        saveReading()
    }

    /// The sealed file as this model last read or wrote it: a save over a file another SyncCloud
    /// changed since is refused (VT108). Nil while nothing is loaded.
    private var onDisk: VaultFileState?

    /// Another SyncCloud saved the Vault: its IDs, as they now are, take the place of this model's,
    /// so the next change is made to them. What was read here stays waiting, but for a number the
    /// other saved, which leaves To Confirm as one confirmed here would. An Undo of a correction
    /// that no longer matches goes. IDs this copy did not see typed in are behind the lock from
    /// now, as at the next open.
    private func reloadSavedIDs() throws {
        guard let store else { throw VaultError.notWritten }
        let (records, state) = try store.loadRecordsAndState()
        let before = Dictionary(entries.map { ($0.id, EditedFields($0)) }, uniquingKeysWith: { first, _ in first })
        for entry in records.entries where before[entry.id].map({ $0 != EditedFields(entry) }) == true {
            editedElsewhereIDs.insert(entry.id)
        }
        entries = records.entries
        newerRecords = records.newer.count
        onDisk = state
        if !entries.isEmpty { hasSomethingSealed = true }
        for entry in entries { dropFinds(matching: entry.value) }
        dropStaleCorrection()
        Logger.shared.info("Vault: another SyncCloud saved the Vault; \(entries.count) saved ID(s) read again")
        keepSelectionVisible()
    }

    /// Saves `changed` and, only once the disk has it, shows it. A refused save leaves the list as
    /// it was, so the panel never shows a number that would be gone at the next launch.
    ///
    /// `quietly`, for a write the user did not ask for just now (a correction's note, made once its
    /// documents are read): refused because another SyncCloud saved, the Vault is read again but
    /// nothing says "make your change again", since the change asked for was saved.
    ///
    /// In the document (VT6), the saved IDs are written with everything else it holds, in one
    /// swap: `droppingFind` leaves To Confirm in it (Confirm), and `fingerprint` is set aside in it
    /// (Delete). Read-only, nothing is written.
    private func write(_ changed: [VaultEntry], quietly: Bool = false, droppingFind: UUID? = nil,
                       fingerprint: String? = nil, naming: NameCorrection? = nil) -> Bool {
        guard let store else { notice = Self.message(for: .notWritten); return false }
        // Only over what was loaded: a list held while the Vault was let go is not the Vault.
        guard contents == .loaded, !refusedReadOnly() else { return false }
        if keepsDocument {
            return writeDocument(changed, quietly: quietly, droppingFind: droppingFind, fingerprint: fingerprint, naming: naming)
        }
        do {
            onDisk = try store.save(changed, expecting: onDisk)
            entries = changed
            notice = nil
            return true
        } catch VaultError.changedElsewhere {
            do {
                try reloadSavedIDs()
                if !quietly { notice = Self.message(for: .changedElsewhere) }
            } catch {
                // Not read again: what this copy shows is not the Vault, and saying so would be
                // false. The reason it would not read is what is shown.
                notice = Self.message(for: error as? VaultError ?? .unreadableFile)
            }
            return false
        } catch let error as VaultError {
            notice = Self.message(for: error)
            return false
        } catch {
            notice = Self.message(for: .notWritten)
            return false
        }
    }

    // MARK: Reading documents

    /// What a read opens (VT7): the folders walked (a refresh has its files already), then which
    /// of them to open, by their paths alone (``VaultReadPlan``): a small share of what is on disk.
    /// The rest are still present: what was read from them before stays. A refresh opens every
    /// changed document an ID came from; the plan chooses among the folders' files, which is
    /// Discover More's question.
    ///
    /// Nil when the read was stopped or the Mac locked (letting the numbers go) during the walk or
    /// the plan: nothing to read into, and the read stops before any document is opened.
    private func plannedSteps(_ scope: VaultReadScope, refreshFiles: [URL], with reader: VaultDocumentReading) async
        -> (files: [URL], unreachable: [String], roots: [String], steps: [VaultReadPlan.Step])? {
        func stopped() -> Bool {
            guard !Task.isCancelled, contents == .loaded else {
                Logger.shared.info("Vault: read stopped before any document was opened; the Vault locked")
                return true
            }
            return false
        }
        var files = refreshFiles
        var unreachable: [String] = []
        if !scope.isRefresh {
            (files, unreachable) = await reader.walk()
            if stopped() { return nil }
        }
        let roots = readFolders
        guard reader.followsReadPlan else {
            return (files, unreachable, roots, files.map { VaultReadPlan.Step(file: $0, account: nil) })
        }
        // Made off the main actor: it asks a file's date for accounts filed by year (VT67).
        let refresh = scope.isRefresh
        let steps = await Task.detached { [files, roots] in
            refresh ? VaultReadPlan.every(files, under: roots, modified: { reader.modified(of: $0) })
                : VaultReadPlan(files: files, under: roots, modified: { reader.modified(of: $0) }).steps
        }.value
        if stopped() { return nil }
        return (files, unreachable, roots, steps)
    }

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
        // Discover More with the Vault locked: the key behind Touch ID asks for a touch (VT31).
        if contents != .loaded { guard await keyReady("read your documents into the Vault") else { return } }
        load()
        guard contents == .loaded else { return }
        // Settings ▸ Vault ▸ Forget while the Vault stayed loaded: the record of read files
        // belongs to before it, and every file is read again so the forgotten come back.
        let generation = keepsDocument ? readGeneration : VaultSetAside.generation(in: defaults)
        if scope == .everything || generation != readGeneration { readIndex = [:] }
        if generation != readGeneration { copyNumbers = [:] }
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
            // An ID's other copies, for all of them: checked, not opened (VT107, owner).
            let others = only == nil ? otherSources.sorted() : []
            // Only a copy Discover More would read again can ask for it: one in a folder it reads.
            let folders = readFolders
            refreshKnown = known.count
            // One ID's documents are read whether or not they changed: it was asked for.
            let index = only == nil ? readIndex : [:]
            let checkIndex = readIndex
            let packetStamps = copyNumbers.mapValues(\.stamp)
            // Asked off the main actor: a file's size and date, for a few hundred files.
            let look = await Task.detached {
                () -> (changed: [URL], missing: [String], othersMissing: [String], othersChanged: [String: String]) in
                var changed: [URL] = [], missing: [String] = [], othersMissing: [String] = []
                var othersChanged: [String: String] = [:]
                for path in known {
                    let url = URL(fileURLWithPath: path)
                    guard reader.exists(url) else { missing.append(path); continue }
                    if let stamp = reader.stamp(of: url), index[path] == stamp { continue }
                    changed.append(url)
                }
                for path in others {
                    let url = URL(fileURLWithPath: path)
                    guard reader.exists(url) else { othersMissing.append(path); continue }
                    // Never read under these rules (after a Forget or a change of rules): not
                    // changed, only unread, and a change of rules offers Discover More itself.
                    // A packet's copy passed over is not marked read: its last read size and date
                    // stand in (VT107 step 3).
                    guard folders.contains(where: { path.hasPrefix($0 + "/") }),
                          let mark = checkIndex[path] ?? packetStamps[path],
                          let stamp = reader.stamp(of: url), !Self.readAsItIs(mark, stamp: stamp) else { continue }
                    othersChanged[path] = stamp
                }
                return (changed, missing, othersMissing, othersChanged)
            }.value
            guard !Task.isCancelled, contents == .loaded, reading == nil else { return }
            refreshMissing = Set(look.missing)
            // A copy changed since it was read: what it says shows once Discover More reads it.
            // Marked as noticed at that size and date, so it asks once per change, not at every
            // Refresh, whether Discover More then reads it or passes it over (the 2026-11-25 review).
            if !look.othersChanged.isEmpty {
                Logger.shared.info("Vault: refresh, \(look.othersChanged.count) other document(s) IDs were read from changed; left for Discover More")
                for (path, stamp) in look.othersChanged { readIndex[path] = Self.noticed + stamp }
                if !needsDiscover { needsDiscover = true; copiesChanged = true }
                readingChanged = true
            }
            let missing = missingDocuments.subtracting(known).subtracting(others)
                .union(refreshMissing).union(look.othersMissing)
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
            // However the read ended (Stop included), what it read so far is sealed: it was sealed
            // only every 25 files, and nothing else might before a quit (VT68).
            // Nothing to seal, or the numbers already let go, and this does nothing.
            saveReading()
            reading = nil
            dropStaleCorrection()
            // The Vault closed while this read went on, and kept the numbers for it: let them go
            // now, as closing would have, however the read ended.
            // Or it was read while the panel showed only its lock: nothing was drawn, and what
            // was loaded to read into goes too.
            if session.releasesAfterRead(sealed: hasSomethingSealed, at: clock()) {
                now = clock()
                lock.expire(at: now)
                releaseIfLocked()
            }
        }
        guard let planned = await plannedSteps(scope, refreshFiles: refreshFiles, with: reader) else { return }
        let (files, unreachable, roots, steps) = planned
        var run = VaultReadRun(scope: scope, total: steps.count, documents: files.count)
        reading = run.progress(done: 0)
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
        var rowsBefore: [UUID: Row] = scope.isRefresh && !afterNewRules
            ? Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        // A Refresh stopped before: what each ID read as before it, which its new readings, sealed
        // as it went, no longer show (the second review: its Updated marks were lost).
        for (id, facts) in refreshBaseline { rowsBefore[id]?.facts = facts }
        let waitingBefore = Set(finds.map(\.id))
        // A refresh asks Keep Mine or Use the New Reading only as it finishes, about saved IDs whose
        // own document it opened. Those documents are marked read only then: marked as they are
        // opened, a Stop, a lock or a quit before the end (or the seal every 25 files) would keep
        // them from being opened, and asked about, again.
        let ownDocuments = scope.isRefresh ? Set(entries.compactMap(Self.ownDocument)) : []
        var ownStamps: [String: String] = [:]
        /// What each file's bytes gave, by ``VaultDocumentReading/contentKey(of:)``, for this read.
        var readByContent: [String: ([[String]], Bool, [VaultPageOrigin]?)] = [:]
        // Sizes and stamps, read off the main actor in one pass (VT67); a size two planned files
        // share marks possible copies. A stamp taken before its file is read can only be older
        // than what is read, which reads the file once more next time, never one less.
        let (sizes, stamps): ([String: Int], [String: String]) = await Task.detached { [steps] in
            (Dictionary(steps.compactMap { step in reader.size(of: step.file).map { (step.file.path, $0) } },
                        uniquingKeysWith: { a, _ in a }),
             Dictionary(steps.compactMap { step in reader.stamp(of: step.file).map { (step.file.path, $0) } },
                        uniquingKeysWith: { a, _ in a }))
        }.value
        guard !Task.isCancelled, contents == .loaded else {
            Logger.shared.info("Vault: read stopped before any document was opened; the Vault locked")
            return
        }
        let sharedSizes = Set(Dictionary(grouping: sizes.values, by: { $0 }).filter { $0.value.count > 1 }.keys)
        // What a corrected ID's documents read for it (``VaultReadAs``), and the files an ID was
        // taken off (Not for This ID): checked before anything else is taken from a file. Only a
        // file as big as one of them is hashed to be compared. Worked out again before each file
        // whenever the IDs changed since: a correction, a merge or a Not for This ID made while the
        // read runs holds for the files it has yet to open.
        var readAs: [String: [String: String]] = [:]
        var notOn: [String: Set<String>] = [:]
        var notedSizes: Set<Int> = []
        var notesAt: Int?
        func refreshNotes() {
            // The rows' revision moves with every change to the IDs (and more): a few loops over
            // the saved IDs' notes, never a comparison of the IDs themselves.
            guard notesAt != rowsRevision else { return }
            notesAt = rowsRevision
            readAs = readAsByContents()
            notOn = notOnByContents()
            notedSizes = Set((Array(readAs.keys) + Array(notOn.keys)).compactMap(VaultFileContents.size(of:)))
        }
        /// Files read with a page left out this time: what they gave asks no Keep Mine question.
        var incomplete = Set<String>()
        var readNow: [String: [VaultFind]] = [:]
        func stopped(at index: Int) {
            Logger.shared.info(run.stoppedLine(at: index))
            // Kept for the next Refresh, which opens these documents again: what each ID read as
            // before this one, while the Vault stays open.
            if scope.isRefresh {
                for (id, row) in rowsBefore where refreshBaseline[id] == nil { refreshBaseline[id] = row.facts }
            }
        }
        func accountNumbers(in path: String) -> Set<String> {
            let found = finds.filter { find in
                VaultReading.accountCategories.contains(find.category) && find.facts.sources.contains { $0.path == path }
            }.map { VaultReading.normalized($0.value) }
            let saved = copies.filter { $0.value[path].map { VaultReading.accountCategories.contains($0.category) } ?? false }.keys
            return Set(found).union(saved)
        }
        func settle(_ step: VaultReadPlan.Step) { run.settle(step, numbers: accountNumbers(in: step.file.path)) }
        let onDisk = Set(files.map(\.path))
        /// Whether a number is held from a document filed in its kind's own folder, not archived
        /// or set down there, other than `path`, that this read sees: the original, read before
        /// its copies (originals first). By what was read, waiting and per file, never by a saved
        /// ID's facts as saved: those can name a home scan replaced since (the 2026-11-25 review).
        func heldAtHome(_ key: String, besides path: String) -> Bool {
            var readings = finds.filter { VaultReading.normalized($0.value) == key }.map(\.facts)
            readings += (copies[key] ?? [:]).values.map(\.facts)
            return readings.contains { facts in
                facts.sources.contains {
                    $0.path != path && onDisk.contains($0.path) && !missingDocuments.contains($0.path)
                        && $0.placement(for: facts.category) > 1
                }
            }
        }
        /// Looks at one planned file: false when the read stopped while it was opened.
        func look(at step: VaultReadPlan.Step, _ index: Int) async -> Bool {
            let file = step.file
            if run.passesOver(step) { return true }
            refreshNotes()
            let stamp = stamps[file.path]
            if let stamp, readIndex[file.path] == stamp {
                settle(step)
                return true
            }
            // A copy in a packet, as it was when it was last read whole, whose every number is held
            // from its own folder: not opened (VT107 step 3, owner). Not marked read either, so it
            // is opened again once one of its numbers is held from nowhere else. Never a copy an
            // ID is read from (chosen with Read from This Copy, or saved from), and only in
            // Discover More: Read Everything Again reads every file. What only it says
            // (a later date, a detail, a number it merely names) is let go with a change of rules,
            // as the owner accepted.
            if scope == .discover, step.account == nil, let stamp, let known = copyNumbers[file.path],
               known.stamp == stamp, !known.numbers.isEmpty, VaultReadPlan.isPacketCopy(file.path, under: roots),
               !refreshSources.contains(file.path), known.numbers.allSatisfy({ heldAtHome($0, besides: file.path) }) {
                run.tally.copiesPassedOver += 1
                return true
            }
            // A file whose bytes were read already in this read (a copy saved in two folders) gives
            // the same pages: they are reused, and only what is read from them is done again here,
            // so this path keeps its own sources, copies and dates (VT107).
            // Only a file another one planned is as big as can be a copy of it: those alone are
            // hashed and kept. And within one area: how a page is read depends on where it is.
            let size = sizes[file.path] ?? -1
            var bytes = sharedSizes.contains(size) || notedSizes.contains(size) ? await reader.contentKey(of: file) : nil
            let content = sharedSizes.contains(size)
                ? bytes.map { VaultReadPlan.area(of: file.path, under: roots).description + " " + $0 }
                : nil
            let (pages, complete, origins): ([[String]], Bool, [VaultPageOrigin]?)
            var tooLarge = false
            if let content, let read = readByContent[content] {
                (pages, complete, origins) = read
            } else {
                let read = await reader.noted(file)
                (pages, complete, origins) = (read.pages, read.complete, read.origins)
                tooLarge = read.notes.tooLarge > 0
                run.tally.notes = run.tally.notes + read.notes
                if let content, !pages.isEmpty { readByContent[content] = (pages, complete, origins) }
            }
            // Locked meanwhile, even if opened again since: this read was stopped.
            guard !Task.isCancelled, contents == .loaded else { return false }
            // Nothing came back: locked, damaged, or not there for a moment. What it gave before,
            // and the choices made about it, stay; it is not marked read, so the next read tries again.
            guard !pages.isEmpty else {
                run.tally.record(pages, ([], []))
                // Over the size cap (VT81): what it gave before stays too, but it is marked read
                // as it is, so it is not opened again until it changes.
                if tooLarge, let stamp {
                    if ownDocuments.contains(file.path) { ownStamps[file.path] = stamp } else { readIndex[file.path] = stamp }
                }
                return true
            }
            // A changed file is read afresh: what it said before is let go first. A number it
            // still carries keeps its row and any choice made about it, as does one chosen
            // about under an older build's rules.
            // The reading rules off the main actor: a page's contacts and a zone's swap search are
            // thousands of tries, and the panel draws meanwhile (the 2026-11-23 review).
            let people = self.people
            var read = await Task.detached(priority: .userInitiated) {
                VaultReading.read(pages: pages, from: file.path, under: roots, people: people, origins: origins)
            }.value
            // A choice made about this very file while its pages were read (Not for This ID, a
            // correction) holds for it too: the notes again, and its bytes when it now needs them.
            refreshNotes()
            if bytes == nil, notedSizes.contains(size) { bytes = await reader.contentKey(of: file) }
            guard !Task.isCancelled, contents == .loaded else { return false }
            var before = Dictionary(finds.filter { $0.facts.sources.contains { $0.path == file.path } }
                .map { (VaultReading.normalized($0.value), VaultChoice($0)) },
                uniquingKeysWith: { a, _ in a })
            forgetSource(file.path)
            if let bytes, let instead = readAs[bytes] { read = Self.reading(read, instead: instead) }
            if let bytes, let dropped = notOn[bytes] {
                read.finds.removeAll { dropped.contains(VaultReading.normalized($0.value)) }
                read.mentions.removeAll { dropped.contains(VaultReading.normalized($0.value)) }
            }
            readNow[file.path] = read.finds
            // What a packet's copy gave, read whole, for passing it over later (VT107 step 3).
            if VaultReadPlan.isPacketCopy(file.path, under: roots), let stamp {
                copyNumbers[file.path] = complete
                    ? VaultCopyNumbers(stamp: stamp, numbers: Set(read.finds.map { VaultReading.normalized($0.value) }).sorted())
                    : nil
            }
            run.tally.record(pages, read)
            for var find in read.finds {
                let key = VaultReading.normalized(find.value)
                if before[key] == nil, !finds.contains(where: { VaultReading.normalized($0.value) == key }),
                   let carried = choices.removeValue(forKey: key) {
                    before[key] = carried
                }
                if let choice = before[key] {
                    find = find.keepingChoices(of: choice)
                }
                if take(find), before[key] == nil { run.tally.added += 1 }
            }
            for mention in read.mentions {
                mentions[VaultReading.normalized(mention.value), default: []].append(mention.source)
            }
            // An account whose papers print its number with no label (a phone bill's header): a
            // number standing alone that a second year of the same account prints too.
            if let account = step.account, run.hasNoNumbers(account), accountNumbers(in: file.path).isEmpty {
                let printed = PrintedPage(pages.flatMap { $0 })
                let bare = VaultReading.bareAccountNumbers(on: printed, from: file.path, under: roots)
                if let (value, earlier) = run.repeatedBareNumber(bare, for: account, in: file.path) {
                    var find = VaultReading.bareAccountFind(value, on: printed, from: file.path, under: roots, people: people)
                    find.facts.add(VaultSource(path: earlier, role: "Account paper", rank: VaultReading.IDRank.letter))
                    if take(find) { run.tally.added += 1 }
                }
            }
            // A file with a page left out is not marked read: what it gave is taken, and the next
            // read opens it again for the rest (VT54).
            if let stamp {
                // Read with a page left out: tried once more as it stands, then marked read until
                // it changes, so a page that never reads does not reopen its file at every read.
                let partial = "partial " + stamp
                let mark = complete || readIndex[file.path] == partial ? stamp : partial
                if !complete { incomplete.insert(file.path) }
                if ownDocuments.contains(file.path) { ownStamps[file.path] = mark } else { readIndex[file.path] = mark }
            }
            settle(step)
            readingChanged = true
            // Sealed every so often, so a read stopped halfway keeps what it had.
            if run.tally.opened % 25 == 0 { saveReading() }
            if run.tally.opened % 250 == 0 {
                Logger.shared.debug("Vault: \(index + 1) of \(steps.count) document(s) looked at, \(run.tally.opened) opened")
            }
            return true
        }
        for (index, step) in steps.enumerated() {
            // Stopped, or the panel closed or the Mac locked, letting the numbers go. What was
            // read so far is sealed: by the release, or on the way out (the `defer` above). A
            // restore lets it go unsealed, on purpose: the restored Vault's file is not written over.
            if Task.isCancelled || contents != .loaded { return stopped(at: index) }
            guard await look(at: step, index) else { return stopped(at: index) }
            reading = run.progress(done: index + 1)
        }
        let tally = run.tally
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
                guard let path = Self.ownDocument(of: entry), let found = readNow[path],
                      !incomplete.contains(path) else { continue }
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
            readIndex.merge(ownStamps) { _, own in own }
            refreshBaseline = [:]
            let gone = waitingBefore.subtracting(finds.map(\.id)).count
            finishRefresh(only: only, afterNewRules: afterNewRules)
            return finishRead(ReadingSummary(documents: refreshKnown, opened: tally.opened, newNumbers: tally.added,
                                             scope: scope, updated: updated, missing: refreshMissing.count, gone: gone),
                              log: "Vault: refreshed \(refreshKnown) document(s), \(tally.opened) opened, \(updated) ID(s) updated, "
                                  + "\(tally.added) new, \(gone) no longer read, \(refreshMissing.count) not found, in "
                                  + String(format: "%.1f", Date().timeIntervalSince(began)) + " s" + tally.notes.summary,
                              activity: .refreshed, "Refreshed \(refreshKnown) document(s): \(updated) ID(s) updated, "
                                  + "\(tally.added) new, \(refreshMissing.count) not found")
        }
        // A file gone from the folders is forgotten, so one put back is read again; a number
        // whose every document is gone is let go, rather than pointing at nothing. Only under a
        // folder this read could see into: one that gave no files at all is unmounted, renamed
        // or not yet allowed (macOS asks before the first look into Documents), and what was
        // read from it is kept until it can be seen again.
        let present = Set(files.map(\.path))
        // Whether each document a saved ID points at is still there, asked off the main actor
        // (VT67); one pointed at only after this asks below.
        var pointedBefore = missingDocuments
        for entry in entries {
            if let path = entry.savedFrom { pointedBefore.insert(path) }
            for source in entry.facts?.sources ?? [] { pointedBefore.insert(source.path) }
        }
        let toLook = pointedBefore.subtracting(present)
        let there: [String: Bool] = await Task.detached {
            Dictionary(uniqueKeysWithValues: toLook.map { ($0, reader.exists(URL(fileURLWithPath: $0))) })
        }.value
        guard !Task.isCancelled, contents == .loaded else { return stopped(at: steps.count) }
        let folders = readFolders
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
        copyNumbers = copyNumbers.filter { !isGone($0.key) }
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
        copiesChanged = false
        staleSources = []
        lastDiscovered = clock()
        // A document a saved ID points at that the folders no longer hold is marked, and one
        // found again is not. The ID stays either way; its row says so.
        var pointedAt = missingDocuments
        for entry in entries {
            if let path = entry.savedFrom { pointedAt.insert(path) }
            for source in entry.facts?.sources ?? [] { pointedAt.insert(source.path) }
        }
        missingDocuments = pointedAt.filter { !present.contains($0) && !(there[$0] ?? reader.exists(URL(fileURLWithPath: $0))) }
        finishRead(ReadingSummary(documents: files.count, opened: tally.opened, newNumbers: tally.added, scope: scope),
                   log: tally.summary(seconds: Date().timeIntervalSince(began)),
                   activity: .discovered, "Looked through \(tally.opened) of \(files.count) document(s): \(tally.added) new ID(s) to confirm")
    }

    /// How every read that ran to its end ends, a refresh or the folders: what it read is
    /// sealed, its summary is the footer's, it is logged and kept in Activity, and the selection
    /// moves to a row still shown if its own went.
    /// The log line is made after the seal, so the time it gives counts it, as it always has.
    private func finishRead(_ summary: ReadingSummary, log: @autoclosure () -> String,
                            activity: VaultActivityEvent.Kind, _ what: String) {
        readingChanged = true
        saveReading()
        lastReading = summary
        Logger.shared.info(log())
        record(activity, what)
        if selection.flatMap(row) == nil { selection = visibleIDs.first }
    }

    /// A refresh of every ID is done: the older build's documents have been read again, and
    /// after a change of rules the rest of the folders are still to be looked at.
    private func finishRefresh(only: UUID?, afterNewRules: Bool) {
        // Every changed copy it was offered for has been read since (one ID's Refresh opens its
        // copies too): nothing is left to offer.
        if copiesChanged, !readIndex.values.contains(where: { $0.hasPrefix(Self.noticed) }) {
            needsDiscover = false
            copiesChanged = false
            readingChanged = true
        }
        guard only == nil else { return }
        if !staleSources.isEmpty { staleSources = []; readingChanged = true }
        if afterNewRules {
            needsReadAgain = false
            needsDiscover = true
            copiesChanged = false
            readingChanged = true
        }
        lastRefreshed = clock()
        // Kept with what was read, so the footer's time outlives the next lock, though a Refresh
        // with nothing to open changed nothing else.
        readingChanged = true
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

    nonisolated static func merged(_ copies: [VaultFind], speaking chosen: String? = nil) -> VaultFind? {
        VaultCopies.merged(copies, speaking: chosen)
    }

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

    /// The household person a file naming `row`'s ID is made out to, by name, when that is someone
    /// other than the ID's own person: "Sigrid" for her card printing only the subscriber's ID.
    /// Nil while the ID's person is not known, or the file is its person's own or nobody's.
    public func otherHolder(of path: String, for row: Row) -> String? {
        guard let own = row.personID, !row.isHousehold,
              let copy = copies[VaultReading.normalized(row.value)]?[path],
              let named = holders.person(of: copy), named != own else { return nil }
        return people.first { $0.id == named }?.displayName
    }

    /// `find` as all its documents now say, keeping its id and the user's choices.
    private func rebuilt(_ find: VaultFind, _ value: String) -> VaultFind {
        holders.rebuilt(find, from: copies[value])
    }

    /// Every waiting ID worked out again from its copies with the people and names as they now
    /// are: whose papers speak for one (``VaultHolders/split(_:owner:)``) turns on both, as a
    /// saved ID's does at every rows rebuild. Only while loaded, and only what changed is set: the
    /// next load works them out again anyway, so nothing is sealed for it.
    private func resplitWaiting() {
        guard contents == .loaded, !finds.isEmpty else { return }
        let holders = self.holders
        let again = finds.map { holders.rebuilt($0, from: copies[VaultReading.normalized($0.value)]) }
        if again != finds { finds = again }
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
    var readingChanged = false

    /// Seals To Confirm and the record of read files. A refusal is logged and otherwise let go:
    /// the next read rebuilds whatever was lost.
    /// What a later build stored in the reading file that this one does not read: sealed back
    /// with it (``VaultReadingState/laterFields``).
    private var readingLaterFields: Data?
    /// The user's own fields this build could not read (``VaultReadingState/unreadFields``).
    private var readingUnreadFields: Data?
    /// The reading file did not open and would not move aside, or the Keychain withheld its key
    /// (``VaultStore/ReadingLoad/keyRefused``): nothing is sealed over it until the Vault is
    /// opened again (VT24). People's Misread and roles chosen meanwhile are not kept.
    private var readingHeld = false

    /// Runs one action (Confirm, Add, Edit) so that every seal it asks for is one, at its end:
    /// each seal re-encodes and encrypts the whole reading file (VT65).
    private func sealingOnce<T>(_ action: () -> T) -> T {
        sealDepth += 1
        let result = action()
        sealDepth -= 1
        if sealDepth == 0 { saveReading() }
        return result
    }
    private var sealDepth = 0

    /// Everything read and chosen that is in memory, as the reading file seals it: what
    /// ``hold(_:)`` took from it, and every change since.
    var sealedReading: VaultReadingState {
        var state = VaultReadingState(generation: readGeneration, finds: finds, read: readIndex,
                                      mentions: mentions, copies: copies, choices: choices,
                                      needsReadAgain: needsReadAgain, lessons: lessons,
                                      staleSources: staleSources.isEmpty ? nil : staleSources.sorted(),
                                      notFound: missingDocuments.isEmpty ? nil : missingDocuments.sorted(),
                                      needsDiscover: needsDiscover ? true : nil,
                                      copiesChanged: copiesChanged ? true : nil,
                                      lastRefreshed: lastRefreshed, lastDiscovered: lastDiscovered, names: names,
                                      nameRoles: nameRoles.isEmpty ? nil : nameRoles,
                                      contacts: contacts.isEmpty ? nil : contacts,
                                      copyNumbers: copyNumbers.isEmpty ? nil : copyNumbers)
        state.laterFields = readingLaterFields
        state.unreadFields = readingUnreadFields
        return state
    }

    /// Holds what the reading file says, as ``VaultReadingState/opened(generation:people:)``
    /// gave it: ``sealedReading`` seals it again.
    private func hold(_ state: VaultReadingState) {
        finds = state.finds
        mentions = state.mentions
        copies = state.copies
        choices = state.choices
        readIndex = state.read
        lessons = state.lessons
        staleSources = Set(state.staleSources ?? [])
        missingDocuments = Set(state.notFound ?? [])
        needsDiscover = state.needsDiscover ?? false
        copiesChanged = needsDiscover && state.copiesChanged == true
        lastRefreshed = state.lastRefreshed
        lastDiscovered = state.lastDiscovered
        names = state.names
        nameRoles = state.nameRoles ?? [:]
        contacts = state.contacts ?? [:]
        copyNumbers = state.copyNumbers ?? [:]
        needsReadAgain = state.needsReadAgain
        readingLaterFields = state.laterFields
        readingUnreadFields = state.unreadFields
    }

    func saveReading() {
        // Within one action, the seal waits for its end (``sealingOnce(_:)``).
        guard sealDepth == 0 else { return }
        // Never once the numbers are let go: what is in memory then is nothing, and sealing it
        // would write that over what was read. Never over a damaged file that would not move.
        guard readingChanged, contents == .loaded, readOnly == nil, let store else { return }
        if keepsDocument {
            sealDocument(in: store)
            return
        }
        guard !readingHeld else { return }
        do {
            try seal(in: store)
        } catch VaultError.changedElsewhere {
            // Another SyncCloud sealed it since: what it holds that is the user's own is merged
            // with this copy's, and sealed again, once. Refused again, the next seal tries.
            guard mergeOtherCopysReading(from: store) else { return }
            do { try seal(in: store) } catch {
                Logger.shared.warning("Vault: To Confirm could not be sealed after another SyncCloud sealed it; the next seal tries again")
            }
        } catch {
            Logger.shared.warning("Vault: To Confirm could not be sealed; the next read finds it again")
        }
    }

    private func seal(in store: VaultStore) throws {
        readingOnDisk = try store.saveReading(sealedReading, expecting: readingOnDisk)
        readingBase = OwnReading(sealedReading)
        readingChanged = false
    }

    /// The reading file as this model last read or sealed it, for a seal to expect (VT111). Nil
    /// while nothing is loaded.
    private var readingOnDisk: VaultFileState?
    /// What was the user's own in it then: what a seal over another copy's merges against.
    private var readingBase: OwnReading?

    /// The fields of the reading file nothing reads back from a document: the user typed or
    /// chose them. What was read (copies, mentions, the read index) stays this copy's: a read
    /// finds it again. Waiting IDs are kept by number, for what was chosen about each.
    struct OwnReading: Equatable {
        var names: [String: String] = [:]
        var nameRoles: [String: VaultNameRoles] = [:]
        var contacts: [String: VaultContacts] = [:]
        var lessons: [String: VaultCardID] = [:]
        var choices: [String: VaultChoice] = [:]
        /// Each waiting ID's choices, by its number.
        var waiting: [String: VaultChoices] = [:]

        init() {}

        init(_ state: VaultReadingState) {
            names = state.names
            nameRoles = state.nameRoles ?? [:]
            contacts = state.contacts ?? [:]
            lessons = state.lessons
            choices = state.choices
            waiting = Dictionary(state.finds.map { (VaultReading.normalized($0.value), $0.choices) },
                                 uniquingKeysWith: { first, _ in first })
        }
    }

    /// How many times this model merged another copy's reading file, for a test.
    private(set) var readingMerges = 0

    /// Another SyncCloud sealed the reading file since this one read it: for each name, role,
    /// contact, lesson and choice, this copy's stands where it changed it since, and the other's
    /// everywhere else, so neither loses what was typed. Both changed one person's contacts or
    /// roles: merged field by field, a list keeping what each added and dropping what each
    /// removed. A waiting ID the other took out of To Confirm (confirmed, set aside) leaves it
    /// here too, unless this copy chose something about it since. False when the other's file
    /// does not open here: nothing is sealed over it, and the panel says so.
    private func mergeOtherCopysReading(from store: VaultStore) -> Bool {
        let (load, state) = store.openReadingAndState()
        let base = readingBase ?? OwnReading(), ours = OwnReading(sealedReading)
        let theirs: OwnReading
        switch load {
        case .loaded(let sealed):
            theirs = OwnReading(sealed)
            // What a later build stored in it goes on with it.
            readingLaterFields = sealed.laterFields
            readingUnreadFields = sealed.unreadFields
        case .none:
            // Gone: set aside by the other copy, or by this store for a key it had to make. Not a
            // sign anything typed was let go, so nothing is: this copy's stands, as before VT111.
            theirs = base
        case .keyRefused, .damaged:
            notice = "Another SyncCloud on this Mac saved what the Vault read in a form this one can’t open, so changes here to names, contacts and To Confirm aren’t kept. Quit one of them."
            Logger.shared.warning("Vault: another SyncCloud sealed a reading file this one cannot open; nothing is sealed over it")
            return false
        }
        let taken = mergeOwn(base: base, ours: ours, theirs: theirs)
        readingOnDisk = state
        readingBase = theirs
        readingMerges += 1
        // Counts only.
        Logger.shared.info("Vault: another SyncCloud sealed the reading file; merged with it, \(taken) waiting ID(s) it took out of To Confirm")
        return true
    }

    /// The user's own, merged with another copy's (VT111): for each name, role, contact, lesson and
    /// choice, this copy's where it changed it since `base`, the other's everywhere else; a waiting
    /// ID the other took out of To Confirm leaves it here too, unless this copy chose something
    /// about it since. Answers how many waiting IDs left.
    private func mergeOwn(base: OwnReading, ours: OwnReading, theirs: OwnReading) -> Int {
        names = Self.merged(base.names, ours.names, theirs.names) { _, ours, _ in ours }
        nameRoles = Self.merged(base.nameRoles, ours.nameRoles, theirs.nameRoles, both: Self.mergedRoles)
        contacts = Self.merged(base.contacts, ours.contacts, theirs.contacts, both: Self.mergedContacts)
        lessons = Self.merged(base.lessons, ours.lessons, theirs.lessons) { _, ours, _ in ours }
        choices = Self.merged(base.choices, ours.choices, theirs.choices) { _, ours, _ in ours }
        let taken = Set(ours.waiting.keys.filter { base.waiting[$0] != nil && theirs.waiting[$0] == nil
                                                   && ours.waiting[$0] == base.waiting[$0] })
        finds.removeAll { taken.contains(VaultReading.normalized($0.value)) }
        for index in finds.indices {
            let key = VaultReading.normalized(finds[index].value)
            if let chosen = theirs.waiting[key], ours.waiting[key] == base.waiting[key], chosen != base.waiting[key] {
                finds[index].choices = chosen
            }
        }
        resplitWaiting()
        // Lessons draw no row of their own: what they move is drawn again.
        objectWillChange.send()
        return taken.count
    }

    /// `ours` where this copy changed a key since `base`, `theirs` everywhere else; a key both
    /// changed is `both`'s.
    nonisolated static func merged<Value: Equatable>(_ base: [String: Value], _ ours: [String: Value], _ theirs: [String: Value],
                                                    both: (Value?, Value?, Value?) -> Value?) -> [String: Value] {
        var result = theirs
        for key in Set(base.keys).union(ours.keys) where ours[key] != base[key] {
            result[key] = theirs[key] == base[key] ? ours[key] : both(base[key], ours[key], theirs[key])
        }
        return result
    }

    /// A list both changed: the other's, with what this one added and without what it removed.
    nonisolated static func merged<Item: Equatable>(_ base: [Item], _ ours: [Item], _ theirs: [Item]) -> [Item] {
        let removed = base.filter { !ours.contains($0) }
        return theirs.filter { !removed.contains($0) } + ours.filter { !base.contains($0) && !theirs.contains($0) }
    }

    /// The household's kinds both copies changed, kind by kind: one changed here is this copy's,
    /// else the other's; one removed by either goes. Never two kinds with one id.
    nonisolated static func mergedKinds(_ base: [VaultCustomKind], _ ours: [VaultCustomKind], _ theirs: [VaultCustomKind]) -> [VaultCustomKind] {
        func byID(_ kinds: [VaultCustomKind]) -> [String: VaultCustomKind] {
            Dictionary(kinds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let merged = Self.merged(byID(base), byID(ours), byID(theirs)) { _, ours, theirs in theirs == nil ? nil : ours }
        var order: [String] = []
        for kind in ours + theirs where merged[kind.id] != nil && !order.contains(kind.id) { order.append(kind.id) }
        return order.compactMap { merged[$0] }
    }

    /// One field both may have changed: this copy's where it did.
    nonisolated static func merged<Field: Equatable>(_ base: Field, _ ours: Field, _ theirs: Field) -> Field {
        ours != base ? ours : theirs
    }

    /// One person's contacts both copies changed: list by list. Taken away by one and changed by
    /// the other, they stay: nothing typed is lost to a removal made beside it.
    nonisolated static func mergedContacts(_ base: VaultContacts?, _ ours: VaultContacts?, _ theirs: VaultContacts?) -> VaultContacts? {
        guard let ours, let theirs else { return ours ?? theirs }
        let base = base ?? VaultContacts()
        let result = VaultContacts(phones: merged(base.phones, ours.phones, theirs.phones),
                                   emails: merged(base.emails, ours.emails, theirs.emails),
                                   addresses: merged(base.addresses, ours.addresses, theirs.addresses),
                                   notTheirs: merged(base.notTheirs, ours.notTheirs, theirs.notTheirs),
                                   notTheirPhones: merged(base.notTheirPhones, ours.notTheirPhones, theirs.notTheirPhones))
        return result.isEmpty ? nil : result
    }

    /// One person's name roles both copies changed: role by role, the kept spellings as a list.
    nonisolated static func mergedRoles(_ base: VaultNameRoles?, _ ours: VaultNameRoles?, _ theirs: VaultNameRoles?) -> VaultNameRoles? {
        guard let ours, let theirs else { return ours ?? theirs }
        let base = base ?? VaultNameRoles()
        let result = VaultNameRoles(legal: merged(base.legal, ours.legal, theirs.legal),
                                    goesBy: merged(base.goesBy, ours.goesBy, theirs.goesBy),
                                    kept: merged(base.kept, ours.kept, theirs.kept))
        return result.isEmpty ? nil : result
    }

    /// Adds a find as an entry, as the editor left it, and takes it out of To Confirm.
    @discardableResult
    public func confirm(_ findID: UUID, as draft: Draft) -> UUID? {
        sealingOnce { confirming(findID, as: draft) }
    }

    private func confirming(_ findID: UUID, as draft: Draft) -> UUID? {
        if refusedReadOnly() { return nil }
        guard var find = find(id: findID) else { return nil }
        var draft = draft
        // Whose the editor says it is, when that is not what it waited as: worked out again for
        // that person, as Belongs To does, so that person's papers speak for it. The name, the
        // person and the documents saved then agree, though People changed while the editor was
        // up (Add to People re-splits every waiting ID).
        if draft.assignment != find.assignment, draft.assignment != nil {
            find.assignment = draft.assignment
            find = rebuilt(find, VaultReading.normalized(find.value))
        }
        // What was read stays with the number as it reads now, whatever the editor changed about
        // its name, and whichever copy it is read from: ``prepared(_:for:)`` puts a chosen copy's
        // name in the editor, and saved here it would outlive the choice.
        draft.facts = find.facts
        // Corrected into a number another waiting ID has: adding drops that one. What both numbers'
        // documents said, and it, are kept from before, for Undo.
        let correcting = VaultReading.normalized(draft.value) != VaultReading.normalized(find.value)
        let kept = correcting ? held(find.value, draft.value) : nil
        let dropping = correcting ? waiting(draft.value, except: findID) : []
        draft.chosenSource = find.chosenSource
        draft.readHolder = rows.first { $0.id == findID }?.holderAsRead
        // In the document, the find leaves To Confirm in the write that saves it: one write.
        guard let id = add(draft, savedFrom: find.sourcePath, droppingFind: findID) else { return nil }
        record(.confirmed, id: id)
        if correcting {
            corrected(find.value, to: draft.value, for: id, owned: [], before: nil, find: find, kept: kept, dropping: dropping)
        }
        finds.removeAll { $0.id == findID }
        if correcting { correctionSettled() }
        readingChanged = true
        saveReading()
        return id
    }

    /// Not This: takes a find out of To Confirm and keeps it out of later reads, across launches,
    /// until Settings ▸ Vault forgets the numbers set aside.
    public func setAside(_ findID: UUID) {
        if refusedReadOnly() { return }
        guard let find = find(id: findID) else { return }
        record(.setAside, find.title, whose: rows.first { $0.id == findID }?.whose, hidesEnding: find.category.hidesEnding)
        remember(find.value)
        finds.removeAll { $0.id == findID }
        copies[VaultReading.normalized(find.value)] = nil
        readingChanged = true
        saveReading()
        keepSelectionVisible()
    }

    // MARK: What a document reads for a corrected ID

    /// A file's size and SHA-256 (``VaultFileContents``), off the main actor: what a note knows a
    /// document by. A test hands in its own, for documents that are not on disk.
    var fileContents: @Sendable (URL) async -> String? = { file in
        await Task.detached(priority: .userInitiated) { VaultFileContents.key(of: file) }.value
    }

    /// The notes being written, one after another: each reads its documents' bytes first.
    private var noting: Task<Void, Never>?

    /// Waits for the notes being written, for a test.
    func notesWritten() async { await noting?.value }
    /// What each ID read as before a Refresh that was stopped, for the next one's Updated marks.
    private var refreshBaseline: [UUID: VaultReadFacts?] = [:]
    /// The correction each ID's note being written belongs to (``corrected(_:to:for:owned:before:find:logged:)``).
    private var noteFor: [UUID: UUID] = [:]

    /// A read number `read`, corrected by hand to `value`: what its documents said goes with the
    /// ID `id` saved as `value`, and each of them gets a note (``VaultReadAs``) of what it reads
    /// for it. Nothing is set aside: the misreading may be a relative's real ID on another card.
    /// A document `owned` already notes reads what its note says, not `read`, and keeps it.
    /// `before` is the saved ID as it was, for Edit; `find`, the waiting ID it was added from, for
    /// Add to Vault. Either is what Undo puts back, with `kept`, what the two numbers' documents
    /// said, and `dropping`, the waiting IDs with the new number that saving it drops: both as they
    /// were before the action began, taken now when not given. The action calls
    /// ``correctionSettled()`` once it is done.
    private func corrected(_ read: String, to value: String, for id: UUID, owned: [VaultReadAs],
                           before: VaultEntry?, find: VaultFind?, logged: VaultActivityEvent.Kind = .corrected,
                           kept: Held? = nil, dropping: [VaultFind]? = nil) {
        let old = VaultReading.normalized(read), new = VaultReading.normalized(value)
        let paths = Set((copies[old] ?? [:]).keys).union((mentions[old] ?? []).map(\.path))
        let kept = kept ?? held(read, value)
        let dropping = dropping ?? waiting(value, except: find?.id)
        if let moved = copies.removeValue(forKey: old) {
            for (path, var copy) in moved {
                copy.value = value
                copies[new, default: [:]][path] = copy
            }
        }
        if let named = mentions.removeValue(forKey: old) { mentions[new, default: []].append(contentsOf: named) }
        readingChanged = true
        saveReading()
        if let after = entry(id: id) {
            correctionUndo = CorrectionUndo(id: id, before: before, find: find, after: after,
                                            kept: kept, dropped: dropping)
            let file = (before?.facts ?? find?.facts)?.primary.map { ($0.path as NSString).lastPathComponent }
            lastCorrection = Correction(id: id, file: file, changed: Self.charactersChanged(old, new))
        }
        record(logged, id: id)
        guard !paths.isEmpty else { return }
        let earlier = noting, contentsOf = fileContents
        let owned = Set(owned.map(\.contents))
        // This correction's own: an Undo, or a later correction of the same ID, takes it back, so
        // a note still being written then lands on nothing (the second review: a Merge that kept
        // the saved number left it the same number, which the check by number let through).
        let token = UUID()
        noteFor[id] = token
        noting = Task { [weak self] in
            await earlier?.value
            var notes: [VaultReadAs] = []
            for path in paths.sorted() {
                guard let contents = await contentsOf(URL(fileURLWithPath: path)), !owned.contains(contents),
                      !notes.contains(where: { $0.contents == contents }) else { continue }
                notes.append(VaultReadAs(contents: contents, reads: old))
            }
            guard let self, self.noteFor[id] == token else {
                Logger.shared.info("Vault: a corrected ID's note was not written; its correction was undone")
                return
            }
            self.noteFor[id] = nil
            self.note(notes, for: id, as: new, of: paths.count)
        }
    }

    /// Adds `notes` to the saved ID `id`, once its documents were read for them, while it is still
    /// `value`: an ID put back by Undo meanwhile gets none.
    private func note(_ notes: [VaultReadAs], for id: UUID, as value: String, of documents: Int, retry: Bool = true) {
        guard contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }),
              VaultReading.normalized(entries[index].value) == value else {
            Logger.shared.info("Vault: a corrected ID's note was not written; the Vault locked, or the ID went or changed")
            return
        }
        if notes.isEmpty {
            Logger.shared.info("Vault: none of a corrected ID's \(documents) document(s) could be read for a note; "
                               + "its old reading may come back To Confirm")
            return
        }
        var changed = entries
        var kept = changed[index].readAs ?? []
        for note in notes where !kept.contains(where: { $0.contents == note.contents }) { kept.append(note) }
        guard kept != (changed[index].readAs ?? []) else { return }
        changed[index].readAs = kept
        guard write(changed, quietly: true) else {
            // Refused because another SyncCloud saved: the IDs were read again, and the note goes
            // onto them once, if the ID is still there and still this number.
            if retry, onDisk != nil { note(notes, for: id, as: value, of: documents, retry: false) }
            return
        }
        Logger.shared.info("Vault: a corrected ID keeps a note for \(notes.count) of its \(documents) document(s)")
    }

    /// A correction just made: what the pane says under the ID, with Undo.
    public struct Correction: Equatable, Sendable {
        public let id: UUID
        /// The document the ID was read from, by name.
        public let file: String?
        /// How many characters were changed, when the two are the same length.
        public let changed: Int?
        /// A waiting ID merged into this one (Merge…), not a number fixed.
        public let merged: Bool

        public init(id: UUID, file: String?, changed: Int?, merged: Bool = false) {
            self.id = id
            self.file = file
            self.changed = changed
            self.merged = merged
        }
    }

    /// The last correction, until the selection moves off it, Undo, or the Vault locks.
    @Published public private(set) var lastCorrection: Correction?

    /// What Undo puts back: the saved ID as it was (or none, for one added from To Confirm, whose
    /// waiting ID comes back), what its documents said, by number, and the waiting IDs saving the
    /// new number dropped. `left` is what the correction left those numbers' documents saying: a
    /// read since that changed it (a file printing either number) is not undone over. Kept in
    /// memory only, and let go when the Vault locks.
    private struct CorrectionUndo {
        let id: UUID
        let before: VaultEntry?
        let find: VaultFind?
        let after: VaultEntry
        let kept: Held
        let dropped: [VaultFind]
        var left: Held?
    }
    private var correctionUndo: CorrectionUndo?

    /// What two numbers' documents said, by number: what a correction moves from one to the other.
    struct Held: Equatable {
        let copies: [String: [String: VaultFind]?]
        let mentions: [String: [VaultSource]?]
    }

    private func held(_ a: String, _ b: String) -> Held {
        held([VaultReading.normalized(a), VaultReading.normalized(b)])
    }

    private func held(_ keys: [String]) -> Held {
        Held(copies: Dictionary(keys.map { ($0, copies[$0]) }, uniquingKeysWith: { first, _ in first }),
             mentions: Dictionary(keys.map { ($0, mentions[$0]) }, uniquingKeysWith: { first, _ in first }))
    }

    /// The waiting IDs holding `value`, other than `id`.
    private func waiting(_ value: String, except id: UUID?) -> [VaultFind] {
        let key = VaultReading.normalized(value)
        return finds.filter { $0.id != id && VaultReading.normalized($0.value) == key }
    }

    /// The action that made a correction is done: what it left its numbers' documents saying is
    /// what Undo checks for.
    private func correctionSettled() {
        guard let undo = correctionUndo else { return }
        correctionUndo?.left = held(Array(undo.kept.copies.keys))
    }

    /// Whether Undo would still put the last correction back: the ID, and what its numbers'
    /// documents say, as the correction left them (notes written since aside).
    private func correctionUndoable(_ undo: CorrectionUndo) -> Bool {
        guard contents == .loaded, let entry = entry(id: undo.id),
              let left = undo.left, held(Array(undo.kept.copies.keys)) == left else { return false }
        var current = entry
        current.readAs = undo.after.readAs
        return current == undo.after
    }

    /// A read took something for the last correction's numbers: its Undo goes, rather than wait
    /// to be refused.
    private func dropStaleCorrection() {
        guard let undo = correctionUndo, !correctionUndoable(undo) else { return }
        correctionUndo = nil
        lastCorrection = nil
    }

    /// The characters `a` and `b` differ in, place by place; nil when their lengths differ.
    nonisolated static func charactersChanged(_ a: String, _ b: String) -> Int? {
        guard a.count == b.count else { return nil }
        return zip(a, b).filter { $0 != $1 }.count
    }

    /// The pane's note went: the selection moved on.
    public func dismissCorrection() { lastCorrection = nil }

    /// Undo: puts back what the last correction changed, while the ID, and what its numbers'
    /// documents say, are as the correction left them (notes written since aside). An ID added
    /// from To Confirm goes, and waits there again; an edited one has its number, and its notes,
    /// back; a waiting ID the corrected number dropped waits again. Nothing was set aside, so
    /// nothing is let out again.
    @discardableResult
    public func undoCorrection() -> Bool {
        if refusedReadOnly() { return false }
        guard let undo = correctionUndo, contents == .loaded,
              let index = entries.firstIndex(where: { $0.id == undo.id }) else { return false }
        guard correctionUndoable(undo) else {
            correctionUndo = nil
            lastCorrection = nil
            return false
        }
        let title = entries[index].title
        let secretEnding = entries[index].category.hidesEnding
        var changed = entries
        if let before = undo.before { changed[index] = before } else { changed.remove(at: index) }
        // What comes back to To Confirm is held before the write, so the saved IDs and the waiting
        // ones change in one write (the final review); let go again if it is refused.
        let copiesBefore = undo.kept.copies.keys.map { ($0, copies[$0]) }
        let mentionsBefore = undo.kept.mentions.keys.map { ($0, mentions[$0]) }
        for (key, value) in undo.kept.copies { copies[key] = value }
        for (key, value) in undo.kept.mentions { mentions[key] = value }
        var returned: Set<UUID> = []
        for find in [undo.find].compactMap({ $0 }) + undo.dropped where !finds.contains(where: { $0.id == find.id }) {
            finds.append(find)
            returned.insert(find.id)
        }
        // Let go if refused, before a refusal's merge with another copy seals what is held (the
        // second review); once only, whichever comes first.
        var letGoDone = false
        let letGo = { [weak self] in
            guard let self, !letGoDone else { return }
            letGoDone = true
            self.finds.removeAll { returned.contains($0.id) }
            for (key, value) in copiesBefore { self.copies[key] = value }
            for (key, value) in mentionsBefore { self.mentions[key] = value }
        }
        refusedWriteLetsGo = letGo
        defer { refusedWriteLetsGo = nil }
        guard write(changed) else {
            letGo()
            return false
        }
        if let find = undo.find { selection = find.id }
        readingChanged = true
        saveReading()
        record(.other, (lastCorrection?.merged == true ? "Undid the merge into " : "Undid the correction of ") + title,
               hidesEnding: secretEnding)
        noteFor[undo.id] = nil
        correctionUndo = nil
        lastCorrection = nil
        return true
    }

    // MARK: Merge

    /// A saved ID a waiting one could be a second reading of, and how many characters apart.
    public struct MergeCandidate: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let differ: Int
    }

    /// The most characters a saved ID may differ by to be listed in Merge's sheet.
    static let mergeListed = 3
    /// The most it may differ by for the pane to offer Merge… by itself.
    static let mergeOffered = 2

    /// The saved IDs the waiting ID `findID` could be another reading of: the same person's (or
    /// the household's, for a household ID), of the same Kind, at most ``mergeListed`` characters
    /// away, closest first.
    public func mergeCandidates(for findID: UUID) -> [MergeCandidate] {
        guard let find = rows.first(where: { $0.id == findID }), !find.isSaved else { return [] }
        let value = VaultReading.normalized(find.value)
        return rows.compactMap { row -> MergeCandidate? in
            guard row.isSaved, row.category == find.category, row.isHousehold == find.isHousehold,
                  row.isHousehold || (row.personID != nil && row.personID == find.personID) else { return nil }
            let differ = Self.editDistance(value, VaultReading.normalized(row.value))
            guard differ > 0, differ <= Self.mergeListed else { return nil }
            return MergeCandidate(id: row.id, differ: differ)
        }
        .sorted { $0.differ < $1.differ }
    }

    /// The saved ID the pane offers Merge… with, by itself: the closest candidate, a character or
    /// two away. Not when the names the two cards print differ, nor when only their last one or
    /// two characters do, which is how a family's IDs on one plan most often differ.
    public func mergeSuggestion(for findID: UUID) -> MergeCandidate? {
        guard let best = mergeCandidates(for: findID).first, best.differ <= Self.mergeOffered,
              let find = rows.first(where: { $0.id == findID }),
              let saved = rows.first(where: { $0.id == best.id }) else { return nil }
        let a = VaultReading.normalized(find.value), b = VaultReading.normalized(saved.value)
        if a.count == b.count {
            let places = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
            if places.allSatisfy({ $0 >= a.count - 2 }) { return nil }
        }
        if let one = Self.nameKey(find.holderAsRead), let other = Self.nameKey(saved.holderAsRead), one != other { return nil }
        return best
    }

    /// A printed name's letters, upper case, for telling two cards' names apart.
    private static func nameKey(_ name: String?) -> String? {
        let letters = (name ?? "").uppercased().filter(\.isLetter)
        return letters.isEmpty ? nil : letters
    }

    /// The characters to add, drop or change to make `a` into `b`.
    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
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

    /// Merge: the waiting ID `findID` is another reading of the saved ID `entryID`. Its files
    /// join the saved one, whose Read from file stays its own; the number not kept becomes a
    /// note of what its documents read (``VaultReadAs``), so nothing is set aside everywhere.
    /// `keepingReading` keeps the waiting ID's number instead of the saved one's. Undo puts both
    /// back, until the Vault locks.
    @discardableResult
    public func merge(_ findID: UUID, into entryID: UUID, keepingReading: Bool) -> Bool {
        sealingOnce { merging(findID, into: entryID, keepingReading: keepingReading) }
    }

    private func merging(_ findID: UUID, into entryID: UUID, keepingReading: Bool) -> Bool {
        if refusedReadOnly() { return false }
        guard contents == .loaded, let find = find(id: findID),
              let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        let before = entries[index]
        used()
        if keepingReading {
            var changed = entries
            changed[index].value = find.value
            changed[index].updatedAt = clock()
            guard write(changed) else { return false }
            // The saved ID's own documents read its old number: they keep a note of it.
            corrected(before.value, to: find.value, for: entryID, owned: before.readAs ?? [],
                      before: before, find: find, logged: .merged)
        } else {
            corrected(find.value, to: before.value, for: entryID, owned: before.readAs ?? [],
                      before: before, find: find, logged: .merged)
        }
        finds.removeAll { $0.id == findID }
        correctionSettled()
        readingChanged = true
        saveReading()
        let file = find.facts.primary.map { ($0.path as NSString).lastPathComponent }
        lastCorrection = Correction(id: entryID, file: file, changed: nil, merged: true)
        selection = entryID
        showEvenIfFiltered(entryID)
        return true
    }

    /// The saved ID, other than `id`, that already holds `value`: the editor will not add or
    /// change an ID into one the Vault has, and says whose it is.
    public func savedRow(holding value: String, excluding id: UUID?) -> Row? {
        let key = VaultReading.normalized(value)
        guard !key.isEmpty else { return nil }
        return rows.first { $0.isSaved && $0.id != id && VaultReading.normalized($0.value) == key }
    }

    /// The ID holding `value` whose number the lock does not let the panel draw now, if any: a
    /// card's other ID that is in the Vault is drawn in full only once it may be.
    public func lockedRow(holding value: String) -> UUID? {
        let key = VaultReading.normalized(value)
        return rows.first { VaultReading.normalized($0.value) == key && !lock.canShow($0.id, at: now) }?.id
    }

    /// What a saved ID's documents read for it where that is not its number, each once.
    public func readings(of id: UUID) -> [String] {
        var seen: [String] = []
        for note in entry(id: id)?.readAs ?? [] where !seen.contains(note.reads) {
            seen.append(note.reads)
        }
        return seen
    }

    /// Forget: drops what a saved ID's documents were noted to read for it, after a proof when one
    /// is owed. The next read of those documents offers what they read To Confirm again.
    @discardableResult
    public func forgetReadings(of id: UUID) async -> Bool {
        guard let title = entry(id: id)?.title else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("change \(title)", for: id) else { return false }
        }
        guard contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].readAs != nil else { return false }
        var changed = entries
        changed[index].readAs = nil
        used()
        return write(changed)
    }

    /// Each file a saved ID's note knows, by its bytes: what it reads, and the number that is
    /// read instead.
    private func readAsByContents() -> [String: [String: String]] {
        var notes: [String: [String: String]] = [:]
        for entry in entries {
            for note in entry.readAs ?? [] { notes[note.contents, default: [:]][note.reads] = entry.value }
        }
        return notes
    }

    /// Each file a saved ID was taken off (Not for This ID), by its bytes: the numbers it is not for.
    private func notOnByContents() -> [String: Set<String>] {
        var off: [String: Set<String>] = [:]
        for entry in entries {
            for contents in entry.notOn ?? [] { off[contents, default: []].insert(VaultReading.normalized(entry.value)) }
        }
        return off
    }

    /// Not for This ID: the document at `path` names the saved ID `id` but is not for it (a claim
    /// listing it, another person's card). It comes off the ID's list, remembered for its bytes so
    /// a move does not bring it back, and is marked unread: the next Discover More reads it
    /// without this ID, so an ID of its own can come up To Confirm, even when a correction noted
    /// it as reading the ID. Never the file it is read from: Read from This Copy on another copy
    /// changes that.
    @discardableResult
    public func notForThisID(_ id: UUID, path: String) async -> Bool {
        if refusedReadOnly() { return false }
        guard let row = rows.first(where: { $0.id == id }), row.isSaved,
              row.documents.first?.path != path, row.documents.contains(where: { $0.path == path }) else { return false }
        guard let bytes = await fileContents(URL(fileURLWithPath: path)) else {
            notice = "That file couldn’t be read, so it stays with the ID. Is it still there?"
            return false
        }
        guard contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        used()
        var changed = entries
        if !(changed[index].notOn ?? []).contains(bytes) { changed[index].notOn = (changed[index].notOn ?? []) + [bytes] }
        // A note from a correction that took this file for the ID goes too: it would turn what the
        // file reads into this ID's number, which is then dropped, so nothing ever came up.
        changed[index].readAs?.removeAll { $0.contents == bytes }
        if changed[index].readAs?.isEmpty == true { changed[index].readAs = nil }
        changed[index].facts?.sources.removeAll { $0.path == path }
        guard write(changed) else { return false }
        let key = VaultReading.normalized(changed[index].value)
        copies[key]?[path] = nil
        if copies[key]?.isEmpty == true { copies[key] = nil }
        mentions[key]?.removeAll { $0.path == path }
        if mentions[key]?.isEmpty == true { mentions[key] = nil }
        readIndex[path] = nil
        // Read again, never passed over on what it gave before (VT107 step 3).
        copyNumbers[path] = nil
        readingChanged = true
        saveReading()
        record(.takenOff, id: id)
        return true
    }

    // MARK: Fields added by hand

    /// Labels whose value is a plan's code, printed on every card of the plan and read out to any
    /// pharmacy: shown as printed, never hidden like an ID.
    nonisolated static let planCodeLabels: Set<String> = ["rxbin", "rxpcn", "bin", "pcn", "payer id", "rx bin", "rx pcn"]

    /// How an added field is drawn: a plan code as printed, a value with four digits or more
    /// hidden like an ID until the lock allows, anything else as text.
    public nonisolated static func fieldValue(label: String, value: String) -> VaultDetail.Value {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if planCodeLabels.contains(label.lowercased().trimmingCharacters(in: .whitespaces)) { return .text(trimmed) }
        return trimmed.filter(\.isNumber).count >= 4 ? .number(trimmed) : .text(trimmed)
    }

    /// Adds a field to the saved ID `id`: `hidden` nil goes by ``fieldValue(label:value:)``.
    /// Only on an ID read from a document, whose details it joins. A proof first when one is owed.
    @discardableResult
    public func addField(_ id: UUID, label: String, value: String, hidden: Bool? = nil) async -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !value.isEmpty, let entry = entry(id: id), entry.facts != nil else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("change \(entry.title)", for: id) else { return false }
        }
        guard contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let drawn: VaultDetail.Value = hidden.map { $0 ? .number(value) : .text(value) } ?? Self.fieldValue(label: label, value: value)
        let field = VaultDetail(label, drawn)
        guard !(entries[index].fields ?? []).contains(field) else { return true }
        used()
        var changed = entries
        changed[index].fields = (changed[index].fields ?? []) + [field]
        changed[index].updatedAt = clock()
        return write(changed)
    }

    /// Removes the field at `index` from the saved ID `id`'s added fields.
    @discardableResult
    public func removeField(_ id: UUID, at index: Int) async -> Bool {
        guard let entry = entry(id: id), (entry.fields ?? []).indices.contains(index) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("change \(entry.title)", for: id) else { return false }
        }
        guard contents == .loaded, let at = entries.firstIndex(where: { $0.id == id }),
              (entries[at].fields ?? []).indices.contains(index) else { return false }
        used()
        var changed = entries
        changed[at].fields?.remove(at: index)
        if changed[at].fields?.isEmpty == true { changed[at].fields = nil }
        changed[at].updatedAt = clock()
        return write(changed)
    }

    /// What More fields offers from `values`, read off a saved ID's card: not the ID itself or a
    /// piece of it (a passport number read as "V" and "7531864"), not another ID the Vault holds
    /// (a subscriber's on a dependent's card is another person's), nothing its details already
    /// show, and nothing the user dismissed for it.
    public func moreFields(_ values: [VaultCardValue], for id: UUID) -> [VaultCardValue] {
        guard let row = rows.first(where: { $0.id == id }) else { return [] }
        let held = Set(rows.map { VaultReading.normalized($0.value) })
        let shown = Set((row.facts?.details ?? []).map { VaultReading.normalized($0.copied) })
        let dismissed = Set(entry(id: id)?.notFields ?? [])
        return values.filter { value in
            let key = VaultReading.normalized(value.value)
            return !held.contains { Self.overlaps(key, $0) } && !shown.contains(key) && !dismissed.contains(key)
        }
    }

    /// Whether two normalized values are one number, or one is a piece of the other at least five
    /// characters long: what a card prints around a number, or a number split where it has a space.
    nonisolated static func overlaps(_ one: String, _ other: String) -> Bool {
        if one == other { return true }
        let (short, long) = one.count < other.count ? (one, other) : (other, one)
        return short.count >= 5 && long.contains(short)
    }

    /// How many values on this card the user dismissed for the saved ID `id`.
    public func dismissedFields(_ values: [VaultCardValue], for id: UUID) -> Int {
        let dismissed = Set(entry(id: id)?.notFields ?? [])
        return Set(values.map { VaultReading.normalized($0.value) }).intersection(dismissed).count
    }

    /// The X beside a value in More fields: it is not a field of the saved ID `id`, and is never
    /// offered for it again. Nothing is shown by it, so it asks for no proof.
    @discardableResult
    public func dismissField(_ id: UUID, value: String) -> Bool {
        let key = VaultReading.normalized(value)
        guard !key.isEmpty, contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        guard !(entries[index].notFields ?? []).contains(key) else { return true }
        used()
        var changed = entries
        changed[index].notFields = (changed[index].notFields ?? []) + [key]
        changed[index].updatedAt = clock()
        return write(changed)
    }

    /// Show Dismissed: every value dismissed for the saved ID `id` is offered again.
    @discardableResult
    public func restoreDismissedFields(_ id: UUID) -> Bool {
        guard contents == .loaded, let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].notFields != nil else { return false }
        used()
        var changed = entries
        changed[index].notFields = nil
        changed[index].updatedAt = clock()
        return write(changed)
    }

    /// `read` with every number `instead` names given as the number a note says it is for.
    nonisolated static func reading(_ read: (finds: [VaultFind], mentions: [VaultMention]),
                                    instead: [String: String]) -> (finds: [VaultFind], mentions: [VaultMention]) {
        var read = read
        for index in read.finds.indices {
            if let value = instead[VaultReading.normalized(read.finds[index].value)] { read.finds[index].value = value }
        }
        for index in read.mentions.indices {
            if let value = instead[VaultReading.normalized(read.mentions[index].value)] { read.mentions[index].value = value }
        }
        return read
    }

    // MARK: Reading one card

    /// What reading one card for the editor came to (``readCard(_:with:)``).
    public enum CardReading: Equatable, Sendable {
        /// Every labeled value it prints (``VaultReading/cardValues(on:)``).
        case read([VaultCardValue])
        /// It is not where the Vault last saw it: Discover More finds a card that moved.
        case notFound
        /// It is there, and nothing could be read from it.
        case unreadable
    }

    /// Each card read for the editor, by path, with the size and date it was read at: read again
    /// only once it changes. Values in full, so in memory only, and never used past a lock: each
    /// is kept with the lock's epoch it was read in, and let go with the numbers.
    private var cardReadings: [String: (stamp: String, epoch: Int, values: [VaultCardValue])] = [:]

    /// Every labeled value the card at `path` prints, read with `reader` the first time (about a
    /// second a page for a scan), and kept for its size and date after that.
    public func readCard(_ path: String, with reader: VaultDocumentReading) async -> CardReading {
        let file = URL(fileURLWithPath: path)
        let (there, stamp) = await Task.detached { (reader.exists(file), reader.stamp(of: file)) }.value
        guard there else { return .notFound }
        if let stamp, let kept = cardReadings[path], kept.stamp == stamp, kept.epoch == session.epoch {
            return .read(kept.values)
        }
        let epoch = session.epoch
        let pages = await reader.reading(file).pages
        guard pages.contains(where: { !$0.isEmpty }) else { return .unreadable }
        let values = VaultReading.cardValues(on: pages)
        // Locked while it was read: nothing is kept for a Vault that let its numbers go.
        if let stamp, session.stands(epoch), contents == .loaded { cardReadings[path] = (stamp, epoch, values) }
        return .read(values)
    }

    /// Records a number as not to be offered again: its keyed fingerprint in UserDefaults, or,
    /// when the Keychain will not give one, a hash for this run.
    /// In the document (VT6) the fingerprint is held with it, and sealed by the caller's seal;
    /// read-only, for this run only.
    private func remember(_ value: String) {
        if readOnly == nil, let fingerprint = store?.fingerprint(value, makingKey: true) {
            if keepsDocument {
                setAsideFingerprints.insert(fingerprint)
                readingChanged = true
            } else {
                VaultSetAside.add(fingerprint, in: defaults)
            }
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
        return !(keepsDocument ? setAsideFingerprints : VaultSetAside.fingerprints(in: defaults)).contains(fingerprint)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(VaultReading.normalized(value).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: The v7.2 document (VT6)

    /// Why the Vault opened read-only: nothing is written while it is (no document, cache,
    /// set-aside number or pruning), and the panel says why.
    public enum ReadOnly: Equatable, Sendable {
        /// A newer SyncCloud saved it, in a format this build reads but must not write.
        case newerFormat
        /// Another SyncCloud is running, and the v1 files could not be migrated under it.
        case anotherCopyRunning
    }

    /// Set while the Vault is open read-only; nil otherwise. The panel's notice says why.
    @Published public private(set) var readOnly: ReadOnly? {
        didSet { if let readOnly, readOnly != oldValue { notice = Self.message(for: readOnly) } }
    }

    /// Whether a change is refused because the Vault is open read-only: the notice then says why,
    /// before anything is changed in memory that could not be saved.
    func refusedReadOnly() -> Bool {
        guard let readOnly else { return false }
        notice = Self.message(for: readOnly)
        return true
    }

    public static func message(for readOnly: ReadOnly) -> String {
        switch readOnly {
        case .newerFormat:
            return "A newer version of SyncCloud saved this Vault, so it opens here to read only. Changes aren’t saved."
        case .anotherCopyRunning:
            return "Another SyncCloud on this Mac is running, so the Vault opens to read only. Quit it to make changes."
        }
    }

    public var isReadOnly: Bool { readOnly != nil }

    /// The Vault's file is the v7.2 document, as the last load found (``VaultStore/keepsDocument``):
    /// saved IDs, waiting IDs and the user's own data sealed in one, what reading finds again in
    /// the cache.
    private(set) var keepsDocument = false

    /// Whether the Vault is kept as a document: as loaded, or, before a load, as the file says.
    private var documentMode: Bool { contents == .loaded ? keepsDocument : (store?.keepsDocument ?? false) }

    /// The document as this model last read or wrote it: what the next write compares with, and
    /// what a merge with another copy's works from. Nil while nothing is on disk.
    private var documentBase: VaultDocument?
    /// The cache as last read or written: written again only when it changes.
    private var cacheWritten: VaultCache?
    /// The cache file as this model last read or wrote it, to notice another copy's.
    private var cacheOnDisk: VaultFileState?
    /// The numbers set aside, as fingerprints, in the document.
    private var setAsideFingerprints: Set<String> = []
    /// Fingerprints taken in from UserDefaults at this load (a migration's step 5 left undone):
    /// the key goes once a write holds them.
    private var fingerprintsFromDefaults: [String] = []
    /// A document begun here took the moved keys' values: they go once it is written.
    private var removeMovedKeysOnWrite = false
    /// How many times this model wrote the document, and the cache, for a test.
    private(set) var documentWrites = 0
    private(set) var cacheWrites = 0

    /// How many numbers are set aside, for Settings ▸ Vault: the document's while it is kept,
    /// else UserDefaults'. Nil while the document is not open: it holds them, sealed.
    public var setAsideCount: Int? {
        guard documentMode else { return VaultSetAside.fingerprints(in: defaults).count }
        return contents == .loaded ? setAsideFingerprints.count : nil
    }

    /// Settings ▸ Vault ▸ Forget, wherever the numbers are kept: the next read offers everything
    /// again, every file read again. In the document, only while it is loaded and may be written.
    @discardableResult
    public func forgetSetAside() -> Bool {
        if refusedReadOnly() { return false }
        guard documentMode else {
            VaultSetAside.forget(in: defaults)
            return true
        }
        guard contents == .loaded, readOnly == nil else { return false }
        setAsideFingerprints = []
        setAsideThisRun = []
        readGeneration += 1
        readIndex = [:]
        copyNumbers = [:]
        readingChanged = true
        saveReading()
        return documentBase?.setAside.generation == readGeneration
    }

    /// Loads the document: its saved and waiting IDs, the user's own data, and what the cache
    /// holds. A document a later build wrote opens read-only. A waiting ID whose number is saved
    /// leaves To Confirm, its documents kept as documents of the saved one (as ``dropFinds(matching:)``).
    private func loadDocument(from store: VaultStore) {
        do {
            let loaded = try store.loadDocument()
            var document: VaultDocument
            if let loaded {
                document = loaded.document
            } else {
                // Begun here, with the migration on: the moved keys' values are where it starts.
                let owned = store.ownsMovedKeys(in: defaults)
                let values = owned ? VaultMigration.Legacy.values(in: defaults) : (setAside: nil, generation: nil, customKinds: nil)
                let legacy = VaultMigration.Legacy(setAside: values.setAside, generation: values.generation,
                                                   customKinds: values.customKinds)
                let taken = (try? VaultMigration.migrate(legacy, keyID: "", at: clock()))?.document
                document = taken
                    ?? VaultDocument(entries: [], state: VaultReadingState(), setAside: .init(), kinds: [], savedAt: clock())
                document.migratedFrom = nil
                // Cleared at the first write only once taken in: keys it could not read stay.
                removeMovedKeysOnWrite = owned && taken != nil && VaultMigration.movedKeys.contains { defaults.object(forKey: $0) != nil }
            }
            let saved = try document.entries()
            let state = try document.readingState(cache: loaded?.cache)
            if loaded?.readOnly == true { readOnly = .newerFormat }
            entries = saved
            newerRecords = loaded?.unread ?? 0
            onDisk = loaded?.onDisk ?? .absent
            documentBase = loaded?.document
            cacheWritten = loaded?.cache.flatMap { $0.fits(document) ? $0 : nil }
            cacheOnDisk = store.cacheState()
            readGeneration = document.setAside.generation
            setAsideFingerprints = Set(document.setAside.fingerprints)
            kinds = VaultKinds(custom: document.kinds.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
            readingHeld = false
            readingOnDisk = nil
            contents = .loaded
            let opened = state.opened(generation: readGeneration, people: people)
            hold(opened.state)
            readingChanged = opened.changed
            readingBase = OwnReading(state)
            if readOnly == nil, let loaded {
                store.finishMigration(of: loaded.document, defaults: defaults)
                fingerprintsFromDefaults = store.setAsideLeftInDefaults(by: loaded.document, defaults: defaults)
                if !fingerprintsFromDefaults.isEmpty {
                    setAsideFingerprints.formUnion(fingerprintsFromDefaults)
                    readingChanged = true
                }
            }
            rowsRevision &+= 1
            sealingOnce {
                for entry in saved { dropFinds(matching: entry.value) }
                dropOrphanedCopies(laterFields: false)
            }
            logSession("Vault: loaded, \(entries.count) saved ID(s) and \(finds.count) to confirm"
                       + (readOnly == nil ? "" : ", read-only") + "; " + Self.lockMode(lock.settings))
            keepSelectionVisible()
        } catch {
            entries = []
            newerRecords = 0
            contents = .unreadable(error as? VaultError ?? .unreadableFile)
        }
    }

    /// The document as this model holds it now: `entries` in place of the saved IDs when given,
    /// without a waiting ID whose number is saved or `dropping`, and with `fingerprint` set aside.
    func currentDocument(entries changed: [VaultEntry]? = nil, dropping: UUID? = nil, fingerprint: String? = nil) -> VaultDocument {
        let saved = changed ?? entries
        var state = sealedReading
        let numbers = Set(saved.map { VaultReading.normalized($0.value) })
        state.finds.removeAll { $0.id == dropping || numbers.contains(VaultReading.normalized($0.value)) }
        var fingerprints = setAsideFingerprints
        if let fingerprint { fingerprints.insert(fingerprint) }
        return VaultDocument(entries: saved, state: state,
                             setAside: .init(generation: readGeneration, keyID: documentBase?.setAside.keyID ?? "",
                                             fingerprints: fingerprints.sorted()),
                             kinds: kinds.custom, savedAt: clock(), migratedFrom: documentBase?.migratedFrom)
    }

    /// Writes `document` over the one this model last saw, and keeps it as the next write's base.
    private func seal(_ document: VaultDocument, in store: VaultStore) throws {
        let written = try store.saveDocument(document, expecting: onDisk)
        onDisk = written.onDisk
        documentBase = written.document
        documentWrites += 1
        if removeMovedKeysOnWrite {
            for key in VaultMigration.movedKeys { defaults.removeObject(forKey: key) }
            removeMovedKeysOnWrite = false
        }
        if !fingerprintsFromDefaults.isEmpty, Set(written.document.setAside.fingerprints).isSuperset(of: fingerprintsFromDefaults) {
            defaults.removeObject(forKey: VaultSetAside.key)
            fingerprintsFromDefaults = []
        }
    }

    /// ``write(_:quietly:droppingFind:fingerprint:)`` for the document: one atomic write of the
    /// saved IDs with everything else it holds. Refused because another SyncCloud saved it
    /// meanwhile (VT108), the other's saved IDs take this copy's place, the rest is merged
    /// (``mergeOtherCopysDocument()``), and the change asked for is not made.
    /// What a change held in memory before its write (Kind's lesson, Undo's waiting IDs), let go
    /// by a refused write before the other copy's merge is sealed, so none of it reaches the disk.
    private var refusedWriteLetsGo: (() -> Void)?

    private func writeDocument(_ changed: [VaultEntry], quietly: Bool, droppingFind: UUID?, fingerprint: String?,
                               naming: NameCorrection?) -> Bool {
        guard let store else { return false }
        func written() throws -> Bool {
            var document = currentDocument(entries: changed, dropping: droppingFind, fingerprint: fingerprint)
            // A correction made everywhere goes in the same write; it is made in memory only once
            // that write is on disk (``apply(_:)``, VT63), which then finds nothing left to write.
            if let naming { document.names[naming.key] = naming.name }
            try seal(document, in: store)
            entries = changed
            if let fingerprint { setAsideFingerprints.insert(fingerprint) }
            notice = nil
            return true
        }
        do {
            return try written()
        } catch VaultError.changedElsewhere {
            // The saved IDs this copy's change was made against.
            let ownSaved = documentBase.flatMap { try? $0.entries() }
            guard mergeOtherCopysDocument() else { return false }
            // The other copy changed no saved ID (it read documents, typed a contact, set a number
            // aside): nothing this change was made against moved, so it is written over the merge,
            // once. A saved ID it changed is refused, as for a v1 Vault (VT108).
            if let ownSaved, ownSaved == entries, (try? written()) == true { return true }
            if !quietly { notice = Self.message(for: .changedElsewhere) }
            // What the refused change held in memory goes before the merge is sealed.
            refusedWriteLetsGo?()
            refusedWriteLetsGo = nil
            saveReading()
            return false
        } catch let error as VaultError {
            notice = Self.message(for: error)
            return false
        } catch {
            notice = Self.message(for: .notWritten)
            return false
        }
    }

    /// ``saveReading()`` for the document: the document when what it holds changed (a waiting ID,
    /// the user's own data), the cache when what reading finds again did. Another copy's document
    /// since is merged with this one's and written again, once (VT111).
    private func sealDocument(in store: VaultStore) {
        var document = currentDocument()
        // Only the cache changed, but another copy saved since: its cache is the one on disk, so
        // its save is merged first rather than its read marks written over (the final review).
        // A cache-only seal of the other copy's counts too: only the cache moved (the second review).
        if let base = documentBase, document.sameContents(as: base), VaultCache(sealedReading) != cacheWritten,
           store.documentState() != onDisk || cacheOnDisk.map({ store.cacheState() != $0 }) == true {
            guard mergeOtherCopysDocument() else { return }
            document = currentDocument()
        }
        if documentBase.map({ !document.sameContents(as: $0) }) ?? true {
            do {
                try seal(document, in: store)
            } catch VaultError.changedElsewhere {
                guard mergeOtherCopysDocument() else { return }
                do { try seal(currentDocument(), in: store) } catch {
                    Logger.shared.warning("Vault: the Vault could not be sealed after another SyncCloud saved it; the next seal tries again")
                    return
                }
            } catch {
                Logger.shared.warning("Vault: the Vault could not be sealed; the next seal tries again")
                return
            }
        }
        let cache = VaultCache(sealedReading)
        if cache != cacheWritten {
            do {
                try store.saveCache(cache)
                cacheWritten = cache
                cacheOnDisk = store.cacheState()
                cacheWrites += 1
            } catch {
                // What a read finds again: the next seal tries.
                Logger.shared.warning("Vault: the reading cache could not be sealed; the next seal tries again")
            }
        }
        readingChanged = false
    }

    /// Another SyncCloud saved the document since this copy read it: its saved IDs take this
    /// copy's place, as ``reloadSavedIDs()`` does for a v1 Vault (VT108), and each one changed in a
    /// field the editor shows is noted for an open editor (VT112). The user's own data is merged
    /// three ways (``mergeOwn(base:ours:theirs:)``, VT111), and so are the set-aside numbers, the
    /// Forget generation and the kinds. A waiting ID the other saved leaves To Confirm. False when
    /// its document does not open here: nothing is written over it, and the panel says why.
    @discardableResult
    private func mergeOtherCopysDocument() -> Bool {
        guard let store else { return false }
        let found: VaultStore.DocumentLoad?
        do {
            found = try store.loadDocument()
        } catch {
            notice = Self.message(for: error as? VaultError ?? .unreadableFile)
            return false
        }
        guard let loaded = found else {
            // Gone: set aside by the other copy. Nothing typed here is let go; it is written anew.
            onDisk = .absent
            documentBase = nil
            readingChanged = true
            return true
        }
        guard !loaded.readOnly else {
            readOnly = .newerFormat
            return false
        }
        let theirs = loaded.document
        guard let theirEntries = try? theirs.entries(), let theirState = try? theirs.readingState(cache: nil) else {
            notice = Self.message(for: .unreadableFile)
            return false
        }
        let base = documentBase.flatMap { try? $0.readingState(cache: nil) }.map(OwnReading.init) ?? OwnReading()
        let ours = OwnReading(sealedReading)
        let before = Dictionary(entries.map { ($0.id, EditedFields($0)) }, uniquingKeysWith: { first, _ in first })
        for entry in theirEntries where before[entry.id].map({ $0 != EditedFields(entry) }) == true {
            editedElsewhereIDs.insert(entry.id)
        }
        entries = theirEntries
        newerRecords = loaded.unread
        if !entries.isEmpty { hasSomethingSealed = true }
        let taken = mergeOwn(base: base, ours: ours, theirs: OwnReading(theirState))
        let baseAside = documentBase?.setAside ?? .init()
        // A Forget made there (the generation moved there, not here) lets go what this copy read,
        // as one made here would; one made here keeps what the other read out.
        let theyForgot = theirs.setAside.generation != baseAside.generation && readGeneration == baseAside.generation
        let weForgot = readGeneration != baseAside.generation
        if theyForgot {
            readIndex = [:]
            copyNumbers = [:]
        }
        setAsideFingerprints = Set(Self.merged(baseAside.fingerprints, setAsideFingerprints.sorted(), theirs.setAside.fingerprints))
        readGeneration = Self.merged(baseAside.generation, readGeneration, theirs.setAside.generation)
        kinds = VaultKinds(custom: Self.mergedKinds(documentBase?.kinds ?? [], kinds.custom, theirs.kinds))
        // What the other read: its waiting IDs new since the base (not saved, waiting or set aside
        // here) and the documents it read, which this copy's next seal would otherwise write over,
        // leaving them behind a read mark (as the v1 reading file's seal never did).
        if !weForgot {
            let read = (try? theirs.readingState(cache: loaded.cache)).flatMap { $0.generation == theirs.setAside.generation ? $0 : nil }
            for (path, mark) in read?.read ?? [:] where readIndex[path] == nil { readIndex[path] = mark }
            for (number, kept) in read?.copies ?? [:] where copies[number] == nil { copies[number] = kept }
            for (number, kept) in read?.mentions ?? [:] where mentions[number] == nil { mentions[number] = kept }
            for (path, kept) in read?.copyNumbers ?? [:] where copyNumbers[path] == nil { copyNumbers[path] = kept }
        }
        let baseWaiting = Set(((try? documentBase?.finds()) ?? []).map { VaultReading.normalized($0.value) })
        let theirsNew = theirState.finds.filter { !baseWaiting.contains(VaultReading.normalized($0.value)) && isNew($0) }
        finds += theirsNew
        if !theirsNew.isEmpty { resplitWaiting() }
        // Written whole at the next seal: what is on disk may be the other's.
        cacheWritten = nil
        // What the other saved is no longer waiting here.
        let saved = Set(entries.map { VaultReading.normalized($0.value) })
        for find in finds where saved.contains(VaultReading.normalized(find.value)) {
            for source in find.facts.sources { mentions[VaultReading.normalized(find.value), default: []].append(source) }
        }
        finds.removeAll { saved.contains(VaultReading.normalized($0.value)) }
        onDisk = loaded.onDisk
        documentBase = theirs
        readingChanged = true
        readingMerges += 1
        dropStaleCorrection()
        rowsRevision &+= 1
        // Counts only.
        Logger.shared.info("Vault: another SyncCloud saved the Vault; \(entries.count) saved ID(s) read again, merged with it, \(taken) waiting ID(s) it took out of To Confirm")
        keepSelectionVisible()
        return true
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
        case .wouldDrop(let count):
            return "That change would have removed \(count) IDs at once, so it wasn’t saved."
        case .changedElsewhere:
            return "Another SyncCloud on this Mac changed the Vault, so this change wasn’t saved. The Vault now shows what it saved: make your change again."
        }
    }
}

extension VaultModel.Row {
    /// A saved number's row as ``VaultRowSource/rows()`` starts it, before anything weighs it:
    /// no standing or name to show yet, and its card the one chosen, whether a card is kept for
    /// it or not.
    init(entry: VaultEntry, facts: VaultReadFacts?, personID: String?, readHolder: String?,
         reading: VaultRowSource.ChosenReading) {
        self.init(id: entry.id, title: entry.title, value: entry.value, note: entry.note, category: entry.category,
                  facts: facts, standing: VaultStanding(tab: .current), isSaved: true, personID: personID, whose: "",
                  pin: entry.pin, assignment: entry.assignment, isHousehold: false, chosenGeo: entry.geo,
                  chosenCard: entry.card, readHolder: readHolder, ownHolderName: entry.holderName,
                  appSource: reading.app, chosenSource: reading.chosen, sourceChoices: reading.choices)
    }

    /// A waiting number's row, the same way.
    init(find: VaultFind, facts: VaultReadFacts?, personID: String?, readHolder: String?,
         reading: VaultRowSource.ChosenReading) {
        self.init(id: find.id, title: find.title, value: find.value, note: find.note, category: find.category,
                  facts: facts, standing: VaultStanding(tab: .current), isSaved: false, personID: personID, whose: "",
                  pin: find.pin, assignment: find.assignment, isHousehold: false, chosenGeo: find.geo,
                  chosenCard: find.card, readHolder: readHolder,
                  appSource: reading.app, chosenSource: reading.chosen, sourceChoices: reading.choices)
    }
}
