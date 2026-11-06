import Foundation
import CryptoKit
import os

/// On-demand content verification for files that differ by date but have the same size.
/// Uses SHA-256 over the whole file, of any size; skips directories and cloud-only placeholders.
///
/// No size cap, since one-way sync compares by content and must cover every file. The read
/// streams in fixed chunks, so memory stays at one chunk, and it stops at the next chunk on
/// cancel. A caller for whom a large read is too slow filters by size itself:
/// `FileSyncManager.unaskedPassMaxFileBytes` (scan-time verify, the filing scan's already-filed
/// check), the duplicate scan's edge sample, and the merge planner's size match.
public enum FileContentVerifier {

    /// Chunk size for streaming reads while hashing; peak memory per hash is one chunk.
    private static let hashChunkSize = 4 * 1024 * 1024  // 4 MB

    /// Whether a file was hashed and, if not, why, so callers that aggregate many hashes (the
    /// duplicate scan) can tell "not downloaded" from "unreadable".
    public enum HashOutcome: Sendable, Equatable {
        /// The file was hashed; associated value is the SHA-256 hex digest.
        case hashed(String)
        /// Skipped without reading: the file is a cloud-only (dataless) placeholder, and opening it
        /// would force the provider to download the whole file.
        case skippedCloudOnly
        /// Not hashable: directory, missing, unreadable, or the file changed mid-read.
        case unverifiable
        /// Stopped part-way because the caller cancelled. Says nothing about the file, so it is
        /// never cached and never counted as a skip.
        case cancelled

        /// The digest for `.hashed`, else nil: the `sha256Hex` result.
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
    ///     ctime)`. A hit returns the stored digest without reading the file; a miss stores the new
    ///     digest. `nil` always reads and hashes.
    /// - Returns: Hex string of the hash, or `nil` if the path is a directory, missing,
    ///   cloud-only, or the read fails or is cancelled.
    public static func sha256Hex(
        filePath path: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil
    ) async -> String? {
        await hashOutcome(filePath: path, fileManager: fileManager, cache: cache).hash
    }

