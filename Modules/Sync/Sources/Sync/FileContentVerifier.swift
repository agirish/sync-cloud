import Foundation
import CryptoKit

/// On-demand content verification for files that differ by date but have the same size.
/// Uses SHA-256; skips directories and files over the size limit.
public enum FileContentVerifier {

    /// Maximum file size (bytes) to hash. Larger files are skipped so a verify stays quick.
    public static let maxBytesToHash: Int = 100 * 1024 * 1024  // 100 MB

    /// Chunk size for streaming reads while hashing (keeps peak memory per hash to one chunk
    /// instead of the whole file).
    private static let hashChunkSize = 4 * 1024 * 1024  // 4 MB

    /// Why (or that) a file was hashed — lets callers that aggregate many hashes (the
    /// duplicate scan) distinguish "skipped because of the size cap" from "unreadable", instead
    /// of collapsing every non-hash into an indistinguishable `nil`.
    public enum HashOutcome: Sendable, Equatable {
        /// The file was hashed; associated value is the SHA-256 hex digest.
        case hashed(String)
        /// Skipped without reading: the file exceeds the size cap (`maxBytesToHash`).
        case skippedTooLarge
        /// Skipped without reading: the file is a cloud-only (dataless) placeholder — opening it
        /// would force the provider to download the whole file.
        case skippedCloudOnly
        /// Not hashable: directory, missing, unreadable, or the file changed mid-read.
        case unverifiable

        /// The digest for `.hashed`, else nil — the classic `sha256Hex` result.
        public var hash: String? {
            if case .hashed(let hex) = self { return hex }
            return nil
        }
    }

    /// Computes SHA-256 of the file at the given path on a background thread.
    /// The file is hashed in chunks, never loaded into memory whole.
    /// - Parameters:
    ///   - path: Absolute file path.
    ///   - fileManager: File manager (for testability).
    ///   - cache: Optional session cache keyed by `(resolved path, mtime, size)`. On a hit the
    ///     stored digest is returned without touching the file; on a miss the freshly computed
    ///     digest is stored before returning. Passing `nil` reproduces the pre-cache behavior
    ///     exactly (always reads and hashes).
    /// - Returns: Hex string of the hash, or `nil` if the path is a directory, missing, over size limit, or read fails.
    public static func sha256Hex(
        filePath path: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil
    ) async -> String? {
        await hashOutcome(filePath: path, fileManager: fileManager, cache: cache).hash
    }

