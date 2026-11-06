import Events
import Foundation

/// The last Storage Lens report for each scanned root, kept across launches.
///
/// Storage is the only lens whose results are restored. Duplicates and Organize attach a
/// destructive apply to each row, so a restored row would offer to act on a world that may have
/// moved on. Storage only offers Reveal in Finder, so the worst case is a stale reading, which the
/// freshness marker states. The other lenses make the rescan cheap instead (the verdict cache and
/// the hash index).
public struct StorageLensSnapshot: Codable, Sendable, Equatable {
    /// Absolute path of the root this report describes.
    public let root: String
    public let report: StorageLensReport
    /// When the scan that produced it completed — what the freshness marker counts from.
    public let completedAt: Date

    public init(root: String, report: StorageLensReport, completedAt: Date) {
        self.root = root
        self.report = report
        self.completedAt = completedAt
    }
}

/// Reads and writes ``StorageLensSnapshot``s, keyed by root.
///
/// Small by construction: a report holds `topN` rows per list and `treemapBuckets` areas, so a
/// snapshot is tens of kilobytes however large the tree. So it loads synchronously and needs no
/// eviction beyond ``maxRoots``, unlike the hash index.
public enum StorageLensStore {

    /// Bumped when the snapshot shape changes. A foreign schema is never migrated (the contents
    /// are a re-scan away); see ``Read/foreignSchema(_:)`` for how it is handled.
    public static let currentSchema = 1

    /// How many roots to keep; the oldest snapshot is dropped first.
    public static let maxRoots = 12

