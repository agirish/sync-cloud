import CryptoKit
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
    /// How a picture is read: by Vision (``read(_:on:)``). Handed in so a test can be Vision
    /// refusing, or a reading it knows, and still go through everything else the reader does.
    var vision: @Sendable (CGImage, Processor) throws -> [String] = { try VaultFolderReader.read($0, on: $1) }

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
    /// after the first read only new and changed ones (``VaultModel/readDocuments(with:again:scope:)``),
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
        var tooLarge: [String] = []
        let unreachable = Unreachable()
        for folder in folders {
            guard let walk = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in unreachable.paths.append(url.path); return true }) else { continue }
            for case let url as URL in walk where extensions.contains(url.pathExtension.lowercased()) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size <= largestFile { found.append(url) } else { tooLarge.append(url.path) }
            }
        }
        // Counts only, here and below: a file's name can hold the very number it carries.
        if !tooLarge.isEmpty {
            Logger.shared.info("Vault: \(tooLarge.count) file(s) over \(largestFile / 1024 / 1024) MB passed over")
        }
        if !unreachable.paths.isEmpty {
            Logger.shared.info("Vault: \(unreachable.paths.count) folder(s) could not be opened; what was read in them is kept")
        }
        // A file passed over is not seen, so not gone: what it gave before stays, as for a folder
        // that could not be opened (VT81).
        return (found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                unreachable.paths + tooLarge)
    }

    /// Where files are read: a queue of its own, off the cooperative pool, so a wait for the
    /// PDFKit lane (``PDFKitSerialAccess/run(_:)``) parks none of the pool's threads.
    private static let workQueue = DispatchQueue(label: "com.synccloud.vault-reader", qos: .userInitiated,
                                                 attributes: .concurrent)

    func pages(in file: URL) async -> [[String]] { await reading(file).pages }

    func contentKey(of file: URL) async -> String? {
        await withCheckedContinuation { continuation in
            Self.workQueue.async { continuation.resume(returning: Self.contentKey(file)) }
        }
    }

    /// The file's size and SHA-256 (``VaultFileContents``): the key a Vault note knows a card by.
    static func contentKey(_ file: URL) -> String? { VaultFileContents.key(of: file) }

    func reading(_ file: URL) async -> (pages: [[String]], complete: Bool) {
        let read = await noted(file)
        return (read.pages, read.complete)
    }

    func noted(_ file: URL) async -> (pages: [[String]], complete: Bool, notes: VaultReadNotes, origins: [VaultPageOrigin]?) {
        await withCheckedContinuation { continuation in
            Self.workQueue.async { [folders, vision] in
                continuation.resume(returning: Self.read(file, under: folders, vision: vision))
            }
        }
    }

    /// Each page's lines kept apart, so a name line on one page is never paired with a number on
    /// another. A page that could not be rendered or recognised is left out, never read as a
    /// blank page; a file with no page read at all comes back empty, so it is not marked read and
    /// the next read tries it again, and what it gave before stays. One broken page does not keep
    /// a file's other pages from being read, on this read or any later one; the file is then
    /// marked read while one is left out: `complete` says so (VT54). A page whose picture Vision
    /// refused but whose text layer gives or names a number is kept as that layer, and counted as
    /// not read, so its picture is tried again (``VaultPageSource/Reading/pictureUnread``).
    ///
    /// A page read both ways (``VaultPageSource/Reading/also``) gives its second reading as one
    /// more page, after the file's own (``VaultPageSource/filePages(_:)``), and each page says
    /// which page of the file it is: a zone found in a second reading is on the page it was read
    /// from, and the pages after one left out keep their own numbers (VT88).
    private static func read(_ file: URL, under folders: [String],
                             vision: @escaping @Sendable (CGImage, Processor) throws -> [String])
        -> (pages: [[String]], complete: Bool, notes: VaultReadNotes, origins: [VaultPageOrigin]?) {
        var notes = VaultReadNotes()
        // Past the walk's cap since it was read (a scan grown into a bundle): passed over here
        // too, as Discover More passes it over (VT81, owner). Nothing comes back, so what it gave
        // before stays; it is marked read as it is (`tooLarge`), so Refresh opens it again only
        // once it changes.
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > largestFile {
            Logger.shared.info("Vault: a file over \(largestFile / 1024 / 1024) MB passed over")
            notes.tooLarge = 1
            return ([], true, notes, nil)
        }
        // The image's lines, any license barcode's text after them; nil when Vision failed on
        // both processors, which is not the same as a page with no text.
        func recognise(_ image: CGImage) -> [String]? { recognised(image, read: vision) }
        guard file.pathExtension.lowercased() == "pdf" else {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                notes.unopenable = 1
                return ([], true, notes, nil)
            }
            // A photo or scan saved as an image is read as a scanned page is: on colored
            // security paper, in its ink alone as well (``VaultPageSource/seen(_:from:under:)``).
            // An image is what it is: there is no sharper render of it to read again. A file of
            // several pictures (a faxed TIFF) is read as a PDF's pages are, up to the same three
            // (owner, 2026-11-23: its first alone was read, and the file marked read).
            var read: [(page: Int, reading: VaultPageSource.Reading)] = []
            var unread = 0
            for index in 0..<min(max(CGImageSourceGetCount(source), 1), pagesPerDocument) {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { unread += 1; continue }
                let picture = VaultPageSource.Picture(isScan: { true }, read: { sharper in sharper ? nil : recognise(image) },
                                                      barcodes: { decodeBarcodes(image) },
                                                      inkOnly: { _ in inkOnly(image).flatMap(recognise) })
                guard let page = VaultPageSource.noted(picture, from: file.path, under: folders) else { unread += 1; continue }
                read.append((index + 1, page))
                notes = notes + page.notes
            }
            notes.unrecognised += unread
            let paged = VaultPageSource.filePages(read)
            return (paged.pages, unread == 0, notes, paged.origins)
        }
        // Every PDFKit call takes its turn in the process's one lane (VT52); Vision does not, so
        // the lane is free while a page is recognised. The document is opened once and touched
        // only from inside a turn.
        func lane<T>(_ body: () -> T) -> T { PDFKitSerialAccess.run(body) }
        // The bytes are read before the lane is taken: a file iCloud has evicted downloads here,
        // not while every other PDFKit user waits.
        guard let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            Logger.shared.debug("Vault: a PDF could not be opened")
            notes.unopenable = 1
            return ([], true, notes, nil)
        }
        // A locked PDF is passed over: its password is not the Vault's to ask for. The document is
        // only borrowed below, so this is its one owner, and it is let go of in a lane turn of its
        // own: PDFKit's teardown, its pages' with it, is PDFKit too.
        var held = lane({ PDFDocument(data: bytes) })
        guard held != nil else {
            Logger.shared.debug("Vault: a PDF could not be opened")
            notes.unopenable = 1
            return ([], true, notes, nil)
        }
        let result = readPages(of: held!)
        lane { held = nil }
        return result

        func readPages(of document: PDFDocument) -> (pages: [[String]], complete: Bool, notes: VaultReadNotes, origins: [VaultPageOrigin]?) {
            let (locked, pageCount) = lane { (document.isLocked, document.pageCount) }
            guard !locked else {
                Logger.shared.debug("Vault: a locked PDF was passed over")
                notes.locked = 1
                return ([], true, notes, nil)
            }
            var read: [(page: Int, reading: VaultPageSource.Reading)] = []
            var unreadable = 0
            for index in 0..<min(pageCount, pagesPerDocument) {
                guard let page = lane({ document.page(at: index) }) else { continue }
                // Which reading counts is ``VaultPageSource``'s rule; the renders are made here, and
                // only when it asks.
                // Each render is made once per page and scale, and each read once per scale (VT82):
                // the picture is read and then read in its ink alone from the same ``readRender``
                // render, and a card-size page, held to the largest scale, is the same image at
                // ``readRender`` and ``largestRender``.
                let renders = PageRenders(page: page, bounds: lane { page.bounds(for: .mediaBox) }, lane: lane)
                let picture = VaultPageSource.Picture(
                    isScan: { lane { drawsScan(page) } },
                    read: { sharper in renders.read(longSide: sharper ? largestRender : readRender, recognise) },
                    barcodes: { renders.image(longSide: largestRender).map(decodeBarcodes) ?? [] },
                    inkOnly: { sharper in
                        renders.image(longSide: sharper ? largestRender : readRender).flatMap(inkOnly).flatMap(recognise)
                    })
                let textLayer = lane { page.string ?? "" }
                guard let reading = VaultPageSource.reading(textLayer: textLayer, from: file.path, under: folders,
                                                            picture: picture) else {
                    unreadable += 1
                    continue
                }
                read.append((index + 1, reading))
                notes = notes + reading.notes
                // Its layer is kept; its picture, which Vision refused, is tried again next time.
                if reading.pictureUnread { unreadable += 1 }
            }
            if unreadable > 0 {
                Logger.shared.debug("Vault: \(unreadable) page(s) could not be recognised"
                                    + (read.isEmpty ? "; the file is tried again next time"
                                                     : "; what was read is kept, and the file is tried again"))
            }
            notes.unrecognised += unreadable
            let paged = VaultPageSource.filePages(read)
            return (paged.pages, unreadable == 0, notes, paged.origins)
        }
    }

    /// Pictures of this many pixels in all could be a scan of the page, or of a card on it: a
    /// card scanned at 150 dpi is about 500 by 320, and a letterhead's logo is mostly far smaller.
    /// Counted together, because some scanners store a page as strips or tiles.
    static let scanPixels = 150_000

    /// Whether the page draws pictures that could be a scan of it: the image objects its
    /// resources name, those inside the forms it draws, those its content and its forms' draw
    /// inline (`BI … EI`), and those its annotations draw as their appearance (a scanned stamp, a
    /// pasted picture; VT88), come to ``scanPixels`` or more. Where a picture sits on the page, or
    /// whether it is drawn at all, is not looked at. A wrong yes, on a typed page, costs a
    /// recognition (three at most: sharper, and in its ink alone); its picture is the page only
    /// if the text gives no number and the picture one, and beside a full page that gives one
    /// only if it says more (VT88).
    static func drawsScan(_ page: PDFPage) -> Bool { scanSearch(page).found }

    /// ``drawsScan(_:)``, and how many resource dictionaries it opened to find out: each one
    /// once, however many forms share it, or a file whose forms all point back at the page's own
    /// resources would be walked again from every one of them.
    static func scanSearch(_ page: PDFPage) -> (found: Bool, opened: Int) {
        guard let pageRef = page.pageRef, let dictionary = pageRef.dictionary else { return (false, 0) }
        // The scanner reads the page's content with the resources it finds itself. A content
        // stream, an operator table and a scanner are released by hand: none is a CF type.
        let content = CGPDFContentStreamCreateWithPage(pageRef)
        defer { CGPDFContentStreamRelease(content) }
        let search = ScanSearch(page: content)
        // A page's resources are its own, or its parent's.
        var node = dictionary, resources: CGPDFDictionaryRef?
        for _ in 0..<16 {
            if CGPDFDictionaryGetDictionary(node, "Resources", &resources), resources != nil { break }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(node, "Parent", &parent), let parent else { break }
            node = parent
        }
        if let resources { search.look(in: resources, depth: 0) }
        search.inline(in: content)
        search.annotations(of: dictionary, resources: resources)
        return (search.pixels >= scanPixels, search.walked)
    }

    /// The pixels of every picture a page draws, each picture and each dictionary counted once.
    /// It stops as soon as there are enough.
    private final class ScanSearch {
        var pixels = 0
        /// How many dictionaries were walked, each time one was: more than there are means one
        /// was walked twice.
        var walked = 0
        private var opened = Set<CGPDFDictionaryRef>()
        private var counted = Set<CGPDFStreamRef>()
        /// The page's content, which a form's is read inside.
        private let page: CGPDFContentStreamRef

        init(page: CGPDFContentStreamRef) { self.page = page }

        /// Bounded, so a file claiming absurd sizes cannot overflow the sum.
        func add(width: CGPDFInteger, height: CGPDFInteger) {
            pixels += min(max(width, 0), 100_000) * min(max(height, 0), 100_000)
        }

        func look(in resources: CGPDFDictionaryRef, depth: Int) {
            guard depth < 8, pixels < scanPixels, opened.insert(resources).inserted else { return }
            walked += 1
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
                    self.add(width: width, height: height)
                case "Form":
                    self.form(stream, outer: resources, depth: depth + 1)
                default:
                    break
                }
                return self.pixels < scanPixels
            }, nil)
        }

        /// A form: the pictures its resources name, and those its content draws inline. A form
        /// with no resources of its own draws with `outer`, as older files have it.
        func form(_ stream: CGPDFStreamRef, outer: CGPDFDictionaryRef?, depth: Int) {
            guard depth < 8, pixels < scanPixels, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var own: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &own)
            if let own { look(in: own, depth: depth) }
            // Its content is read once, however many names it goes by.
            guard let resources = own ?? outer, counted.insert(stream).inserted else { return }
            let content = CGPDFContentStreamCreateWithStream(stream, resources, page)
            defer { CGPDFContentStreamRelease(content) }
            inline(in: content)
        }

        /// The pictures `content` draws inline. The scanner hands each one over at its `EI`, its
        /// size under the short names a content stream gives it or the long ones.
        func inline(in content: CGPDFContentStreamRef) {
            guard pixels < scanPixels, let table = CGPDFOperatorTableCreate() else { return }
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
                var image: CGPDFStreamRef?
                guard let info, CGPDFScannerPopStream(scanner, &image), let image,
                      let dictionary = CGPDFStreamGetDictionary(image) else { return }
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                if !CGPDFDictionaryGetInteger(dictionary, "W", &width) { CGPDFDictionaryGetInteger(dictionary, "Width", &width) }
                if !CGPDFDictionaryGetInteger(dictionary, "H", &height) { CGPDFDictionaryGetInteger(dictionary, "Height", &height) }
                Unmanaged<ScanSearch>.fromOpaque(info).takeUnretainedValue().add(width: width, height: height)
            }
            let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            CGPDFScannerScan(scanner)
        }

        /// What the page's annotations draw: each one's normal appearance, or, kept by state,
        /// the state it shows.
        func annotations(of page: CGPDFDictionaryRef, resources: CGPDFDictionaryRef?) {
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { return }
            for index in 0..<CGPDFArrayGetCount(annotations) where pixels < scanPixels {
                var annotation: CGPDFDictionaryRef?, appearances: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                      CGPDFDictionaryGetDictionary(annotation, "AP", &appearances), let appearances else { continue }
                var normal: CGPDFStreamRef?, states: CGPDFDictionaryRef?, shown: UnsafePointer<CChar>?
                if CGPDFDictionaryGetStream(appearances, "N", &normal), let normal {
                    form(normal, outer: resources, depth: 0)
                } else if CGPDFDictionaryGetDictionary(appearances, "N", &states), let states,
                          CGPDFDictionaryGetName(annotation, "AS", &shown), let shown,
                          CGPDFDictionaryGetStream(states, shown, &normal), let normal {
                    form(normal, outer: resources, depth: 0)
                }
            }
        }
    }

    /// One page's renders and readings, each made once and only when asked, by scale: two long
    /// sides that clamp to one scale are one image. Only the ``readRender`` render is kept, which is
    /// read and then read in its ink alone; the sharper one is asked for once (its reading is kept,
    /// and the barcode render is asked for only when the sharper read was not made), so it is let go
    /// rather than held beside the other for the rest of the page.
    final class PageRenders {
        private let page: PDFPage
        private let bounds: CGRect
        private let lane: (() -> CGImage?) -> CGImage?
        private var images: [CGFloat: CGImage?] = [:]
        private var reads: [CGFloat: [String]?] = [:]
        /// How many renders were made: one per scale asked for, at most.
        private(set) var made = 0

        /// `bounds` is the page's media box, asked for in the lane.
        init(page: PDFPage, bounds: CGRect, lane: @escaping (() -> CGImage?) -> CGImage?) {
            (self.page, self.bounds, self.lane) = (page, bounds, lane)
        }

        private func scale(_ longSide: CGFloat) -> CGFloat { VaultFolderReader.scale(of: bounds, longSide: longSide) }

        func image(longSide: CGFloat) -> CGImage? {
            let scale = scale(longSide)
            if let image = images[scale] { return image }
            let image = lane { VaultFolderReader.render(page, scale: scale) }
            made += 1
            if scale == self.scale(VaultFolderReader.readRender) { images[scale] = image }
            return image
        }

        /// The render's lines, as `recognise` reads them: Vision once per scale.
        func read(longSide: CGFloat, _ recognise: (CGImage) -> [String]?) -> [String]? {
            let scale = scale(longSide)
            if let lines = reads[scale] { return lines }
            let lines = image(longSide: longSide).flatMap(recognise)
            reads[scale] = lines
            return lines
        }
    }

    /// The scale a page is rendered at for `longSide` pixels: within ``scales``, and never past
    /// ``largestRender`` pixels on its long side. A photo saved as a PDF at 72 dpi is a page of
    /// 4,032 points, which the floor of 2 drew at 8,064 pixels, about 195 MB a render.
    static func scale(of bounds: CGRect, longSide: CGFloat) -> CGFloat {
        let long = max(bounds.width, bounds.height, 1)
        return min(max(scales.lowerBound, min(scales.upperBound, longSide / long)), largestRender / long)
    }

    /// The scales a page is drawn at, points to pixels: a card-size page is not blown up past 6,
    /// and no page is drawn under 2 unless ``largestRender`` holds it lower.
    static let scales: ClosedRange<CGFloat> = 2...6

    /// The pixels a page is read at on its long side: what a zone's small type needs.
    static let readRender: CGFloat = 2400

    /// The most pixels a render or an ink-alone copy has on its long side: what a Social Security
    /// card's small type and a barcode, the sharpest reads asked for, need.
    static let largestRender: CGFloat = 4000

    /// The page drawn at `scale` (``scale(of:longSide:)``): about ``readRender`` pixels on its long
    /// side to read it, ``largestRender`` for a Social Security card or a barcode.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                                   for: .mediaBox)
        // Drawn into a bitmap of its own here, in the lane, so nothing PDFKit drew lazily is drawn
        // later outside it. The same pixels.
        guard let drawn = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // A format a context will not take is read as it came, as it was before.
        guard let context = CGContext(data: nil, width: drawn.width, height: drawn.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: drawn.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: drawn.bitmapInfo.rawValue) else { return drawn }
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
        return context.makeImage() ?? drawn
    }

    /// Which processor Vision may read on: its own choice, the Neural Engine when it has one, or
    /// the CPU alone.
    enum Processor: Sendable { case any, cpu }

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
        let (text, barcodes) = try requests(on: processor)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, barcodes])
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines + payloadLines(barcodes.results ?? [])
    }

    /// The two requests a page is read with, each held to the CPU at every stage when asked.
    static func requests(on processor: Processor) throws -> (text: VNRecognizeTextRequest, barcodes: VNDetectBarcodesRequest) {
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
        return (text, barcodes)
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
        // A photo far past ``largestRender`` pixels (48 megapixels: about 195 MB of pixels here,
        // beside the image) is brought down to it; one a little past it (a 12-megapixel phone
        // photo) keeps its own pixels, so its ink is judged as it always was.
        let long = CGFloat(max(image.width, image.height, 1))
        let fit = long > largestRender * 1.5 ? largestRender / long : 1
        let (w, h) = (max(1, Int(CGFloat(image.width) * fit)), max(1, Int(CGFloat(image.height) * fit)))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            let ink = (r + g + b) / 3 < inkDarkest && max(r, g, b) - min(r, g, b) < inkGreyest
            let value: UInt8 = ink ? 0 : 255
            pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
        }
        return context.makeImage()
    }

    /// Ink, in ``inkOnly(_:)``: a pixel whose mean is under this (of 255), and whose channels are
    /// less than ``inkGreyest`` apart, so grey or black.
    static let inkDarkest = 140
    static let inkGreyest = 70
    /// Colored paper, in ``coloredShare(_:)``: a pixel whose channels are more than this apart, a
    /// hue well away from grey, and whose brightest is over ``coloredBrightest``, paper not ink.
    static let coloredApart = 50
    static let coloredBrightest = 120
    /// The width ``coloredShare(_:)`` samples an image at.
    static let sampleWidth = 400

    /// The size `coloredShare` samples an image at: ``sampleWidth`` across, its height to scale,
    /// held to ten times that: a sliver of an image (4 by 60,000 pixels) would otherwise ask for
    /// gigabytes.
    static func sampleSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (sampleWidth, max(1, min(sampleWidth * 10, height * sampleWidth / max(width, 1))))
    }

    /// The share of `image`'s pixels, sampled at ``sampleWidth`` across, that are strongly colored
    /// and not dark: a hue well apart from grey, bright enough to be paper rather than ink.
    static func coloredShare(_ image: CGImage) -> Double {
        let (w, h) = sampleSize(width: image.width, height: image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var colored = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            if max(r, g, b) - min(r, g, b) > coloredApart && max(r, g, b) > coloredBrightest { colored += 1 }
        }
        return Double(colored) / Double(w * h)
    }

    /// A barcode's text, one element to a line.
    private static func payloadLines(_ results: [VNBarcodeObservation]) -> [String] {
        results.compactMap(\.payloadStringValue)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{1e}")) }
    }
}
