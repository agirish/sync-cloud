import Foundation

/// Where the tree already holds each document, built from the persisted content indexes: the shared
/// input to "this folder is somebody else's copy" and "this file is already filed".
///
/// One identity per file: the ``ContentFingerprint`` digest where there is one, else the byte hash.
/// The fingerprint must win for PDFs, because a provider can hand out the same statement twice with
/// a fresh `/ID` stamped in, so copies share no byte hash with their originals and only the text
/// digest sees them as the same document.
public struct DocumentIdentityIndex: Sendable {
    /// Identity → the provider-relative folders holding a copy.
    public let foldersByIdentity: [String: Set<String>]
    /// Identity → every absolute path holding a copy, in sorted order.
    public let pathsByIdentity: [String: [String]]
    /// Provider-relative folder → how many identified documents sit directly in it.
    public let documentCounts: [String: Int]

    public var isEmpty: Bool { foldersByIdentity.isEmpty }

    public init(foldersByIdentity: [String: Set<String>], pathsByIdentity: [String: [String]],
                documentCounts: [String: Int]) {
        self.foldersByIdentity = foldersByIdentity
        self.pathsByIdentity = pathsByIdentity
        self.documentCounts = documentCounts
    }

    public static let empty = DocumentIdentityIndex(foldersByIdentity: [:], pathsByIdentity: [:],
                                                    documentCounts: [:])

    /// Builds the index from the persisted stores. `textless` is the "too little text" markers' own
    /// store: it holds no identity, but a marker newer than a path's digest says that digest
    /// describes the file as it was (a PDF with text, since overwritten by a scan of nothing).
    ///
    /// `existsOnDisk` is injected to keep this pure, and it matters: the indexes are a cache that
    /// outlives its files, and a stale record would let a vanished folder vouch for a document or
    /// inflate the count that decides which of two folders is the established one.
    public static func build(hashes: [ContentHashRecord], fingerprints: [ContentHashRecord],
                             textless: [ContentHashRecord] = [],
                             providerRoot: String,
                             existsOnDisk: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> DocumentIdentityIndex {
        let prefix = providerRoot.hasSuffix("/") ? providerRoot : providerRoot + "/"
        var identity: [String: String] = [:]
        // Byte hashes first, fingerprints second, so a PDF in both is keyed by what it says.
        // Prefixed so the two namespaces can never collide.
        //
        // A negative marker is not an identity: every document that said too little carries the
        // same one, and keyed by it they would all be "the same document". Where the newest record
        // is a marker the document keeps its byte hash, as one with no fingerprint does; an older
        // digest describes a state of the file that is gone. The markers live in their own store
        // (`textless`), so they are read in beside the digests to be weighed with them.
        for (path, r) in newestPerPath(hashes, under: prefix) { identity[path] = "b:" + r.hex }
        for (path, r) in newestPerPath(fingerprints + textless, under: prefix)
        where !ContentFingerprint.isNoFingerprintMarker(r.hex) {
            identity[path] = "f:" + r.hex
        }

        var foldersByIdentity: [String: Set<String>] = [:]
        var pathsByIdentity: [String: [String]] = [:]
        var documentCounts: [String: Int] = [:]
        for (path, id) in identity where existsOnDisk(path) {
            let folder = String(((path as NSString).deletingLastPathComponent + "/")
                .dropFirst(prefix.count).dropLast())
            foldersByIdentity[id, default: []].insert(folder)
            pathsByIdentity[id, default: []].append(path)
            documentCounts[folder, default: 0] += 1
        }
        for (id, paths) in pathsByIdentity { pathsByIdentity[id] = paths.sorted() }
        return DocumentIdentityIndex(foldersByIdentity: foldersByIdentity,
                                     pathsByIdentity: pathsByIdentity,
                                     documentCounts: documentCounts)
    }

    /// The newest record for each path under `prefix`.
    ///
    /// A content index is an append-only log, not a map from path to digest. Its key is (path,
    /// mtime, size, file number, ctime), so editing a file adds a second record for the same path,
    /// and the old one survives until it ages out (``ContentHashCache/maxEntryAge``). Taking the
    /// last record in array order would let the save's `Dictionary` order, reseeded every launch,
    /// pick a file's identity, so it could differ between two launches over an unchanged tree.
    ///
    /// Newest wins; the tie-breaks only make the answer total: `storedAt` (when the digest was
    /// computed), then `mtime` (which state of the file it describes), then the digest itself.
    private static func newestPerPath(_ records: [ContentHashRecord],
                                      under prefix: String) -> [String: ContentHashRecord] {
        var out: [String: ContentHashRecord] = [:]
        for r in records where r.path.hasPrefix(prefix) {
            guard let held = out[r.path] else { out[r.path] = r; continue }
            if (r.storedAt, r.mtime, r.hex) > (held.storedAt, held.mtime, held.hex) { out[r.path] = r }
        }
        return out
    }

    /// The folders already holding this document, other than `excluding`.
    public func folders(holding identity: String, excluding: String? = nil) -> [String] {
        (foldersByIdentity[identity] ?? []).filter { $0 != excluding }.sorted()
    }

    /// The same answer for an index built with `existsOnDisk: { _ in true }`, asking the check here
    /// of the paths behind `identity` alone. A caller looking up a few identities then stats a few
    /// paths, not every record in two index files. `providerRoot` must be the one the index was
    /// built for.
    public func folders(holding identity: String, excluding: String? = nil, providerRoot: String,
                        existsOnDisk: (String) -> Bool) -> [String] {
        let prefix = providerRoot.hasSuffix("/") ? providerRoot : providerRoot + "/"
        let folders = Set((pathsByIdentity[identity] ?? []).filter(existsOnDisk).map {
            String((($0 as NSString).deletingLastPathComponent + "/").dropFirst(prefix.count).dropLast())
        })
        return folders.filter { $0 != excluding }.sorted()
    }

    /// Whether any path in an index built without the existence check is still on disk: its
    /// ``isEmpty`` as an index built with the check would answer it. Stops at the first one found.
    public func holdsAnyPath(existsOnDisk: (String) -> Bool) -> Bool {
        pathsByIdentity.values.contains { $0.contains(where: existsOnDisk) }
    }
}

/// Folders that are somebody else's copies (an evidence packet, a submission bundle, a scratch
/// duplicate) rather than a document's home.
///
/// Content can't make this distinction, and no tuning of the router's weights fixes it: a folder of
/// copied payslips says the same words as the folder that holds the originals, because it holds the
/// same documents. On the real tree the two scored within 0.2% of each other once the folder size
/// term was equalised.
///
/// So the signal is structural and directional: A is a satellite of B when most of A's documents
/// are also in B and B is substantially the larger folder.
public enum SatelliteFolders {

