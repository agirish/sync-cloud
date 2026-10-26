import Events
import Foundation

/// **Which profile folder holds each Setup folder's Restructure history** (FR4, follow-up) —
/// `profiles/restructure-roots.json`, beside `profiles.json`.
///
/// Restructure's ledger (`restructure.json`: suppressions, answers, drafts, landings and their
/// Undo, the trend) and the person verdicts (`person-tags.json`) are keyed by paths relative to
/// the folder Setup walked. A walk of ANOTHER folder used to carry them across, so a suggestion
/// suppressed at `Tax/Forms` in one folder stayed hidden at `Tax/Forms` in the next. Each folder
/// now keeps its own (``historyNames``): leaving a folder records here which profile folder holds
/// its history, and walking back to it takes that history up again.
///
/// One entry per folder, keyed by the folder as the profile records it (`~/Documents`), compared
/// with ``FilingProfileStore/namesSameRoot(_:_:)``. `landingsSeen` is every landing the other
/// folders' histories held when the user walked away — a landing NOT among them, in a folder that
/// overlaps this one, came after, and has reshaped the tree this folder's Undo describes. `leftAt`
/// is when, for the log alone.
///
/// **An unreadable map is never written over.** Every reader answers ``Reading/unreadable(_:)``
/// for a file that is there and cannot be read, and every caller then keeps the cautious
/// behaviour: the walk carries the history as it always did, and the retire sweep retires nothing.
public enum RestructureRootMap {

    public static let filename = "restructure-roots.json"
    static let currentSchema = 1

    public struct Entry: Codable, Equatable, Sendable {
        /// The folder, as its profile records it.
        public var root: String
        /// The profile folder holding that folder's latest Restructure history.
        public var profileId: String
        /// When the user walked away from it — for the log; nothing is ordered by it.
        public var leftAt: String
        /// The manifest id of every landing the map's other folders held when the user walked
        /// away (review R6). **A set, not a time**: `leftAt` and a landing's `at` are local stamps
        /// with no zone, so a zone change or the autumn hour mis-ordered them and re-pointed an
        /// Undo over a tree a later landing had reshaped. Nil in an entry that predates it, and
        /// then every landing counts as later — the cautious side, which only withholds an Undo.
        public var landingsSeen: [String]?
        /// When a walk back to this folder could not copy its history in (review C1) — the
        /// folder then started empty, and this entry is the only way back to the history. Such
        /// an entry is never dropped or replaced by a walk of the folder or away from it; the
        /// next walk of the folder tries the copy again. Nil on every other entry.
        public var takeUpFailedAt: String?

        public init(root: String, profileId: String, leftAt: String,
                    landingsSeen: [String]? = nil, takeUpFailedAt: String? = nil) {
            self.root = root
            self.profileId = profileId
            self.leftAt = leftAt
            self.landingsSeen = landingsSeen
            self.takeUpFailedAt = takeUpFailedAt
        }
    }

    public enum Reading: Equatable {
        case loaded([Entry])
        /// Something is at the path and this build could not read it — the reason, for the log.
        case unreadable(String)
    }

