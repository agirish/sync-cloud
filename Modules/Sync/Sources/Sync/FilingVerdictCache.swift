import Events
import Foundation

// MARK: - Key

/// What a cached classifier verdict is keyed on.
///
/// The rule the whole cache rests on: **an unchanged file, asked the same question, gets the same
/// answer.** Every input to that sentence is in this key —
///
/// - `filePath` + `modifiedMillis` + `size` identify the file. This is the same (path, mtime, size)
///   triple ``ContentHashKey`` uses and the sync engine already trusts to mean "unchanged"; an edit
///   bumps the mtime, so a stale entry is bypassed rather than served.
/// - `model` — an Opus verdict is not a Haiku verdict. Switching models in Settings therefore
///   misses every entry and re-pays, which is correct and is worth warning about in the UI.
/// - `promptVersion` — see ``CloudFilingProtocol/promptVersion``. Editing the instructions or the
///   tool schema changes the question being asked, so it must change the key.
/// - `excludedRelativePaths` — a "Try another" re-ask says *"not there"*, which is a different
///   question than the one whose answer is cached. Sorted here so ordering can't split an entry.
///
/// **Deliberately NOT keyed on the folder taxonomy.** Keying on the tree would mean one new folder
/// anywhere invalidates every entry under that provider and the next scan re-pays in full — which
/// defeats the point. The narrower guard lives in ``FilingVerdictCache/verdict(for:providerRoot:existingRelative:)``:
/// a hit is dropped when the folders its destination hangs off have since gone away. Gaining
/// folders leaves entries valid (the cached answer is still *an* answer, just possibly no longer
/// the best one — "Rescan (ignore cache)" is the way to ask afresh).
///
/// `modifiedMillis` is an `Int` rather than the `TimeInterval` ``ContentHashKey`` carries because
/// this key is persisted: a `Double` round-tripping through JSON is a needless way for a key to
/// stop matching itself. Milliseconds is far finer than any mtime this cares about.
public struct FilingVerdictKey: Hashable, Codable, Sendable {
    public let filePath: String
    public let modifiedMillis: Int
    public let size: Int
    public let model: String
    public let promptVersion: Int
    public let excludedRelativePaths: [String]
    /// Digest of the profile artifacts the question was composed against — see
    /// ``FilingProfileStore/fingerprint(id:in:)``. Empty on an unsurveyed tree, and on entries
    /// written before this existed, which is why it decodes with a default rather than failing:
    /// a shape change that throws discards the whole cache file, and those entries are still
    /// answers to the question a tree with no artifacts asks.
    /// A digest of the filing artifacts the question was composed against — see
    /// ``FilingProfileStore/fingerprint(id:in:)``.
    ///
    /// **Deliberately NOT defaulted.** It used to default to `""`, which meant the scan's
    /// `artifacts: filingArtifactFingerprint` argument could be deleted and everything still
    /// compiled — measured, and 2,246 Sync tests passed with it gone. What that costs is not
    /// hypothetical: regenerate the profile, rescan, and every verdict composed against the OLD
    /// tree is replayed until the cache is deleted by hand, and on the refine tier those are
    /// answers that were paid for. A required argument turns that deletion into a build error,
    /// which is the guard this repo prefers wherever a silent default can drop a fact.
    public let artifacts: String

