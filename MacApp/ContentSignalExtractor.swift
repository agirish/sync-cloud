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
    /// no correctness. Only the PDF branch is serialized, on ``pdfQueue`` below.
    private static let workQueue = DispatchQueue(label: "com.synccloud.content-signals",
                                                 qos: .utility, attributes: .concurrent)

    /// **PDFKit text extraction is serialized, and that is a correctness requirement.**
    ///
    /// `PDFDocument`/`PDFPage.string` is not thread-safe. Measured through this exact reader over a
    /// real 10,286-document tree, six at a time: **1.69% of documents came back with different text
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
    /// The price, on that same full-tree cold pass reading up to ``maxPDFPages`` per document:
    /// 106 s six-at-a-time against 198 s serial. A real scan reads only the files it is classifying,
    /// four at a time, so it pays a fraction of that.
    private static let pdfQueue = DispatchQueue(label: "com.synccloud.content-signals.pdf",
                                                qos: .utility)

    private static let pdfConcurrencyLock = NSLock()
    private nonisolated(unsafe) static var livePDFParses = 0
    private nonisolated(unsafe) static var peakPDFParses = 0

    /// The most PDF parses ever running at once on ``pdfQueue``. Test instrumentation only —
    /// serialization cannot be asserted from the outside any other way, and a queue quietly made
    /// concurrent again would otherwise be caught only by a sub-2%-of-documents flake on a tree no
    /// test has. Nothing outside tests reads it.
    ///
    /// **Read-only, and there is deliberately no reset.** A reset would be a second writer of a
    /// process-wide counter, and swift-testing runs a suite's tests in parallel: one test zeroing it
    /// between another's parses and that other's read makes a correct serialization look like none
    /// at all. No reset is needed, because on a serial queue this can only ever be 0 or 1 — so
    /// "never two at once" reads as `== 1` for the life of the process once anything has parsed,
    /// and a queue made concurrent pushes it above 1 and stays there.
    static var peakConcurrentPDFParses: Int {
        pdfConcurrencyLock.lock()
        defer { pdfConcurrencyLock.unlock() }
        return peakPDFParses
    }

    /// The seam the manager injects: `syncManager.filingContentExtractor = ContentSignalExtractor.tokens(forFileAt:)`.
    static func tokens(forFileAt path: String) async -> Set<String> {
        await withCheckedContinuation { continuation in
            workQueue.async { continuation.resume(returning: extractSync(path)) }
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

    /// Runs the PDF parse on ``pdfQueue``. `sync` rather than `async`: the caller is already off the
    /// cooperative pool on ``workQueue``, so blocking it is exactly the intent — several extractions
    /// queue up here and take their turn. Never call this from `pdfQueue` itself (nothing does; the
    /// only caller is `extractTextSync`, which runs on `workQueue`) — `DispatchQueue.sync` onto the
    /// queue you are already on deadlocks.
    private static func pdfText(_ url: URL) -> String {
        pdfQueue.sync {
            pdfConcurrencyLock.lock()
            livePDFParses += 1
            peakPDFParses = max(peakPDFParses, livePDFParses)
            pdfConcurrencyLock.unlock()
            defer {
                pdfConcurrencyLock.lock()
                livePDFParses -= 1
                pdfConcurrencyLock.unlock()
            }
            return pdfTextSync(url)
        }
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
        // The fourth branch of the same rule, and the one this line had been missing: Vision
        // failing outright and an image that genuinely holds no words both answered `""`, so a
        // broken recognizer read exactly like a folder of blank scans — the one thing an operator
        // most needs to tell apart.
        //
        // Returning early is kept, deliberately: `main` falls through here instead, because
        // `perform` can leave partial results behind, but that is a change to what this reader
        // ANSWERS and this is a maintenance line. The log line is the whole change.
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
