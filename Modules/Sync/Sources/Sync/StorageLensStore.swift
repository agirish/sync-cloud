import Events
import Foundation

/// The last Storage Lens report for each scanned root, kept across launches.
///
/// **Storage is the only lens whose results are restored, and the reason is what its actions do.**
/// Duplicates and Organize both attach a destructive apply to a row — trash this copy, move this
/// file — so a restored row is an offer to act on a world that may have moved on since. Storage
/// never mutates anything; its one action is Reveal in Finder. Restoring it therefore risks a
/// stale *reading*, which the freshness marker states outright, rather than a stale *offer*.
///
/// The counterpart for the other two lenses is not restoring their results but making the rescan
/// cheap — the verdict cache and the persisted hash index.
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
/// Small by construction, unlike the other two on-disk caches: a report holds `topN` rows per list
/// (20) and `treemapBuckets` areas (8), so one snapshot is tens of kilobytes however large the tree
/// it describes. That is why this one loads synchronously and keeps every root, where the hash
/// index needed a background load and an eviction policy.
public enum StorageLensStore {

    /// Bumped when the snapshot shape changes; a foreign schema is discarded rather than migrated,
    /// for the same reason as the other stores — the contents are a re-scan away.
    public static let currentSchema = 1

    /// How many roots to keep. Someone who points Storage at a dozen folders should not accumulate
    /// snapshots forever, and the oldest is the least likely to be wanted.
    public static let maxRoots = 12

