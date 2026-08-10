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
/// The synchronous parse runs on its own queue, never on the cooperative pool — the same reason
/// `ContentSignalExtractor` has one. A full-tree pass is 10,569 documents.
public enum PDFTextExtractor {

    private static let maxCharsPerPage = 20_000

    /// **Serialized, and that is a correctness requirement rather than a style choice.**
    ///
    /// This started out `.concurrent`, six parses at a time, like `ContentSignalExtractor`'s queue.
    /// The corpus replay caught it: the same 10,569 documents, the same binary, two runs back to
    /// back produced **226 groups and then 235**. Isolating it — read every document serially once,
    /// then concurrently twice — showed **~1% of documents extract different text under
    /// concurrency**, and disagree with each other run to run, while serial passes over those same
    /// documents were byte-for-byte identical. PDFKit's text extraction is not thread-safe; the
    /// affected files are ones whose embedded fonts need substitution (a whole folder of PG&E
    /// bills, a run of mortgage statements), which is consistent with a race in the shared font
    /// machinery underneath.
    ///
    /// A fingerprint that flaps is worse than no fingerprint: the cache would hold one digest and
    /// the next scan compute another, so groups would appear and vanish between scans, and two
    /// copies of one document read in the same batch could be handed different digests and missed.
    ///
    /// The price is real and bounded — the full tree goes from ~46 s of wall time to ~4 minutes on
    /// a COLD scan, and to nothing at all afterwards, because every digest is cached by (path,
    /// mtime, size). Callers may still issue reads concurrently; they simply queue here.
    ///
    /// **The lane is ``PDFKitSerialAccess``, not a queue of this type's own.** A private serial
    /// queue here protected this reader from itself and nothing more: `ContentSignalExtractor` was
    /// parsing PDFs on its own queue at the same time, and two serial queues race exactly like one
    /// concurrent one — 4.5–6.3% of documents flapped, against 0% with the lane to itself. See that
    /// type for the measurement.

    /// The document at `path`, or nil when there is nothing to read: not a PDF, unparseable,
    /// password-locked, or an iCloud file that is not on this disk.
    public static func read(atPath path: String) async -> ExtractedDocument? {
        await PDFKitSerialAccess.perform { readSync(path) }
    }

    /// Synchronous half, so tests can drive it without an executor.
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
