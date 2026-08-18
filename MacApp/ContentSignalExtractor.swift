import Foundation
import PDFKit
import Vision
import NaturalLanguage
import ImageIO
import Sync
import Events

/// On-device content signals for Filing (F2). Given a file, it reads a bounded amount of text —
/// PDF text via PDFKit, image/scan text via Vision OCR, or a plain-text head — and pulls
/// entity/keyword tokens via NaturalLanguage. Nothing leaves the device. Returns an empty set for
/// unsupported types, evicted iCloud files, or when nothing useful is found.
///
/// The heavy synchronous work (PDF parse, OCR) runs on a dedicated queue so it never blocks the
/// Swift cooperative thread pool.
enum ContentSignalExtractor {

    private static let maxTextChars = 20_000
    private static let maxTokens = 40
    private static let maxPDFPages = 5

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp"]
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "log", "text"]

    /// Dedicated concurrent queue — keeps synchronous PDF/OCR work off the cooperative executor.
    ///
    /// Stays concurrent: OCR is the slow branch (0.5–2.1 s per file) and Vision tolerates being
    /// driven from several threads, so funnelling scans through one lane would cost real time for
    /// no correctness. Only the PDF branch is serialized — see ``pdfText(_:)``.
    private static let workQueue = DispatchQueue(label: "com.synccloud.content-signals",
                                                 qos: .utility, attributes: .concurrent)

    /// The seam the manager injects: `syncManager.filingContentExtractor = ContentSignalExtractor.tokens(forFileAt:)`.
    static func tokens(forFileAt path: String) async -> Set<String> {
        await withCheckedContinuation { continuation in
            workQueue.async { continuation.resume(returning: extractSync(path)) }
        }
    }

    /// Renders a PDF's first page and reads it with OCR — for scans with no text layer.
    ///
    /// **Deliberately not part of `snippet(forFileAt:)`.** Rendering plus Vision measured 0.5–2.1 s
    /// per file on a real tree, against a few milliseconds for pulling an existing text layer. That
    /// is a click for one file and ten minutes for a 500-file inbox, so the scan records which files
    /// would benefit and the user spends it — see `FileSyncManager.readScan(for:)`.
    ///
    /// 2× is the smallest scale that read a real lease reliably; at 1× Vision missed body text on
    /// the scans measured.
    ///
    /// **The PDFKit half takes ``PDFKitSerialAccess``'s lane; Vision does not.** Opening the document
    /// and drawing the page is the same unsafe machinery ``pdfText(_:)`` serializes, so it takes its
    /// turn there. Recognition is the expensive part (seconds), it is not PDFKit, and holding the
    /// lane across it would stall every scan extraction behind one user-initiated OCR — so the lane
    /// is released the moment there is a bitmap.
    static func ocrPDFFirstPage(atPath path: String) async -> String? {
        await withCheckedContinuation { continuation in
            workQueue.async {
                let url = URL(fileURLWithPath: path)
                guard !isEvictediCloudFile(url) else { return continuation.resume(returning: nil) }
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
                    // **Said here because here is the only place the cause exists.** This returns
                    // nil for a recognizer that never ran and for a page that genuinely carries no
                    // text alike, and the caller — `FileSyncManager.readScan(for:)` — logs
                    // "OCR found no text in …" for both. So a Vision pipeline that is broken on
                    // every file read exactly like a folder of blank scans, which is the one thing
                    // an operator most needs to tell apart. Warning, not error: it is a per-file
                    // read failure and the button stays offered, so nothing is lost but this file.
                    Logger.shared.warning("Filing: OCR failed on “\(url.lastPathComponent)”: "
                                          + "\(error.localizedDescription)")
                }
                // Deliberately falls through rather than returning early: `perform` may leave
                // partial results behind, and those were used before this catch existed. The log
                // line is the whole change here — the answer this path gives is untouched.
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : String(text.prefix(maxTextChars)))
            }
        }
    }

    /// The seam the manager injects for the AI classifier: a bounded plain-text excerpt of the file
    /// (PDF text / OCR / plain), or nil when there's nothing readable. Same evicted-iCloud guard and
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

    /// Reads a bounded amount of text from a supported file. Empty for unsupported types, evicted
    /// iCloud files, or when nothing useful is found. Shared by the token and snippet seams.
    ///
    /// Internal rather than private so the read failures below can be driven from a test with a
    /// real unreadable file — the three branches it dispatches to all answer `""`, and what
    /// separates "nothing to say" from "could not look" is only the log line.
    static func extractTextSync(_ url: URL) -> String {
        // Never force-download an evicted iCloud file just to peek at its contents.
        guard !isEvictediCloudFile(url) else { return "" }

        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return pdfText(url) }
        if imageExtensions.contains(ext) { return ocrText(url) }
        if textExtensions.contains(ext) { return plainText(url) }
        return ""
    }

    /// True when the file is an iCloud item that isn't currently downloaded locally.
    private static func isEvictediCloudFile(_ url: URL) -> Bool {
        guard let vals = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              vals.isUbiquitousItem == true,
              let status = vals.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    /// Page 1, and further pages only while page 1 has not produced enough to work with.
    ///
    /// **`maxPDFPages` is a fallback for a thin first page, not a target.** Nothing downstream reads
    /// five pages: the router scores 400 characters (its measured sample), the on-device prompt
    /// carries at most 1,200 and the cloud one 800. Only the keyword engine's entity pass looks
    /// further, and it now runs for files with no confident home. So a 14-page phone bill was being
    /// parsed five pages deep to produce 16,910 characters of which every consumer used the first
    /// few hundred — on every classifiable file in the scan, extraction being the most expensive
    /// thing in it.
    ///
    /// A cover page, a fax header or a scanned first sheet still reads short, and those keep pulling
    /// pages until there is something to work with. That was the reason for reading past page 1, and
    /// it is preserved exactly; what stops is reading past a page that already said plenty.
    private static let enoughFromOnePage = 600

    /// Takes the PDFKit lane. The synchronous `run` rather than the async `perform` because this
    /// caller is already off the cooperative pool on ``workQueue`` — blocking it is exactly the
    /// intent, so several extractions queue up and take their turn.
    ///
    ///
    /// `PDFDocument`/`PDFPage.string` is not thread-safe. Measured through this exact reader over a
    /// real 10,286-document tree, six at a time: **0.83% of documents came back with different text
    /// than a serial pass**, and concurrent passes disagreed with each other as well. Narrowed to a
    /// single mortgage statement, 30 serial reads produced **one** text; adding 180 concurrent reads
    /// of the same file produced **18 distinct texts**, differing by whole reordered or dropped
    /// blocks — one came back 1,341 characters against 2,616. The affected documents are the ones
    /// whose embedded fonts need substitution (Chase statements, PG&E bills, mortgage statements).
    ///
    /// It matters more than those character counts suggest, because nothing downstream reads the
    /// whole extract — the classifier prompt carries a few hundred characters. Across those 18
    /// variants there were **7 different first-400-character windows**, so a document's tokens are
    /// drawn from text that changes between scans: unstable suggestions, and a verdict cached under
    /// a key (path, mtime, size, model, prompt) that cannot see that the question itself was
    /// composed from a different excerpt.
    ///
    /// The price is small precisely because this reader stops at ``enoughFromOnePage``: on that same
    /// full-tree cold pass, 39 s six-at-a-time against 78 s serial. (Reading all five pages, as the
    /// v2.x line still does, costs 106 s against 198 s — and flaps at 1.69% rather than 0.83%, since
    /// exposure scales with how much of each document is touched.) A real scan reads only the files
    /// it is classifying, four at a time, so it pays a fraction of that 39 s.
    ///
    /// **The lane is ``PDFKitSerialAccess``, shared with `PDFTextExtractor`, not one of this type's
    /// own.** Two serial queues race exactly like one concurrent queue — 4.5–6.3% of documents
    /// flapped when a second serial queue read PDFs alongside, against 0% with the lane to itself —
    /// and a folder-memory survey and a duplicate scan guard only their own re-entrancy, so nothing
    /// stops them extracting at the same time.
    private static func pdfText(_ url: URL) -> String {
        PDFKitSerialAccess.run { pdfTextSync(url) }
    }

    private static func pdfTextSync(_ url: URL) -> String {
        // Same rule as `plainText` and the OCR branch: a PDF that will not open is not a PDF with
        // no text in it, and only one of those is worth an operator's attention. `PDFDocument`
        // reports no error of its own, so the line says what is known — it did not open.
        guard let doc = PDFDocument(url: url) else {
            Logger.shared.warning("Filing: could not open “\(url.lastPathComponent)” as a PDF")
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

    /// **A read that failed and a file that is genuinely empty must not look the same.**
    ///
    /// This was `try?` straight to `""`. A text file the scan cannot open — permissions, a file
    /// deleted between the walk and the read, an unreachable network mount — contributed no tokens
    /// and no excerpt, and the document was then classified on its filename alone with nothing
    /// anywhere saying why. That is the same complaint the OCR branch below already answers in
    /// prose: an empty return is indistinguishable from a document that simply holds no words, and
    /// telling those apart is what an operator most needs.
    ///
    /// Warning rather than error, and the answer is unchanged: it is one file's read failing, the
    /// scan carries on, and if it fires on every file the repetition is itself the diagnosis.
    private static func plainText(_ url: URL) -> String {
        do {
            let data = try FileHandle(forReadingFrom: url).read(upToCount: 64 * 1024)
            return String(decoding: data ?? Data(), as: UTF8.self)
        } catch {
            Logger.shared.warning("Filing: could not read “\(url.lastPathComponent)”: "
                                  + "\(error.localizedDescription)")
            return ""
        }
    }

    /// Synchronous OCR: Vision's `.fast` CPU recognizer runs `perform` inline and populates
    /// `request.results`, so we read the results directly — no completion-handler continuation
    /// (which risked a double-resume crash or a never-resume hang).
    private static func ocrText(_ url: URL) -> String {
        // The branch below warns when Vision fails; this one is the same failure one step earlier —
        // an image that will not decode read as an image holding no words.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Logger.shared.warning("Filing: could not decode “\(url.lastPathComponent)” as an image")
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Same reason as the OCR path above: an empty return here is indistinguishable from an
        // image that simply holds no words, so the file contributes no tokens and no excerpt and
        // nothing anywhere says why. Warning for a benign per-item read failure; if it fires on
        // every image in a scan, that repetition is itself the diagnosis.
        do { try handler.perform([request]) } catch {
            Logger.shared.warning("Filing: OCR failed on “\(url.lastPathComponent)”: "
                                  + "\(error.localizedDescription)")
            return ""
        }
        let joined = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        // Bound like the pdf/plain-text branches (whose doc promises "a bounded amount of text"):
        // a dense full-page scan can yield a very large OCR string, and every consumer re-caps it
        // anyway, so cap here for consistency.
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
        // Tax form numbers are bare digits (stripped by the word tokenizer). Match them as a
        // whole number, not a substring, so a longer figure — a phone number ending "…8101099",
        // an amount like "10402" — doesn't inject a spurious 1099/1040 signal. Splitting on
        // non-digits yields the maximal digit runs; a run must equal the form exactly.
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