    public init(filePath: String, modificationDate: Date?, size: Int, model: String,
                promptVersion: Int, excludedRelativePaths: [String] = [], artifacts: String) {
        self.filePath = filePath
        self.modifiedMillis = modificationDate.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
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
    /// Whether the backend DECLARED it was proposing a folder that does not exist — see
    /// ``FilingVerdict/proposesNewFolder``. Stored, because the entry reconstructs the verdict and
    /// a field dropped on the round trip comes back as "did not declare": every cached new-folder
    /// proposal would be trimmed to its existing parent on replay, silently turning a served hit
    /// into a different answer than the one that was cached. Decoded with a default so entries
    /// written before this existed still load rather than discarding the whole file.
    public let proposesNewFolder: Bool
    /// **Where `relativePath` actually resolved to when this was recorded**, provider-relative —
    /// the comparand for the staleness test below it, and nothing else.
    ///
    /// Separate from `relativePath` because that one is the *served answer*: the entry
    /// reconstructs `verdict` from it, so overwriting it with the resolution would change what a
    /// hit returns. And it has to exist, because the two differ for a whole class of verdicts —
    /// exactly the class the sanitizer was written for. `Immigration/OCI/Divit/eOCI.pdf` resolves
    /// to `Immigration/OCI/Divit` (the trailing file name is stripped); comparing the resolution
    /// against the raw string therefore failed *every* time, with nothing changed and nothing
    /// wrong, so those answers could never be served and were re-billed on every refine — the one
    /// thing this cache exists to prevent.
    ///
    /// Optional: entries written before this field existed have only the raw string, and for them
    /// the test below behaves exactly as it did. They heal on their next record.
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

/// Classifier verdicts kept across scans and launches, so a folder whose files have not changed is
/// never re-classified — and, when the backend is the paid cloud one, never re-paid for.
///
/// Pure: every operation here is a function of its inputs, with no disk access and no clock of its
/// own. ``FilingVerdictStore`` is the half that touches the filesystem, so the decisions this type
/// makes can be tested without a temp directory — the split ``DuplicateFinder`` and
/// ``FileSyncManager`` already use.
///
/// **Entries never expire.** As long as the key matches, the answer stands: the key already
/// contains everything the answer depended on, so an entry going stale with age would mean the key
/// is wrong, not that time passed. The one bound is ``maxEntries``, which exists so the file cannot
/// grow forever — and evicting is always safe, because the cost of a miss is a re-ask, never a
/// wrong answer.
public struct FilingVerdictCache: Sendable, Equatable {

    /// Bumped when the on-disk shape changes. A file written by a different schema is discarded
    /// rather than migrated: the whole contents are reconstructible by re-asking, so a migration
    /// would be code to maintain forever in exchange for one avoided re-scan.
    public static let currentSchema = 1

    /// Upper bound on retained entries; the oldest-written are dropped once exceeded.
    ///
    /// Unlike ``ContentHashCache``'s cap this is not a cliff — that one evicts a working set that
    /// is about to be re-read in the same pass, so overflowing it takes the hit rate to zero. Here
    /// the working set is one folder's loose files (tens to low hundreds), and eviction is by age
    /// across every folder ever scanned. At roughly 250 bytes an entry, 50 000 is about 12 MB and
    /// far more files than a person accumulates loose.
    public static let maxEntries = 50_000

    public private(set) var entries: [FilingVerdictKey: FilingVerdictCacheEntry]

    public init(entries: [FilingVerdictKey: FilingVerdictCacheEntry] = [:]) {
        self.entries = entries
    }

    public var count: Int { entries.count }

    // MARK: Lookup

    /// The still-valid verdict for `key`, or nil for a miss.
    ///
    /// Beyond the key matching, one thing is re-checked against the live folder tree: **the
    /// destination must not have lost the folders it hangs off.** A verdict naming
    /// `Documents/Vehicles/Tesla` when `Documents/Vehicles` existed proposed creating one folder;
    /// if `Documents/Vehicles` has since been deleted the same verdict now proposes creating two,
    /// and that is a different — and less likely to be wanted — offer than the one that was
    /// cached. Resolving more new segments than were recorded is exactly that condition, so it is
    /// treated as a miss and the file is re-classified.
    ///
    /// The inverse (resolving FEWER new segments, because someone created the folder in the
    /// meantime) is a hit: the answer got better, not worse.
    ///
    /// **And the destination it resolves to must still be the destination that was cached.** The
    /// segment count was a proxy for "the same offer", and it stopped being one when an undeclared
    /// new folder started being trimmed to its existing parent (see
    /// ``FilingEngine/destination(from:providerRoot:existingRelative:fileName:)``): a verdict for
    /// `Documents/Family/Divit` whose `Family` was deleted since now resolves to `Documents` — a
    /// count of zero, matching the cached zero, and a completely different folder. Comparing the
    /// path catches both that and anything else the resolver may learn to change.
    public func verdict(for key: FilingVerdictKey, providerRoot: String,
                        existingRelative: Set<String>) -> FilingVerdict? {
        guard let entry = entries[key] else { return nil }
        guard let resolved = FilingEngine.destination(from: entry.verdict, providerRoot: providerRoot,
                                                      existingRelative: existingRelative)
        else { return nil }   // no longer resolves to a usable path at all
        guard resolved.newSegments.count <= entry.newSegmentCount else { return nil }
        // Compared against **where it resolved when it was recorded**, not against the model's raw
        // string. Those are the same for most answers and deliberately different for the ones the
        // resolver sanitizes; comparing against the raw string made that whole class unservable.
        // Legacy entries carry no resolution and fall back to the old comparand — no worse than
        // before, and rewritten with one the next time they are recorded.
        let now = FilingEngine.relative(resolved.path, under: providerRoot)
        let raw = entry.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // **Either the resolution it was recorded with, or the answer itself.** Comparing only
        // against the recorded resolution turned a case that used to hit into a miss: a verdict
        // for `Documents/Family/Divit` recorded while `Divit` did not exist resolves to
        // `Documents/Family` and is stored as such — then the user CREATES `Divit`, the resolution
        // becomes the model's actual answer, and a strict comparison called that stale. It is the
        // opposite: the offer got better, which the paragraph above already promises is a hit.
        // A verdict that now resolves somewhere neither of those names — `Family` deleted, so it
        // trims to `Documents` — still misses, which is what the guard is for.
        guard now == entry.resolvedRelativePath || now == raw else { return nil }
        return entry.verdict
    }

    // MARK: Recording

    /// Records `verdict` for `key`, capturing how much of its destination is new *now* so the
    /// staleness test above has something to compare against later. A verdict that does not
    /// resolve to a usable path is not stored — there would be nothing to serve.
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

    /// Forgets every entry for files under `root` — the per-provider clear.
    public mutating func removeAll(under root: String) {
        entries = entries.filter { !PathBoundary.contains($0.key.filePath, under: root) }
    }
}

// MARK: - Codable

extension FilingVerdictCache: Codable {
    private enum CodingKeys: String, CodingKey { case schema, entries }

    /// Encoded as a flat ARRAY of entries, each carrying its own key, rather than as a dictionary.
    /// A Swift `Dictionary` with a struct key encodes as an unkeyed run of alternating keys and
    /// values, which is valid JSON but reads as corrupt to anything that opens the file; and a
    /// String-keyed form would need the key's fields joined into one string, which a path
    /// containing the separator could forge. The array keeps the on-disk form obvious and the
    /// in-memory form a real dictionary.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == Self.currentSchema else { self.init(); return }
        let list = try container.decode([FilingVerdictCacheEntry].self, forKey: .entries)
        // Last write wins on a duplicate key — impossible from `record`, but a hand-edited or
        // concatenated file should not throw when simply keeping one of them is well defined.
        self.init(entries: Dictionary(list.map { ($0.key, $0) },
                                      uniquingKeysWith: { $0.cachedAt >= $1.cachedAt ? $0 : $1 }))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchema, forKey: .schema)
        try container.encode(entries.values.sorted { $0.cachedAt < $1.cachedAt }, forKey: .entries)
    }
}

