import Events
import Foundation

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

        public init(title: String = "", value: String = "", personID: String? = nil,
                    note: String = "", kind: VaultEntry.Kind = .other) {
            self.title = title
            self.value = value
            self.personID = personID
            self.note = note
            self.kind = kind
        }

        public init(_ entry: VaultEntry) {
            self.init(title: entry.title, value: entry.value, personID: entry.personID,
                      note: entry.note, kind: entry.kind)
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
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.addedAt < b.addedAt
    }

    public var selectedEntry: VaultEntry? { entries.first { $0.id == selection } }

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
    public var isOpen: Bool { lock.isOpen(at: now) }
    public var secondsLeft: Int? { lock.secondsLeft(at: now) }

    /// Moves the selection one row up or down the visible list, stopping at its ends.
    public func moveSelection(by step: Int) {
        let visible = visibleEntries
        guard !visible.isEmpty else { return }
        guard let index = visible.firstIndex(where: { $0.id == selection }) else {
            selection = visible.first?.id
            return
        }
        selection = visible[min(max(index + step, 0), visible.count - 1)].id
        used()
    }

    private func keepSelectionVisible() {
        let visible = visibleEntries
        if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
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
        entries = []
        contents = .notLoaded
        selection = nil
    }

    /// Once a second while the panel is up.
    public func tick() {
        now = clock()
        lock.expire(at: now)
    }

    private func used() { lock.used(at: clock()) }

    private func releaseIfLocked() {
        guard lock.settings.requiresAuthentication, !lock.isOpen(at: now) else { return }
        entries = []
        contents = .notLoaded
        selection = nil
    }

    private func load() {
        guard contents != .loaded else { keepSelectionVisible(); return }
        guard let store else { contents = .unreadable(.unreadableFile); return }
        do {
            entries = try store.load()
            contents = .loaded
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
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("show \(entry.title)", for: id) else { return false }
        }
        used()
        return lock.canShow(id, at: clock())
    }

    /// Copy: puts `id`'s number on the pasteboard, after a proof when one is owed.
    @discardableResult
    public func copy(_ id: UUID) async -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("copy \(entry.title)", for: id) else { return false }
        }
        guard lock.canShow(id, at: clock()) else { return false }
        copyToPasteboard(entry.value)
        used()
        return true
    }

    // MARK: Editing

    /// Adds a number. No proof: the person typing it already has it in hand.
    @discardableResult
    public func add(_ draft: Draft) -> UUID? {
        guard draft.isComplete, contents == .loaded || contents == .notLoaded else { return nil }
        if contents == .notLoaded { load() }
        guard contents == .loaded else { return nil }
        let stamp = clock()
        let entry = VaultEntry(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               value: draft.value.trimmingCharacters(in: .whitespacesAndNewlines),
                               personID: draft.personID,
                               note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                               kind: draft.kind, addedAt: stamp)
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
        changed[index].updatedAt = clock()
        used()
        return write(changed)
    }

    /// Removes an entry for good, after a proof when one is owed. There is no Trash for a number.
    @discardableResult
    public func delete(_ id: UUID) async -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        if lock.needsProof(for: id, at: clock()) {
            guard await prove("remove \(entry.title)", for: id) else { return false }
        }
        used()
        guard write(entries.filter { $0.id != id }) else { return false }
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
