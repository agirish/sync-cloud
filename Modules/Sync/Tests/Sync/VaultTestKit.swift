import Foundation
import Security
import Sync
#if canImport(EventsTestSupport)
import EventsTestSupport
#endif

// The Vault's test kit (VT98): what its tests share, in one file, compiled into Sync's tests and,
// through `project.yml`, into the app's (``VaultShelf``, the rig, the fakes). Public API only, so
// both can compile it. Every number a test hands it is made up.

/// A test's proof has its Touch ID unless it says otherwise (``VaultFakeAuthenticator/touchID``):
/// tests only. The app's proof asks macOS (``VaultDeviceOwnerProof/touchID``).
extension VaultAuthenticating {
    var touchID: VaultTouchID { .ready }
}

/// An in-memory ``KeychainStore`` with the Vault key's item slot, and a slot for each other item
/// the Vault keeps. Tests never touch the real login keychain.
final class VaultFakeKeychain: KeychainStore, @unchecked Sendable {
    var itemData: Data?
    var forcedCopyStatus: OSStatus?
    var forcedAddStatus: OSStatus?
    /// The Vault key's adds.
    private(set) var adds = 0
    private(set) var lastAdded: [String: Any]?
    /// Items of other services, by service.
    private(set) var others: [String: Data] = [:]

    private static func otherService(_ query: [String: Any]) -> String? {
        let service = query[kSecAttrService as String] as? String
        return service == "com.synccloud.vault-key" ? nil : service
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let service = Self.otherService(query) {
            return others.removeValue(forKey: service) != nil ? errSecSuccess : errSecItemNotFound
        }
        let had = itemData != nil
        itemData = nil
        return had ? errSecSuccess : errSecItemNotFound
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        if let service = Self.otherService(attributes) {
            if others[service] != nil { return errSecDuplicateItem }
            others[service] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
        adds += 1
        if let forcedAddStatus { return forcedAddStatus }
        if itemData != nil { return errSecDuplicateItem }
        lastAdded = attributes
        itemData = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    /// Every read, by service: what a test counts round trips with (VT10).
    private(set) var reads: [String] = []

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        reads.append(query[kSecAttrService as String] as? String ?? "")
        if let forcedCopyStatus { return (forcedCopyStatus, nil) }
        if let service = Self.otherService(query) {
            guard let data = others[service] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data as AnyObject)
        }
        guard let itemData else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, itemData as AnyObject)
    }

    /// What every update answers, when set: a Keychain that refuses a change.
    var forcedUpdateStatus: OSStatus?

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if let forcedUpdateStatus { return forcedUpdateStatus }
        if let service = Self.otherService(query) {
            guard others[service] != nil else { return errSecItemNotFound }
            others[service] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
        guard itemData != nil else { return errSecItemNotFound }
        itemData = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
}


/// A throwaway defaults suite for one Vault test, and its name. Never wiped: a wipe per test
/// waits on cfprefsd under a global lock on the main actor, which broke the parking suites
/// (testing laws). Its name goes to the shared ledger instead, whose sweep at a later test run's
/// start (or the hourly sweep of stale scratch plists) deletes the plist (VT94). The trade:
/// cfprefsd keeps the domain cached until it restarts, as a bare suite always did.
func vaultScratchSuite(_ prefix: String) -> (name: String, defaults: UserDefaults) {
    let name = "\(prefix)-\(UUID().uuidString)"
    scratchDefaultsLedger.record(name)
    return (name, UserDefaults(suiteName: name)!)   // a fresh UUID is never a reserved domain name
}

func vaultScratchDefaults(_ prefix: String) -> UserDefaults { vaultScratchSuite(prefix).defaults }

/// A folder of its own for each test's sealed file, removed when the test ends.
struct VaultScratch {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("SyncCloud/vault.sealed") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A stand-in for Touch ID that answers what the test tells it to and counts the asks.
final class VaultFakeAuthenticator: VaultAuthenticating, @unchecked Sendable {
    var answer: VaultProof = .allowed
    /// Whether this Mac has Touch ID set up, as the test says.
    var touchID: VaultTouchID = .ready
    private(set) var reasons: [String] = []
    func prove(reason: String) async -> VaultProof {
        reasons.append(reason)
        return answer
    }
}

/// A clock the test moves.
final class VaultTestClock: @unchecked Sendable {
    var now = VaultRig.t0
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A Vault on a scratch folder, with a fake keychain, a proof the test answers, the clock above,
/// a defaults suite of its own and a clipboard it reads back.
struct VaultRig {
    /// The time every Vault test starts at.
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    let scratch: VaultScratch
    let keychain = VaultFakeKeychain()
    let auth = VaultFakeAuthenticator()
    let clock = VaultTestClock()
    let defaults: UserDefaults
    let suite: String
    var copied: [String] { box.copied }
    final class Box: @unchecked Sendable { var copied: [String] = [] }
    let box = Box()

    /// Kept in the v1 files, the migration off: for a test of the v1 files themselves.
    let v1: Bool

