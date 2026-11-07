import Events
import Foundation

// MARK: - Key

/// What a cached classifier verdict is keyed on. The cache's rule: an unchanged file, asked the
/// same question, gets the same answer, so every input to that is in the key:
///
/// - `filePath`, `modifiedMillis`, `size`: the triple the sync engine trusts as "unchanged". Unlike
///   ``ContentHashKey`` it lacks file number and status-change time, so an edit that restores the
///   mtime and keeps the size is served the old verdict.
/// - `model`: switching models misses every entry and re-pays, which is correct.
/// - `promptVersion` (``CloudFilingProtocol/promptVersion``): new instructions or tool schema ask a
///   different question.
/// - `excludedRelativePaths`: a "Try another" re-ask is a different question. Sorted so ordering
///   can't split an entry.
///
/// Not keyed on the folder tree, or one new folder would re-pay every entry under its provider.
/// ``FilingVerdictCache/verdict(for:providerRoot:existingRelative:)`` drops a hit whose destination
/// lost its folders instead; gained folders leave entries valid ("Rescan (ignore cache)" asks anew).
///
/// `modifiedMillis` is an `Int` because the key is persisted, and a `Double` through JSON can stop
/// matching itself.
public struct FilingVerdictKey: Hashable, Codable, Sendable {
    public let filePath: String
    public let modifiedMillis: Int
    public let size: Int
    public let model: String
    public let promptVersion: Int
    public let excludedRelativePaths: [String]
    /// Digest of the filing artifacts the question was composed against
    /// (``FilingProfileStore/fingerprint(id:in:)``); empty on an unsurveyed tree. **A required init
    /// argument, never defaulted**, so dropping it at the scan is a build error rather than old
    /// verdicts replayed after the profile changes. Decoding does default it to empty, since a
    /// throwing decode would discard the whole cache file.
    public let artifacts: String

    /// Fails when the file's mtime or size is unknown, rather than standing in a value: `0` would
    /// be an ordinary-looking key, and a file whose contents change while its facts stay unreadable
    /// would be served its old verdict. nil turns the cache off for that file, read and write, as a
    /// nil ``FileSyncManager/filingArtifactFingerprint`` does. The cost is a re-ask, paid on the
    /// cloud tier, every scan for such a file; it is rare, and serving a stale paid answer is worse.
    public init?(filePath: String, modificationDate: Date?, size: Int?, model: String,
                 promptVersion: Int, excludedRelativePaths: [String] = [], artifacts: String) {
        guard let modificationDate, let size else { return nil }
        self.filePath = filePath
        self.modifiedMillis = Int((modificationDate.timeIntervalSince1970 * 1000).rounded())
        self.size = size
        self.model = model
        self.promptVersion = promptVersion
        self.excludedRelativePaths = excludedRelativePaths.sorted()
        self.artifacts = artifacts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decode(String.self, forKey: .filePath)
        modifiedMillis = try c.decode(Int.self, forKey: .modifiedMillis)
        size = try c.decode(Int.self, forKey: .size)
        model = try c.decode(String.self, forKey: .model)
        promptVersion = try c.decode(Int.self, forKey: .promptVersion)
        excludedRelativePaths = try c.decodeIfPresent([String].self, forKey: .excludedRelativePaths) ?? []
        artifacts = try c.decodeIfPresent(String.self, forKey: .artifacts) ?? ""
    }
}

// MARK: - Entry

/// One cached verdict, plus what is needed to decide it is still good.
public struct FilingVerdictCacheEntry: Codable, Sendable, Equatable {
    public let key: FilingVerdictKey
    /// The verdict's own fields, stored flat so the entry is one self-describing record.
    public let relativePath: String
    public let confidence: FilingConfidence
    public let reason: String
    /// How many trailing segments of the destination did NOT exist when this verdict was cached.
    /// The staleness test compares this against the same count resolved from the live taxonomy —
    /// see ``FilingVerdictCache/verdict(for:providerRoot:existingRelative:)``.
    public let newSegmentCount: Int
    /// Whether the backend declared it was proposing a folder that doesn't exist
    /// (``FilingVerdict/proposesNewFolder``). Stored, or every cached new-folder proposal would be
    /// trimmed to its existing parent on replay. Decodes as false when missing, so the file still
    /// loads.
    public let proposesNewFolder: Bool
    /// Where `relativePath` resolved to when this was recorded, provider-relative: used only by the
    /// staleness test. Kept apart from `relativePath`, the served answer, because the two differ
    /// whenever the resolver sanitizes (`A/B/file.pdf` resolves to `A/B`), and comparing against the
    /// raw string would miss and re-bill those every time. nil on older entries, which compare
    /// against the raw string until they are recorded again.
    public let resolvedRelativePath: String?
    /// When this entry was written. Used only to decide eviction order; never to expire an entry.
    public let cachedAt: Date

