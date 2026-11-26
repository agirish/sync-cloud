import CryptoKit
import Darwin
import Events
import Foundation

/// From the v1 files to the v7.2 document (VT6): the Vault's SCVAULT1 entries, the reading file's
/// SCVREAD1 state, and the three UserDefaults keys the document takes in (``movedKeys``), made into
/// one ``VaultDocument`` and its ``VaultCache``.
///
/// ``migrate(_:keyID:people:folders:at:)`` is pure: bytes and values in, a document out, nothing
/// read from or written to the disk, the Keychain or UserDefaults. ``VaultStore/migrate(defaults:people:folders:)``
/// does the steps around it, in the order the spec gives, each safe to stop after.
///
/// Gated by ``enabled``: off, a build that finds the v1 files opens and saves them as it always did.
public enum VaultMigration {
    /// Whether a load migrates the v1 files. Off: nothing migrates, and the v1 files open and save
    /// exactly as before 7.2. On since the owner's own Vault went through the count-only harness
    /// on a copy (2026-11-25): every saved and waiting ID, name, contact, lesson, set-aside
    /// fingerprint and kind came through equal.
    public static let enabled = true

    /// The UserDefaults keys the document takes in: the set-aside fingerprints, the Forget
    /// generation, the household's kinds. Removed once the document holds them (step 5).
    public static let movedKeys = [VaultSetAside.key, VaultSetAside.generationKey, VaultKinds.key]

    /// What the migration reads: each v1 file's plaintext JSON and its sealed bytes' SHA-256 (hex),
    /// and the moved keys' values as UserDefaults gives them (`object(forKey:)`). Nil for what is
    /// not there.
    public struct Legacy: @unchecked Sendable {
        public var vaultPlain: Data?
        public var vaultDigest: String?
        public var readingPlain: Data?
        public var readingDigest: String?
        public var setAside: Any?
        public var generation: Any?
        public var customKinds: Any?

        public init(vaultPlain: Data? = nil, vaultDigest: String? = nil, readingPlain: Data? = nil,
                    readingDigest: String? = nil, setAside: Any? = nil, generation: Any? = nil, customKinds: Any? = nil) {
            self.vaultPlain = vaultPlain
            self.vaultDigest = vaultDigest
            self.readingPlain = readingPlain
            self.readingDigest = readingDigest
            self.setAside = setAside
            self.generation = generation
            self.customKinds = customKinds
        }

        /// The moved keys' values in `defaults`.
        public static func values(in defaults: UserDefaults) -> (setAside: Any?, generation: Any?, customKinds: Any?) {
            (defaults.object(forKey: VaultSetAside.key), defaults.object(forKey: VaultSetAside.generationKey),
             defaults.object(forKey: VaultKinds.key))
        }
    }

    /// What a migration came to, in counts. Never a number, a title or a name.
    public struct Report: Equatable, Sendable, CustomStringConvertible {
        public var saved = 0
        public var waiting = 0
        public var fingerprints = 0
        public var kinds = 0
        /// Files read from (0–2).
        public var files = 0

        public var description: String {
            "\(saved) saved ID(s), \(waiting) to confirm, \(fingerprints) set-aside fingerprint(s), \(kinds) kind(s) from \(files) file(s)"
        }
    }

    /// Why a migration stopped, changing nothing. Counts only.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// The Vault's entries: elements that did not decode, keys decoding dropped.
        case vault(undecodable: Int, unexpected: Int)
        /// The reading file's state, the same.
        case reading(undecodable: Int, unexpected: Int)
        /// A moved UserDefaults key whose value is not what this build stores there.
        case defaults(Int)
        /// The document does not give back what the v1 files did: which check failed.
        case selfCheck(String)
        /// A v1 file there that could not be opened or read: damaged, or the Keychain withheld the key.
        case unopened(String)
        /// Another SyncCloud is running: it would go on writing the v1 files.
        case anotherCopyRunning