    init(v1: Bool = false) throws {
        scratch = try VaultScratch()
        (suite, defaults) = vaultScratchSuite("vault-model-tests")
        self.v1 = v1
    }

    var store: VaultStore { VaultStore(fileURL: scratch.fileURL, keychain: keychain, migrating: v1 ? false : nil) }

    @MainActor func model(backup: VaultBackup? = nil) -> VaultModel {
        let clock = clock, box = box
        return VaultModel(store: store, authenticator: auth, defaults: defaults,
                          clock: { clock.now }, backup: backup, copyToPasteboard: { box.copied.append($0) })
    }

    func seed(_ entries: [VaultEntry]) throws { try store.writeSavedOnDisk(entries) }
    func cleanUp() { scratch.remove() }

    /// Settings' Forget: through an opened model when the Vault is the document, which holds the
    /// set-aside numbers; in the v1 Vault's defaults otherwise.
    @MainActor func forgetSetAside() async {
        guard store.keepsDocument else { VaultSetAside.forget(in: defaults); return }
        let model = model()
        await model.opened()
        _ = model.forgetSetAside()
        model.closed()
    }
}

/// Documents the test can change, move away and count the opening of.
final class VaultShelf: VaultDocumentReading, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: [String]]
    private var stamps: [String: Int] = [:]
    private var opens: [String] = []
    private var walks = 0

    init(_ pages: [String: [String]]) { self.pages = pages }

    /// Replaces a document's page, as a new scan saved over the old one would.
    func write(_ path: String, _ page: [String]) {
        lock.withLock { pages[path] = page; stamps[path, default: 1] += 1 }
    }
    func remove(_ path: String) { lock.withLock { pages[path] = nil } }
    var opened: [String] { lock.withLock { opens } }
    var walked: Int { lock.withLock { walks } }
    func forgetOpened() { lock.withLock { opens = [] } }

    func files() async -> [URL] { lock.withLock { walks += 1; return pages.keys.sorted().map { URL(fileURLWithPath: $0) } } }
    func pages(in file: URL) async -> [[String]] {
        lock.withLock { opens.append(file.path); return pages[file.path].map { [$0] } ?? [] }
    }
    func stamp(of file: URL) -> String? { lock.withLock { pages[file.path] == nil ? nil : String(stamps[file.path, default: 1]) } }
    func modified(of file: URL) -> Date? { nil }
    func exists(_ file: URL) -> Bool { lock.withLock { pages[file.path] != nil } }
}

/// The Vault as it is on disk, whichever format holds it: the v1 files, or the v7.2 document and
/// its cache. A test seeds and inspects through these, so it tests the format the app keeps.
extension VaultStore {
    /// The saved IDs on disk.
    func savedOnDisk() throws -> [VaultEntry] {
        guard fileFormat == .document else { return try load() }
        return try loadDocument()?.document.entries() ?? []
    }

    /// What reading kept: the document's waiting IDs and user data with the cache's finds.
    func readingOnDisk() -> VaultReadingState? {
        guard fileFormat == .document else { return loadReading() }
        guard let loaded = try? loadDocument() else { return nil }
        return try? loaded.document.readingState(cache: loaded.cache)
    }

    /// Seals `state` as another copy of the app would, beside the saved IDs on disk.
    @discardableResult
    func writeReadingOnDisk(_ state: VaultReadingState) throws -> VaultFileState {
        guard fileFormat == .document, let loaded = try loadDocument() else { return try saveReading(state) }
        let document = VaultDocument(entries: try loaded.document.entries(), state: state, setAside: loaded.document.setAside,
                                     kinds: loaded.document.kinds, savedAt: VaultRig.t0, migratedFrom: loaded.document.migratedFrom)
        let written = try saveDocument(document, expecting: loaded.onDisk)
        try saveCache(VaultCache(state))
        return written.onDisk
    }

    /// The sealed file that holds what reading kept: the document, or the v1 reading file.
    var readingFileOnDisk: URL { fileFormat == .document ? fileURL : readingURL }

    /// The set-aside fingerprints: the document's, or the v1 Vault's in `defaults`.
    func setAsideOnDisk(_ defaults: UserDefaults) -> Set<String> {
        guard fileFormat == .document else { return VaultSetAside.fingerprints(in: defaults) }
        return Set(((try? loadDocument()) ?? nil)?.document.setAside.fingerprints ?? [])
    }

    /// Saves `entries` as another copy of the app would, keeping what else the Vault holds.
    @discardableResult
    func writeSavedOnDisk(_ entries: [VaultEntry]) throws -> VaultFileState {
        guard keepsDocument else { return try save(entries) }
        let loaded = try loadDocument()
        let state = try loaded.map { try $0.document.readingState(cache: $0.cache) } ?? VaultReadingState()
        let document = VaultDocument(entries: entries, state: state, setAside: loaded?.document.setAside ?? .init(),
                                     kinds: loaded?.document.kinds ?? [], savedAt: VaultRig.t0,
                                     migratedFrom: loaded?.document.migratedFrom)
        return try saveDocument(document, expecting: loaded?.onDisk ?? .absent).onDisk
    }
}

