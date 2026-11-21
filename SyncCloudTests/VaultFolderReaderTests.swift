import AppKit
import CoreText
import Foundation
import PDFKit
import Sync
import Testing
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