    private struct File: Codable {
        let schemaVersion: Int
        let roots: [Entry]
    }

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// The map — empty when there is no file, unreadable when there is one this build cannot read
    /// (including a schema newer than it writes).
    public static func read(in directory: URL) -> Reading {
        let url = url(in: directory)
        // lstat semantics, as `RestructureStore.load` has: a broken link is something at the path.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
            return .loaded([])
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable("it exists but could not be read")
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            return .unreadable("it is not a map this build can read")
        }
        guard file.schemaVersion == currentSchema else {
            return .unreadable("schema \(file.schemaVersion), not \(currentSchema)")
        }
        return .loaded(file.roots)
    }

    /// Writes the whole map atomically, entries in root order so the bytes are a function of the
    /// state. Refuses over a file ``read(in:)`` cannot read.
    static func write(_ entries: [Entry], in directory: URL) throws {
        if case .unreadable(let why) = read(in: directory) {
            throw CocoaError(.fileWriteNoPermission,
                             userInfo: [NSLocalizedDescriptionKey: "\(filename): \(why)"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let bytes = try encoder.encode(File(schemaVersion: currentSchema,
                                            roots: entries.sorted { $0.root < $1.root }))
        try bytes.write(to: url(in: directory), options: .atomic)
    }

    /// The index of the entry for `root` (an expanded path), compared as one folder.
    static func index(of root: String?, in entries: [Entry]) -> Int? {
        entries.firstIndex { FilingProfileStore.namesSameRoot(expanded($0.root), root) }
    }

    static func expanded(_ recorded: String) -> String {
        (recorded as NSString).expandingTildeInPath
    }

    // MARK: - An entry with nothing left to return to

    /// Why `entry` names nothing anymore — its Setup folder was deleted, or its profile folder
    /// is gone — or nil while either may still be there (review R4).
    ///
    /// **Gone only when the disk says so.** A folder that cannot be asked about (permissions, an
    /// I/O error) is not gone, and neither is one whose parent is missing — a volume that is not
    /// mounted, a cloud folder whose provider is signed out — nor a volume or provider folder
    /// itself: those come back, and their history with them. **Nor anything in iCloud Drive**
    /// (`~/Library/Mobile Documents`, review C11): signing out takes the whole local tree away at
    /// any depth, and signing back in brings it back.
    ///
    /// **And only when the disk answers in time** (review C11): this runs on the main actor during
    /// Setup's Save, and a stat of a network volume that has stopped answering does not return.
    /// The folder is asked on another thread for at most `deadline`; no answer is not gone.
    static func whyGone(_ entry: Entry, in directory: URL, deadline: DispatchTimeInterval = .seconds(2),
                        probe: @escaping @Sendable (_ root: String, _ parent: String) -> Bool
                            = { isGone($0) && isDirectory($1) }) -> String? {
        if isGone(directory.appendingPathComponent(entry.profileId).path) {
            return "its profile folder \(entry.profileId) is gone"
        }
        let root = expanded(entry.root)
        let parent = (root as NSString).deletingLastPathComponent
        let comesBack = ["/Volumes", expanded("~/Library/CloudStorage")]
        let iCloudDrive = expanded("~/Library/Mobile Documents")
        guard root.hasPrefix("/"), !comesBack.contains(parent),
              root != iCloudDrive, !root.hasPrefix(iCloudDrive + "/") else { return nil }
        final class Answer: @unchecked Sendable { var gone = false }
        let answer = Answer()
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            answer.gone = probe(root, parent)
            answered.signal()
        }
        guard answered.wait(timeout: .now() + deadline) == .success else {
            Logger.shared.warning("Restructure: \(entry.root) did not answer in time — its history "
                + "entry is kept")
            return nil
        }
        return answer.gone ? "the folder is gone" : nil
    }

    /// `lstat` answers "no such file" — not any other error.
    static func isGone(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - What a folder's history is

    /// The files a Setup folder's history is made of: Restructure's ledger, and the person
    /// verdicts (review R2) — `PersonTagKey.path` and every tag's `recordedPath` are paths
    /// relative to the folder walked, so a verdict on `Finance/2024 receipt.pdf` in one folder
    /// said nothing about the file of that name in another. The roster, `people.json`, is about
    /// people alone and still follows every walk.
    static let historyNames = ["restructure.json", "person-tags.json"]

    /// Whether `id`'s folder holds history the user made — in the ledger, a suppression, an
    /// answer, a draft, a landing, an acknowledged nudge; among the verdicts, any tag; in either,
    /// a section this build does not model. Absent holds nothing; a file that will not parse
    /// holds something, since unreadable is never treated as disposable.
    ///
    /// **The trend is not history** (review R1). The app stamps a trend point into the ledger
    /// after every Setup walk, so an empty ledger a walk just started holds one within the
    /// second — and counted here, it read as history, displaced the map entry naming the real
    /// history, and left that to the next sweep.
    static func holdsHistory(id: String, in directory: URL) -> Bool {
        let folder = directory.appendingPathComponent(id)
        return holdsUserState(at: folder.appendingPathComponent("restructure.json"),
                              ignoring: ["schemaVersion", "trend"])
            || holdsUserState(at: folder.appendingPathComponent("person-tags.json"),
                              ignoring: ["schemaVersion", "note"])
    }

    /// Whether the JSON object at `url` has a non-empty section other than `ignoring` — parsed
    /// whole, on the caller's actor, but never decoded into a ledger of inverses.
    private static func holdsUserState(at url: URL, ignoring: Set<String>) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return true }
        return object.contains { key, value in
            guard !ignoring.contains(key) else { return false }
            if let list = value as? [Any] { return !list.isEmpty }
            if let map = value as? [String: Any] { return !map.isEmpty }
            return !(value is NSNull)
        }
    }

    /// An empty ledger and an empty verdict file for `id`, where it has none — a Setup walk of a
    /// folder with no history of its own must not inherit the old folder's path-keyed state, but
    /// must hold both files, or the retire sweep's "only copy" rule keeps every old folder
    /// forever. Leaves an existing file alone.
    @MainActor
    static func startEmptyHistory(in directory: URL, profileId: String) {
        RestructureStore.startEmptyLedger(in: directory, profileId: profileId)
        PersonTagStore.startEmptyFile(in: directory, profileId: profileId)
    }

    // MARK: - What the retire sweep must keep

    /// Every profile id a returning folder's history needs on disk: each folder the map names,
    /// and each id its ledger's records name (`appliedUnderProfileId`, `producedProfileId`) —
    /// Undo re-points at those. Nil when the map, or a ledger it names, is unreadable: the sweep
    /// then cannot tell what a returning Undo needs, and retires nothing.
    static func protectedProfileIds(in directory: URL) -> Set<String>? {
        let entries: [Entry]
        switch read(in: directory) {
        case .unreadable(let why):
            Logger.shared.warning("Filing profiles: retired nothing — \(filename) \(why), so "
                + "which folders hold each Setup folder's Restructure history is unknown")
            return nil
        case .loaded(let loaded):
            entries = loaded
        }
        var ids: Set<String> = []
        for entry in entries {
            ids.insert(entry.profileId)
            switch ledgerRecords(id: entry.profileId, in: directory) {
            case .absent:
                continue
            case .unreadable:
                Logger.shared.warning("Filing profiles: retired nothing — the Restructure history "
                    + "of \(entry.root) in \(entry.profileId) could not be read, so the folders "
                    + "its Undo needs are unknown")
                return nil
            case .loaded(let records):
                for record in records {
                    if let id = record.appliedUnderProfileId { ids.insert(id) }
                    if let id = record.producedProfileId { ids.insert(id) }
                }
            }
        }
        return ids
    }

    // MARK: - The ledger, read for ids alone

    /// The three fields of a ledger record this needs, without building the manifests and
    /// inverses — though the whole file is still parsed, on the caller's actor: the main actor,
    /// for a Setup walk and for the retire sweep (review R8). `RestructureStore` is not used
    /// because it is a main-actor object that decodes, keeps and publishes the whole ledger.
    struct LedgerRecord: Decodable {
        let manifestId: String?
        let appliedUnderProfileId: String?
        let producedProfileId: String?
        private enum Key: String, CodingKey { case manifest, appliedUnderProfileId, producedProfileId }
        private struct ManifestProbe: Decodable { let manifestId: String? }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            manifestId = (try? c.decodeIfPresent(ManifestProbe.self, forKey: .manifest))??.manifestId
            appliedUnderProfileId = try? c.decodeIfPresent(String.self, forKey: .appliedUnderProfileId)
            producedProfileId = try? c.decodeIfPresent(String.self, forKey: .producedProfileId)
        }
    }

    /// Every landing the ledgers of `ids` hold, by manifest id — what an entry records as seen
    /// when its folder is left (``Entry/landingsSeen``). A ledger that cannot be read adds
    /// nothing, so its landings count as later — the cautious side.
    static func landings(in ids: [String], directory: URL) -> [String] {
        var seen: Set<String> = []
        for id in ids {
            guard case .loaded(let records) = ledgerRecords(id: id, in: directory) else { continue }
            seen.formUnion(records.compactMap(\.manifestId))
        }
        return seen.sorted()
    }

    private struct LedgerProbe: Decodable {
        let applied: [LedgerRecord]?
    }

    enum LedgerReading {
        case absent
        case loaded([LedgerRecord])
        case unreadable
    }

    static func ledgerRecords(id: String, in directory: URL) -> LedgerReading {
        let url = directory.appendingPathComponent("\(id)/restructure.json")
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
            return .absent
        }
        guard let data = try? Data(contentsOf: url),
              let probe = try? JSONDecoder().decode(LedgerProbe.self, from: data) else {
            return .unreadable
        }
        return .loaded(probe.applied ?? [])
    }

    // MARK: - Whether a returning Undo still describes the tree

    /// Why a returning Undo is withheld: the overlapping folder, and whether a landing there is
    /// KNOWN to have come after (`unsure` false) or only could have (review C9).
    struct Withholding: Equatable {
        let root: String
        let unsure: Bool
    }

    /// The first folder among `others` that overlaps `root` and holds a landing not in `seen` —
    /// one applied after the user left `root` — nil when there is none, and the returning
    /// folder's Undo may follow it.
    ///
    /// Overlap is one folder being the other or inside it, compared as given and again resolved:
    /// a landing in `~/Documents/Tax` reshapes `~/Documents`, and one in `~/Documents` reshapes
    /// `~/Documents/Tax`. **Ordered by what was there, not by the clock** (review R6). A `seen`
    /// of nil (an entry from before it was recorded), a landing with no id, and a ledger that
    /// cannot be read all count as later — the cautious side, which only withholds an Undo — and
    /// are answered `unsure`, so the card does not claim a reorganization it cannot see.
    static func laterOverlappingLanding(in root: String, seen: [String]?,
                                        others: [(root: String, profileId: String)],
                                        directory: URL) -> Withholding? {
        let seen = seen.map(Set.init)
        var unsure: Withholding?
        for other in others where rootsOverlap(root, other.root) {
            switch ledgerRecords(id: other.profileId, in: directory) {
            case .absent:
                continue
            case .unreadable:
                unsure = unsure ?? Withholding(root: other.root, unsure: true)
            case .loaded(let records):
                for record in records {
                    guard let seen, let id = record.manifestId else {
                        unsure = unsure ?? Withholding(root: other.root, unsure: true)
                        continue
                    }
                    if !seen.contains(id) { return Withholding(root: other.root, unsure: false) }
                }
            }
        }
        return unsure
    }

    /// Whether one folder is the other or inside it — as spelled, and again with links resolved,
    /// case folded where the volume folds it.
    static func rootsOverlap(_ a: String, _ b: String) -> Bool {
        if FilingProfileStore.namesSameRoot(a, b) { return true }
        let caseSensitive = FileSyncManager.volumeSupportsCaseSensitiveNames(
            for: URL(fileURLWithPath: expanded(a)))
        func spellings(_ path: String) -> [String] {
            let url = URL(fileURLWithPath: expanded(path)).standardizedFileURL
            return [url.path, url.resolvingSymlinksInPath().path].map {
                caseSensitive ? $0 : $0.lowercased()
            }
        }
        func inside(_ child: String, _ parent: String) -> Bool {
            parent == "/" ? child.hasPrefix("/") : child.hasPrefix(parent + "/")
        }
        for x in spellings(a) {
            for y in spellings(b) where x == y || inside(x, y) || inside(y, x) { return true }
        }
        return false
    }
}
