import Foundation
import CryptoKit

/// On-demand content verification for files that differ by date but have the same size.
/// Uses SHA-256; skips directories and files over the size limit.
public enum FileContentVerifier {

    /// Maximum file size (bytes) to hash. Larger files are skipped to avoid memory use (file is read into memory once).
    public static let maxBytesToHash: Int = 100 * 1024 * 1024  // 100 MB

    /// Computes SHA-256 of the file at the given path on a background thread.
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
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url), data.count == size else {
                return nil
            }
            let digest = SHA256.hash(data: data)
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
