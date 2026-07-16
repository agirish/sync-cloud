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

    /// Why (or that) a file was hashed — lets callers that aggregate many hashes (the Tidy
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
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return .unverifiable
            }
            // `attributesOfItem` does not resolve a trailing symlink (lstat semantics) while
            // the FileHandle read below follows it, so a symlinked file would stat as the
            // link's own byte count and never verify. Stat the resolved path for links; a
            // broken link already returned nil above (`fileExists` resolves, and fails).
            var statPath = path
            if (try? fileManager.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                statPath = (path as NSString).resolvingSymlinksInPath
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: statPath),
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
            // (Tidy's note) stays honest — a dataless 4 GB video is "not downloaded", not "too
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
            let digest = hasher.finalize()
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            if let cache, let cacheKey {
                await cache.store(hex, for: cacheKey)
            }
            return .hashed(hex)
        }.value
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
