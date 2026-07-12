import Foundation
import PDFKit
import Vision
import NaturalLanguage
import ImageIO
import Sync

/// On-device content signals for Filing (F2). Given a file, it reads a bounded amount of text —
/// PDF text via PDFKit, image/scan text via Vision OCR, or a plain-text head — and pulls
/// entity/keyword tokens via NaturalLanguage. Nothing leaves the device. Returns an empty set for
/// unsupported types or when nothing useful is found.
enum ContentSignalExtractor {

    /// Cap the text we analyze so a huge PDF/scan stays fast.
    private static let maxTextChars = 20_000
    private static let maxTokens = 40
    private static let maxPDFPages = 5

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp"]
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "log", "text"]

    /// The seam the manager injects: `syncManager.filingContentExtractor = ContentSignalExtractor.tokens(forFileAt:)`.
    static func tokens(forFileAt path: String) async -> Set<String> {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "pdf" {
            text = pdfText(url)
        } else if imageExtensions.contains(ext) {
            text = await ocrText(url)
        } else if textExtensions.contains(ext) {
            text = plainText(url)
        } else {
            return []
        }
        guard !text.isEmpty else { return [] }
        return tokens(fromText: text)
    }

    // MARK: Text extraction

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

    private static func ocrText(_ url: URL) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let text = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ") ?? ""
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch { continuation.resume(returning: "") }
        }
    }

    // MARK: Tokenization (testable)

    /// Entity + category-keyword tokens from a block of text, using the same tokenizer as the
    /// FilingEngine so content and filename tokens are comparable.
    static func tokens(fromText text: String) -> Set<String> {
        let snippet = String(text.prefix(maxTextChars))
        var tokens = entities(in: snippet)
        // Category keywords that appear as whole words (insurers, brands, "invoice", "statement"…).
        tokens.formUnion(FilingEngine.nameTokens(snippet).intersection(FilingEngine.categoryKeywords))
        // Tax form numbers are bare digits (stripped by the tokenizer) — match them raw.
        let lower = snippet.lowercased()
        for form in ["1099", "1040"] where lower.contains(form) { tokens.insert(form) }
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
