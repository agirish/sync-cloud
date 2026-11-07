import Foundation
import PDFKit
import Vision
import NaturalLanguage
import ImageIO
import Sync
import Events

/// On-device content signals for Filing. Reads a bounded amount of a file's text (PDF text via
/// PDFKit, image text via Vision OCR, or a plain-text head) and pulls entity and keyword tokens via
/// NaturalLanguage. Nothing leaves the device. Empty for unsupported types, cloud-only
/// placeholders, or when nothing useful is found.
///
/// The heavy synchronous work (PDF parse, OCR) runs on a dedicated queue so it never blocks the
/// Swift cooperative thread pool.
enum ContentSignalExtractor {
    /// The running scan's warning budget, set for the extraction `workQueue` is running.
    /// Touched only on `workQueue`, which is serial.
    nonisolated(unsafe) private static var budget: FilingWarningBudget?

    /// Logs a per-file read warning, or keeps the name for the scan's closing line once the
    /// budget is spent. With no budget (a read outside a scan) every warning is logged.
    private static func warn(_ name: String, _ message: @autoclosure () -> String,
                             file: String = #file, line: Int = #line, function: String = #function) {
        guard budget?.admit(name) ?? true else { return }
        // The caller's place in the Location tail, not this helper's.
        Logger.shared.warning(message(), file: file, line: line, function: function)
    }