    /// `~/Library/Application Support/SyncCloud/storage-lens.json`. Injected by the app, never
    /// defaulted inside `Sync` — same rule as the verdict cache and the hash index, and for the
    /// same reason: library code must not reach into the real home directory just because nobody
    /// said otherwise.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/storage-lens.json")
    }

    private struct Payload: Codable {
        let schema: Int
        let snapshots: [StorageLensSnapshot]
    }

    /// How a read of the snapshot file went.
    ///
    /// **Absent, unreadable and foreign-schema all answered `[]`, and both writers are
    /// read-modify-writes over that answer.** So an unreadable file did not cost a re-scan, which
    /// is what the doc claimed: the next analysis wrote a file holding ONE snapshot and the other
    /// eleven roots were gone, and "Forget this root" filtered an empty list to an empty list,
    /// which trips the delete-the-file guard below — forget one silently meaning forget all.
    /// `FilingProfileStore.indexForAmending` is the sibling that gets this right: it refuses to
    /// amend what it could not read.
    ///
    /// A schema this build does not know is treated as unreadable rather than as empty, and that
    /// is the sharper half: a NEWER build's file is perfectly good data, and overwriting it is not
    /// a recovery.
    enum Read {
        /// No file. Nothing to lose, and a scan writes the first one.
        case absent
        /// A file that could not be opened at all (mode 000, an ACL, an I/O error, a dangling
        /// symlink), one that could not be decoded, or one written under another schema.
        case unreadable
        case loaded([StorageLensSnapshot])
    }

    static func read(from url: URL) -> Read {
        guard let data = try? Data(contentsOf: url) else {
            // **"Absent" and "there but unreadable" are different answers**, and a `try?` alone
            // conflates them — the same read-layer hole this file fixed at the parse layer. A
            // file that exists but cannot be opened — mode 000, an ACL, an I/O error — read as a
            // first scan, so `saveInBackground` merged into `[]` and overwrote one snapshot over
            // up to twelve roots. `attributesOfItem` rather than `fileExists`, because only the
            // former sees a symlink that does not resolve: `fileExists` follows links and answers
            // false for one whose target is on an unmounted volume — and the write then replaces
            // the link itself.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                return .unreadable
            }
            return .absent
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return .unreadable }
        guard payload.schema == currentSchema else { return .unreadable }
        return .loaded(payload.snapshots.sorted { $0.completedAt > $1.completedAt })
    }

    /// Every stored snapshot, newest first. Absent and unreadable both read as empty here, which is
    /// right for the DISPLAY callers this serves: a missing report costs a re-scan. A caller about
    /// to WRITE must use ``read(from:)``, because for it the two are not the same fact at all.
    public static func load(from url: URL) -> [StorageLensSnapshot] {
        if case .loaded(let snapshots) = read(from: url) { return snapshots }
        return []
    }

    /// Moves an unreadable file aside so a fresh one can be written without destroying it, and
    /// answers **where it went** — nil when the move failed.
    ///
    /// A nil answer means the caller must not write: the whole point is that the bytes survive,
    /// and a write that lands on top of them after a failed rename is the original defect with
    /// extra steps. It is also the only thing that lets each caller say what actually happened —
    /// `clearInBackground` used to discard the result entirely and report a rescue either way.
    ///
    /// **The kept name is unique PER EPISODE — see ``UnreadableSetAside``, and nothing here
    /// deletes anything.** The old fixed slot plus its unconditional pre-move `removeItem` is the
    /// shape the other two stores were fixed out of: a second episode destroyed the first
    /// episode's kept file, and a move that then failed left neither it nor a protected current
    /// file. Snapshots are re-scannable, so the stakes are lower here than in the verdict cache —
    /// which is a reason to share the fix, not to keep a second spelling of the defect.
    ///
    /// This line claims only the set-aside itself. What happens NEXT differs by caller — a save
    /// writes a fresh file beside the kept one, a forget writes nothing at all — so each says its
    /// own half rather than this one promising a "fresh file" that a forget never produces.
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
    public static func snapshot(for root: String, from url: URL) -> StorageLensSnapshot? {
        load(from: url).first { $0.root == root }
    }

    /// Bytes the snapshot file occupies, or nil when there is none. A `stat`, like the hash
    /// index's — see ``ContentHashIndexStore/sizeOnDisk(at:fileManager:)``.
    public static func sizeOnDisk(at url: URL, fileManager: FileManager = .default) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size].flatMap { $0 as? NSNumber }?.intValue
    }

    private static let writeQueue = DispatchQueue(label: "com.synccloud.storage-lens-store")

    /// Replaces the snapshot for `snapshot.root` and writes the file, off the calling thread.
    ///
    /// Read-modify-write happens ON the queue rather than at the call site, so two roots analyzed
    /// in quick succession cannot each read the same prior state and have the second write erase
    /// the first's snapshot.
    public static func saveInBackground(_ snapshot: StorageLensSnapshot, to url: URL) {
        writeQueue.async {
            let existing: [StorageLensSnapshot]
            switch read(from: url) {
            case .loaded(let snapshots): existing = snapshots
            case .absent: existing = []
            case .unreadable:
                // The file is kept and a fresh one is written beside it. Merging into `[]` without
                // this is what silently replaced eleven roots with one.
                guard setAsideUnreadable(url) != nil else {
                    Logger.shared.error("Storage snapshots: this analysis was not saved — the "
                                        + "unreadable file could not be moved out of its way.")
                    return
                }
                existing = []
            }
            var all = existing.filter { $0.root != snapshot.root }
            all.insert(snapshot, at: 0)
            write(Array(all.prefix(maxRoots)), to: url)
        }
    }

    /// Forgets the snapshot for `root`, or every one when `root` is nil.
    ///
    /// **"Forget this root" may not empty the file it could not read.** Filtering `[]` yields `[]`,
    /// and `write` reads an empty list as "delete the file" — so one unreadable byte turned a
    /// request to forget ONE root into forgetting all twelve, with the request itself as the
    /// trigger. Forget-all is unaffected: that is what the user asked for either way.
    public static func clearInBackground(root: String?, from url: URL,
                                        fileManager: FileManager = .default) {
        writeQueue.async {
            guard let root else { write([], to: url); return }
            switch read(from: url) {
            case .absent:
                return                                    // nothing to forget
            case .unreadable:
                // Kept rather than deleted, and the request is refused rather than applied to a
                // list this build cannot see.
                //
                // **Both outcomes are said, and neither claims the other's facts.** This ignored
                // the move's result and logged "It has been kept beside the fresh one" whatever
                // happened: a failed move read as a successful rescue, sending a user to look for
                // a kept file that was never written. The "fresh one" was wrong in the other
                // direction too — forgetting a root writes no file at all, so on the success path
                // the only thing beside the kept file is nothing.
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
                write(snapshots.filter { $0.root != root }, to: url)
            }
        }
    }

    private static func write(_ snapshots: [StorageLensSnapshot], to url: URL) {
        do {
            // Empty means DELETE, not "write an empty payload". `load` cannot tell the two apart —
            // both answer `[]` — but anything asking what this store occupies on disk can, and a
            // Clear that left 27 bytes of `{"schema":1,"snapshots":[]}` behind reads as a Clear
            // that did not work. Nothing else writes an empty list: `saveInBackground` always
            // inserts one.
            guard !snapshots.isEmpty else {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // Already absent is the desired end state.
                }
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
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
