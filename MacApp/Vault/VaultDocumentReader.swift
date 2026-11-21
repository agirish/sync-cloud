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

    /// Every file in the folders, however many. Of those, only what ``VaultReadPlan`` picks is
    /// opened (identity papers whole, one paper per account per year, IDs by name elsewhere), and
    /// after the first read only new and changed ones (``VaultModel/readDocuments(with:again:)``),
    /// so a large folder costs its time once, and a read stopped partway carries on from where it
    /// stopped.
    func files() async -> [URL] { await walk().files }

    var followsReadPlan: Bool { true }

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
        await Task.detached(priority: .userInitiated) { [folders] in Self.read(file, under: folders) }.value
    }

    /// Each page's lines kept apart, so a name line on one page is never paired with a number on
    /// another. A page that could not be rendered or recognised is left out, never read as a
    /// blank page; a file with no page read at all comes back empty, so it is not marked read and
    /// the next read tries it again, and what it gave before stays. One broken page does not keep
    /// a file's other pages from being read, on this read or any later one.
    private static func read(_ file: URL, under folders: [String]) -> [[String]] {
        guard file.pathExtension.lowercased() == "pdf" else {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
            // A photo or scan saved as an image is read as a scanned page is: on colored
            // security paper, in its ink alone as well (``VaultPageSource/seen(_:from:under:)``).
            // An image is what it is: there is no sharper render of it to read again.
            let picture = VaultPageSource.Picture(isScan: { true }, read: { sharper in sharper ? nil : recognise(image) },
                                                  barcodes: { decodeBarcodes(image) },
                                                  inkOnly: { inkOnly(image).flatMap(recognise) })
            return VaultPageSource.seen(picture, from: file.path, under: folders).map { [$0] } ?? []
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
            // Which reading counts is ``VaultPageSource``'s rule; the renders are made here, and
            // only when it asks.
            let picture = VaultPageSource.Picture(
                isScan: { drawsScan(page) },
                read: { sharper in render(page, longSide: sharper ? 4000 : 2400).flatMap(recognise) },
                barcodes: { render(page, longSide: 4000).map(decodeBarcodes) ?? [] },
                inkOnly: { render(page).flatMap(inkOnly).flatMap(recognise) })
            guard let lines = VaultPageSource.lines(textLayer: page.string ?? "", from: file.path, under: folders,
                                                    picture: picture) else {
                unreadable += 1
                continue
            }
            pages.append(lines)
        }
        return pages
    }

    /// Pictures of this many pixels in all could be a scan of the page, or of a card on it: a
    /// card scanned at 150 dpi is about 500 by 320, and a letterhead's logo is mostly far smaller.
    /// Counted together, because some scanners store a page as strips or tiles.
    static let scanPixels = 150_000

    /// Whether the page draws pictures that could be a scan of it: its image objects, and those
    /// inside the forms it draws, come to ``scanPixels`` or more. Where a picture sits on the
    /// page, or whether it is drawn at all, is not looked at; a wrong yes costs one recognition.
    static func drawsScan(_ page: PDFPage) -> Bool { scanSearch(page).found }

    /// ``drawsScan(_:)``, and how many resource dictionaries it opened to find out: each one
    /// once, however many forms share it, or a file whose forms all point back at the page's own
    /// resources would be walked again from every one of them.
    static func scanSearch(_ page: PDFPage) -> (found: Bool, opened: Int) {
        guard var node = page.pageRef?.dictionary else { return (false, 0) }
        // A page's resources are its own, or its parent's.
        for _ in 0..<16 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(node, "Resources", &resources), let resources {
                let search = ScanSearch()
                search.look(in: resources, depth: 0)
                return (search.pixels >= scanPixels, search.opened.count)
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(node, "Parent", &parent), let parent else { return (false, 0) }
            node = parent
        }
        return (false, 0)
    }

    /// The pixels of every picture a page's resources hold, each picture and each dictionary
    /// counted once. It stops as soon as there are enough.
    private final class ScanSearch {
        var pixels = 0
        var opened = Set<CGPDFDictionaryRef>()
        private var counted = Set<CGPDFStreamRef>()

        func look(in resources: CGPDFDictionaryRef, depth: Int) {
            guard depth < 8, pixels < scanPixels, opened.insert(resources).inserted else { return }
            var objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return }
            CGPDFDictionaryApplyBlock(objects, { _, object, _ in
                var stream: CGPDFStreamRef?
                var subtype: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream),
                      CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
                switch String(cString: subtype) {
                case "Image" where self.counted.insert(stream).inserted:
                    var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                    CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                    CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                    // Bounded, so a file claiming absurd sizes cannot overflow the sum.
                    self.pixels += min(max(width, 0), 100_000) * min(max(height, 0), 100_000)
                case "Form":
                    var inner: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner {
                        self.look(in: inner, depth: depth + 1)
                    }
                default:
                    break
                }
                return self.pixels < scanPixels
            }, nil)
        }
    }

    /// The page at about 2400 pixels on its long side: the zone's small type needs that much.
    private static func render(_ page: PDFPage, longSide: CGFloat = 2400) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = max(2, min(6, longSide / max(bounds.width, bounds.height, 1)))
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                                   for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Which processor Vision may read on: its own choice, the Neural Engine when it has one, or
    /// the CPU alone.
    enum Processor: Sendable { case any, cpu }

    /// The image's lines, any license barcode's text after them; nil when Vision failed, which
    /// is not the same as a page with no text.
    private static func recognise(_ image: CGImage) -> [String]? {
        recognised(image) { try read($0, on: $1) }
    }

    /// `read` on Vision's choice of processor and, when that fails, again on the CPU. The Neural
    /// Engine can refuse every text request for minutes or hours while the CPU still reads a
    /// page in under a second (`PictureText` does the same for Save as PDF); without this a
    /// Read Documents run inside such a spell reads no scan at all. `read` is handed in so a test
    /// can be the refusal.
    static func recognised(_ image: CGImage, read: (CGImage, Processor) throws -> [String]) -> [String]? {
        if let lines = try? read(image, .any) { return lines }
        guard let lines = try? read(image, .cpu) else {
            Logger.shared.debug("Vault: text recognition failed, on the CPU too")
            return nil
        }
        Logger.shared.debug("Vault: text recognition failed; the page was read on the CPU")
        return lines
    }

    /// Accurate recognition without language correction, which "corrects" a zone's fillers and
    /// a receipt number's letters into words. A US license's PDF417 barcode is decoded in the
    /// same pass and its text added after the page's lines, one element to a line, for
    /// ``VaultReading`` to read: it states the number, name and dates outright.
    static func read(_ image: CGImage, on processor: Processor) throws -> [String] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.pdf417]
        if processor == .cpu {
            for request in [text, barcodes] as [VNRequest] {
                for (stage, devices) in try request.supportedComputeStageDevices {
                    guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else { continue }
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, barcodes])
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
    /// A share of strongly colored pixels this large is security paper, or a color photo: a
    /// Social Security card's red pattern measured 12% on the owner's three cards, color passport
    /// photos 14 to 41%, plain scans and letters under 2%.
    static let coloredPaper = 0.08

    /// `image` in its ink alone, when it is on colored paper: every pixel dark and grey (ink)
    /// black, every other white. Nil for a page that is not colored, which is never read this
    /// way. The thresholds read DANI, and the card's number, on a Social Security card whose
    /// red pattern Vision otherwise reads into the letters.
    static func inkOnly(_ image: CGImage) -> CGImage? {
        guard coloredShare(image) >= coloredPaper else { return nil }
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            let ink = (r + g + b) / 3 < 140 && max(r, g, b) - min(r, g, b) < 70
            let value: UInt8 = ink ? 0 : 255
            pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
        }
        return context.makeImage()
    }

    /// The share of `image`'s pixels, sampled at 400 across, that are strongly colored and not
    /// dark: a hue well apart from grey, bright enough to be paper rather than ink.
    static func coloredShare(_ image: CGImage) -> Double {
        let w = 400, h = max(1, image.height * 400 / max(image.width, 1))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var colored = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            if max(r, g, b) - min(r, g, b) > 50 && max(r, g, b) > 120 { colored += 1 }
        }
        return Double(colored) / Double(w * h)
    }

    private static func payloadLines(_ results: [VNBarcodeObservation]) -> [String] {
        results.compactMap(\.payloadStringValue)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{1e}")) }
    }
}