    public var verdict: FilingVerdict {
        FilingVerdict(relativePath: relativePath, confidence: confidence, reason: reason,
                      proposesNewFolder: proposesNewFolder)
    }

    public init(key: FilingVerdictKey, relativePath: String, confidence: FilingConfidence,
                reason: String, newSegmentCount: Int, cachedAt: Date,
                proposesNewFolder: Bool = false, resolvedRelativePath: String? = nil) {
        self.key = key
        self.relativePath = relativePath
        self.confidence = confidence
        self.reason = reason
        self.newSegmentCount = newSegmentCount
        self.cachedAt = cachedAt
        self.proposesNewFolder = proposesNewFolder
        self.resolvedRelativePath = resolvedRelativePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(FilingVerdictKey.self, forKey: .key)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        confidence = try c.decode(FilingConfidence.self, forKey: .confidence)
        reason = try c.decode(String.self, forKey: .reason)
        newSegmentCount = try c.decode(Int.self, forKey: .newSegmentCount)
        cachedAt = try c.decode(Date.self, forKey: .cachedAt)
        proposesNewFolder = try c.decodeIfPresent(Bool.self, forKey: .proposesNewFolder) ?? false
        resolvedRelativePath = try c.decodeIfPresent(String.self, forKey: .resolvedRelativePath)
    }
}

// MARK: - Cache

/// Classifier verdicts kept across scans and launches, so unchanged files are never re-classified,
/// or re-paid for on the cloud backend. Pure: no disk and no clock of its own;
/// ``FilingVerdictStore`` is the disk half, so these decisions test without a temp directory.
///
/// Entries never expire: the key holds everything the answer depended on. ``maxEntries`` only
/// bounds the file, and evicting is always safe, since a miss costs a re-ask, never a wrong answer.
public struct FilingVerdictCache: Sendable, Equatable {

    /// Bumped when the on-disk shape changes. A file of another schema isn't migrated: re-asking
    /// rebuilds it, and a migration is code to keep forever to save one scan.
    public static let currentSchema = 1

    /// Upper bound on retained entries; the oldest-written are dropped beyond it. Not a cliff like
    /// ``ContentHashCache``'s: the working set is one folder's loose files, and eviction is by age
    /// across every folder. At about 250 bytes an entry, 50 000 is about 12 MB.
    public static let maxEntries = 50_000

    public private(set) var entries: [FilingVerdictKey: FilingVerdictCacheEntry]

    public init(entries: [FilingVerdictKey: FilingVerdictCacheEntry] = [:]) {
        self.entries = entries
    }

    public var count: Int { entries.count }

    // MARK: Lookup

    /// The still-valid verdict for `key`, or nil for a miss. Two checks against the live tree:
    ///
    /// - The destination must not have lost folders it hangs off: resolving more new segments than
    ///   recorded is a different offer, so a miss. Fewer (someone made the folder) is a hit.
    /// - It must still resolve to the cached destination. An undeclared new folder is trimmed to its
    ///   existing parent
    ///   (``FilingEngine/destination(from:providerRoot:existingRelative:fileName:)``), so a deleted
    ///   parent can keep the count and land somewhere else entirely.
    public func verdict(for key: FilingVerdictKey, providerRoot: String,
                        existingRelative: Set<String>) -> FilingVerdict? {
        guard let entry = entries[key] else { return nil }
        guard let resolved = FilingEngine.destination(from: entry.verdict, providerRoot: providerRoot,
                                                      existingRelative: existingRelative)
        else { return nil }   // no longer resolves to a usable path at all
        guard resolved.newSegments.count <= entry.newSegmentCount else { return nil }
        // Compared against where it resolved when recorded, not just the model's raw string, which
        // differs for every answer the resolver sanitizes. Entries without a resolution use the raw
        // string until recorded again.
        let now = FilingEngine.relative(resolved.path, under: providerRoot)
        let raw = entry.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Either the recorded resolution or the answer itself: once the user creates the trimmed
        // folder, the resolution becomes the model's answer, a better offer and so a hit. Anywhere
        // else (a parent deleted, so it trims higher) is a miss.
        guard now == entry.resolvedRelativePath || now == raw else { return nil }
        return entry.verdict
    }