    private static let maxTextChars = 20_000
    private static let maxTokens = 40
    private static let maxPDFPages = 5

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp"]
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "log", "text"]

    /// Keeps synchronous PDF and OCR work off the cooperative executor. Concurrent, because OCR is
    /// the slow branch (seconds per file) and Vision tolerates several threads. Only the PDF branch
    /// is serialized (see ``pdfText(_:)``).
    private static let workQueue = DispatchQueue(label: "com.synccloud.content-signals",
                                                 qos: .utility, attributes: .concurrent)

    /// The seam the manager injects: `syncManager.filingContentExtractor = ContentSignalExtractor.tokens(forFileAt:)`.
    static func tokens(forFileAt path: String) async -> Set<String> {
        await withCheckedContinuation { continuation in
            // Read here, in the task: a task-local isn't visible inside the queue's block.
            let budget = FilingWarningBudget.current
            workQueue.async {
                // The queue is serial, so one extraction at a time sees this budget.
                Self.budget = budget
                defer { Self.budget = nil }
                continuation.resume(returning: extractSync(path))
            }
        }
    }

    /// Renders a PDF's first page and reads it with OCR, for scans with no text layer.
    ///
    /// Not part of `snippet(forFileAt:)`: rendering plus Vision takes 0.5–2.1 s per file against
    /// milliseconds for an existing text layer, so the scan records which files would benefit and
    /// the user chooses to spend it (`FileSyncManager.readScan(for:)`). 2× is the smallest scale
    /// that reads body text reliably; at 1× Vision misses it.
    ///
    /// The PDFKit half takes ``PDFKitSerialAccess``'s lane; Vision does not. Opening and
    /// drawing the page is the unsafe machinery ``pdfText(_:)`` serializes. Recognition is the
    /// expensive part and is not PDFKit, so the lane is released once there is a bitmap rather
    /// than stalling every scan extraction behind one OCR.
    static func ocrPDFFirstPage(atPath path: String) async -> String? {
        await withCheckedContinuation { continuation in
            workQueue.async {
                let url = URL(fileURLWithPath: path)
                // Same provider-agnostic guard as `extractTextSync`: rendering page 1 opens the
                // document, and opening a placeholder is what makes the provider fetch it.
                guard FilingSurvey.isAvailable(url.path) else { return continuation.resume(returning: nil) }
                let image: CGImage? = PDFKitSerialAccess.run {
                    guard let doc = PDFDocument(url: url), !doc.isLocked,
                          let page = doc.page(at: 0) else { return nil }
                    let bounds = page.bounds(for: .mediaBox)
                    let scale: CGFloat = 2
                    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                    guard size.width > 1, size.height > 1,
                          let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                    else { return nil }
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(origin: .zero, size: size))
                    ctx.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: ctx)
                    return ctx.makeImage()
                }
                guard let image else { return continuation.resume(returning: nil) }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    // Logged here, the only place the cause exists: this returns nil both for a
                    // recognizer that failed and for a blank page, and the caller
                    // (`FileSyncManager.readScan(for:)`) logs both as "no text". Warning, not
                    // error: one file's read failed and the button stays offered.
                    warn(url.lastPathComponent, "Filing: OCR failed on “\(url.lastPathComponent)”: "
                                          + "\(error.localizedDescription)")
                }
                // Falls through rather than returning early: `perform` may leave partial results
                // behind, and those are still used.
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : String(text.prefix(maxTextChars)))
            }
        }
    }

    /// The seam the manager injects for the AI classifier: a bounded plain-text excerpt of the file
    /// (PDF text / OCR / plain), or nil when there's nothing readable. Same cloud-only guard and
    /// bounds as the token path — nothing leaves the device.
    static func snippet(forFileAt path: String) async -> String? {
        await withCheckedContinuation { continuation in
            workQueue.async {
                let text = extractTextSync(URL(fileURLWithPath: path))
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }

    // MARK: Extraction (runs on workQueue)

    private static func extractSync(_ path: String) -> Set<String> {
        let text = extractTextSync(URL(fileURLWithPath: path))
        guard !text.isEmpty else { return [] }
        return tokens(fromText: text)
    }

    /// Reads a bounded amount of text from a supported file. Empty for unsupported types,
    /// cloud-only placeholders, or when nothing useful is found. Shared by the token and snippet
    /// seams.
    ///
    /// The cloud-only guard is `FilingSurvey.isAvailable`, not a copy, so a dataless Dropbox,
    /// OneDrive or Drive file is never opened (opening it makes the provider download it).
    ///
    /// Internal so a test can drive the read failures with a real unreadable file: every branch
    /// answers `""`, and only the log line separates "nothing to say" from "could not look".
    static func extractTextSync(_ url: URL) -> String {
        // Never force-download a cloud-only placeholder just to peek at its contents.
        guard FilingSurvey.isAvailable(url.path) else { return "" }

        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return pdfText(url) }
        if imageExtensions.contains(ext) { return ocrText(url) }
        if textExtensions.contains(ext) { return plainText(url) }
        return ""
    }

    /// Page 1, and further pages only while page 1 has not produced enough to work with.
    ///
    /// `maxPDFPages` is a fallback for a thin first page, not a target. Nothing downstream needs
    /// five pages: the router scores 400 characters, the on-device prompt carries at most 1,200 and
    /// the cloud one 800, and extraction is the most expensive step in a scan. A cover page, fax
    /// header or scanned first sheet still reads short, and keeps pulling pages until there is
    /// something to work with.
    private static let enoughFromOnePage = 600

    /// Takes the PDFKit lane. The synchronous `run`, not the async `perform`, because this caller is
    /// already off the cooperative pool on ``workQueue``: blocking it is the intent, so several
    /// extractions queue up and take their turn.
    ///
    /// **`PDFDocument`/`PDFPage.string` is not thread-safe.** Read concurrently, documents whose
    /// embedded fonts need substitution come back with whole blocks reordered or dropped, so the
    /// text differs between scans. The classifier reads only the first few hundred characters, so
    /// that means unstable suggestions and cached verdicts drawn from a different excerpt than
    /// their key implies. Serializing costs little because this reader stops at
    /// ``enoughFromOnePage``.
    ///
    /// **The lane is ``PDFKitSerialAccess``, shared with `PDFTextExtractor`, never one of this
    /// type's own:** two serial queues race exactly like one concurrent queue, and a folder-memory
    /// survey and a duplicate scan can extract at the same time.
    private static func pdfText(_ url: URL) -> String {
        PDFKitSerialAccess.run { pdfTextSync(url) }
    }

    private static func pdfTextSync(_ url: URL) -> String {
        // As in `plainText` and the OCR branch: a PDF that will not open is not a PDF with no
        // text, so say so. `PDFDocument` reports no error of its own.
        guard let doc = PDFDocument(url: url) else {
            warn(url.lastPathComponent, "Filing: could not open “\(url.lastPathComponent)” as a PDF")
            return ""
        }
        var out = ""
        for i in 0..<min(doc.pageCount, maxPDFPages) {
            if let s = doc.page(at: i)?.string { out += s + "\n" }
            if out.count >= maxTextChars { break }
            if out.count >= enoughFromOnePage { break }
        }
        return String(out.prefix(maxTextChars))
    }

    /// The first 64 KB as UTF-8. A read that failed must not look like an empty file: one the scan
    /// cannot open (permissions, deleted since the walk, an unreachable mount) is classified on its
    /// filename alone, so the warning says why. Warning, not error: one file failed and the scan
    /// carries on; if it fires on every file, the repetition is the diagnosis.
    private static func plainText(_ url: URL) -> String {
        do {
            let data = try FileHandle(forReadingFrom: url).read(upToCount: 64 * 1024)
            return String(decoding: data ?? Data(), as: UTF8.self)
        } catch {
            warn(url.lastPathComponent, "Filing: could not read “\(url.lastPathComponent)”: "
                                  + "\(error.localizedDescription)")
            return ""
        }
    }

    /// Synchronous OCR: Vision's `.fast` recognizer runs `perform` inline and populates
    /// `request.results`, so the results are read directly. No completion-handler continuation,
    /// which risks a double-resume crash or a never-resume hang.
    private static func ocrText(_ url: URL) -> String {
        // The same failure one step before Vision: an image that will not decode must not read
        // as an image holding no words.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            warn(url.lastPathComponent, "Filing: could not decode “\(url.lastPathComponent)” as an image")
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // As in the OCR path above: an empty return looks like an image with no words, so the
        // failure is logged. Warning, since it is one file's read.
        do { try handler.perform([request]) } catch {
            warn(url.lastPathComponent, "Filing: OCR failed on “\(url.lastPathComponent)”: "
                                  + "\(error.localizedDescription)")
            return ""
        }
        let joined = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        // Bounded like the PDF and plain-text branches: a dense full-page scan can yield a very
        // large string.
        return String(joined.prefix(maxTextChars))
    }

    // MARK: Tokenization (pure, testable)

    /// Entity + category-keyword tokens from a block of text, using the same tokenizer as the
    /// FilingEngine so content and filename tokens are comparable.
    static func tokens(fromText text: String) -> Set<String> {
        let snippet = String(text.prefix(maxTextChars))
        var tokens = entities(in: snippet)
        // Category keywords that appear as whole words (insurers, brands, "invoice", "statement"…).
        tokens.formUnion(FilingEngine.nameTokens(snippet).intersection(FilingEngine.categoryKeywords))
        // Tax form numbers are bare digits, which the word tokenizer strips. Match whole digit
        // runs, not substrings, so a phone number ending "…8101099" or an amount like "10402"
        // doesn't inject a spurious 1099/1040.
        let digitRuns = snippet.components(separatedBy: CharacterSet.decimalDigits.inverted)
        for form in ["1099", "1040"] where digitRuns.contains(form) { tokens.insert(form) }
        return tokens
    }

    private static func entities(in text: String) -> Set<String> {
        var out = Set<String>()
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            if tag == .organizationName || tag == .placeName {
                for t in FilingEngine.nameTokens(String(text[range])) { out.insert(t) }
            }
            return out.count < maxTokens
        }
        return out
    }
}
