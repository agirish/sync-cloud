import Foundation
import ImageIO
import PDFKit
import Events
import Sync
import Vision

/// Read Documents' pages: the files in the folders chosen in Settings ▸ Vault, read with
/// Vision at its accurate level.
///
/// Accurate, unlike filing's fast reads (`ContentSignalExtractor`): on real scans the fast level
/// missed every passport zone, receipt number and I-94 number the Vault looks for. It costs about
/// a second a page, which is why this reads only folders someone chose, only when asked, and
/// only the files that changed since the last read.
struct VaultFolderReader: VaultDocumentReading {
    let folders: [String]

    /// What a number can be printed on.
    static let extensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "heic", "tif", "tiff"]
    /// A passport's zone is on its photo page and a notice's numbers are on its first page, so a
    /// long document's later pages are not read.
    static let pagesPerDocument = 3
    /// A scan of a passport or a notice is a few megabytes; a file far larger is a book or a
    /// photo library export, and would hold up the read for nothing.
    static let largestFile = 60 * 1024 * 1024

    /// Every file in the folders, however many: only new and changed ones are opened after the
    /// first read (``VaultModel/readDocuments(with:again:)``), so a large folder costs its time
    /// once, and a read stopped partway carries on from where it stopped.
    func files() async -> [URL] { await walk().files }

    func walk() async -> (files: [URL], unreachable: [String]) {
        await Task.detached(priority: .userInitiated) { [folders] in Self.walk(folders) }.value
    }

    /// Collects the folders the walk could not open, from the enumerator's error handler.
    private final class Unreachable: @unchecked Sendable { var paths: [String] = [] }

    private static func walk(_ folders: [String]) -> (files: [URL], unreachable: [String]) {
        var found: [URL] = []
        var tooLarge = 0
        let unreachable = Unreachable()
        for folder in folders {
            guard let walk = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in unreachable.paths.append(url.path); return true }) else { continue }
            for case let url as URL in walk where extensions.contains(url.pathExtension.lowercased()) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size <= largestFile { found.append(url) } else { tooLarge += 1 }
            }
        }
        // Counts only, here and below: a file's name can hold the very number it carries.
        if tooLarge > 0 {
            Logger.shared.info("Vault: \(tooLarge) file(s) over \(largestFile / 1024 / 1024) MB passed over")
        }
        if !unreachable.paths.isEmpty {
            Logger.shared.info("Vault: \(unreachable.paths.count) folder(s) could not be opened; what was read in them is kept")
        }
        return (found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, unreachable.paths)
    }

    func pages(in file: URL) async -> [[String]] {
        await Task.detached(priority: .userInitiated) { Self.read(file) }.value
    }

    /// Each page's lines kept apart, so a name line on one page is never paired with a number on
    /// another. A page that could not be rendered or recognised is left out, never read as a
    /// blank page; a file with no page read at all comes back empty, so it is not marked read and
    /// the next read tries it again, and what it gave before stays. One broken page does not keep
    /// a file's other pages from being read, on this read or any later one.
    private static func read(_ file: URL) -> [[String]] {
        guard file.pathExtension.lowercased() == "pdf" else {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let lines = recognise(image) else { return [] }
            return [lines]
        }
        // A locked PDF is passed over: its password is not the Vault's to ask for.
        guard let document = PDFDocument(url: file) else {
            Logger.shared.debug("Vault: a PDF could not be opened")
            return []
        }
        guard !document.isLocked else {
            Logger.shared.debug("Vault: a locked PDF was passed over")
            return []
        }
        var pages: [[String]] = []
        var unreadable = 0
        defer {
            if unreadable > 0 {
                Logger.shared.debug("Vault: \(unreadable) page(s) could not be recognised"
                                    + (pages.isEmpty ? "; the file is tried again next time" : "; the rest were read"))
            }
        }
        for index in 0..<min(document.pageCount, pagesPerDocument) {
            guard let page = document.page(at: index) else { continue }
            let layer = page.string ?? ""
            if layer.filter({ !$0.isWhitespace }).count > 40 {
                var lines = layer.components(separatedBy: .newlines)
                // A scanner's text layer carries the words, never a barcode: a license back is
                // rendered once for its barcode alone.
                if VaultReading.wantsSharperRead(lines), let image = render(page, longSide: 4000) {
                    let decoded = decodeBarcodes(image)
                    lines += decoded
                    Logger.shared.debug("Vault: a license back was rendered for its barcode; "
                                        + (decoded.isEmpty ? "none decoded" : "decoded"))
                }
                pages.append(lines)
            } else {
                guard let image = render(page), var lines = recognise(image) else {
                    unreadable += 1
                    continue
                }
                // A Social Security card's small type runs a digit in at this size, and a license
                // back's barcode can fail to decode; both read true at about 4000 pixels. Only
                // such a page, with nothing read from it, is read again.
                if VaultReading.wantsSharperRead(lines), let sharper = render(page, longSide: 4000),
                   let again = recognise(sharper) {
                    lines = again
                    Logger.shared.debug("Vault: a page was read again at 4000 px; "
                                        + (VaultReading.wantsSharperRead(lines) ? "still nothing read" : "now read"))
                }
                pages.append(lines)
            }
        }
        return pages
    }

    /// The page at about 2400 pixels on its long side: the zone's small type needs that much.
    private static func render(_ page: PDFPage, longSide: CGFloat = 2400) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = max(2, min(6, longSide / max(bounds.width, bounds.height, 1)))
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                                   for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Accurate recognition without language correction, which "corrects" a zone's fillers and
    /// a receipt number's letters into words. A US license's PDF417 barcode is decoded in the
    /// same pass and its text added after the page's lines, one element to a line, for
    /// ``VaultReading`` to read: it states the number, name and dates outright.
    /// Nil when Vision failed, which is not the same as a page with no text.
    private static func recognise(_ image: CGImage) -> [String]? {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.pdf417]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, barcodes])
        } catch {
            return nil
        }
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines + payloadLines(barcodes.results ?? [])
    }

    /// A page's PDF417 barcodes and nothing else.
    private static func decodeBarcodes(_ image: CGImage) -> [String] {
        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.pdf417]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([barcodes])
        } catch {
            return []
        }
        return payloadLines(barcodes.results ?? [])
    }

    /// A barcode's text, one element to a line.
    private static func payloadLines(_ results: [VNBarcodeObservation]) -> [String] {
        results.compactMap(\.payloadStringValue)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{1e}")) }
    }
}
