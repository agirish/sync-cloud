import Foundation
import CryptoKit

/// What a PDF reader hands the fingerprint: the text it could pull, plus the two structural
/// readings that are content rather than bytes.
///
/// A value type rather than a bare `String` because the text alone over-claims, and the two extra
/// fields are what measurement said to add (see ``ContentFingerprint``). Everything here is
/// derivable from the document, nothing from the file's bytes — that is the whole point.
public struct ExtractedDocument: Sendable, Equatable {
    /// Page text, in page order, for the pages that were read.
    public let pages: [String]
    /// AcroForm widget values — what a *filled* form holds that its blank template does not.
    /// Empty for the great majority of documents.
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

/// A digest over what a PDF *says* rather than what its bytes are — so two downloads of one
/// document match even though a provider re-stamped a fresh `/ID` into the second.
///
/// **The problem, measured on this tree.** 10,569 PDFs; 736 groups share a byte size and 232 share
/// a (name, size). Of those 232, only 183 are byte-identical — the other 49 are the same document
/// twice with different bytes, and `DuplicateFinder` cannot see any of them. Worse than the three
/// blind spots `DEFERRED_ENHANCEMENTS.md` #6 lists, because those are *counted and reported* while
/// this one hashes successfully, fails to match, and reports a clean result that is wrong.
///
/// **What the digest is over.** The token multiset of the extracted text and the form field
/// values, plus the page count and each page's media box. Each ingredient was ablated over one
/// frozen extraction of the real tree — 253 groups at baseline, about five more than the live
/// reader reports for the reason ``PDFTextExtractor`` records — and what it is worth is:
///
/// | ingredient | groups it removes | recall cost |
/// |---|---|---|
/// | form field values | 14 | none |
/// | media boxes | 3 | none |
/// | page count | 0 | none |
/// | ``minimumTokens`` floor | 0 | 4 pairs the byte hash already had |
///
/// Two of those are honestly inert on this tree and are kept for reasons the corpus cannot show;
/// each says why at its own declaration. **Ablate over a frozen extraction, not by re-running the
/// reader** — re-parsing the tree per variant took 28 minutes a run under load, and the tree itself
/// moves underneath a measurement that slow.
///
/// **Sorted, not ordered — but the margin is three documents, not the landslide the case for it
/// assumed.** Hashing the token *sequence* would be strictly more discriminating, and over the same
/// extraction it finds 248 of the 253 groups the multiset finds. Reading the five groups only the
/// multiset admits settles it: three are real (a state tax transcript filed twice, a compressed
/// passport beside its original, a compressed birth certificate beside its original — re-renders
/// that reordered the text PDFKit hands back), and two are not the same document (a resume
/// revision, and a report whose filename literally ends "- Sorted"). Sorting wins, and it is worth
/// knowing it wins by three documents rather than by the margin the hand-run that motivated it
/// suggested.
///
/// **Counts, not a set.** A set of tokens loses repetition, so two statements differing only in how
/// many times a line item repeats would collide. Counting costs nothing.
///
/// **No decodability gate, and that is deliberate.** ``FilingSurvey/isDecodable(_:)`` refuses text
/// from a PDF whose fonts carry no `ToUnicode` map, because glyph soup would become a folder's
/// rarest anchors. That hazard does not exist here and the reflex to port it is expensive: two
/// downloads of one soupy document produce the *same* soup, which is a perfectly good identity.
/// Measured, gating on decodability would drop 11 groups, and ten of them are real — including both
/// halves of the `Form 1095-C` pair that is the clearest evidence in the tree of a folder taxonomy
/// duplicated in two places.
public enum ContentFingerprint {

