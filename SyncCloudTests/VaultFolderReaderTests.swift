import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import Sync
import Testing
import Vision
@testable import SyncCloud

/// Read Documents' reader on real files (``VaultFolderReader``): which PDF pages it reads from
/// their picture. The rule itself is `VaultPageSourceTests`, in Sync; here are the two things only
/// the app can do, telling a scan from a typed page and reading one with Vision. Every number is
/// made up; the passport lines are ICAO Doc 9303's own example.
@Suite struct VaultFolderReaderTests {
    private final class FixtureDir {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultFolderReaderTests-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    }

    /// What a signing service stamps on every page it handles.
    static let stamp = "DocuSign Envelope ID: 1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"
    static let passport = ["PASSPORT   UTOPIA", "Surname ERIKSSON", "Given names ANNA MARIA",
                           "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<", "L898902C36UTO7408122F1204159ZE184226B<<<<<10"]

    /// `lines` as a scanner hands a page over: pixels, and no text. A zone's lines are set in a
    /// typewriter face, as a passport prints them.
    static func scan(of lines: [String], width: Int = 1700, height: Int = 1100) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let size = CGFloat(width) / 32
        for (i, line) in lines.enumerated() {
            let font = line.contains("<") ? NSFont(name: "Courier", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size)
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            context.textPosition = CGPoint(x: size, y: CGFloat(height) - size * 2.4 * CGFloat(i + 1))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return try #require(context.makeImage())
    }