    /// `sha256Hex` with a classified result. `isCloudOnly` is the dataless check made before the
    /// file is opened, so a placeholder is skipped, never downloaded; injectable because tests
    /// can't make a real dataless file.
    ///
    /// Cancellable mid-file two ways: cancelling the calling task reaches the read through
    /// ``onHashLane``, and `isCancelled` is asked before every chunk for a caller that stops with a
    /// `Progress` (Verify All). Either way it stops within one chunk and answers `.cancelled`.
    ///
    /// The read is blocking I/O on a `.utility` detached task that yields after each chunk, so it
    /// holds a cooperative-pool thread for one 4 MB read at a time. Held for a whole scan, blocking
    /// I/O starves the pool.
    public static func hashOutcome(
        filePath path: String,
        fileManager: FileManaging = FileManager.default,
        cache: ContentHashCache? = nil,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> HashOutcome {
        await onHashLane { callerCancelled -> HashOutcome in
            // One `attributesOfItem` for a non-symlink answers existence, type, size and mtime.
            // Stats are the whole cost of a warm rescan, where every digest is a cache hit.
            //
            // With a cache, the key adds one raw `stat` for the file number and ctime
            // (`ContentHashKey.diskIdentity`), which `attributesOfItem` lacks. Not folded into that
            // stat: a persisted key needs Foundation's exact `Date` mtime (see the descriptor note).
            guard let stat = Self.statForHash(filePath: path, fileManager: fileManager) else {
                return .unverifiable
            }
            let (statPath, attributes, size) = stat
            // Build the cache key from the same resolved path. When mtime is unavailable the file
            // is hashed normally but never cached (no stable key); with no cache there is nothing
            // to key, so the identity stat is skipped.
            let cacheKey = cache == nil ? nil
                : Self.cacheKey(statPath: statPath, attributes: attributes, size: size)
            if let cache, let cacheKey, let hit = await cache.hash(for: cacheKey) {
                return .hashed(hit)
            }
            // The dataless check must precede any read: opening a placeholder forces the provider
            // to download the whole file, which a metadata scan must never do. Checked on the
            // resolved path, and after the cache: a hit needs no read, and eviction doesn't change
            // content.
            if isCloudOnly(statPath) { return .skippedCloudOnly }
            if callerCancelled() || isCancelled() { return .cancelled }
            guard let handle = FileHandle(forReadingAtPath: path) else { return .unverifiable }
            defer { try? handle.close() }

            // The descriptor's stat is the only metadata provably about the bytes read below; the
            // path stat above could describe a file replaced before the open.
            //
            // Only the size is compared, not the mtime: an `fstat` mtime and a Foundation `Date`
            // differ by one ULP on about a quarter of files, so either comparing or keying from
            // `fstat` would read them as changed and miss persisted entries. The key must stay
            // derivable from a path stat anyway: a cache hit must not open a placeholder.
            let openedStat = Self.descriptorStat(handle)
            if let openedStat, Int(openedStat.st_size) != size {
                // Replaced between the stat and the open; caught before reading the whole file.
                return .unverifiable
            }

            var hasher = SHA256()
            var totalBytes = 0
            while true {
                if callerCancelled() || isCancelled() { return .cancelled }
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
                    // The file grew past the stat'd size mid-read; unverifiable.
                    if totalBytes > size { return nil }
                    hasher.update(data: chunk)
                    return true
                }
                guard let advance else { return .unverifiable }
                if !advance { break }
                // Lets other work have this pool thread between chunks.
                await Task.yield()
            }
            guard totalBytes == size else { return .unverifiable }
            // Re-`fstat` the same descriptor: both are raw `timespec`s, so this can be exact. It
            // catches a same-length rewrite mid-read, which the byte count can't, and which would
            // persist a digest of two spliced files. Unverifiable drops it out of grouping instead.
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
    }

    /// Runs `body` on the hash lane: a `.utility` detached task, so blocking reads leave the
    /// caller's actor (usually the main actor) and run at the lane's priority. Detached tasks don't
    /// inherit cancellation, so it is forwarded by hand: as `callerCancelled`, which `body` asks
    /// before each read, and by cancelling the detached task, so `Task.isCancelled` is true inside.
    ///
    /// **The handler is installed before the task is spawned.** Spawning first leaves a window in
    /// which a cancel reaches the read only once the caller is scheduled again, so on a loaded
    /// machine it reads on past it. A cancel before the task is stored finds no task, so the spawn
    /// cancels it itself; the flag covers the read's checks in between.
    static func onHashLane<T: Sendable>(
        _ body: @escaping @Sendable (_ callerCancelled: @escaping @Sendable () -> Bool) async -> T
    ) async -> T {
        let state = OSAllocatedUnfairLock(initialState: (cancelled: false, task: Task<T, Never>?.none))
        return await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                await body { state.withLock { $0.cancelled } }
            }
            if state.withLock({ $0.task = task; return $0.cancelled }) { task.cancel() }
            return await task.value
        } onCancel: {
            state.withLock { $0.cancelled = true; return $0.task }?.cancel()
        }
    }

