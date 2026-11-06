import Events
import Foundation

/// One persisted digest: the ``ContentHashKey`` fields, the hash, when it was recorded, and when a
/// lookup last used it.
///
/// `mtime` stays an unrounded `TimeInterval`, unlike ``FilingVerdictKey``'s: it must reproduce the
/// key built at hashing time from `attributesOfItem[.modificationDate]`, and any rounding would make
/// every reloaded entry miss. Safe because `Double` round-trips JSON exactly, which holds for a
/// reproduced key but not for the verdict cache's constructed one.
public struct ContentHashRecord: Codable, Sendable, Equatable {
    public let path: String
    public let mtime: TimeInterval
    public let size: Int
    public let hex: String
    public let storedAt: Date
    /// ``ContentHashKey/fileNumber`` and ``ContentHashKey/statusChanged``; absent for a key the disk
    /// couldn't answer them for, and in an older record.
    public let fileNumber: UInt64?
    public let statusChanged: TimeInterval?
    /// When a lookup last used this digest, which ``ContentHashCache/maxEntryAge`` counts from.
    /// Absent in an older record, which then counts from `storedAt`.
    public let lastUsed: Date?

    public init(path: String, mtime: TimeInterval, size: Int, hex: String, storedAt: Date,
                fileNumber: UInt64? = nil, statusChanged: TimeInterval? = nil,
                lastUsed: Date? = nil) {
        self.path = path
        self.mtime = mtime
        self.size = size
        self.hex = hex
        self.storedAt = storedAt
        self.fileNumber = fileNumber
        self.statusChanged = statusChanged
        self.lastUsed = lastUsed
    }
}

/// The on-disk half of ``ContentHashCache``: where the index lives, and reading and writing it.
/// Its own store, not shared with ``FilingVerdictStore``, so a small verdict write never waits on
/// its queue behind this far larger index.
public enum ContentHashIndexStore {

    /// Bumped when the record shape changes. A file from another schema is discarded, not migrated:
    /// every entry can be rebuilt by re-hashing.
    ///
    /// Adding an optional field needs no bump. `fileNumber`, `statusChanged` and `lastUsed` decode as
    /// absent from an older file; an entry keyed without the identity fields never matches a real
    /// file's key, so it is never served and ages out under ``ContentHashCache/maxEntryAge``. An
    /// older build reading a newer file ignores the new fields.
    public static let currentSchema = 1

    /// `~/Library/Application Support/SyncCloud/content-hash-index.json`. Alongside the verdict
    /// cache, and like it, only ever passed in by the app.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/content-hash-index.json")
    }

    /// `~/Library/Application Support/SyncCloud/content-fingerprint-index.json` — the same records
    /// holding ``ContentFingerprint`` digests, for ``ContentHashCache/sharedFingerprints``.
    ///
    /// Its own file, so a change to ``ContentFingerprint/scheme`` is answered by deleting this one
    /// alone. It must be deleted: entries live while used, so an unchanged file would keep its
    /// old-scheme digest for good.
    public static func defaultFingerprintURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/content-fingerprint-index.json")
    }

    /// `~/Library/Application Support/SyncCloud/content-textless-index.json`: documents found to
    /// have too little text, for ``ContentHashCache/sharedTextless``. Its own file so no older build
    /// reads a negative as a digest; see there.
    public static func defaultTextlessURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/content-textless-index.json")
    }

    private struct Payload: Codable {
        let schema: Int
        let records: [ContentHashRecord]
    }

    /// Reads the index at `url`. Every failure — missing, unreadable, wrong schema — yields an
    /// empty result, because the consequence is re-hashing rather than a wrong answer.
    public static func load(from url: URL) -> [ContentHashRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            Logger.shared.warning("Content-hash index at \(url.lastPathComponent) could not be read — starting a fresh one")
            return []
        }
        guard payload.schema == currentSchema else { return [] }
        return payload.records
    }

    /// Serializes writes so a later, larger snapshot cannot be overtaken by an earlier one.
    private static let writeQueue = DispatchQueue(label: "com.synccloud.content-hash-index")

    /// Encodes and writes off the calling thread. The encode is the costly half (up to a hundred
    /// thousand records) and would stall every hasher on the actor. Nothing awaits it: the in-memory
    /// cache is authoritative, and a write lost to a quit costs re-hashing, not correctness.
    public static func saveInBackground(_ records: [ContentHashRecord], to url: URL) {
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(Payload(schema: currentSchema, records: records))
                try data.write(to: url, options: .atomic)
                Logger.shared.debug("Content-hash index saved — \(records.count) entr\(records.count == 1 ? "y" : "ies")")
            } catch {
                Logger.shared.warning("Couldn't save the content-hash index: \(error.localizedDescription)")
            }
        }
    }

    /// Bytes the index occupies on disk, or nil when there is no file yet. A `stat`, not a decode:
    /// it answers what SyncCloud stores, and an entry count would cost a full parse.
    public static func sizeOnDisk(at url: URL, fileManager: FileManager = .default) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size].flatMap { $0 as? NSNumber }?.intValue
    }

    /// Deletes the index file. Serialized with the writes, so a save already queued can't land after
    /// the delete and resurrect it. Only the disk half: the user-facing erase is
    /// ``ContentHashCache/forgetPersistedIndex()``, since the cache would write its in-memory
    /// digests straight back.
    static func deleteInBackground(at url: URL) {
        writeQueue.async {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Nothing to delete is the desired end state, not a failure.
            } catch {
                Logger.shared.warning("Couldn't delete the content-hash index: \(error.localizedDescription)")
            }
        }
    }

    /// Blocks until queued writes finish, as a barrier (see
    /// ``FilingVerdictStore/waitForPendingWrites()``). **Never call it on the main actor**: it parks
    /// the thread behind whatever is queued, which can be a multi-megabyte encode. Settings' Clear,
    /// the one production caller, hops to a detached task first.
    public static func waitForPendingWrites() {
        writeQueue.sync {}
    }
}