    /// One page: `picture` across it when given, and `text` as real text above it, which is all
    /// the page's text layer then holds.
    static func writePDF(picture: CGImage?, text: [String], to path: String) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        if let picture {
            let height = 612 * CGFloat(picture.height) / CGFloat(picture.width)
            context.draw(picture, in: CGRect(x: 0, y: 700 - height, width: 612, height: height))
        }
        for (i, line) in text.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 9)])
            context.textPosition = CGPoint(x: 36, y: 770 - CGFloat(i) * 12)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func page(at path: String) throws -> PDFPage {
        try #require(PDFDocument(url: URL(fileURLWithPath: path))?.page(at: 0))
    }

    @Test func aPageDrawingAPictureTheSizeOfAScanIsOne() throws {
        let dir = FixtureDir()
        try Self.writePDF(picture: Self.scan(of: Self.passport), text: [Self.stamp], to: dir.path("stamped.pdf"))
        #expect(VaultFolderReader.drawsScan(try Self.page(at: dir.path("stamped.pdf"))))
        // A typed page has no picture; a letterhead's logo is one, and far too small to be the page.
        try Self.writePDF(picture: nil, text: [Self.stamp], to: dir.path("typed.pdf"))
        #expect(!VaultFolderReader.drawsScan(try Self.page(at: dir.path("typed.pdf"))))
        try Self.writePDF(picture: Self.scan(of: ["Cable Co."], width: 240, height: 80), text: [Self.stamp],
                          to: dir.path("letterhead.pdf"))
        #expect(!VaultFolderReader.drawsScan(try Self.page(at: dir.path("letterhead.pdf"))))
    }

    // MARK: Scans as files store them

    /// A PDF written out object by object, for the shapes CoreGraphics never writes itself.
    /// `objects[0]` is object 3, the page; the catalog and the page tree are objects 1 and 2, and
    /// `tree` adds entries to the page tree's dictionary.
    static func writeRawPDF(tree: String = "", objects: [String], to path: String) throws {
        let all = ["<< /Type /Catalog /Pages 2 0 R >>",
                   "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] \(tree) >>"] + objects
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in all.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(all.count + 1)\n0000000000 65535 f \n"
            + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
            + "trailer\n<< /Size \(all.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func image(_ width: Int, _ height: Int) -> String {
        "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray "
            + "/BitsPerComponent 8 /Length 1 >>\nstream\nx\nendstream"
    }

    static func form(resources: String) -> String {
        "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources \(resources) /Length 0 >>\nstream\n\nendstream"
    }

    static let emptyPage = "<< /Length 0 >>\nstream\n\nendstream"

    @Test func aScanIsFoundHoweverTheFileStoresIt() throws {
        let dir = FixtureDir()
        func search(_ name: String, tree: String = "", _ objects: [String]) throws -> (found: Bool, opened: Int) {
            try Self.writeRawPDF(tree: tree, objects: objects, to: dir.path(name))
            return VaultFolderReader.scanSearch(try Self.page(at: dir.path(name)))
        }
        // Resources the page inherits from the page tree.
        #expect(try search("inherited.pdf", tree: "/Resources << /XObject << /Im1 5 0 R >> >>",
                           ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>", Self.emptyPage, Self.image(1700, 1100)]).found)
        // Inside a form inside a form, as a signing service leaves the page it wrapped.
        #expect(try search("nested.pdf", [
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /XObject << /Fm1 5 0 R >> >> >>", Self.emptyPage,
            Self.form(resources: "<< /XObject << /Fm2 6 0 R >> >>"), Self.form(resources: "<< /XObject << /Im1 7 0 R >> >>"),
            Self.image(1700, 1100)]).found)
        // Cut into tiles, none of them large: three make a card's worth, two do not.
        func tiles(_ count: Int) -> [String] {
            let names = (0..<count).map { "/T\($0) \(5 + $0) 0 R" }.joined(separator: " ")
            return ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /XObject << \(names) >> >> >>", Self.emptyPage]
                + (0..<count).map { _ in Self.image(256, 256) }
        }
        #expect(try search("three-tiles.pdf", tiles(3)).found)
        #expect(try !search("two-tiles.pdf", tiles(2)).found)
        // The size that counts: a card scanned at 150 dpi is a scan, a picture a little smaller
        // is a logo or a photo.
        func one(_ width: Int, _ height: Int) -> [String] {
            ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> >> >>",
             Self.emptyPage, Self.image(width, height)]
        }
        #expect(try search("card.pdf", one(500, 320)).found)
        #expect(try search("exactly.pdf", one(500, 300)).found && 500 * 300 == VaultFolderReader.scanPixels)
        #expect(try !search("photo.pdf", one(499, 300)).found)
        // A file claiming a picture larger than any could be is a scan, not an overflow.
        #expect(try search("absurd.pdf", one(4_000_000_000, 4_000_000_000)).found)
        // One small picture under two names is one picture.
        #expect(try !search("twice.pdf", [
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /XObject << /A 5 0 R /B 5 0 R >> >> >>",
            Self.emptyPage, Self.image(300, 300)]).found)
    }

    /// Sixty forms that all name the page's own resources as theirs: walked again from each one,
    /// that is millions of visits (1.5 s measured, and minutes at two hundred). Each dictionary
    /// is opened once.
    @Test(.timeLimit(.minutes(1))) func formsThatShareThePagesResourcesAreOpenedOnce() throws {
        let dir = FixtureDir()
        let forms = 60
        let names = (0..<forms).map { "/F\($0) \(7 + $0) 0 R" }.joined(separator: " ")
        try Self.writeRawPDF(objects: [
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources 5 0 R >>", Self.emptyPage,
            "<< /XObject << /Logo 6 0 R \(names) >> >>", Self.image(240, 80),
        ] + (0..<forms).map { _ in Self.form(resources: "5 0 R") }, to: dir.path("shared.pdf"))
        let search = VaultFolderReader.scanSearch(try Self.page(at: dir.path("shared.pdf")))
        #expect(!search.found, "a letterhead's logo, however many forms draw it")
        #expect(search.opened == 1, "one dictionary, walked once however many forms name it")
    }

    // MARK: When Vision refuses

    /// Vision's Neural Engine refuses every text request for minutes at a time (twice in half an
    /// hour on 2026-11-20, 161 scans unread in one of them); the CPU still reads.
    @Test func aPageTheNeuralEngineRefusesIsReadOnTheCPU() throws {
        struct Refused: Error {}
        let image = try Self.scan(of: ["A"], width: 64, height: 64)
        var asked: [VaultFolderReader.Processor] = []
        let lines = VaultFolderReader.recognised(image) { _, processor in
            asked.append(processor)
            if processor == .any { throw Refused() }
            return ["read on the CPU"]
        }
        #expect(lines == ["read on the CPU"])
        #expect(asked == [.any, .cpu])
        // Refused on both: not read, which is not a page with no text.
        #expect(VaultFolderReader.recognised(image) { _, _ in throw Refused() } == nil)
        // A healthy read is made once, and a page with no words is an empty reading.
        asked = []
        #expect(VaultFolderReader.recognised(image) { _, processor in asked.append(processor); return [] } == [])
        #expect(asked == [.any])
    }

    /// The same through the reader itself, on a scanned page with no text: what the app's Read
    /// Documents runs, Vision alone stood in for. No Vision here, so this runs anywhere.
    @Test func theReaderItselfReadsARefusedPageOnTheCPU() async throws {
        struct Refused: Error {}
        let dir = FixtureDir()
        let path = dir.path("scan.pdf")
        try Self.writePDF(picture: Self.scan(of: Self.passport), text: [], to: path)
        let asked = Asked()
        var reader = VaultFolderReader(folders: [dir.url.path])
        reader.vision = { _, processor in
            asked.note(processor)
            if processor == .any { throw Refused() }
            return Self.passport
        }
        #expect(await reader.pages(in: URL(fileURLWithPath: path)) == [Self.passport])
        #expect(asked.processors == [.any, .cpu])
        // Refused on both: no page, so the file is not marked read with nothing, and the reader
        // says a page was left out (VT54).
        reader.vision = { _, _ in throw Refused() }
        let refused = await reader.reading(URL(fileURLWithPath: path))
        #expect(refused.pages.isEmpty && !refused.complete)
        // An image file is read the same way.
        let image = dir.path("scan.png")
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: image) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try Self.scan(of: Self.passport, width: 400, height: 260), nil)
        #expect(CGImageDestinationFinalize(destination))
        let again = Asked()
        reader.vision = { _, processor in
            again.note(processor)
            if processor == .any { throw Refused() }
            return Self.passport
        }
        #expect(await reader.pages(in: URL(fileURLWithPath: image)) == [Self.passport])
        #expect(again.processors == [.any, .cpu])
    }

    /// Every PDFKit call takes its turn in the process's one lane (VT52): with the lane held, a
    /// PDF is not opened, and nothing of it read, until it is let go.
    @Test(.timeLimit(.minutes(1))) func aPDFIsReadOnlyInThePDFKitLane() async throws {
        let dir = FixtureDir()
        let path = dir.path("scan.pdf")
        try Self.writePDF(picture: Self.scan(of: Self.passport), text: [], to: path)
        let asked = Asked()
        var reader = VaultFolderReader(folders: [dir.url.path])
        // Vision runs outside the lane: never on its queue.
        reader.vision = { _, processor in
            let queue = String(cString: __dispatch_queue_get_label(nil))
            asked.note(queue == "com.synccloud.pdfkit" ? .cpu : processor)
            return Self.passport
        }

        let held = DispatchSemaphore(value: 0), letGo = DispatchSemaphore(value: 0)
        // Let go however the test ends: a lane left held would hold every later test's PDFs.
        defer { letGo.signal() }
        let holding = Task { await PDFKitSerialAccess.perform { held.signal(); letGo.wait() } }
        await withCheckedContinuation { c in DispatchQueue.global().async { held.wait(); c.resume() } }
        let reading = Task { await reader.pages(in: URL(fileURLWithPath: path)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(asked.processors.isEmpty, "the PDF was read outside the PDFKit lane")
        letGo.signal()
        await holding.value
        #expect(await reading.value == [Self.passport])
        #expect(asked.processors == [.any], "Vision ran inside the PDFKit lane")
    }

    /// The key two files share only when their bytes do (VT107): size and SHA-256, so the same
    /// bytes under two names match and one byte changed does not.
    @Test func aFilesContentKeyIsItsBytes() async throws {
        let dir = FixtureDir()
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var changed = bytes
        changed[2_999_999] ^= 1
        for (name, data) in [("a.pdf", bytes), ("b.pdf", bytes), ("c.pdf", changed)] {
            try data.write(to: URL(fileURLWithPath: dir.path(name)))
        }
        let reader = VaultFolderReader(folders: [dir.url.path])
        let (a, b, c) = (await reader.contentKey(of: URL(fileURLWithPath: dir.path("a.pdf"))),
                         await reader.contentKey(of: URL(fileURLWithPath: dir.path("b.pdf"))),
                         await reader.contentKey(of: URL(fileURLWithPath: dir.path("c.pdf"))))
        #expect(a != nil && a == b, "the same bytes under two names gave two keys")
        #expect(a != c, "a byte changed gave the same key")
    }

    /// Which processors a reader asked, in order; the reader asks from its own task.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [VaultFolderReader.Processor] = []
        func note(_ processor: VaultFolderReader.Processor) { lock.withLock { asked.append(processor) } }
        var processors: [VaultFolderReader.Processor] { lock.withLock { asked } }
    }

    /// A stamped scan through the reader with a known reading for its picture: the picture is
    /// the file's page and the typed text a page after it. Runs anywhere.
    @Test func aScanUnderATypedNumberIsTwoPagesWhateverReadsThePicture() async throws {
        let dir = FixtureDir()
        let path = dir.path("exhibit.pdf")
        let typed = "Exhibit 4 to the petition, receipt LIN2412345678, page 3 of 12"
        try Self.writePDF(picture: Self.scan(of: Self.passport), text: [typed], to: path)
        var reader = VaultFolderReader(folders: [dir.url.path])
        reader.vision = { _, _ in Self.passport }
        let pages = await reader.pages(in: URL(fileURLWithPath: path))
        #expect(pages.first == Self.passport && pages.count == 2)
        #expect(pages.last?.joined().contains("LIN2412345678") == true)
        #expect(Set(VaultReading.read(pages: pages, from: path, under: [dir.url.path]).finds.map(\.value))
                == ["L898902C3", "LIN2412345678"])
    }

    /// The CPU's own reading, which the fallback above hands back: it must be a real one, and
    /// made on the CPU at every stage of both requests, or it is the refused read made again.
    /// Pinned: Vision's `.accurate` recognizer fails on GitHub's hosted VMs.
    @Test(.machinePinned(.textRecognition)) func theCPUReadsAPageByItself() throws {
        let lines = try VaultFolderReader.read(Self.scan(of: Self.passport), on: .cpu)
        #expect(VaultReading.finds(in: lines, from: "/Passport/scan.jpg").map(\.value) == ["L898902C3"])

        func devices(_ request: VNRequest) throws -> [Bool] {
            try request.supportedComputeStageDevices.keys.map { stage in
                if case .cpu? = request.computeDevice(for: stage) { true } else { false }
            }
        }
        let held = try VaultFolderReader.requests(on: .cpu)
        #expect(try !devices(held.text).isEmpty && devices(held.text).allSatisfy { $0 })
        #expect(try devices(held.barcodes).allSatisfy { $0 })
        // Left to Vision, nothing is held anywhere.
        let free = try VaultFolderReader.requests(on: .any)
        #expect(try devices(free.text).allSatisfy { !$0 })
    }

    /// A scanned passport page under a typed case number, read by Vision itself: both numbers,
    /// whether Vision read the typed line too (one page) or not (the layer as a second).
    /// Pinned: Vision's `.accurate` recognizer fails on GitHub's hosted VMs.
    @Test(.machinePinned(.textRecognition)) func aScanUnderATypedNumberGivesBothNumbers() async throws {
        let dir = FixtureDir()
        let path = dir.path("exhibit.pdf")
        let typed = "Exhibit 4 to the petition, receipt LIN2412345678, page 3 of 12"
        try Self.writePDF(picture: Self.scan(of: Self.passport), text: [typed], to: path)
        let pages = await VaultFolderReader(folders: [dir.url.path]).pages(in: URL(fileURLWithPath: path))
        #expect((1...2).contains(pages.count))
        let finds = VaultReading.read(pages: pages, from: path, under: [dir.url.path]).finds
        #expect(Set(finds.map(\.value)) == ["L898902C3", "LIN2412345678"])
    }

    /// A scanned passport page a signing service stamped: the stamp is the page's whole text
    /// layer, and is more than the forty letters that used to mean "this page has its text".
    /// Pinned: Vision's `.accurate` recognizer fails on GitHub's hosted VMs.
    @Test(.machinePinned(.textRecognition)) func aScannedPassportUnderAStampIsRead() async throws {
        let dir = FixtureDir()
        let path = dir.path("passport.pdf")
        try Self.writePDF(picture: Self.scan(of: Self.passport), text: [Self.stamp], to: path)

        // The fixture must be what it claims, or the read below proves nothing.
        let layer = try Self.page(at: path).string ?? ""
        #expect(layer.filter { !$0.isWhitespace }.count > VaultPageSource.leastText)
        #expect(layer.contains("DocuSign") && !layer.contains("ERIKSSON"), "the layer is the stamp alone")
        #expect(VaultReading.finds(in: layer.components(separatedBy: .newlines), from: path).isEmpty)

        let pages = await VaultFolderReader(folders: [dir.url.path]).pages(in: URL(fileURLWithPath: path))
        let finds = VaultReading.read(pages: pages, from: path, under: [dir.url.path]).finds
        #expect(finds.map(\.value) == ["L898902C3"], "pages: \(pages.count), lines: \(pages.first?.count ?? 0)")
        #expect(finds.first?.category == .passport)
    }
}
