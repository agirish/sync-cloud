import Foundation
import CryptoKit

/// On-demand content verification for files that differ by date but have the same size.
/// Uses SHA-256 over the whole file, of any size; skips directories and cloud-only placeholders.
///
/// **There is no size cap.** Files used to be skipped over 100 MB so a verify stayed quick; RD67's
/// one-way sync compares by content and must cover every file. The read streams in fixed chunks,
/// so memory stays at one chunk whatever the size, and it stops at the next chunk when its caller
/// cancels. A caller for whom a large read is too slow — a pass the user did not ask for — filters
/// by size itself: `FileSyncManager.unaskedPassMaxFileBytes` (scan-time verify, the filing scan's
/// already-filed check), the duplicate scan's edge sample, and the merge planner's size match.
public enum FileContentVerifier {

    /// Chunk size for streaming reads while hashing (keeps peak memory per hash to one chunk
    /// instead of the whole file).
    private static let hashChunkSize = 4 * 1024 * 1024  // 4 MB

    /// Why (or that) a file was hashed — lets callers that aggregate many hashes (the
    /// duplicate scan) distinguish "not downloaded" from "unreadable", instead of collapsing
    /// every non-hash into an indistinguishable `nil`.
    public enum HashOutcome: Sendable, Equatable {
        /// The file was hashed; associated value is the SHA-256 hex digest.
        case hashed(String)
        /// Skipped without reading: the file is a cloud-only (dataless) placeholder — opening it
        /// would force the provider to download the whole file.
        case skippedCloudOnly
        /// Not hashable: directory, missing, unreadable, or the file changed mid-read.
        case unverifiable
        /// Stopped part-way because the caller cancelled. Says nothing about the file, so it is
        /// never cached and never counted as a skip.
        case cancelled

        /// The digest for `.hashed`, else nil — the classic `sha256Hex` result.
        public var hash: String? {
            if case .hashed(let hex) = self { return hex }
            return nil
        }
    }

    /// Computes SHA-256 of the file at the given path on a background thread.
    /// The file is hashed in chunks, never loaded into memory whole, whatever its size.
    /// - Parameters:
    ///   - path: Absolute file path.
    ///   - fileManager: File manager (for testability).
    ///   - cache: Optional session cache keyed by `(resolved path, mtime, size, file number,
    ///     ctime)`. On a hit the stored digest is returned without touching the file; on a miss the
    ///     freshly computed digest is stored before returning. Passing `nil` reproduces the
    ///     pre-cache behavior exactly (always reads and hashes).
    /// - Returns: Hex string of the hash, or `nil` if the path is a directory, missing,
    ///   cloud-only, or the read fails or is cancelled.
    public static func sha256Hex(
        filePath path: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil
    ) async -> String? {
        await hashOutcome(filePath: path, fileManager: fileManager, cache: cache).hash
    }

