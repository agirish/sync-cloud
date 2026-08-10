import Foundation

/// Where the tree already holds each document — built from the persisted content indexes, and the
/// shared input to both "this folder is somebody else's copy" and "this file is already filed".
///
/// One identity per file: the ``ContentFingerprint`` digest where there is one, and the byte hash
/// otherwise. **The fingerprint has to win for PDFs**, because the case this exists for is a
/// provider handing out the same statement twice with a fresh `/ID` stamped into it — the four
/// payslips copied into an H-1B petition folder share not one byte-hash with the originals they
/// were copied from, and only the text digest sees them as the same documents.
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

    /// Builds the index from the two persisted stores.
    ///
    /// `existsOnDisk` is injected so this stays pure and testable, and because it matters: the
    /// indexes are a cache and outlive the files they describe. A stale record would let a folder
    /// that no longer exists vouch for a document, or inflate the count that decides which of two
    /// folders is the established one.
    public static func build(hashes: [ContentHashRecord], fingerprints: [ContentHashRecord],
                             providerRoot: String,
                             existsOnDisk: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> DocumentIdentityIndex {
        let prefix = providerRoot.hasSuffix("/") ? providerRoot : providerRoot + "/"
        var identity: [String: String] = [:]
        // Byte hashes first, fingerprints second, so a PDF that is in both ends up keyed by what it
        // SAYS. Prefixed rather than bare so the two namespaces can never collide.
        for r in hashes where r.path.hasPrefix(prefix) { identity[r.path] = "b:" + r.hex }
        for r in fingerprints where r.path.hasPrefix(prefix) { identity[r.path] = "f:" + r.hex }

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

    /// The folders already holding this document, other than `excluding`.
    public func folders(holding identity: String, excluding: String? = nil) -> [String] {
        (foldersByIdentity[identity] ?? []).filter { $0 != excluding }.sorted()
    }
}

/// Folders that are somebody else's copies — an evidence packet, a submission bundle, a scratch
/// duplicate — rather than a document's home.
///
/// **The distinction the router cannot make from content**, and that is not a shortcoming of the
/// weights. `Immigration/…/Petition/Supporting Documents/pay_statements` holds four copies of
/// payslips whose originals are in `Work/HPE/Compensation/Salary Statements/2026`; the two folders
/// say the same words because they hold the same documents. Measured on the real tree, the raw
/// content evidence for a fifth payslip is 76.49 for the copy against 70.69 for the home — and the
/// entire 5.80 difference is the anchor `payslip`, which the copies' folder learned from the
/// filenames they were saved under. Equalise the `÷√docs` term and the two land 1.3154 to 1.3128, a
/// 0.2% gap. **No amount of tuning separates a folder from a stash of its own documents.**
///
/// So the signal is structural and directional: A is a satellite of B when most of A's documents
/// are also in B and B is substantially the larger folder.
public enum SatelliteFolders {

    /// How much of a folder's own documents must also live in the candidate home. Below this the
    /// relation is coincidence: at 0.5 the tree produces pairs like `Home/Insurance/2022` inside a
    /// hiring folder's candidate list, on the strength of two documents out of three.
    public static let minimumShare = 0.75
    /// And at least this many documents, for the same reason — a share is not evidence at n = 2.
    public static let minimumShared = 3
    /// How much bigger the home must be. **This is the threshold that separates a satellite from
    /// two folders that merely overlap**, and it was chosen by reading what each value admits on
    /// the real tree: at 1.01× the relation includes `Papers/SQL` inside `Papers/Data Analytics`
    /// (3 documents against 4), `Checking 5670/2016` inside `Savings 3931/2016` (6 against 7) and
    /// two sem-results asset folders pointing at each other — pairs where "bigger" is noise and the
    /// direction is arbitrary. At 2× those are gone and every case the relation exists for remains.
    public static let minimumSizeRatio = 2.0

    /// Satellite folder → the folders it is a copy of. Both sides are provider-relative.
    ///
    /// `accepts` is the profile's own ``FolderProfile/acceptsNewFiles(_:)``, and it is not a
    /// nicety: without it the biggest folder in a family is routinely an **inbox**, and the
    /// relation reads backwards. On this tree it made satellites of
    /// `Finance/US/Credit Accounts/Chase/Credit 2809/2024` (inside `Chase/TODO`, 47 documents),
    /// `Work/HPE/Compensation/401(k)` (inside `Fidelity/TODO - 2023`) and five more — every one of
    /// them a real home being demoted in favour of the pile it was filed out of.
    public static func homesBySatellite(in index: DocumentIdentityIndex,
                                        accepts: (String) -> Bool) -> [String: Set<String>] {
        // How many of A's documents each other folder B also holds.
        var sharedWith: [String: [String: Int]] = [:]
        for folders in index.foldersByIdentity.values where folders.count > 1 {
            for a in folders {
                for b in folders where b != a {
                    // One increment per (a, b) per identity — a folder holding the same document
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
