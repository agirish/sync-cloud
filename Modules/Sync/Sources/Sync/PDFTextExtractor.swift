import Foundation
import PDFKit

/// Reads a PDF into the ``ExtractedDocument`` that ``ContentFingerprint`` digests.
///
/// In `Sync` rather than `MacApp`, unlike `ContentSignalExtractor` (which needs Vision and
/// NaturalLanguage and is gated by the user's read-contents setting): this is PDFKit alone, not
/// user-gated, and `MacApp` belongs to no SPM package, so only here can the extraction rules (page
/// cap, locked documents, cloud-only placeholders) be unit-tested.
///
/// The parse runs on ``PDFKitSerialAccess``'s lane: off the cooperative pool, and one at a time
/// across the process. PDFKit's text extraction is not thread-safe (about 1% of documents, those
/// whose embedded fonts need substitution, read differently under concurrency), and a private
/// serial queue would still race `ContentSignalExtractor`'s. A fingerprint that flaps is worse
/// than none: cached and fresh digests would disagree, so groups would appear and vanish between
/// scans. The cost is a slower cold scan (minutes rather than seconds on a full tree) and nothing
/// after, since every digest is cached by (path, mtime, size, file number, ctime).
///
/// A small residue remains: a pair that groups when read alone can occasionally fail to group
/// inside a full-tree run. It only ever costs an unreported duplicate, never a false one, which
/// is the side this feature may be wrong on.
public enum PDFTextExtractor {

    private static let maxCharsPerPage = 20_000

    /// The document at `path`, or nil when there is nothing to read: not a PDF, unparseable,
    /// password-locked, or an iCloud file that is not on this disk.
    ///
    /// The availability check runs before the lane, not on it: it is a `stat` and a resource
    /// read, not PDFKit, and on a cloud-stored tree most documents fail it, so each would hold up
    /// Edit's PDFs, Print and the column preview only to be turned away.
    ///
    /// The `lstat` half is asked again on the lane, just before the open. The lane's queue can be
    /// seconds long on a cold scan, and a file "Optimize Storage" evicts in that wait would be
    /// opened as a synchronous download, holding the lane and everything behind it.
    public static func read(atPath path: String,
                            isAvailable: @Sendable (String) -> Bool = FilingSurvey.isAvailable) async -> ExtractedDocument? {
        guard ContentFingerprint.canFingerprint(path: path), isAvailable(path) else { return nil }
        return await PDFKitSerialAccess.perform {
            readSync(path, isAvailable: { !MaterializationStatus.isCloudOnly(atPath: $0) })
        }
    }

    /// What reading `path` came to, three ways (``FingerprintReading``). Not read is
    /// ``FingerprintReading/unreadable``; read but under the token floor is
    /// ``FingerprintReading/tooLittleText``.
    public static func reading(atPath path: String,
                               isAvailable: @Sendable (String) -> Bool = FilingSurvey.isAvailable) async -> FingerprintReading {
        guard let document = await read(atPath: path, isAvailable: isAvailable) else { return .unreadable }
        return ContentFingerprint.digest(of: document).map(FingerprintReading.digest) ?? .tooLittleText
    }

    /// Synchronous half, so tests can drive it without an executor.
    ///
    /// **Call it on ``PDFKitSerialAccess``'s lane**, or from a test that is the only reader: this
    /// is the parse with none of the serialization, which ``read(atPath:)`` provides.
    ///
    /// `isAvailable` is a parameter because a dataless file can't be made in a test, and this
    /// guard matters most (see below). Defaulted rather than a settable static, so parallel tests
    /// can't see each other's substitution.
    static func readSync(_ path: String,
                         isAvailable: (String) -> Bool = FilingSurvey.isAvailable) -> ExtractedDocument? {
        guard ContentFingerprint.canFingerprint(path: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        // Never force-download a cloud-only placeholder to fingerprint it. The scan hands this
        // every PDF in the tree, so without this line a cloud-stored tree would download the
        // user's whole offloaded library on every cold scan.
        guard isAvailable(path) else { return nil }
        // A locked document yields no text, and "no text" is a claim we must not make about it:
        // nil declines instead, which the skip counter reports. Belt and braces: PDFKit gives a
        // locked document no page text and no widget values, so the token floor declines it too,
        // and no test can tell this line from its absence.
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

    /// The default extraction seam the duplicate scan and To File use: path in, reading out.
    public static let fingerprintReading: @Sendable (String) async -> FingerprintReading = { path in
        await reading(atPath: path)
    }

    /// Path in, digest out, nil for either kind of no-digest: for a caller that caches nothing.
    public static let fingerprint: @Sendable (String) async -> String? = { path in
        if case .digest(let digest) = await reading(atPath: path) { return digest }
        return nil
    }
}