    /// Bumped when any rule below changes. It is the first thing in the canonical string, so a
    /// digest computed under an older rule can never COLLIDE with one computed under this one.
    ///
    /// **That is not the same as being safe to bump, and the difference is the cache.** The
    /// persisted index is keyed on (path, mtime, size) — the scheme is nowhere in the key — so
    /// after a bump every unchanged file keeps being served the digest it was given under the old
    /// rule, while anything new or edited gets one under the new rule. The two never collide; they
    /// simply never match, so a re-stamped pair straddling the bump goes unreported until the old
    /// entries age out under ``ContentHashCache/maxEntryAge`` (30 days). One-way toward a missed
    /// group rather than a false one, and self-healing — but silent, and up to a month long.
    ///
    /// So bumping this means deleting the fingerprint index with it. It has its own file precisely
    /// so that costs nothing else: Settings ▸ Saved scan data already clears it, or delete
    /// ``ContentHashIndexStore/defaultFingerprintURL(fileManager:)``. Budget one full re-read of
    /// the tree afterwards (~5.5 minutes for 10,569 documents).
    public static let scheme = "pdf-text-1"

    /// How many pages are read. Nothing downstream needs more, and a 500-page document would
    /// otherwise pay for pages that only repeat the covenant boilerplate on page 3.
    ///
    /// This cap is why ``ExtractedDocument/pageCount`` is in the digest: two documents sharing
    /// their first twenty pages and differing after them would otherwise be called the same. That
    /// case does not occur in the surveyed tree — the page count removed no group there — so it is
    /// pinned by a fixture rather than by the corpus.
    public static let maxPagesRead = 20

    /// Below this many tokens a document has not said enough to be identified by what it says.
    ///
    /// **A bound on a degenerate case, and measured INERT on the tree it was written for — which is
    /// not what the first version of this comment claimed.** As the text thins, the canonical string
    /// approaches page count plus page geometry and stops being about the document at all; the floor
    /// is where that is cut off.
    ///
    /// The draft justified it with ten unrelated quarterly earnings summaries — each a two-page
    /// 612×792 scan whose entire extracted content was the page-number token `1` — grouping as one.
    /// That reading came from a concurrent extraction, and it was **an artifact of the race**
    /// ``PDFTextExtractor/workQueue`` now prevents: read serially, every one of those documents
    /// yields *zero* tokens and is declined whatever the floor is. Ablated over a frozen serial
    /// extraction the floor removes **no group at all**, and its only measurable effect is to stop
    /// judging four byte-identical pairs — which costs nothing, because the content hash has already
    /// grouped those.
    ///
    /// So it stays as insurance rather than as a fix: a one-token page is a shape a scanner can
    /// certainly produce, `textlessScansOfTheSameShapeAreNotOneDocument` shows what happens without
    /// the floor when it does, and eight is a judgement — there is no knee in the data to pick it
    /// from. If a real corpus ever shows it declining documents that mattered, lower it.
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
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Maximal runs of ASCII alphanumerics, lowercased.
    ///
    /// Deliberately NOT ``FilingRouter/tokenize(_:)``. That tokenizer drops stop words and
    /// one-character tokens because it is scoring *relevance*, where "the" carries nothing; this is
    /// asking *identity*, where every character the document contains is evidence and throwing any
    /// of it away only makes two documents easier to confuse. The two never meet — no fingerprint
    /// is ever compared against a corpus anchor — so they are free to disagree.
    ///
    /// **ASCII, and that IS throwing something away — measured, and it costs nothing here.** A
    /// document in a non-Latin script contributes only its ASCII residue (dates, amounts, form
    /// numbers), which is a recall risk and, if two different such documents shared that residue,
    /// a precision one. Ablated against a Unicode-aware tokenizer over the frozen serial extraction
    /// of the real tree: 7 documents of 10,280 are a quarter or more non-ASCII words, **none** of
    /// them falls under the token floor that a Unicode rule would clear, and the two tokenizers
    /// find the **same 253 groups** — no group unique to either, recall 485/485 with 0
    /// disagreements both ways. So this stays, on a tree that cannot tell the difference; a corpus
    /// with real non-Latin documents in it would be a reason to re-measure, not to assume.
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

    /// The file extensions a fingerprint can be taken of. PDFs only, for now: the roadmap item is
    /// about a re-stamped PDF, 80% of this tree's files are PDFs, and the extractor below is the
    /// only reader wired up.
    public static let fingerprintableExtensions: Set<String> = ["pdf"]

    /// Whether this path is worth handing to an extractor at all.
    public static func canFingerprint(path: String) -> Bool {
        fingerprintableExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