    /// How much of a folder's own documents must also live in the candidate home. Below this the
    /// relation is coincidence: at 0.5 it pairs unrelated folders on two documents out of three.
    public static let minimumShare = 0.75
    /// And at least this many documents, for the same reason: a share is not evidence at n = 2.
    public static let minimumShared = 3
    /// How much bigger the home must be: the threshold that separates a satellite from two folders
    /// that merely overlap. Chosen on the real tree: near 1× it admits pairs like 3 documents
    /// against 4, where "bigger" is noise and the direction arbitrary; at 2× those are gone and
    /// every case the relation exists for remains.
    public static let minimumSizeRatio = 2.0

    /// Satellite folder → the folders it is a copy of. Both sides are provider-relative.
    ///
    /// `accepts` is the profile's own ``FolderProfile/acceptsNewFiles(_:)``, and it is required:
    /// the biggest folder in a family is often an inbox, and without it real homes would be made
    /// satellites of the pile they were filed out of.
    public static func homesBySatellite(in index: DocumentIdentityIndex,
                                        accepts: (String) -> Bool) -> [String: Set<String>] {
        // How many of A's documents each other folder B also holds.
        var sharedWith: [String: [String: Int]] = [:]
        for folders in index.foldersByIdentity.values where folders.count > 1 {
            for a in folders {
                for b in folders where b != a {
                    // One increment per (a, b) per identity: a folder holding the same document
                    // twice must not count it twice against its own total.
                    sharedWith[a, default: [:]][b, default: 0] += 1
                }
            }
        }
        var out: [String: Set<String>] = [:]
        for (a, others) in sharedWith {
            let ownDocs = index.documentCounts[a] ?? 0
            guard ownDocs >= minimumShared else { continue }
            for (b, shared) in others {
                guard shared >= minimumShared,
                      Double(shared) / Double(ownDocs) >= minimumShare,
                      Double(index.documentCounts[b] ?? 0) >= minimumSizeRatio * Double(ownDocs),
                      accepts(b)
                else { continue }
                out[a, default: []].insert(b)
            }
        }
        return out
    }
}