    /// The stat a hash of `path` rests on: the path it reads (a symlink's target), its attributes
    /// and size. nil wherever ``hashOutcome`` answers `.unverifiable` before reading (missing,
    /// unreadable, a directory, a broken link, no size). Shared, so callers deciding whether to hash
    /// ask about exactly the bytes the hash would read.
    static func statForHash(filePath path: String, fileManager: FileManaging)
        -> (statPath: String, attributes: [FileAttributeKey: Any], size: Int)? {
        guard let linkAttributes = try? fileManager.attributesOfItem(atPath: path) else {
            // Missing or unreadable.
            return nil
        }
        // `attributesOfItem` doesn't follow a trailing symlink while the `FileHandle` read does,
        // so a link would stat as its own byte count and never verify. Stat the resolved path; a
        // broken link fails there.
        var statPath = path
        var attributes = linkAttributes
        if (linkAttributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            statPath = (path as NSString).resolvingSymlinksInPath
            guard let resolved = try? fileManager.attributesOfItem(atPath: statPath) else {
                return nil
            }
            attributes = resolved
        }
        // On the resolved attributes, so a link to a directory is unverifiable rather than
        // hashed as a file.
        guard (attributes[.type] as? FileAttributeType) != .typeDirectory,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return nil
        }
        return (statPath, attributes, size)
    }

    /// The size a hash of `path` would read now (``statForHash``), or nil when it could not be
    /// hashed at all. Synchronous file metadata: call it off the main actor.
    public static func sizeForHash(filePath path: String, fileManager: FileManaging = FileManager.default) -> Int? {
        statForHash(filePath: path, fileManager: fileManager)?.size
    }

    /// The digest ``hashOutcome`` would serve from `cache` without reading a byte, or nil when it
    /// would have to read. On the hash's lane: it stats the file.
    static func cachedDigest(filePath path: String, fileManager: FileManaging,
                             cache: ContentHashCache) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let stat = Self.statForHash(filePath: path, fileManager: fileManager),
                  let key = Self.cacheKey(statPath: stat.statPath, attributes: stat.attributes,
                                          size: stat.size) else { return nil }
            return await cache.hash(for: key)
        }.value
    }

    /// Bytes read from each end of a file by ``edgeSample``.
    static let edgeSampleBytes = 1024 * 1024  // 1 MB

    /// A digest of a file's size and its first and last ``edgeSampleBytes``. Never a content
    /// identity: only a cheap proof that two same-size files differ, for the duplicate scan
    /// (`FileSyncManager.duplicateEdgeSampleAbove`). Equal samples mean nothing until the full hash.
    ///
    /// nil when no sample could be taken: cloud-only (never opened, as in ``hashOutcome``),
    /// unreadable, a descriptor whose size is not `size`, or cancelled. Every nil means unknown,
    /// never different. On the hash's lane, with its cancellation forwarded the same way.
    static func edgeSample(
        filePath path: String,
        size: Int,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    ) async -> String? {
        await onHashLane { callerCancelled -> String? in
            // The path ``hashOutcome`` asks about: a symlink's target, else the path as given.
            // Not resolving every path: that rewrites `/private/var/…` to `/var/…`.
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
            let checkPath = isLink ? (path as NSString).resolvingSymlinksInPath : path
            if isCloudOnly(checkPath) || callerCancelled() { return nil }
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let opened = Self.descriptorStat(handle), Int(opened.st_size) == size else { return nil }
            return autoreleasepool { () -> String? in
                var hasher = SHA256()
                withUnsafeBytes(of: Int64(size).littleEndian) { hasher.update(bufferPointer: $0) }
                // A short read would look like a difference from its twin, so it answers unknown.
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
    }

    /// Whether two `fstat`s of one descriptor, before and after the read, describe the same file:
    /// the mid-read coherence check in ``hashOutcome``. Split out so the pure decision can be tested
    /// without winning a race. A missing stat on either side is not evidence of change: coherent.
    static func snapshotIsCoherent(opened: stat?, closing: stat?) -> Bool {
        guard let opened, let closing else { return true }
        return opened.st_mtimespec.tv_sec == closing.st_mtimespec.tv_sec
            && opened.st_mtimespec.tv_nsec == closing.st_mtimespec.tv_nsec
            && opened.st_size == closing.st_size
    }

    /// The key a file's digest is cached under: path, mtime and size from the attributes already
    /// read, and the file number and ctime from one more path `stat` (``ContentHashKey``). Shared,
    /// so a test stores under exactly the key a hash looks up. nil when there is no mtime.
    static func cacheKey(statPath: String, attributes: [FileAttributeKey: Any],
                         size: Int) -> ContentHashKey? {
        guard let modified = attributes[.modificationDate] as? Date else { return nil }
        let identity = ContentHashKey.diskIdentity(atPath: statPath)
        return ContentHashKey(path: statPath, mtime: modified.timeIntervalSince1970, size: size,
                              fileNumber: identity?.fileNumber, statusChanged: identity?.statusChanged)
    }

    /// `fstat` of an open handle's descriptor, or nil if it fails.
    ///
    /// Raw, not through ``FileManaging``: it describes the descriptor being read, which no
    /// path-based call can. `FileHandle` is outside the seam for the same reason.
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
    /// The first side that can't be hashed stops the other, since the answer is already nil.
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
