import CryptoKit
import Events
import Foundation

/// Where Read Documents gets its pages: the app's Vision reader, or a stand-in in tests.
public protocol VaultDocumentReading: Sendable {
    /// The files in the chosen folders that could hold a number.
    func files() async -> [URL]
    /// One file's pages as recognised lines; empty when it cannot be read.
    func lines(in file: URL) async -> [String]
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
        public var kind: VaultEntry.Kind
        /// An older number kept for reference, such as a past passport's.
        public var isOlder: Bool
        /// The document's own date, carried from a find; not edited.
        public var dated: Date?

        public init(title: String = "", value: String = "", personID: String? = nil,
                    note: String = "", kind: VaultEntry.Kind = .other, isOlder: Bool = false,
                    dated: Date? = nil) {
            self.title = title
            self.value = value
            self.personID = personID
            self.note = note
            self.kind = kind
            self.isOlder = isOlder
            self.dated = dated
        }

        public init(_ entry: VaultEntry) {
            self.init(title: entry.title, value: entry.value, personID: entry.personID,
                      note: entry.note, kind: entry.kind, isOlder: entry.isOlder, dated: entry.dated)
        }

        /// A read number, for the editor to confirm. Whose it is is suggested from the name the
        /// document is made out to, when exactly one person in the household answers to it.
        public init(_ find: VaultFind, people: [Person] = []) {
            var personID: String?
            if let holder = find.holder, !people.isEmpty {
                let named = PersonRegistry(people: people).detect(in: holder)
                if named.count == 1 { personID = named.first }
            }
            self.init(title: find.title, value: find.value, personID: personID,
                      note: find.note, kind: find.kind, isOlder: find.isOlder, dated: find.dated)
        }

        /// A name and a number are the least an entry can be.
        public var isComplete: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @Published public private(set) var entries: [VaultEntry] = []
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
    @Published public private(set) var finds: [VaultFind] = []
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
        lock = VaultLock(settings: VaultLockSettings(defaults: defaults))
        now = clock()
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

    /// To Confirm, as the search leaves it. Shown whoever the list is filtered to: a find belongs
    /// to nobody until it is confirmed.
    ///
    /// The current numbers, then, when ``showsOlderFinds`` is on or a search is typed, the older
    /// ones. Each part by kind (passports, I-94s, receipt numbers), then newest first.
    public var visibleFinds: [VaultFind] {
        let matching = searchedFinds.sorted(by: Self.findOrder)
        let current = matching.filter { !$0.isOlder }
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard showsOlderFinds || searching else { return current }
        return current + matching.filter(\.isOlder)
    }

