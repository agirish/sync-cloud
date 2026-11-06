import Foundation
import CryptoKit

/// What a PDF reader hands the fingerprint: the text it could pull, plus the structural readings
/// that are content rather than bytes. Not a bare `String`, because text alone over-claims (see
/// ``ContentFingerprint``). Everything here comes from the document, nothing from the file's bytes.
public struct ExtractedDocument: Sendable, Equatable {
    /// Page text, in page order, for the pages that were read.
    public let pages: [String]
    /// AcroForm widget values: what a filled form holds that its blank template does not. Empty for
    /// most documents.
    public let formFieldValues: [String]
    /// The document's full page count, including pages beyond ``ContentFingerprint/maxPagesRead``.
    public let pageCount: Int
    /// Each read page's media box as `"<width>x<height>"` in whole points.
    public let pageBoxes: [String]

    public init(pages: [String], formFieldValues: [String] = [], pageCount: Int, pageBoxes: [String] = []) {
        self.pages = pages
        self.formFieldValues = formFieldValues
        self.pageCount = pageCount
        self.pageBoxes = pageBoxes
    }
}

/// What reading one document for its fingerprint came to. Three cases, because only one of the two
/// "no digest" answers may be cached. A document parsed with too little text says the same until its
/// bytes change. One that could not be read (a cloud placeholder, stale, password-locked or
/// unparseable) must be tried again next scan: cached, a placeholder would stay unfingerprinted
/// after it downloaded, since downloading leaves its path, mtime and size as they were.
public enum FingerprintReading: Sendable, Equatable {
    case digest(String)
    /// Parsed fine; fewer than ``ContentFingerprint/minimumTokens`` tokens. Cached.
    case tooLittleText
    /// Not read at all. Never cached.
    case unreadable
}

/// A digest over what a PDF says rather than what its bytes are, so two downloads of one document
/// match even when a provider re-stamped a fresh `/ID` into the second. `DuplicateFinder` can't
/// see such pairs: they hash fine, fail to match, and report a clean result that is wrong.
///
/// The digest covers the token multiset of the text and form field values, plus the page count and
/// each page's media box. On the surveyed tree the form values and media boxes each remove false
/// groups; the page count and ``minimumTokens`` remove none and are kept for reasons the corpus
/// can't show, given at their declarations. Measure a change over a frozen extraction, not by
/// re-running the reader, which is slow enough that the tree moves underneath it.
///
/// Sorted, not ordered: sorting also matches re-renders whose text PDFKit hands back in a different
/// order, and on the surveyed tree it gained more real groups than false ones, by a small margin.
/// Counts, not a set, so two statements differing only in how often a line repeats don't collide.
///
/// No decodability gate (unlike ``FilingSurvey/isDecodable(_:)``): two downloads of one document
/// whose fonts lack a `ToUnicode` map produce the same glyph soup, which is still a good identity,
/// and gating on it would drop real groups.
public enum ContentFingerprint {

    /// Bumped when any rule below changes. It leads the canonical string, so digests from different
    /// rules can never collide.
    ///
    /// **Bumping it means deleting the fingerprint index too.** The persisted index is keyed on
    /// (path, mtime, size, file number, ctime), not the scheme, so unchanged files keep their
    /// old-rule digest while new ones get the new rule, and a pair straddling the bump silently
    /// never matches. Entries live while used (``ContentHashCache/maxEntryAge``), so it never heals.
    /// Settings ▸ Saved scan data clears it, or delete
    /// ``ContentHashIndexStore/defaultFingerprintURL(fileManager:)``; expect a full re-read of the
    /// tree (minutes for ten thousand documents).
    public static let scheme = "pdf-text-1"

    /// How many pages are read; nothing downstream needs more. This cap is why
    /// ``ExtractedDocument/pageCount`` is in the digest: two documents sharing their first twenty
    /// pages and differing after would otherwise match. A fixture pins that case, since the surveyed
    /// tree has none.
    public static let maxPagesRead = 20

    /// Below this many tokens a document has not said enough to be identified by what it says. As
    /// text thins, the canonical string approaches page count plus geometry and stops being about the
    /// document; the floor cuts that off. It changes no group on the surveyed tree and is insurance:
    /// a scanner can produce one-token pages (`textlessScansOfTheSameShapeAreNotOneDocument`). Eight
    /// is a judgement; lower it if it declines documents that matter. Changing it re-reads documents
    /// cached as too short, since their marker names it (``tooLittleTextMarker``).
    public static let minimumTokens = 8

    /// The digest, or nil when this document has not said enough to be identified by its text.
    public static func digest(of document: ExtractedDocument) -> String? {
        var counts: [String: Int] = [:]
        var total = 0
        for page in document.pages.prefix(maxPagesRead) {
            for token in tokens(in: page) { counts[token, default: 0] += 1; total += 1 }
        }
        for value in document.formFieldValues {
            for token in tokens(in: value) { counts[token, default: 0] += 1; total += 1 }
        }
        guard total >= minimumTokens else { return nil }

        var canonical = "\(scheme)|p\(document.pageCount)|b"
        canonical += document.pageBoxes.prefix(maxPagesRead).joined(separator: ",")
        canonical += "|"
        for key in counts.keys.sorted() {
            canonical += "\(key) \(counts[key]!);"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return HexEncoding.string(digest)
    }

    /// Maximal runs of ASCII alphanumerics, lowercased.
    ///
    /// Not ``FilingRouter/tokenize(_:)``, which drops stop words and one-character tokens because it
    /// scores relevance; this asks identity, where every character is evidence. The two never meet,
    /// so they may disagree. ASCII-only means a non-Latin document contributes only its dates,
    /// amounts and form numbers; on the surveyed tree a Unicode tokenizer found the same groups, but
    /// a corpus with many non-Latin documents is a reason to re-measure.
    static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        current.reserveCapacity(24)
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// What ``ContentHashCache/sharedTextless`` holds for a document read with fewer than
    /// ``minimumTokens`` tokens. Keyed like a digest, so it is invalidated like one, and it spares a
    /// warm rescan re-parsing every image-only scan.
    ///
    /// **Never an identity.** It can't equal a 64-hex digest, but every negative is the same string,
    /// so reading it as an identity would make all of them one document: Duplicates would group them
    /// and To File would call each "already filed". So it lives in its own store no identity reader
    /// opens, ``FileSyncManager/fingerprintDocuments`` answers nil for it, and
    /// ``DocumentIdentityIndex/build(hashes:fingerprints:textless:providerRoot:existsOnDisk:)`` drops
    /// one that reaches the fingerprint index.
    ///
    /// It names ``scheme`` and the floor, so lowering the floor without a scheme bump turns old
    /// markers into misses and those documents are read again rather than declined for good.
    public static let tooLittleTextMarker = noFingerprintPrefix + scheme + ":floor\(minimumTokens)"

    static let noFingerprintPrefix = "none:"

    /// Whether a cached value is a negative marker, from this scheme or any other.
    public static func isNoFingerprintMarker(_ value: String) -> Bool {
        value.hasPrefix(noFingerprintPrefix)
    }

    /// The file extensions a fingerprint can be taken of. PDFs only for now: they are most of the
    /// files, and the PDF extractor is the only reader wired up.
    public static let fingerprintableExtensions: Set<String> = ["pdf"]

    /// Whether this path is worth handing to an extractor at all.
    public static func canFingerprint(path: String) -> Bool {
        fingerprintableExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