    /// `sha256Hex` with a classified result instead of a collapsed nil. `maxBytes` is injectable
    /// for tests only (creating a real >100 MB fixture per run would be wasteful); production
    /// callers use the default cap. `isCloudOnly` is the dataless check consulted before the file
    /// is opened — a cloud-only placeholder is skipped, never force-downloaded; injectable because
    /// a real dataless file can't be fabricated in tests (the flag is provider-set).
    public static func hashOutcome(
        filePath path: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil,
        maxBytes: Int = maxBytesToHash,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    ) async -> HashOutcome {
        await Task.detached(priority: .utility) { () -> HashOutcome in
            // ONE metadata read for a non-symlink, where there used to be three. `fileExists`
            // asked about existence and directory-ness, a discarded `attributesOfItem` asked
            // about the link type, and a second one asked for size and mtime — and
            // `attributesOfItem` answers all four in a single round trip. Three stats per
            // hashed file is the whole cost of a WARM rescan, where every digest is a cache hit
            // and the reads never happen: the cache saves the bytes and the stats spend the
            // saving.
            guard let linkAttributes = try? fileManager.attributesOfItem(atPath: path) else {
                // Missing or unreadable — the verdict `fileExists` used to return here.
                return .unverifiable
            }
            // `attributesOfItem` does not resolve a trailing symlink (lstat semantics) while
            // the FileHandle read below follows it, so a symlinked file would stat as the
            // link's own byte count and never verify. Stat the resolved path for links; a
            // broken link fails that second read, which is where it now returns instead of at
            // the `fileExists` above (which resolved, and failed).
            var statPath = path
            var attributes = linkAttributes
            if (linkAttributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                statPath = (path as NSString).resolvingSymlinksInPath
                guard let resolved = try? fileManager.attributesOfItem(atPath: statPath) else {
                    return .unverifiable
                }
                attributes = resolved
            }
            // **On the RESOLVED attributes, deliberately.** `fileExists(atPath:isDirectory:)`
            // followed the link before answering, so a symlink pointing at a directory was
            // unverifiable; asking the link's own attributes instead would call it a file and
            // go on to hash it.
            guard (attributes[.type] as? FileAttributeType) != .typeDirectory,
                  let size = (attributes[.size] as? NSNumber)?.intValue else {
                return .unverifiable
            }
            // Build the cache key from the same resolved stat. mtime comes from the attributes we
            // already read, so this adds a dictionary lookup, not a syscall. When mtime is
            // unavailable the file is hashed normally but never cached (no stable key).
            let cacheKey = (attributes[.modificationDate] as? Date).map {
                ContentHashKey(path: statPath, mtime: $0.timeIntervalSince1970, size: size)
            }
            if let cache, let cacheKey, let hit = await cache.hash(for: cacheKey) {
                return .hashed(hit)
            }
            // The dataless check comes BEFORE the size cap: a cloud-only placeholder is skipped
            // as cloud-only whatever its byte count, so the per-reason skip split callers surface
            // (the Duplicates lens's note) stays honest — a dataless 4 GB video is "not downloaded", not "too
            // large to hash", and the two remedies differ (download it vs raise the cap). The
            // check is an lstat-cheap flag read, and it must precede any byte being read anyway:
            // opening a dataless placeholder forces the provider to download the whole file — a
            // metadata scan must never do that. Checked on the resolved path (the file a symlink
            // would actually open), and only after the cache: a hit needs no read, and eviction
            // doesn't change content.
            if isCloudOnly(statPath) { return .skippedCloudOnly }
            guard size <= maxBytes else { return .skippedTooLarge }
            guard let handle = FileHandle(forReadingAtPath: path) else { return .unverifiable }
            defer { try? handle.close() }

            // What the DESCRIPTOR says, which is the only metadata provably about the bytes read
            // below. Everything above was read from the PATH, before the open — a window in which
            // the file can be replaced, leaving a digest keyed to a file it is not a digest of.
            //
            // **Only the size is compared, and the mtime deliberately is not.** An `fstat` mtime
            // and a Foundation `Date` mtime disagree by one ULP on roughly a quarter of real files
            // (measured over 4,500: 2.4e-07 s, the resolution of a `Double` at this magnitude), so
            // comparing the two — or keying from `fstat` — would read as "changed" for a quarter of
            // the tree and silently miss every entry already persisted under the Foundation value.
            // The key must stay derivable from a PATH stat regardless: a cache hit must not open
            // the file, or a cloud-only placeholder would be downloaded just to be skipped.
            let openedStat = Self.descriptorStat(handle)
            if let openedStat, Int(openedStat.st_size) != size {
                // Replaced between the stat and the open. The read loop would reach the same
                // verdict after reading the whole file; this reaches it before.
                return .unverifiable
            }

            var hasher = SHA256()
            var totalBytes = 0
            while true {
                // read(upToCount:) bridges each chunk through an autoreleased NSData; without a
                // per-iteration pool they accumulate until the closure returns, letting peak
                // memory approach the whole file again. nil = unverifiable, false = end-of-file.
                let advance: Bool? = autoreleasepool {
                    let chunk: Data?
                    do { chunk = try handle.read(upToCount: hashChunkSize) }
                    catch { return nil }
                    // nil or empty means end-of-file.
                    guard let chunk, !chunk.isEmpty else { return false }
                    totalBytes += chunk.count
                    // The file grew past the stat'd size mid-read; treat as unverifiable,
                    // matching the previous whole-read size check.
                    if totalBytes > size { return nil }
                    hasher.update(data: chunk)
                    return true
                }
                guard let advance else { return .unverifiable }
                if !advance { break }
            }
            guard totalBytes == size else { return .unverifiable }
            // Re-`fstat` the same descriptor and compare against the first one — both raw
            // `timespec`s from the same API, so this comparison has none of the cross-API rounding
            // problem the size-only check above exists to avoid, and it can be exact.
            //
            // It closes the one mid-read corruption the byte count cannot see: a rewrite that
            // lands the SAME number of bytes. Today that produces a digest of two files spliced
            // together and PERSISTS it under the pre-read mtime, where it stays wrong until the
            // mtime moves again. Unverifiable is the safe verdict — it drops the file out of
            // grouping rather than grouping it on a digest of nothing that ever existed on disk.
            guard Self.snapshotIsCoherent(opened: openedStat, closing: Self.descriptorStat(handle)) else {
                return .unverifiable
            }
            let digest = hasher.finalize()
            let hex = HexEncoding.string(digest)
            if let cache, let cacheKey {
                await cache.store(hex, for: cacheKey)
            }
            return .hashed(hex)
        }.value
    }

    /// Whether two `fstat`s of the same descriptor, taken before and after the read, describe the
    /// same file — the test behind the mid-read coherence check in ``hashOutcome``.
    ///
    /// Split out because the wiring it guards can only be reached by winning a race, and a guard
    /// whose logic is reachable only by racing is a guard nobody can check. The decision is pure,
    /// so it is tested directly; the wiring is covered by the size check at open, which the same
    /// `fstat` feeds.
    ///
    /// A missing stat on either side means the question could not be asked, and an unanswered
    /// question is not evidence of change — coherent, matching what the code did before any of
    /// this existed.
    static func snapshotIsCoherent(opened: stat?, closing: stat?) -> Bool {
        guard let opened, let closing else { return true }
        return opened.st_mtimespec.tv_sec == closing.st_mtimespec.tv_sec
            && opened.st_mtimespec.tv_nsec == closing.st_mtimespec.tv_nsec
            && opened.st_size == closing.st_size
    }

    /// `fstat` of an open handle's descriptor, or nil if it fails.
    ///
    /// Deliberately raw rather than routed through ``FileManaging``: the point is to describe the
    /// descriptor the bytes are being read from, and no path-based call — mockable or not — can
    /// answer that. `FileHandle` is already outside the seam for the same reason.
    private static func descriptorStat(_ handle: FileHandle) -> stat? {
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return nil }
        return st
    }

    /// Returns whether the two files have identical content (same SHA-256).
    /// Returns `nil` if either file cannot be hashed (e.g. directory, too large, missing).
    /// `cache`, when supplied, lets unchanged files skip the re-hash on a repeat verify.
    public static func filesHaveSameContent(
        leftPath: String,
        rightPath: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil
    ) async -> Bool? {
        async let leftHash = sha256Hex(filePath: leftPath, fileManager: fileManager, cache: cache)
        async let rightHash = sha256Hex(filePath: rightPath, fileManager: fileManager, cache: cache)
        let (l, r) = await (leftHash, rightHash)
        guard let l = l, let r = r else { return nil }
        return l == r
    }
}