        public var description: String {
            switch self {
            case .vault(let u, let k): return "the Vault’s file: \(u) record(s) that do not decode, \(k) unexpected key(s)"
            case .reading(let u, let k): return "the reading file: \(u) part(s) that do not decode, \(k) unexpected key(s)"
            case .defaults(let n): return "\(n) UserDefaults value(s) not in the shape this build stores"
            case .selfCheck(let what): return "the self-check found \(what) different"
            case .unopened(let what): return "\(what) did not open"
            case .anotherCopyRunning: return "another SyncCloud is running"
            }
        }
    }

    /// The document and cache `legacy` becomes, checked against it (``selfCheck``) before it is
    /// handed back. `people` and `folders` are the household's and the folders read, for the rows
    /// the check compares; `at` is when, for the document's stamp and the rows' day.
    public static func migrate(_ legacy: Legacy, keyID: String, people: [Person] = [], folders: [String] = [],
                               at date: Date) throws -> (document: VaultDocument, cache: VaultCache, report: Report) {
        var report = Report()
        // The entries.
        var entries: [VaultEntry] = []
        if let plain = legacy.vaultPlain {
            do {
                entries = try VaultLegacyFormat.entries(fromPlain: plain)
            } catch let refused as VaultLegacyFormat.Refused {
                throw Refusal.vault(undecodable: refused.undecodable + (refused.notTheShape ? 1 : 0), unexpected: refused.unexpected)
            }
            report.files += 1
        }
        // The moved defaults.
        var wrong = 0
        var fingerprints: [String] = []
        if let value = legacy.setAside {
            if let list = value as? [String] { fingerprints = Array(Set(list)).sorted() } else { wrong += 1 }
        }
        var generation = 0
        if let value = legacy.generation {
            // A number, as `integer(forKey:)` reads it; never a string it would coerce.
            if let number = value as? NSNumber, !(value is String), CFGetTypeID(number) == CFNumberGetTypeID() {
                generation = number.intValue
            } else { wrong += 1 }
        }
        var kinds: [VaultCustomKind] = []
        if let value = legacy.customKinds {
            if let data = value as? Data, let decoded = try? JSONDecoder().decode([VaultCustomKind].self, from: data),
               let stored = try? JSONSerialization.jsonObject(with: data),
               let again = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)),
               VaultLegacyFormat.differences(stored: stored, read: again) == 0 {
                // As ``VaultKinds/load(from:)`` keeps them: a kind with no name is none.
                kinds = decoded.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            } else { wrong += 1 }
        }
        guard wrong == 0 else { throw Refusal.defaults(wrong) }
        // The reading file.
        var state = VaultReadingState(generation: generation)
        if let plain = legacy.readingPlain {
            do {
                state = try VaultLegacyFormat.readingState(fromPlain: plain)
            } catch let refused as VaultLegacyFormat.Refused {
                throw Refusal.reading(undecodable: refused.undecodable + (refused.notTheShape ? 1 : 0), unexpected: refused.unexpected)
            }
            report.files += 1
        }
        let document = VaultDocument(
            entries: entries, state: state,
            setAside: VaultDocument.SetAside(generation: generation, keyID: keyID, fingerprints: fingerprints),
            kinds: kinds, savedAt: date,
            migratedFrom: VaultDocument.MigratedFrom(vault: legacy.vaultDigest, reading: legacy.readingDigest,
                                                     fingerprints: fingerprints.count))
        let cache = VaultCache(state)
        try selfCheck(document, cache, against: legacy, entries: entries, state: state, fingerprints: fingerprints,
                      generation: generation, kinds: kinds, people: people, folders: folders, at: date)
        report.saved = entries.count
        report.waiting = state.finds.count
        report.fingerprints = fingerprints.count
        report.kinds = kinds.count
        return (document, cache, report)
    }

    /// Converted back, the document gives what the v1 files gave as this build's v1 load reads
    /// them (``VaultFile/records(fromList:)``, record by record): the same saved IDs (by id,
    /// exactly the same set, in order), each equal; the same waiting IDs and reading state; the
    /// same set-aside numbers, generation and kinds; and the very rows the panel would draw from
    /// either. Both sides read the v1 records through ``VaultLegacyFormat``, so a misreading the
    /// two share is not caught here: the retired shapes it reads differently from builds before
    /// 7.2 (`household` beside a person, `older`, `dated`) are counted by the harness instead.
    static func selfCheck(_ document: VaultDocument, _ cache: VaultCache, against legacy: Legacy, entries: [VaultEntry],
                          state: VaultReadingState, fingerprints: [String], generation: Int, kinds: [VaultCustomKind],
                          people: [Person], folders: [String], at date: Date) throws {
        // The everyday load of the v1 Vault.
        var loaded: [VaultEntry] = []
        if let plain = legacy.vaultPlain {
            guard let list = try? JSONSerialization.jsonObject(with: plain) as? [Any] else { throw Refusal.selfCheck("the Vault’s list") }
            let records = VaultFile.records(fromList: list)
            guard records.newer.isEmpty else { throw Refusal.selfCheck("records a later build wrote") }
            loaded = records.entries
        }
        let saved: [VaultEntry], waiting: [VaultFind], reading: VaultReadingState
        do {
            saved = try document.entries()
            waiting = try document.finds()
            reading = try document.readingState(cache: cache)
        } catch {
            throw Refusal.selfCheck("a record that does not convert back")
        }
        guard saved.count == loaded.count, saved.count == entries.count else { throw Refusal.selfCheck("the count of saved IDs") }
        guard saved.map(\.id) == loaded.map(\.id), Set(saved.map(\.id)) == Set(loaded.map(\.id)) else {
            throw Refusal.selfCheck("the saved IDs")
        }
        guard saved == loaded, saved == entries else {
            throw Refusal.selfCheck("a saved ID")
        }
        guard waiting == state.finds else { throw Refusal.selfCheck("the waiting IDs") }
        guard normalized(reading) == normalized(state) else { throw Refusal.selfCheck("the reading state") }
        guard document.setAside.fingerprints == fingerprints, Set(document.setAside.fingerprints).count == fingerprints.count,
              document.setAside.generation == generation, document.kinds == kinds else {
            throw Refusal.selfCheck("the set-aside numbers or kinds")
        }
        // The rows the panel would draw, from the v1 load and from the document.
        func rows(_ entries: [VaultEntry], _ sealed: VaultReadingState) -> [VaultModel.Row] {
            let opened = sealed.opened(generation: generation, people: people).state
            return VaultRowSource(entries: entries, finds: opened.finds, copies: opened.copies, mentions: opened.mentions,
                                  missingDocuments: Set(opened.notFound ?? []),
                                  holders: VaultHolders(names: opened.names, people: people), lessons: opened.lessons,
                                  kinds: VaultKinds(custom: kinds), folders: folders, now: date).rows().rows
        }
        guard rows(loaded, state) == rows(saved, reading) else { throw Refusal.selfCheck("the rows") }
    }

    /// `state` with what holds nothing said one way: an empty list or map is none.
    static func normalized(_ state: VaultReadingState) -> VaultReadingState {
        var state = state
        if state.staleSources?.isEmpty == true { state.staleSources = nil }
        if state.notFound?.isEmpty == true { state.notFound = nil }
        if state.nameRoles?.isEmpty == true { state.nameRoles = nil }
        if state.contacts?.isEmpty == true { state.contacts = nil }
        if state.copyNumbers?.isEmpty == true { state.copyNumbers = nil }
        state.laterFields = nil
        state.unreadFields = nil
        return state
    }

    /// SHA-256 of `data`, hex: what ``VaultDocument/MigratedFrom`` records.
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether another copy of this app is running: a process, not this one, whose app bundle has
    /// this one's identifier. Asked of the kernel's process list (libproc), so the Sync engine
    /// needs no AppKit. False where this process has no bundle identifier (a test runner).
    public static func anotherCopyRunning() -> Bool {
        guard let mine = Bundle.main.bundleIdentifier else { return false }
        let me = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard found > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(found)) where pid > 0 && pid != me {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            let executable = String(cString: path)
            guard let range = executable.range(of: ".app/Contents/MacOS/") else { continue }
            let app = String(executable[..<range.lowerBound]) + ".app"
            if Bundle(path: app)?.bundleIdentifier == mine { return true }
        }
        return false
    }
}
