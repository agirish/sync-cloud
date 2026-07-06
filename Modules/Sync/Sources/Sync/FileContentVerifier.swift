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
    /// - Returns: Hex string of the hash, or `nil` if the path is a directory, missing, over size limit, or read fails.
    public static func sha256Hex(filePath path: String, fileManager: FileManaging = FileManager.default) async -> String? {
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
            guard let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
                  size <= maxBytesToHash else {
                return nil
            }
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }

            var hasher = SHA256()
            var totalBytes = 0
            while true {
                let chunk: Data?
                do { chunk = try handle.read(upToCount: hashChunkSize) }
                catch { return nil }
                // nil or empty means end-of-file.
                guard let chunk, !chunk.isEmpty else { break }
                totalBytes += chunk.count
                // The file grew past the stat'd size mid-read; treat as unverifiable,
                // matching the previous whole-read size check.
                if totalBytes > size { return nil }
                hasher.update(data: chunk)
            }
            guard totalBytes == size else { return nil }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Returns whether the two files have identical content (same SHA-256).
    /// Returns `nil` if either file cannot be hashed (e.g. directory, too large, missing).
    public static func filesHaveSameContent(
        leftPath: String,
        rightPath: String,
        fileManager: FileManaging = FileManager.default
    ) async -> Bool? {
        async let leftHash = sha256Hex(filePath: leftPath, fileManager: fileManager)
        async let rightHash = sha256Hex(filePath: rightPath, fileManager: fileManager)
        let (l, r) = await (leftHash, rightHash)
        guard let l = l, let r = r else { return nil }
        return l == r
    }
}
