import Foundation
import PDFKit
import Vision
import NaturalLanguage
import ImageIO
import Sync

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
    private static let workQueue = DispatchQueue(label: "com.synccloud.content-signals",
                                                 qos: .utility, attributes: .concurrent)

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
    private static func extractTextSync(_ url: URL) -> String {
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

    private static func pdfText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<min(doc.pageCount, maxPDFPages) {
            if let s = doc.page(at: i)?.string { out += s + "\n" }
            if out.count >= maxTextChars { break }
        }
        return String(out.prefix(maxTextChars))
    }

    private static func plainText(_ url: URL) -> String {
        guard let data = try? FileHandle(forReadingFrom: url).read(upToCount: 64 * 1024) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Synchronous OCR: Vision's `.fast` CPU recognizer runs `perform` inline and populates
    /// `request.results`, so we read the results directly — no completion-handler continuation
    /// (which risked a double-resume crash or a never-resume hang).
    private static func ocrText(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
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