    // MARK: Recording

    /// Records `verdict` for `key` with how much of its destination is new now, for the staleness
    /// test. A verdict that doesn't resolve to a usable path isn't stored.
    public mutating func record(_ verdict: FilingVerdict, for key: FilingVerdictKey,
                                providerRoot: String, existingRelative: Set<String>, now: Date) {
        guard let resolved = FilingEngine.destination(from: verdict, providerRoot: providerRoot,
                                                      existingRelative: existingRelative)
        else { return }
        entries[key] = FilingVerdictCacheEntry(
            key: key, relativePath: verdict.relativePath, confidence: verdict.confidence,
            reason: verdict.reason, newSegmentCount: resolved.newSegments.count, cachedAt: now,
            proposesNewFolder: verdict.proposesNewFolder,
            resolvedRelativePath: FilingEngine.relative(resolved.path, under: providerRoot))
    }

    /// Drops the oldest-written entries until at most `limit` remain.
    public mutating func trim(to limit: Int = maxEntries) {
        guard entries.count > limit, limit >= 0 else { return }
        let survivors = entries.values
            .sorted { $0.cachedAt > $1.cachedAt }
            .prefix(limit)
        entries = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0) })
    }

    /// Forgets every entry for files under `root`: the per-provider clear.
    public mutating func removeAll(under root: String) {
        entries = entries.filter { !PathBoundary.contains($0.key.filePath, under: root) }
    }
}

// MARK: - Codable

extension FilingVerdictCache: Codable {
    private enum CodingKeys: String, CodingKey { case schema, entries }

    /// Encoded as a flat array of entries, each carrying its key. A struct-keyed `Dictionary`
    /// encodes as alternating keys and values, which reads as corrupt, and a joined string key
    /// could be forged by a path containing the separator.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        // **An unknown schema is not an empty cache.** Answering empty would let the next `save`
        // overwrite a newer build's file of paid answers. Thrown so the store can tell the case
        // apart and refuse to write (`FilingVerdictStore.load`).
        guard schema == Self.currentSchema else {
            throw ForeignSchema(found: schema, expected: Self.currentSchema)
        }
        let list = try container.decode([FilingVerdictCacheEntry].self, forKey: .entries)
        // The newest wins on a duplicate key: impossible from `record`, but a hand-edited file
        // shouldn't throw when keeping one is well defined.
        self.init(entries: Dictionary(list.map { ($0.key, $0) },
                                      uniquingKeysWith: { $0.cachedAt >= $1.cachedAt ? $0 : $1 }))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchema, forKey: .schema)
        try container.encode(entries.values.sorted { $0.cachedAt < $1.cachedAt }, forKey: .entries)
    }
}

/// Thrown by ``FilingVerdictCache/init(from:)`` for a file this build's decoder cannot claim.
struct ForeignSchema: Error {
    let found: Int
    let expected: Int
}

// MARK: - Store

/// The disk half of the verdict cache: where the file lives, and reading and writing it. In
/// Application Support, not UserDefaults: defaults are read whole by every process that touches the
/// domain, and this grows with the user's files, not their settings.
public enum FilingVerdictStore {

