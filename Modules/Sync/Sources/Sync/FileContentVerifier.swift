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
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
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
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size <= maxBytesToHash else {
                return nil
            }
            // Build the cache key from the same resolved stat. mtime comes from the attributes we
            // already read, so this adds a dictionary lookup, not a syscall. When mtime is
            // unavailable the file is hashed normally but never cached (no stable key).
            let cacheKey = (attributes[.modificationDate] as? Date).map {
                ContentHashKey(path: statPath, mtime: $0.timeIntervalSince1970, size: size)
            }
            if let cache, let cacheKey, let hit = await cache.hash(for: cacheKey) {
                return hit
            }
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
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
                guard let advance else { return nil }
                if !advance { break }
            }
            guard totalBytes == size else { return nil }
            let digest = hasher.finalize()
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            if let cache, let cacheKey {
                await cache.store(hex, for: cacheKey)
            }
            return hex
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
