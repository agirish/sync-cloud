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

    /// VT81 (owner): a document grown past the walk's cap since it was read is passed over by
    /// Refresh too, which opens it by name: nothing comes back, so what it gave before stays.
    @Test func aFileOverTheCapIsPassedOverWhenOpenedByName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("scan.pdf")
        try Self.writePDF(picture: nil, text: ["Passport No. L898902C3"], to: big.path)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(VaultFolderReader.largestFile + 1))
        try handle.close()
        let reader = VaultFolderReader(folders: [folder.path])
        let read = await reader.noted(big)
        #expect(read.pages.isEmpty && read.complete && read.notes.tooLarge == 1, "marked read as it is")
        let walked = await reader.walk()
        #expect(walked.files.isEmpty, "the walk passes it over too")
        #expect(walked.unreachable.contains { $0.hasSuffix("/scan.pdf") }, "and what it gave before is kept")
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

    /// A content stream that draws an inline picture of `width` by `height` across the page's
    /// upper half: `BI … ID … EI`, its pixels in the stream itself, which no resource names.
    /// `pixels` false writes one byte for them, which is all a search needs.
    static func inline(_ width: Int, _ height: Int, pixels: Bool = false) -> String {
        let data = pixels ? String(repeating: "0", count: width * height) : "x"
        return "q 612 0 0 392 0 300 cm BI /W \(width) /H \(height) /CS /G /BPC 8 ID \(data) EI Q"
    }

    /// A stream of `content`, for a page's contents.
    static func contents(_ content: String) -> String {
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    /// A form an annotation draws as its appearance: `content` with `resources`, across the
    /// page's upper half.
    static func appearance(_ content: String, resources: String = "<< >>") -> String {
        "<< /Type /XObject /Subtype /Form /BBox [0 0 612 392] /Resources \(resources) /Length \(content.utf8.count) >>"
            + "\nstream\n\(content)\nendstream"
    }

    /// A dark gray picture of `width` by `height`, its pixels written out.
    static func picture(_ width: Int, _ height: Int) -> String {
        "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray "
            + "/BitsPerComponent 8 /Length \(width * height) >>\nstream\n\(String(repeating: "0", count: width * height))\nendstream"
    }

    /// VT88: a scan the page's content draws inline, or an annotation draws as its appearance (a
    /// scanned stamp or a pasted picture), is the page's picture as much as one its resources name.
    @Test func aScanDrawnInlineOrByAnAnnotationIsFound() throws {
        let dir = FixtureDir()
        func found(_ name: String, _ objects: [String]) throws -> Bool {
            try Self.writeRawPDF(objects: objects, to: dir.path(name))
            return VaultFolderReader.drawsScan(try Self.page(at: dir.path(name)))
        }
        // Inline in the page's own content, at the size that counts and a little under it.
        func inlinePage(_ width: Int, _ height: Int) -> [String] {
            ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << >> >>", Self.contents(Self.inline(width, height))]
        }
        #expect(try found("inline.pdf", inlinePage(500, 320)))
        #expect(try !found("inline-logo.pdf", inlinePage(499, 300)))
        // Inline in a form the page draws.
        #expect(try found("inline-form.pdf", [
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /XObject << /Fm1 5 0 R >> >> >>",
            Self.contents("/Fm1 Do"),
            Self.appearance("BI /W 1700 /H 1100 /CS /G /BPC 8 ID x EI")]))
        // An annotation's appearance that names a picture, or draws one inline.
        func annotated(_ appearance: [String]) -> [String] {
            ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << >> /Annots [5 0 R] >>", Self.emptyPage,
             "<< /Type /Annot /Subtype /Stamp /Rect [0 300 612 692] /AP << /N 6 0 R >> >>"] + appearance
        }
        #expect(try found("annotation.pdf", annotated([
            Self.appearance("612 0 0 392 0 0 cm /Im1 Do", resources: "<< /XObject << /Im1 7 0 R >> >>"),
            Self.image(1700, 1100)])))
        #expect(try found("annotation-inline.pdf", annotated([Self.appearance("BI /W 1700 /H 1100 /CS /G /BPC 8 ID x EI")])))
        #expect(try !found("annotation-logo.pdf", annotated([
            Self.appearance("/Im1 Do", resources: "<< /XObject << /Im1 7 0 R >> >>"), Self.image(240, 80)])))
        // An appearance kept by state is the state shown: a scan in a state not shown is not drawn.
        func states(_ shown: String) -> [String] {
            ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << >> /Annots [5 0 R] >>", Self.emptyPage,
             "<< /Type /Annot /Subtype /Stamp /Rect [0 300 612 692] /AS /\(shown) /AP << /N << /On 6 0 R /Off 7 0 R >> >> >>",
             Self.appearance("BI /W 1700 /H 1100 /CS /G /BPC 8 ID x EI"), Self.appearance("")]
        }
        #expect(try found("state-on.pdf", states("On")))
        #expect(try !found("state-off.pdf", states("Off")))
    }

    /// The share of `image`'s pixels that are dark.
    static func darkShare(of image: CGImage) throws -> Double {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let dark = (0..<(image.width * image.height)).count(where: { bytes[$0 * 4] < 128 })
        return Double(dark) / Double(image.width * image.height)
    }

    /// Through the reader: a stamped page whose scan is drawn inline, or by an annotation, is read
    /// from its picture, and the render Vision reads draws it. Vision is stood in for by a reading
    /// given only when the render shows the scan, so this runs anywhere.
    @Test func aStampedScanDrawnInlineOrByAnAnnotationIsReadFromItsPicture() async throws {
        let dir = FixtureDir()
        let font = "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >>"
        let text = "BT /F1 9 Tf 36 770 Td (\(Self.stamp)) Tj ET"
        let files: [(String, [String])] = [
            ("inline.pdf", ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << \(font) >> >>",
                            Self.contents(text + " " + Self.inline(500, 320, pixels: true))]),
            ("annotation.pdf", ["<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << \(font) >> /Annots [5 0 R] >>",
                                Self.contents(text), "<< /Type /Annot /Subtype /Stamp /Rect [0 300 612 692] /AP << /N 6 0 R >> >>",
                                Self.appearance("612 0 0 392 0 0 cm /Im1 Do", resources: "<< /XObject << /Im1 7 0 R >> >>"),
                                Self.picture(500, 320)]),
        ]
        for (name, objects) in files {
            let path = dir.path(name)
            try Self.writeRawPDF(objects: objects, to: path)
            // The fixture must be what it claims: the stamp is the whole layer, and more than a
            // few letters.
            let layer = try Self.page(at: path).string ?? ""
            #expect(layer.contains("DocuSign") && layer.filter { !$0.isWhitespace }.count > VaultPageSource.leastText,
                    "\(name): the layer is the stamp")
            var reader = VaultFolderReader(folders: [dir.url.path])
            reader.vision = { image, _ in (try? Self.darkShare(of: image)).map { $0 > 0.3 } == true ? Self.passport : [] }
            let pages = await reader.pages(in: URL(fileURLWithPath: path))
            let finds = VaultReading.read(pages: pages, from: path, under: [dir.url.path]).finds
            #expect(finds.map(\.value) == ["L898902C3"], "\(name): \(pages.count) page(s)")
        }
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

    /// A scan under a short text layer that gives a number, with Vision refusing the picture:
    /// the layer is kept, and the file comes back not complete, so its picture is tried again
    /// rather than the file marked read (the 2026-11-23 review).
    @Test func aRefusedScanUnderANumberedStampIsKeptAndTriedAgain() async throws {
        struct Refused: Error {}
        let dir = FixtureDir()
        let path = dir.path("notice.pdf")
        try Self.writePDF(picture: Self.scan(of: Self.passport), text: ["Receipt Number: EAC2190012345"], to: path)
        var reader = VaultFolderReader(folders: [dir.url.path])
        reader.vision = { _, _ in throw Refused() }
        let read = await reader.reading(URL(fileURLWithPath: path))
        #expect(read.pages.joined().joined(separator: " ").contains("EAC2190012345"))
        #expect(!read.complete)
        reader.vision = { _, _ in Self.passport }
        #expect(await reader.reading(URL(fileURLWithPath: path)).complete)
    }

    /// A picture file of several pages (a faxed TIFF) is read as a PDF's are, up to three
    /// (owner, 2026-11-23: its first alone was read).
    @Test func aTIFFsPagesAreReadUpToThree() async throws {
        let dir = FixtureDir()
        let path = dir.path("fax.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.tiff" as CFString, 4, nil))
        for width in [400, 410, 420, 430] {
            CGImageDestinationAddImage(destination, try Self.scan(of: ["Page"], width: width, height: 260), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        var reader = VaultFolderReader(folders: [dir.url.path])
        reader.vision = { image, _ in ["Frame \(image.width)"] }
        let read = await reader.reading(URL(fileURLWithPath: path))
        #expect(read.pages == [["Frame 400"], ["Frame 410"], ["Frame 420"]])
        #expect(read.complete)
    }

    /// A render and an ink-alone copy stop at ``VaultFolderReader/largestRender`` pixels: a photo
    /// saved as a 72-dpi PDF (4,032 points) was drawn at 8,064. Pages of every usual size render as
    /// before (the 2026-11-23 review).
    @Test func aRenderStopsAtTheLargestSize() throws {
        let photo = CGRect(x: 0, y: 0, width: 4032, height: 3024)
        #expect(VaultFolderReader.scale(of: photo, longSide: 2400) * 4032 <= VaultFolderReader.largestRender)
        #expect(VaultFolderReader.scale(of: photo, longSide: 4000) * 4032 <= VaultFolderReader.largestRender)
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792), card = CGRect(x: 0, y: 0, width: 243, height: 153)
        #expect(abs(VaultFolderReader.scale(of: letter, longSide: 2400) - 2400 / 792) < 0.0001)
        #expect(VaultFolderReader.scale(of: card, longSide: 2400) == 6)
        #expect(VaultFolderReader.scale(of: CGRect(x: 0, y: 0, width: 792, height: 1224), longSide: 2400) == 2)
        // The color sample of a sliver is held to ten times its width; a usual page is as it was.
        let sliver = VaultFolderReader.sampleSize(width: 4, height: 60_000)
        #expect(sliver.width == 400 && sliver.height == 4000)
        let page = VaultFolderReader.sampleSize(width: 1700, height: 1100)
        #expect(page.width == 400 && page.height == 258)
    }

    /// The ink-alone copy of a photo far past the largest render is brought down to it; one a
    /// little past it (a 12-megapixel phone photo) keeps its own pixels.
    @Test func anInkCopyIsBroughtDownOnlyFarPastTheLargestRender() throws {
        func red(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        #expect(VaultFolderReader.inkOnly(try red(8000, 300))?.width == 4000)
        #expect(VaultFolderReader.inkOnly(try red(4032, 300))?.width == 4032)
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

    /// One render per page and scale (VT82): asked twice for one size, or for two sizes a card's
    /// small page clamps to one scale, it renders once; a letter page's two sizes are two.
    @Test func eachPageIsRenderedOncePerScale() throws {
        let dir = FixtureDir()
        for (name, box, renders) in [("card.pdf", CGRect(x: 0, y: 0, width: 243, height: 153), 1),
                                     ("letter.pdf", CGRect(x: 0, y: 0, width: 612, height: 792), 2)] {
            let path = dir.path(name)
            let data = NSMutableData()
            var mediaBox = box
            let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
            context.beginPDFPage(nil)
            context.draw(try Self.scan(of: ["A card"], width: 500, height: 320), in: box)
            context.endPDFPage()
            context.closePDF()
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            let page = try Self.page(at: path)
            let pages = VaultFolderReader.PageRenders(page: page, bounds: page.bounds(for: .mediaBox), lane: { $0() })
            let first = try #require(pages.image(longSide: 2400))
            #expect(pages.image(longSide: 2400) === first, "\(name): the same render again")
            _ = pages.image(longSide: 4000)
            _ = pages.image(longSide: 2400)
            #expect(pages.made == renders, "\(name): \(pages.made) renders")
            var recognised = 0
            for side: CGFloat in [2400, 4000, 2400, 4000] {
                _ = pages.read(longSide: side) { _ in recognised += 1; return ["A card"] }
            }
            #expect(recognised == renders, "\(name): Vision ran \(recognised) times")
        }
    }

    /// A Social Security card with nothing read is read again sharper; on a card's small page the
    /// sharper render is the same image, so Vision reads it once, and the reading is the same.
    @Test func aCardsSharperReadIsNotVisionAgainOnTheSameImage() async throws {
        let dir = FixtureDir()
        let path = dir.path("card.pdf")
        let card = ["SOCIAL SECURITY", "THIS NUMBER HAS BEEN ESTABLISHED FOR", "ANNA ERIKSSON", "SIGNATURE"]
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 243, height: 153)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.draw(try Self.scan(of: card, width: 800, height: 504), in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        #expect(VaultReading.wantsSharperRead(card), "a card with no number is read again")
        let asked = Asked()
        var reader = VaultFolderReader(folders: [dir.url.path])
        reader.vision = { _, processor in asked.note(processor); return card }
        #expect(await reader.pages(in: URL(fileURLWithPath: path)) == [card])
        #expect(asked.processors == [.any], "Vision ran \(asked.processors.count) times on one image")
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
