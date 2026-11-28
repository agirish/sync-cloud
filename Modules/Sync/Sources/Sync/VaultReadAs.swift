import CryptoKit
import Foundation

/// What one document reads for a saved ID whose number was corrected by hand: "this card reads
/// WZ74605142 for this ID". The reader checks it before anything else, so the card's dates keep
/// coming to the ID and the old reading never comes back To Confirm.
///
/// The document is known by its bytes (``VaultFileContents``), not its path: SyncCloud moves a
/// card when it files it, and a path would lose the note at the first move.
public struct VaultReadAs: Codable, Equatable, Hashable, Sendable {
    /// The document's size and SHA-256, as ``VaultFileContents/key(of:)`` gives them.
    public var contents: String
    /// What the reader reads there, letters and digits only (``VaultReading/normalized(_:)``).
    public var reads: String

    public init(contents: String, reads: String) {
        self.contents = contents
        self.reads = VaultReading.normalized(reads)
    }

    /// The document's size in bytes: a file of another size is never hashed to be compared.
    public var size: Int? { VaultFileContents.size(of: contents) }
}

/// A file's bytes as a key two files share only when their bytes are the same.
public enum VaultFileContents {
    /// The file's size and SHA-256, "1024-9f86…", read a megabyte at a time. Nil when it cannot
    /// be opened. It reads the whole file: call it off the main actor.
    public static func key(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            size += chunk.count
        }
        return key(size: size, digest: hash.finalize())
    }

    /// The key for `size` bytes hashing to `digest`.
    public static func key(size: Int, digest: SHA256.Digest) -> String {
        "\(size)-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The size a key starts with.
    public static func size(of key: String) -> Int? { Int(key.prefix { $0 != "-" }) }
}