    /// `~/Library/Application Support/SyncCloud/filing-verdicts.json`. The app isn't sandboxed, so
    /// there is no container indirection.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/filing-verdicts.json")
    }

    /// Reads the cache at `url`. Every failure returns an empty cache, so the next scan re-asks.
    /// **A file that is there but unreadable is moved aside first**, so the next save can't
    /// overwrite its paid answers; re-asking is acceptable, deleting the bytes is not. Absent stays
    /// silent: a first launch has nothing to protect. If the move fails the guard stays armed, and
    /// `save` refuses and retries the move until it lands, as ``PersonTagStore`` and
    /// ``StorageLensStore`` do.
    public static func load(from url: URL, fileManager: FileManager = .default) -> FilingVerdictCache {
        guard let data = try? Data(contentsOf: url) else {
            // `attributesOfItem`, not `fileExists`: only it sees a symlink that doesn't resolve.
            if (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
                arm(url, why: "could not be opened")
                _ = setAsideUnreadable(url, fileManager: fileManager, next: loadWritesNothing)
            }
            return FilingVerdictCache()
        }
        do {
            return try JSONDecoder().decode(FilingVerdictCache.self, from: data)
        } catch let foreign as ForeignSchema {
            // **A newer build's cache is good data, not an unreadable file.** Setting it aside
            // would ping-pong between builds, each launch minting another ~12 MB dated copy nothing
            // sweeps. The file stays put, this launch works from memory, and `save` refuses.
            markForeignSchema(url, foreign)
            Logger.shared.warning("The Filing verdict cache at \(url.lastPathComponent) was written "
                                + "by a newer SyncCloud (schema \(foreign.found), this build reads "
                                + "\(foreign.expected)). It is left exactly as it is and nothing is "
                                + "cached to disk this launch — every scan re-asks (and, on the "
                                + "paid tier, pays) until you run the newer build again or move "
                                + "the file aside by hand.")
            return FilingVerdictCache()
        } catch {
            arm(url, why: "could not be decoded")
            _ = setAsideUnreadable(url, fileManager: fileManager, next: loadWritesNothing)
            return FilingVerdictCache()
        }
    }

    /// Paths holding a file of a schema this build doesn't know. Per path like ``armedPaths``, but
    /// never retried: the file can't become readable to this build. Nothing clears it within a
    /// launch, and `load` re-marks it on the next.
    nonisolated(unsafe) private static var foreignSchemaPaths: Set<String> = []

    private static func markForeignSchema(_ url: URL, _ foreign: ForeignSchema) {
        armedLock.lock(); defer { armedLock.unlock() }
        foreignSchemaPaths.insert(url.path)
    }

    private static func isForeignSchema(_ url: URL) -> Bool {
        armedLock.lock(); defer { armedLock.unlock() }
        return foreignSchemaPaths.contains(url.path)
    }

    /// Moves the unreadable cache aside so no queued snapshot write can land on the paid verdicts.
    /// The log line states only the set-aside; `next` is the caller's half, since `load` writes no
    /// fresh file and must not send the user looking for one. **Nothing here deletes anything:** the
    /// kept name is unique per episode (``UnreadableSetAside``), because an earlier set-aside is the
    /// only copy of its paid answers.
    @discardableResult
    private static func setAsideUnreadable(_ url: URL, fileManager: FileManager,
                                           next: String) -> Bool {
        let why = reasonArmed(url) ?? "could not be read"
        let kept = UnreadableSetAside.destination(for: url, at: Date(), fileManager: fileManager)
        do {
            try fileManager.moveItem(at: url, to: kept)
            disarm(url)
            Logger.shared.warning("Filing verdict cache at \(url.lastPathComponent) \(why) — it "
                                  + "has been kept as \(kept.lastPathComponent). \(next) The next "
                                  + "scan re-asks (and, on the paid tier, pays), but nothing was "
                                  + "overwritten.")
            return true
        } catch {
            // A source that is gone (deleted or moved since the failed read) leaves nothing to
            // overwrite, so disarm; staying armed would refuse every save this launch. Probed with
            // `attributesOfItem`, not the error code, so a dangling symlink, still a directory
            // entry, keeps refusing. As in `PersonTagStore.save`.
            if (try? fileManager.attributesOfItem(atPath: url.path)) == nil {
                disarm(url)
                Logger.shared.warning("The unreadable Filing verdict cache at "
                                      + "\(url.lastPathComponent) is no longer there — deleted or "
                                      + "moved since it failed to read. Nothing is left to set "
                                      + "aside. \(next)")
                return true
            }
            Logger.shared.error("Filing verdict cache at \(url.lastPathComponent) \(why) and could "
                                + "not be moved aside (\(error.localizedDescription)) — NOT "
                                + "overwriting it; this launch's verdicts stay in memory only, and "
                                + "the set-aside is attempted again on the next save.")
            return false
        }
    }

    /// What follows a set-aside made from ``load(from:fileManager:)``: nothing yet. A load writes no
    /// file, so the line says when a replacement appears rather than pointing at one.
    private static let loadWritesNothing =
        "Nothing has been written in its place — this launch starts with an empty cache in memory, "
        + "and a file is written only once it records a verdict."

    // MARK: - The armed guard

    /// Paths whose bytes couldn't be read and are not yet moved aside, with why. While armed, `save`
    /// refuses, so an empty cache never overwrites paid verdicts whose rescue failed. Keyed by path,
    /// not instance, because the protected thing is a file reached through static calls from two
    /// places (a detached load, the write queue). A lock, because `load` doesn't run on the queue.
    private static let armedLock = NSLock()
    /// `nonisolated(unsafe)` because every access is under `armedLock`, an invariant the compiler
    /// can't see.
    nonisolated(unsafe) private static var armedPaths: [String: String] = [:]

    private static func arm(_ url: URL, why: String) {
        armedLock.lock(); defer { armedLock.unlock() }
        armedPaths[url.path] = why
    }

    private static func disarm(_ url: URL) {
        armedLock.lock(); defer { armedLock.unlock() }
        armedPaths[url.path] = nil
    }

    private static func reasonArmed(_ url: URL) -> String? {
        armedLock.lock(); defer { armedLock.unlock() }
        return armedPaths[url.path]
    }

    /// Serializes writes. Every writer hands its whole snapshot here, so the last queued one is the
    /// current state (scans and Clears alike) and the file converges on it. **Only if every writer
    /// uses this queue:** a synchronous `save` racing a queued pre-clear snapshot could resurrect a
    /// cleared cache. New writers use ``saveInBackground(_:to:)``; `save` is for paths with no
    /// possible concurrent writer.
    private static let writeQueue = DispatchQueue(label: "com.synccloud.filing-verdict-store")

    /// Writes `cache` off the calling thread, in order. The caller is the `@MainActor`
    /// `FileSyncManager`, and encoding and writing ~10 MB there would hitch every scan. Nothing
    /// waits: the in-memory copy is authoritative, and a write lost to a quit costs a re-ask.
    public static func saveInBackground(_ cache: FilingVerdictCache, to url: URL) {
        writeQueue.async { _ = save(cache, to: url) }
    }

    /// Blocks until every queued write has finished. For tests only: one that builds a second
    /// manager to load the first's entries would otherwise race the background write. A barrier on
    /// the serial queue makes the wait exact, not timed.
    public static func waitForPendingWrites() {
        writeQueue.sync {}
    }

    /// Writes `cache` to `url`, creating the enclosing directory. Best-effort: a failed write costs
    /// a re-ask on the next scan and nothing else, so it is logged rather than surfaced.
    /// Synchronous — prefer ``saveInBackground(_:to:)`` from the main actor.
    @discardableResult
    public static func save(_ cache: FilingVerdictCache, to url: URL,
                            fileManager: FileManager = .default) -> Bool {
        // **No write until the rescue has landed.** While armed, the bytes at `url` are unread paid
        // verdicts, and an atomic write (which needs only directory permission) would destroy them.
        // Retried each save; safe because nothing writes `url` while armed, so each attempt moves
        // the user's bytes. Meanwhile verdicts live in memory and the error repeats per save.
        // A newer build's file is never written or moved; silent here, since `load` already said so.
        guard !isForeignSchema(url) else { return false }
        if reasonArmed(url) != nil,
           !setAsideUnreadable(url, fileManager: fileManager,
                               next: "A fresh cache is written beside it.") {
            return false
        }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Logger.shared.warning("Couldn't save the Filing verdict cache: \(error.localizedDescription)")
            return false
        }
    }
}