// MARK: - Store

/// The disk half of the verdict cache: where the file lives, and reading/writing it.
///
/// This is the app's first use of Application Support — everything else it persists lives in
/// UserDefaults or `~/sync-cloud.log`. Defaults is the wrong home for this one: it is read whole
/// into memory by every process that touches the domain, and this store is sized by how many files
/// the user has rather than by how many settings they have.
public enum FilingVerdictStore {

    /// `~/Library/Application Support/SyncCloud/filing-verdicts.json`.
    ///
    /// The app is not sandboxed, so this is an ordinary path with no container indirection.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/filing-verdicts.json")
    }

    /// Reads the cache at `url`. **Every failure returns an empty cache**, deliberately: a missing,
    /// unreadable, or wrong-schema file means the next scan re-asks and pays, which is the same
    /// outcome as never having cached at all. There is nothing here worth risking a thrown error or
    /// a half-decoded state for — unlike the remembered-rules store, whose contents cannot be
    /// reconstructed and which therefore refuses to proceed on an unreadable read.
    public static func load(from url: URL) -> FilingVerdictCache {
        guard let data = try? Data(contentsOf: url) else { return FilingVerdictCache() }
        guard let cache = try? JSONDecoder().decode(FilingVerdictCache.self, from: data) else {
            Logger.shared.warning("Filing verdict cache at \(url.lastPathComponent) could not be read — starting a fresh one")
            return FilingVerdictCache()
        }
        return cache
    }

    /// Serializes writes. Every writer hands its whole snapshot of the memoized cache here, so the
    /// LAST queued snapshot is always the current state — scans that grow it and Clears that empty
    /// it alike — and writing them in order makes the file converge on the memo.
    ///
    /// That only holds if every writer goes through this queue. This doc used to justify ordering
    /// with "the in-memory copy only grows", which `clearFilingVerdictCache` falsified the day it
    /// was written — and clear then bypassed the queue with a synchronous `save`, racing any
    /// queued scan write, whose PRE-clear snapshot could land last and resurrect everything on the
    /// next launch. **New writers use ``saveInBackground(_:to:)``; the synchronous `save` is for
    /// paths with no possible concurrent writer.**
    private static let writeQueue = DispatchQueue(label: "com.synccloud.filing-verdict-store")

    /// Writes `cache` off the calling thread, in order.
    ///
    /// The caller is `FileSyncManager`, which is `@MainActor`: at the entry cap this file is on the
    /// order of ten megabytes, and encoding plus an atomic write of that on the main actor is a
    /// visible hitch at the end of every scan — in an app whose main-thread stalls are already a
    /// known sore point. Nothing waits on the result, so there is nothing to block for: the
    /// in-memory copy is authoritative for this launch, and a write lost to a quit costs a re-ask.
    public static func saveInBackground(_ cache: FilingVerdictCache, to url: URL) {
        writeQueue.async { _ = save(cache, to: url) }
    }

    /// Blocks until every queued write has finished.
    ///
    /// For tests, and only tests: production never waits, because the in-memory copy is what the
    /// current launch reads. A test that scans, builds a SECOND manager, and expects it to load the
    /// first one's entries is racing the background write — the exact shape of flake this codebase
    /// has paid for before. A barrier on the serial queue makes that wait exact rather than timed.
    public static func waitForPendingWrites() {
        writeQueue.sync {}
    }

    /// Writes `cache` to `url`, creating the enclosing directory. Best-effort: a failed write costs
    /// a re-ask on the next scan and nothing else, so it is logged rather than surfaced.
    /// Synchronous — prefer ``saveInBackground(_:to:)`` from the main actor.
    @discardableResult
    public static func save(_ cache: FilingVerdictCache, to url: URL,
                            fileManager: FileManager = .default) -> Bool {
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