    /// `sha256Hex` with a classified result instead of a collapsed nil. `isCloudOnly` is the
    /// dataless check consulted before the file is opened — a cloud-only placeholder is skipped,
    /// never force-downloaded; injectable because a real dataless file can't be fabricated in
    /// tests (the flag is provider-set).
    ///
    /// **Cancellable mid-file, two ways.** Cancelling the calling task reaches the read through
    /// the detached task below, and `isCancelled` is asked before every chunk for a caller whose
    /// stop is a `Progress` rather than a task (Verify All). Either way the read stops within one
    /// chunk and answers `.cancelled`. Without it, a 5 GB file would read to its end after Stop.
    ///
    /// **One chunk at a time on the cooperative pool.** The read is blocking I/O on a `.utility`
    /// detached task — the lane every hash has always run on — and it yields after each chunk, so
    /// a long file holds a pool thread for one 4 MB read at a time, not for the whole file.
    /// Blocking file I/O held across a whole scan is what starved the pool in RD38.
    public static func hashOutcome(
        filePath path: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> HashOutcome {
        // Detached so the blocking read leaves the caller's actor (most callers are the main
        // actor), and so its priority is the hash lane's, not the caller's. Detached tasks do not
        // inherit cancellation, so it is forwarded by hand.
        let work = Task.detached(priority: .utility) { () -> HashOutcome in
            // ONE `attributesOfItem` for a non-symlink, where there used to be three. `fileExists`
            // asked about existence and directory-ness, a discarded `attributesOfItem` asked
            // about the link type, and a second one asked for size and mtime — and
            // `attributesOfItem` answers all four in a single round trip. Stats per hashed file
            // are the whole cost of a WARM rescan, where every digest is a cache hit and the
            // reads never happen: the cache saves the bytes and the stats spend the saving.
            //
            // **Two stats with a cache, not one.** The cache key adds a raw `stat` of the same
            // path for the file number and status-change time (FR59, `ContentHashKey.diskIdentity`)
            // — `attributesOfItem` reports no ctime — so it is taken only when there is a cache
            // to key. Folding all four into that one raw stat would leave the `FileManaging` seam
            // and re-derive the mtime from a `timespec`, where a persisted key needs Foundation's
            // exact `Date` value (see the descriptor note below).
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
            // Build the cache key from the same resolved path. When mtime is unavailable the file
            // is hashed normally but never cached (no stable key); with no cache there is nothing
            // to key, so the identity stat is skipped.
            let cacheKey = cache == nil ? nil
                : Self.cacheKey(statPath: statPath, attributes: attributes, size: size)
            if let cache, let cacheKey, let hit = await cache.hash(for: cacheKey) {
                return .hashed(hit)
            }
            // The dataless check is an lstat-cheap flag read, and it must precede any byte being
            // read: opening a dataless placeholder forces the provider to download the whole file
            // — a metadata scan must never do that. Checked on the resolved path (the file a
            // symlink would actually open), and only after the cache: a hit needs no read, and
            // eviction doesn't change content.
            if isCloudOnly(statPath) { return .skippedCloudOnly }
            if Task.isCancelled || isCancelled() { return .cancelled }
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
                if Task.isCancelled || isCancelled() { return .cancelled }
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
                // Lets other work at higher priority have this pool thread between chunks — see
                // the doc comment's note on the cooperative pool.
                await Task.yield()
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
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// Bytes read from each end of a file by ``edgeSample``.
    static let edgeSampleBytes = 1024 * 1024  // 1 MB

    /// A digest of a file's size and its first and last ``edgeSampleBytes`` — never a content
    /// identity, only a cheap way to prove two same-size files DIFFER without reading either whole
    /// (the duplicate scan's use; see `FileSyncManager.duplicateEdgeSampleAbove`). Different
    /// samples mean different files; equal samples mean nothing until the full hash.
    ///
    /// nil when no sample could be taken: cloud-only (never opened, as in ``hashOutcome``),
    /// unreadable, a descriptor whose size is not `size`, or cancelled. Every nil means unknown,
    /// never different. On the hash's lane, with its cancellation forwarded the same way.
    static func edgeSample(
        filePath path: String,
        size: Int,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    ) async -> String? {
        let work = Task.detached(priority: .utility) { () -> String? in
            // The path ``hashOutcome`` asks about: a symlink's target, else the path as given.
            // Resolving every path would not do — it rewrites `/private/var/…` to `/var/…`.
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
            let checkPath = isLink ? (path as NSString).resolvingSymlinksInPath : path
            if isCloudOnly(checkPath) || Task.isCancelled { return nil }
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let opened = Self.descriptorStat(handle), Int(opened.st_size) == size else { return nil }
            return autoreleasepool { () -> String? in
                var hasher = SHA256()
                withUnsafeBytes(of: Int64(size).littleEndian) { hasher.update(bufferPointer: $0) }
                // A short read is a sample of fewer bytes than its twin's, which would read as a
                // difference. Unknown instead — the full hash loops to EOF and needs no such check.
                let headWanted = min(edgeSampleBytes, size)
                guard let head = try? handle.read(upToCount: headWanted) ?? Data(),
                      head.count == headWanted else { return nil }
                hasher.update(data: head)
                // The tail starts where the head ended for a file under two samples long, so no
                // byte is read twice and every byte of a short file is covered.
                let tailStart = max(head.count, size - edgeSampleBytes)
                if tailStart < size {
                    guard (try? handle.seek(toOffset: UInt64(tailStart))) != nil,
                          let tail = try? handle.read(upToCount: size - tailStart),
                          tail.count == size - tailStart else { return nil }
                    hasher.update(data: tail)
                }
                return HexEncoding.string(hasher.finalize())
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
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

    /// The key a file's digest is cached under: path, mtime and size from the attributes already
    /// read, and the file number and status-change time from one more path `stat` (FR59 — see
    /// ``ContentHashKey``). The one spelling of it, so a test can store under exactly the key a
    /// hash will look up. nil when the attributes carry no mtime.
    static func cacheKey(statPath: String, attributes: [FileAttributeKey: Any],
                         size: Int) -> ContentHashKey? {
        guard let modified = attributes[.modificationDate] as? Date else { return nil }
        let identity = ContentHashKey.diskIdentity(atPath: statPath)
        return ContentHashKey(path: statPath, mtime: modified.timeIntervalSince1970, size: size,
                              fileNumber: identity?.fileNumber, statusChanged: identity?.statusChanged)
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
    /// Returns `nil` if either file cannot be hashed (e.g. directory, cloud-only, missing) or the
    /// check was cancelled. `cache`, when supplied, lets unchanged files skip the re-hash on a
    /// repeat verify. `isCancelled` stops both reads at their next chunk (see ``hashOutcome``).
    ///
    /// **The first side that cannot be hashed stops the other.** The answer is already nil, so
    /// reading the rest of a 30 GB twin of a cloud-only file would buy nothing.
    public static func filesHaveSameContent(
        leftPath: String,
        rightPath: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> Bool? {
        let hashes = await withTaskGroup(of: (Bool, HashOutcome).self) { group -> [Bool: String] in
            for (isLeft, path) in [(true, leftPath), (false, rightPath)] {
                group.addTask {
                    (isLeft, await hashOutcome(filePath: path, fileManager: fileManager, cache: cache,
                                               isCancelled: isCancelled))
                }
            }
            var hashes: [Bool: String] = [:]
            for await (isLeft, outcome) in group {
                guard let hash = outcome.hash else { group.cancelAll(); continue }
                hashes[isLeft] = hash
            }
            return hashes
        }
        guard let l = hashes[true], let r = hashes[false] else { return nil }
        return l == r
    }
}
