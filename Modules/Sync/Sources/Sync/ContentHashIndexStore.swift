import Events
import Foundation

/// One persisted digest: the ``ContentHashKey`` fields, the hash, and when it was recorded.
///
/// `mtime` stays a `TimeInterval` rather than being quantized the way ``FilingVerdictKey`` does it.
/// The reason is that this field must reproduce a key built at hashing time from
/// `attributesOfItem[.modificationDate]`, so any rounding here would make every reloaded entry miss
/// the very lookups it exists to serve. That is only safe because `Double` round-trips JSON
/// exactly — verified against 200 000 realistic sub-millisecond mtimes through both `JSONEncoder`
/// and `JSONSerialization`, zero bit-pattern mismatches — which is precisely the guarantee the
/// verdict cache could not rely on, because there the key is *constructed* rather than reproduced.
public struct ContentHashRecord: Codable, Sendable, Equatable {
    public let path: String
    public let mtime: TimeInterval
    public let size: Int
    public let hex: String
    public let storedAt: Date

    public init(path: String, mtime: TimeInterval, size: Int, hex: String, storedAt: Date) {
        self.path = path
        self.mtime = mtime
        self.size = size
        self.hex = hex
        self.storedAt = storedAt
    }
}

/// The on-disk half of ``ContentHashCache`` — where the index lives, and reading/writing it.
///
/// Deliberately its own store rather than a generalization of ``FilingVerdictStore``, which has the
/// same shape. Two is not yet a pattern, and separate write queues are the more correct arrangement
/// here anyway: this index is orders of magnitude larger than the verdict cache, and funnelling
/// both through one queue would make a small verdict write wait behind a multi-megabyte one.
public enum ContentHashIndexStore {

    /// Bumped when the record shape changes. A file from another schema is discarded rather than
    /// migrated — every entry is reconstructible by re-hashing, so a migration would be permanent
    /// code in exchange for one avoided re-scan.
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
    /// Its own file, so a change to ``ContentFingerprint/scheme`` can be answered by deleting this
    /// one and nothing else. (Nothing deletes it today: a digest carries its scheme in the string
    /// it hashed, so an old entry simply stops matching new ones and ages out under
    /// ``ContentHashCache/maxEntryAge`` — wrong-looking rather than wrong.)
    public static func defaultFingerprintURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/content-fingerprint-index.json")
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

    /// Encodes and writes off the calling thread.
    ///
    /// The encode is the expensive half here, not the write: at the entry cap this is on the order
    /// of a hundred thousand records, and doing that on the actor would stall every hasher waiting
    /// on it. Nothing awaits the result — the in-memory cache is authoritative for this launch, and
    /// a write lost to a quit costs re-hashing, not correctness.
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

    /// Bytes the index occupies on disk, or nil when there is no file yet.
    ///
    /// A `stat`, deliberately, not a decode: this answers "what is SyncCloud storing", which is a
    /// question about the file rather than about its contents, and the entry count would cost a
    /// full parse of the largest thing this app writes to say something less useful.
    public static func sizeOnDisk(at url: URL, fileManager: FileManager = .default) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size].flatMap { $0 as? NSNumber }?.intValue
    }

    /// Deletes the index file. Serialized with the writes, so a save already queued cannot land
    /// after the delete and resurrect it.
    ///
    /// **Not the whole of forgetting.** ``ContentHashCache`` holds this session's digests in
    /// memory and would write them straight back on its next `save()`, so the user-facing erase is
    /// ``ContentHashCache/forgetPersistedIndex()``, which drops both halves. This is the disk half
    /// alone and exists for that method to call.
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

    /// Blocks until queued writes finish — see ``FilingVerdictStore/waitForPendingWrites()`` for
    /// why a barrier rather than a wait-and-hope. **Never call it on the main actor**: it parks
    /// the calling thread behind whatever is queued, which here can be a multi-megabyte encode.
    /// Tests call it from their own context; the one production caller (Settings' Clear) hops to
    /// a detached task first.
    public static func waitForPendingWrites() {
        writeQueue.sync {}
    }
}
