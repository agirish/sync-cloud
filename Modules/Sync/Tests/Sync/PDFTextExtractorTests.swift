import Foundation
import CoreGraphics
import CoreText
import os
import Testing
@testable import Sync

/// The PDFKit reader, against PDFs written here at run time — so this covers the real parse, not a
/// stand-in for it. Generating the fixtures rather than checking them in is what lets the
/// re-stamp case be built honestly: the same text drawn twice into two files whose bytes differ.
@Suite struct PDFTextExtractorTests {

    /// Writes a PDF at `url` with one page per entry in `pages`, each drawn as a single line of
    /// text. `mediaBox` and the optional `producer` string are what let two otherwise identical
    /// documents be given different geometry or different bytes.
    private func writePDF(_ pages: [String], to url: URL,
                          mediaBox: CGRect = CGRect(x: 0, y: 0, width: 612, height: 792),
                          producer: String? = nil) throws {
        var box = mediaBox
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      producer.map { ["kCGPDFContextProducer": $0] as CFDictionary })
        else { throw CocoaError(.fileWriteUnknown) }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: box.height - 60)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTextExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let sentence = "Account statement for Father Elder amount due 124.50 thank you"

    @Test func readsThePageTextAndGeometry() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bill.pdf")
        try writePDF([sentence, "page two"], to: url)

        let document = try #require(PDFTextExtractor.readSync(url.path))
        #expect(document.pageCount == 2)
        #expect(document.pages.count == 2)
        #expect(document.pages[0].contains("124.50"))
        #expect(document.pageBoxes == ["612x792", "612x792"])
    }

    @Test func twoWritesOfTheSameTextDifferInBytesAndAgreeInFingerprint() throws {
        // The feature's premise on real PDF bytes: a provider re-generating the document stamps
        // something new into it (here, the Producer string), so the bytes differ but the text
        // doesn't.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("download-1.pdf")
        let second = dir.appendingPathComponent("download-2.pdf")
        try writePDF([sentence], to: first, producer: "Provider Renderer 4.1")
        try writePDF([sentence], to: second, producer: "Provider Renderer 9.7 build 22041")

        let a = try Data(contentsOf: first), b = try Data(contentsOf: second)
        #expect(a != b)   // the fixture is only meaningful if the bytes really differ

        let da = ContentFingerprint.digest(of: try #require(PDFTextExtractor.readSync(first.path)))
        let db = ContentFingerprint.digest(of: try #require(PDFTextExtractor.readSync(second.path)))
        #expect(da != nil)
        #expect(da == db)
    }

    @Test func differentPaperSizeIsADifferentDocument() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let letter = dir.appendingPathComponent("letter.pdf")
        let a4 = dir.appendingPathComponent("a4.pdf")
        try writePDF([sentence], to: letter)
        try writePDF([sentence], to: a4, mediaBox: CGRect(x: 0, y: 0, width: 595, height: 842))

        let dl = ContentFingerprint.digest(of: try #require(PDFTextExtractor.readSync(letter.path)))
        let da = ContentFingerprint.digest(of: try #require(PDFTextExtractor.readSync(a4.path)))
        #expect(dl != nil)
        #expect(dl != da)
    }

    @Test func readsAtMostTheCappedPageCountButReportsTheRealOne() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("long.pdf")
        let count = ContentFingerprint.maxPagesRead + 5
        try writePDF((0..<count).map { "\(sentence) page \($0)" }, to: url)

        let document = try #require(PDFTextExtractor.readSync(url.path))
        #expect(document.pageCount == count)
        #expect(document.pages.count == ContentFingerprint.maxPagesRead)
        #expect(document.pageBoxes.count == ContentFingerprint.maxPagesRead)
    }

    @Test func nonPDFsAndUnparseableFilesAreDeclined() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("notes.txt")
        try Data("Account statement for Father Elder amount due".utf8).write(to: text)
        let fake = dir.appendingPathComponent("not-really.pdf")
        try Data(repeating: 0x41, count: 4096).write(to: fake)

        #expect(PDFTextExtractor.readSync(text.path) == nil)
        #expect(PDFTextExtractor.readSync(fake.path) == nil)
        #expect(PDFTextExtractor.readSync(dir.appendingPathComponent("absent.pdf").path) == nil)
    }

    @Test func anEvictedICloudFileIsDeclinedRatherThanDownloaded() throws {
        // The scan hands the reader every PDF in the tree. On an iCloud tree, a reader that opened
        // whatever it was given would force-download the whole offloaded library on the first cold
        // scan. A real dataless file can't be fabricated, so availability is injected; the fixture
        // reads fine when available, so nil can't pass by accident.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("statement.pdf")
        try writePDF(["Chase statement account 2809 balance due 1234.56 thank you"], to: url)

        let present = try #require(PDFTextExtractor.readSync(url.path))
        #expect(present.pages.first?.contains("2809") == true)
        #expect(PDFTextExtractor.readSync(url.path, isAvailable: { _ in false }) == nil)
    }

    @Test func anImageOnlyPDFYieldsNoFingerprintRatherThanAnEmptyOne() throws {
        // A scan with no text layer parses to nothing, and "nothing" must not become a digest that
        // every other textless scan of the same shape shares.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 200, height: 200))
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFTextExtractor.readSync(url.path))
        #expect(document.pageCount == 1)
        #expect(ContentFingerprint.digest(of: document) == nil)
    }

    @Test func theReadingSaysWhyThereIsNoDigest() async throws {
        // Only "read, and said too little" may be cached as a negative. Anything not read at all
        // (not on this disk, locked, unparseable) must come back unreadable, or a placeholder would
        // stay unfingerprinted after it downloaded.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("statement.pdf")
        try writePDF(["Chase statement account 2809 balance due 1234.56 thank you"], to: text)
        let scan = dir.appendingPathComponent("scan.pdf")
        try writePDF([""], to: scan)
        let fake = dir.appendingPathComponent("not-really.pdf")
        try Data(repeating: 0x41, count: 4096).write(to: fake)
        let locked = dir.appendingPathComponent("locked.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: locked as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box,
                                             [kCGPDFContextUserPassword: "secret",
                                              kCGPDFContextOwnerPassword: "secret"] as CFDictionary))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: sentence, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let available: @Sendable (String) -> Bool = { _ in true }
        guard case .digest = await PDFTextExtractor.reading(atPath: text.path, isAvailable: available) else {
            Issue.record("a readable statement gave no digest"); return
        }
        #expect(await PDFTextExtractor.reading(atPath: scan.path, isAvailable: available) == .tooLittleText)
        #expect(await PDFTextExtractor.reading(atPath: text.path, isAvailable: { _ in false }) == .unreadable)
        #expect(await PDFTextExtractor.reading(atPath: locked.path, isAvailable: available) == .unreadable)
        #expect(await PDFTextExtractor.reading(atPath: fake.path, isAvailable: available) == .unreadable)
        #expect(await PDFTextExtractor.reading(atPath: dir.appendingPathComponent("absent.pdf").path,
                                               isAvailable: available) == .unreadable)
    }

    @Test func availabilityIsAskedBeforeTheLaneNotOnIt() async throws {
        // A placeholder must not take the PDF lane's turn, holding up Edit's PDFs, Print and the
        // column preview, only to be turned away by a stat.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("statement.pdf")
        try writePDF([sentence], to: url)
        let asked = OSAllocatedUnfairLock<[String]>(initialState: [])
        _ = await PDFTextExtractor.reading(atPath: url.path, isAvailable: { _ in
            let label = String(cString: __dispatch_queue_get_label(nil))
            asked.withLock { $0.append(label) }
            return false
        })
        let labels = asked.withLock { $0 }
        #expect(labels.count == 1)
        #expect(!labels.contains("com.synccloud.pdfkit"))
    }

    /// Concurrent PDFKit parses extract different text run to run on real documents (the race
    /// needs the font substitution real bills trigger, so a synthetic fixture can't show it). What
    /// is asserted is the fix: however many callers ask at once, one parse runs. The lane is
    /// process-wide, not per-reader: two serial queues parsing PDFs at once race exactly like one
    /// concurrent one. `ContentSignalExtractor` lives in `MacApp`, out of reach here, so this
    /// asserts that reads through the lane's two entry points at once never overlap. A second lane
    /// anywhere would fail invisibly.
    @Test func theLaneSerializesItsTwoEntryPointsAgainstEachOther() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for i in 0..<12 {
            let url = dir.appendingPathComponent("doc-\(i).pdf")
            try writePDF(["\(sentence) number \(i)"], to: url)
            urls.append(url)
        }

        let read = await withTaskGroup(of: Bool.self) { group -> Int in
            for url in urls {
                // The async door — `fingerprint` reads through it, and a digest means it read.
                group.addTask { await PDFTextExtractor.fingerprint(url.path) != nil }
                // The synchronous door — what ContentSignalExtractor uses from its own queue.
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        DispatchQueue.global(qos: .utility).async {
                            let doc = PDFKitSerialAccess.run { PDFTextExtractor.readSync(url.path) }
                            continuation.resume(returning: doc != nil)
                        }
                    }
                }
            }
            var ok = 0
            for await didRead in group where didRead { ok += 1 }
            return ok
        }
        // Non-vacuity comes from the reads, not the peak: both doors must return a document, or a
        // broken fixture could move the counter and pass.
        #expect(read == urls.count * 2, "only \(read) of \(urls.count * 2) reads returned a document")

        let peak = PDFKitSerialAccess.peakConcurrentParses
        #expect(peak == 1, "\(peak) parses overlapped — the two entry points are not one lane")
    }

    @Test func theAsyncSeamReturnsTheSameDigestAsTheSyncRead() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bill.pdf")
        try writePDF([sentence], to: url)
        let viaSeam = await PDFTextExtractor.fingerprint(url.path)
        let direct = ContentFingerprint.digest(of: try #require(PDFTextExtractor.readSync(url.path)))
        #expect(viaSeam != nil)
        #expect(viaSeam == direct)
    }
}