    /// Whether the older numbers are on the list now: asked for, or a search is typed.
    public var olderFindsShown: Bool {
        showsOlderFinds || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let titleOrder = ["Passport", "I-94 admission number", "USCIS receipt number"]

    private static func findOrder(_ a: VaultFind, _ b: VaultFind) -> Bool {
        let (ta, tb) = (titleOrder.firstIndex(of: a.title) ?? 99, titleOrder.firstIndex(of: b.title) ?? 99)
        if ta != tb { return ta < tb }
        return (a.dated ?? .distantPast) > (b.dated ?? .distantPast)
    }

    /// How many older numbers the search leaves, shown or not: the count beside "Older".
    public var olderFindCount: Int { searchedFinds.filter(\.isOlder).count }

    private var searchedFinds: [VaultFind] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return finds }
        return finds.filter { $0.title.lowercased().contains(needle) || $0.note.lowercased().contains(needle) }
    }

    public var selectedFind: VaultFind? { finds.first { $0.id == selection } }

    /// Every row in list order: To Confirm first, then the entries.
    private var visibleIDs: [UUID] { visibleFinds.map(\.id) + visibleEntries.map(\.id) }

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
        let settings = VaultLockSettings(defaults: defaults)
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
        contents = .notLoaded
        selection = nil
    }

    private func load() {
        guard contents != .loaded else { keepSelectionVisible(); return }
        guard let store else { contents = .unreadable(.unreadableFile); return }
        do {
            entries = try store.load()
            contents = .loaded
            if let state = store.loadReading() {
                finds = state.finds
                // Another build's rules, or a Forget since: read every file again next time.
                let current = state.version == VaultReading.version
                    && state.generation == VaultSetAside.generation(in: defaults)
                readIndex = current ? state.read : [:]
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
        let entry = VaultEntry(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               value: draft.value.trimmingCharacters(in: .whitespacesAndNewlines),
                               personID: draft.personID,
                               note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                               kind: draft.kind, sourcePath: sourcePath, addedAt: stamp,
                               dated: draft.dated, isOlder: draft.isOlder)
        guard write(entries + [entry]) else { return nil }
        selection = entry.id
        return entry.id
    }

    /// Changes an entry, after a proof when its number is not already showing: the editor draws
    /// it in full.
    @discardableResult
    public func update(_ id: UUID, to draft: Draft) async -> Bool {
        guard draft.isComplete, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("change \(entries[index].title)", for: id) else { return false }
        }
        var changed = entries
        changed[index].title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].personID = draft.personID
        changed[index].note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[index].kind = draft.kind
        changed[index].isOlder = draft.isOlder
        changed[index].updatedAt = clock()
        used()
        return write(changed)
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
        if again { readIndex = [:] }
        reading = ReadingProgress(done: 0, total: 0)
        defer { reading = nil }
        let files = await reader.files()
        reading = ReadingProgress(done: 0, total: files.count)
        var added = 0
        var opened = 0
        for (index, file) in files.enumerated() {
            // The panel closed or the Mac locked. What was read so far was sealed as it went.
            if Task.isCancelled || contents != .loaded { return }
            let stamp = reader.stamp(of: file)
            if let stamp, readIndex[file.path] == stamp {
                reading = ReadingProgress(done: index + 1, total: files.count)
                continue
            }
            let lines = await reader.lines(in: file)
            guard contents == .loaded else { return }
            opened += 1
            for find in VaultReading.finds(in: lines, from: file.path) where take(find) { added += 1 }
            if let stamp { readIndex[file.path] = stamp }
            readingChanged = true
            reading = ReadingProgress(done: index + 1, total: files.count)
            // Sealed every so often, so a read stopped halfway keeps what it had.
            if opened % 25 == 0 {
                finds = VaultReading.markingOlder(finds, now: clock())
                saveReading()
            }
        }
        // A file gone from the folders is forgotten, so one put back is read again.
        let present = Set(files.map(\.path))
        readIndex = readIndex.filter { present.contains($0.key) }
        finds = VaultReading.markingOlder(finds, now: clock())
        readingChanged = true
        saveReading()
        lastReading = ReadingSummary(documents: files.count, opened: opened, newNumbers: added)
        // Counts only. A file's name can hold the very number it carries.
        Logger.shared.info("Vault: \(files.count) document(s), \(opened) opened; \(added) new number(s) to confirm")
        if selection.flatMap(row) == nil { selection = visibleIDs.first }
    }

    /// Adds a find to To Confirm when its number is new. When the number is already waiting, read
    /// from another file, the copy outside an Archive folder or with the later date is kept as its
    /// source. True when it was new.
    private func take(_ find: VaultFind) -> Bool {
        let value = VaultReading.normalized(find.value)
        if let index = finds.firstIndex(where: { VaultReading.normalized($0.value) == value }) {
            let held = finds[index]
            let better = held.isArchived != find.isArchived ? !find.isArchived
                : (find.dated ?? .distantPast) > (held.dated ?? .distantPast)
            // What any copy says about when the number runs out, and which form it is for, is kept
            // whichever copy stays the source: a receipt notice and its approval say different
            // things about one case.
            let validUntil = [held.validUntil, find.validUntil].compactMap { $0 }.max()
            if better {
                // Same row, newer source; whether it is older is worked out again after the read.
                finds[index] = VaultFind(id: held.id, title: find.title, value: find.value, kind: find.kind,
                                         note: find.note.isEmpty ? held.note : find.note,
                                         holder: find.holder ?? held.holder,
                                         sourcePath: find.sourcePath, dated: find.dated ?? held.dated,
                                         validUntil: validUntil)
            } else {
                finds[index].validUntil = validUntil
                if finds[index].note.isEmpty { finds[index].note = find.note }
            }
            return false
        }
        guard isNew(find) else { return false }
        finds.append(find)
        return true
    }

    /// Something in To Confirm or the record of read files changed since it was last sealed.
    private var readingChanged = false

    /// Seals To Confirm and the record of read files. A refusal is logged and otherwise let go:
    /// the next read rebuilds whatever was lost.
    private func saveReading() {
        guard readingChanged, let store else { return }
        let state = VaultReadingState(generation: VaultSetAside.generation(in: defaults),
                                      finds: finds, read: readIndex)
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
        guard let find = finds.first(where: { $0.id == findID }),
              let id = add(draft, sourcePath: find.sourcePath) else { return nil }
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
        let settings = VaultLockSettings(defaults: defaults)
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
