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

    /// Every stored snapshot, newest first. Any failure yields an empty list — a missing report
    /// costs a re-scan, which is exactly what the user got before this existed.
    public static func load(from url: URL) -> [StorageLensSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            Logger.shared.warning("Storage Lens snapshots at \(url.lastPathComponent) could not be read — starting fresh")
            return []
        }
        guard payload.schema == currentSchema else { return [] }
        return payload.snapshots.sorted { $0.completedAt > $1.completedAt }
    }

    /// The stored snapshot for `root`, if there is one.
    public static func snapshot(for root: String, from url: URL) -> StorageLensSnapshot? {
        load(from: url).first { $0.root == root }
    }

    private static let writeQueue = DispatchQueue(label: "com.synccloud.storage-lens-store")

    /// Replaces the snapshot for `snapshot.root` and writes the file, off the calling thread.
    ///
    /// Read-modify-write happens ON the queue rather than at the call site, so two roots analyzed
    /// in quick succession cannot each read the same prior state and have the second write erase
    /// the first's snapshot.
    public static func saveInBackground(_ snapshot: StorageLensSnapshot, to url: URL) {
        writeQueue.async {
            var all = load(from: url).filter { $0.root != snapshot.root }
            all.insert(snapshot, at: 0)
            write(Array(all.prefix(maxRoots)), to: url)
        }
    }

    /// Forgets the snapshot for `root`, or every one when `root` is nil.
    public static func clearInBackground(root: String?, from url: URL) {
        writeQueue.async {
            let remaining = root.map { r in load(from: url).filter { $0.root != r } } ?? []
            write(remaining, to: url)
        }
    }

    private static func write(_ snapshots: [StorageLensSnapshot], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Payload(schema: currentSchema, snapshots: snapshots))
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.warning("Couldn't save the Storage Lens snapshot: \(error.localizedDescription)")
        }
    }

    /// Blocks until queued writes finish. Tests only — see ``FilingVerdictStore/waitForPendingWrites()``.
    public static func waitForPendingWrites() {
        writeQueue.sync {}
    }
}