    /// `~/Library/Application Support/SyncCloud/storage-lens.json`. Injected by the app, never
    /// defaulted inside `Sync`, like the verdict cache and hash index: library code must not reach
    /// into the real home directory by default.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/storage-lens.json")
    }

    private struct Payload: Codable {
        let schema: Int
        let snapshots: [StorageLensSnapshot]
    }

    /// Just the version stamp, decoded on its own so a file this build can't fully decode can
    /// still say which schema wrote it. See `read(from:)` for why the order matters.
    private struct SchemaProbe: Codable {
        let schema: Int
    }

    /// How a read of the snapshot file went. Both writers read-modify-write, so they must tell
    /// these apart: treating an unreadable file as empty would let one save replace every other
    /// root's snapshot, and a forget empty the whole file (as
    /// `FilingProfileStore.indexForAmending` refuses to amend what it couldn't read).
    ///
    /// A foreign schema is its own case, not an unreadable one: a newer build's file is good data,
    /// and setting it aside would repeat on every launch of an old/new pair, minting a dated file
    /// each time that nothing sweeps. So it is left in place, this build works from memory, and the
    /// write is refused, as the log says.
    enum Read {
        /// No file. Nothing to lose, and a scan writes the first one.
        case absent
        /// A file that could not be opened at all (mode 000, an ACL, an I/O error, a dangling
        /// symlink), or one that could not be decoded. Set aside before anything is written.
        case unreadable
        /// A file written under a schema this build does not know — good data it cannot read.
        /// Never moved, never overwritten, and no write proceeds past it.
        case foreignSchema(Int)
        case loaded([StorageLensSnapshot])
    }

    /// `fileManager` drives only the presence probe; `Data(contentsOf:)` takes none and is not
    /// faked. A test's double decides present-vs-absent, which is what decides whether a set-aside
    /// is needed.
    static func read(from url: URL, fileManager: FileManager = .default) -> Read {
        guard let data = try? Data(contentsOf: url) else {
            // Absent and "there but unreadable" are different answers: read as a first scan, a
            // file that can't be opened would be overwritten with one snapshot. `attributesOfItem`,
            // not `fileExists`, which follows links and answers false for a dangling one, so the
            // write would replace the link itself.
            guard (try? fileManager.attributesOfItem(atPath: url.path)) == nil else {
                return .unreadable
            }
            return .absent
        }
        // The schema is read before the payload. A newer build that changed `StorageLensSnapshot`
        // fails this build's `Payload` decode, and read in the other order that file would be
        // `.unreadable` and set aside on every launch, the ping-pong `Read` describes.
        guard let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data) else {
            return .unreadable
        }
        guard probe.schema == currentSchema else { return .foreignSchema(probe.schema) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return .unreadable }
        return .loaded(payload.snapshots.sorted { $0.completedAt > $1.completedAt })
    }

    /// Every stored snapshot, newest first. Absent and unreadable both read as empty, which suits
    /// display: a missing report costs a re-scan. A caller about to write must use
    /// ``read(from:fileManager:)``, for which the two are different facts.
    public static func load(from url: URL, fileManager: FileManager = .default) -> [StorageLensSnapshot] {
        // Memoised against the file's modification date and size, so a repeated read is one
        // `stat`. The app calls this on many triggers (workspace, appearance, root, lens, scope),
        // and when a root has no snapshot nothing stops them, so each would decode every saved
        // report on the main actor. Writes are `.atomic`, so a save gives the file a fresh date and
        // invalidates the memo by itself. An absent file has a stamp too (both halves nil).
        //
        // The writers call `read` directly: for them absent, unreadable and foreign-schema are
        // different facts, which a display memo doesn't answer.
        let stamp = Stamp(of: url, fileManager: fileManager)
        if let memoised = decodeMemo.value(for: stamp) { return memoised }
        var snapshots: [StorageLensSnapshot] = []
        if case .loaded(let decoded) = read(from: url, fileManager: fileManager) { snapshots = decoded }
        decodeMemo.store(snapshots, for: stamp)
        return snapshots
    }

    /// What a file looked like when it was last decoded: which file, and the two attributes an
    /// atomic replacement always changes. Absent is a stamp too (both nil), so "nothing saved"
    /// memoises like anything else.
    struct Stamp: Equatable {
        let path: String
        let modified: Date?
        let size: Int?

        init(of url: URL, fileManager: FileManager) {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            self.path = url.path
            self.modified = attributes?[.modificationDate] as? Date
            self.size = (attributes?[.size] as? NSNumber)?.intValue
        }
    }

    /// The decoded files, each held against its own stamp.
    ///
    /// Locked rather than actor-isolated, so callers on any thread needn't `await` a cheap call.
    /// Keyed by path for the tests, which run in parallel over their own files: a single slot would
    /// let them evict each other. Capped; the app (one store URL) never reaches the cap, and at it
    /// the memo simply empties.
    private final class DecodeMemo: @unchecked Sendable {
        static let capacity = 16

        private let lock = NSLock()
        private var entries: [String: (stamp: Stamp, snapshots: [StorageLensSnapshot])] = [:]

        func value(for stamp: Stamp) -> [StorageLensSnapshot]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[stamp.path], entry.stamp == stamp else { return nil }
            return entry.snapshots
        }

        func store(_ snapshots: [StorageLensSnapshot], for stamp: Stamp) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= Self.capacity, !entries.keys.contains(stamp.path) { entries.removeAll() }
            entries[stamp.path] = (stamp, snapshots)
        }

        func forget(path: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeValue(forKey: path)
        }
    }

    private static let decodeMemo = DecodeMemo()

    /// Drops one file's memo, for a test proving the memo answered; the app never needs it. One
    /// path, not the whole map: suites run in parallel, and clearing everything could land between
    /// another test's two reads.
    static func forgetDecodeMemo(for url: URL) { decodeMemo.forget(path: url.path) }

    /// Says a newer build's file is in the way, once per call, naming what to do about it.
    private static func refuseForeignSchema(_ url: URL, _ schema: Int, action: String) {
        Logger.shared.error("Storage snapshots at \(url.lastPathComponent) were written by a newer "
                            + "SyncCloud (schema \(schema), this build reads \(currentSchema)) — "
                            + "\(action). The file is good data this build cannot read, so it is "
                            + "left exactly as it is rather than replaced; move it aside by hand "
                            + "to start fresh on this build.")
    }

    /// Moves an unreadable file aside so nothing overwrites it, and answers where it went, or nil
    /// when the move failed. **On nil the caller must not write**, or it lands on the bytes this
    /// exists to keep.
    ///
    /// The kept name is unique per episode (``UnreadableSetAside``), and nothing here deletes, so a
    /// second episode can't destroy the first one's kept file. Its log line claims only the
    /// set-aside; each caller says what it did next (a save writes a fresh file, a forget nothing).
    private static func setAsideUnreadable(_ url: URL,
                                           fileManager: FileManager = .default) -> URL? {
        let kept = UnreadableSetAside.destination(for: url, at: Date(), fileManager: fileManager)
        do {
            try fileManager.moveItem(at: url, to: kept)
            Logger.shared.error("Storage snapshots at \(url.lastPathComponent) could not be read "
                                + "(or were written by a newer SyncCloud), so they have been kept "
                                + "as \(kept.lastPathComponent). Nothing was overwritten.")
            return kept
        } catch {
            Logger.shared.error("Storage snapshots at \(url.lastPathComponent) could not be read and "
                                + "could not be moved aside (\(error.localizedDescription)) — NOT "
                                + "overwriting them.")
            return nil
        }
    }

    /// The stored snapshot for `root`, if there is one.
    public static func snapshot(for root: String, from url: URL,
                                fileManager: FileManager = .default) -> StorageLensSnapshot? {
        load(from: url, fileManager: fileManager).first { $0.root == root }
    }

    /// Bytes the snapshot file occupies, or nil when there is none. A `stat`, like the hash
    /// index's — see ``ContentHashIndexStore/sizeOnDisk(at:fileManager:)``.
    public static func sizeOnDisk(at url: URL, fileManager: FileManager = .default) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size].flatMap { $0 as? NSNumber }?.intValue
    }

    private static let writeQueue = DispatchQueue(label: "com.synccloud.storage-lens-store")

    /// Replaces the snapshot for `snapshot.root` and writes the file, off the calling thread.
    ///
    /// Read-modify-write happens on the queue, not at the call site, so two roots analyzed in quick
    /// succession can't both read the same prior state and have the second erase the first.
    public static func saveInBackground(_ snapshot: StorageLensSnapshot, to url: URL,
                                        fileManager: FileManager = .default) {
        writeQueue.async {
            let existing: [StorageLensSnapshot]
            switch read(from: url, fileManager: fileManager) {
            case .loaded(let snapshots): existing = snapshots
            case .absent: existing = []
            case .foreignSchema(let schema):
                // Not an episode — see `Read`. Nothing is moved and nothing is written.
                refuseForeignSchema(url, schema, action: "this analysis was not saved")
                return
            case .unreadable:
                // Keep the file and write a fresh one beside it; merging into `[]` over it would
                // replace every other root's snapshot.
                guard setAsideUnreadable(url, fileManager: fileManager) != nil else {
                    Logger.shared.error("Storage snapshots: this analysis was not saved — the "
                                        + "unreadable file could not be moved out of its way.")
                    return
                }
                existing = []
            }
            var all = existing.filter { $0.root != snapshot.root }
            all.insert(snapshot, at: 0)
            write(Array(all.prefix(maxRoots)), to: url, fileManager: fileManager)
        }
    }

    /// Forgets the snapshot for `root`, or every one when `root` is nil.
    ///
    /// **"Forget this root" must not empty a file it couldn't read**: filtering `[]` yields `[]`,
    /// which `write` takes as "delete the file", forgetting every root. Forget-all is unaffected.
    public static func clearInBackground(root: String?, from url: URL,
                                        fileManager: FileManager = .default) {
        writeQueue.async {
            guard let root else { write([], to: url, fileManager: fileManager); return }
            switch read(from: url, fileManager: fileManager) {
            case .absent:
                return                                    // nothing to forget
            case .foreignSchema(let schema):
                refuseForeignSchema(url, schema,
                                    action: "“Forget this root” could not be applied")
                return
            case .unreadable:
                // Kept rather than deleted, and the request is refused rather than applied to a
                // list this build can't see. Each branch logs only what happened: a failed move
                // keeps nothing, and a forget never writes a fresh file.
                if let kept = setAsideUnreadable(url, fileManager: fileManager) {
                    Logger.shared.error("Storage snapshots: “Forget this root” could not be applied "
                                        + "to \(url.lastPathComponent) because the file could not be "
                                        + "read. It has been kept as \(kept.lastPathComponent) "
                                        + "rather than emptied — the other roots are in that file, "
                                        + "and nothing was written in its place.")
                } else {
                    Logger.shared.error("Storage snapshots: “Forget this root” could not be applied "
                                        + "to \(url.lastPathComponent) because the file could not be "
                                        + "read, and it could not be moved aside either — nothing "
                                        + "was emptied and the file is untouched.")
                }
            case .loaded(let snapshots):
                write(snapshots.filter { $0.root != root }, to: url, fileManager: fileManager)
            }
        }
    }

    private static func write(_ snapshots: [StorageLensSnapshot], to url: URL,
                              fileManager: FileManager = .default) {
        do {
            // Empty means delete, not "write an empty payload": `load` can't tell them apart, but
            // the size on disk can, and a Clear that left a file behind would look like it failed.
            // Only a forget writes an empty list; `saveInBackground` always inserts one.
            guard !snapshots.isEmpty else {
                do {
                    try fileManager.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // Already absent is the desired end state.
                }
                return
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Payload(schema: currentSchema, snapshots: snapshots))
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.warning("Couldn't save the Storage snapshot: \(error.localizedDescription)")
        }
    }

    /// Blocks until queued writes finish — see ``FilingVerdictStore/waitForPendingWrites()``.
    /// **Never on the main actor**; the one production caller (Settings' Clear) detaches first.
    public static func waitForPendingWrites() {
        writeQueue.sync {}
    }
}
