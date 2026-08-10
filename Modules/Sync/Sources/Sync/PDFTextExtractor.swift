import Foundation
import PDFKit

/// Reads a PDF into the ``ExtractedDocument`` that ``ContentFingerprint`` digests.
///
/// **Here rather than in `MacApp`, unlike `ContentSignalExtractor`.** That one lives in the app
/// because it reaches for Vision and NaturalLanguage, and because Filing injects it through a seam
/// the user's read-contents setting gates. This one is PDFKit alone, it is not user-gated, and
/// `MacApp` belongs to no SPM package — anything put there can only be compiled by the app build
/// and can never be unit-tested. Keeping it in `Sync` is what lets the extraction rules (page cap,
/// locked documents, evicted iCloud files) have tests at all.
///
/// The parse runs on ``PDFKitSerialAccess``'s lane — off the cooperative pool, and one at a time
/// across the whole process. A full-tree pass is 10,569 documents.
///
/// **Why the lane, and not merely "off the main thread".** This reader started out on a private
/// `.concurrent` queue, six parses at a time. The corpus replay caught it: the same 10,569
/// documents, the same binary, two runs back to back produced **226 groups and then 235**. Reading
/// every document serially once and then concurrently twice showed **~1% extract different text
/// under concurrency** while serial passes were byte-for-byte identical — PDFKit's text extraction
/// is not thread-safe, and the affected files are the ones whose embedded fonts need substitution.
/// A private *serial* queue then fixed this reader against itself and nothing more, because
/// `ContentSignalExtractor` was parsing PDFs on its own queue at the same time and two serial
/// queues race exactly like one concurrent one. Hence the process-wide lane.
///
/// A fingerprint that flaps is worse than no fingerprint: the cache would hold one digest and the
/// next scan compute another, so groups would appear and vanish between scans, and two copies of
/// one document read in the same batch could be handed different digests and missed. The price is
/// bounded — ~5.5 minutes for the full tree on a COLD scan against ~46 s, and nothing afterwards,
/// because every digest is cached by (path, mtime, size).
///
/// **Serialization removed the large effect, not every trace of it, and the residue is worth
/// knowing.** Two full replays of the same 10,569 documents now agree exactly (248 groups and 248),
/// and two independent serial re-extractions of the whole tree are byte-for-byte identical — 0 of
/// 10,569 documents differ. But the *workload itself* still shows: a pair of Chase statements that
/// groups when the two are read on their own fails to group inside the full-tree run, and about 5
/// of ~250 groups move that way. Whatever the mechanism (cache pressure inside PDFKit is the
/// obvious suspect; it is not parse order — 2,500 unrelated parses between two reads of the same
/// file change nothing), the DIRECTION is what matters and it is one-way: recall against
/// byte-identical pairs stayed 485/485 with **0 disagreements** in every configuration measured.
/// The residue costs an occasionally unreported duplicate, never a false claim about one — which
/// is the side of the trade this feature is allowed to be wrong on.
public enum PDFTextExtractor {

    private static let maxCharsPerPage = 20_000

    /// The document at `path`, or nil when there is nothing to read: not a PDF, unparseable,
    /// password-locked, or an iCloud file that is not on this disk.
    public static func read(atPath path: String) async -> ExtractedDocument? {
        await PDFKitSerialAccess.perform { readSync(path) }
    }

    /// Synchronous half, so tests can drive it without an executor.
    ///
    /// **Call it on ``PDFKitSerialAccess``'s lane, or from a test that is the only reader.** It is
    /// the parse itself, with none of the serialization — the lane is taken by ``read(atPath:)``
    /// above, not here.
    static func readSync(_ path: String) -> ExtractedDocument? {
        guard ContentFingerprint.canFingerprint(path: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        // Never force-download an evicted iCloud file to fingerprint it. `FilingSurvey.isAvailable`
        // makes the same call for the same reason: the extractor would come back with nothing and
        // the absence would be indistinguishable from an image-only scan.
        guard FilingSurvey.isAvailable(path) else { return nil }
        // A locked document yields no text, and "no text" is a claim we must not make about it —
        // returning nil declines instead, which is what the skip counter reports.
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }

        var pages: [String] = []
        var boxes: [String] = []
        var fields: [String] = []
        for index in 0..<min(document.pageCount, ContentFingerprint.maxPagesRead) {
            guard let page = document.page(at: index) else { continue }
            pages.append(String((page.string ?? "").prefix(maxCharsPerPage)))
            let bounds = page.bounds(for: .mediaBox)
            boxes.append("\(Int(bounds.width))x\(Int(bounds.height))")
            for annotation in page.annotations {
                guard let value = annotation.widgetStringValue, !value.isEmpty else { continue }
                fields.append(annotation.fieldName.map { "\($0)=\(value)" } ?? value)
            }
        }
        return ExtractedDocument(pages: pages, formFieldValues: fields,
                                 pageCount: document.pageCount, pageBoxes: boxes)
    }

    /// The default extraction seam the duplicate scan uses — path in, digest out.
    public static let fingerprint: @Sendable (String) async -> String? = { path in
        guard let document = await read(atPath: path) else { return nil }
        return ContentFingerprint.digest(of: document)
    }
}
