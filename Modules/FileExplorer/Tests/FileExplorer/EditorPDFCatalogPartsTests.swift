import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Sync
@testable import FileExplorer

extension PDFFixtures {
    /// A 3-page PDF labelled "i", "ii", "1", whose catalog also has tags, layers and a colour output
    /// intent — what no rebuilding tool's copy keeps (decision BW). Assembled by hand: PDFKit's
    /// writer produces none of them.
    static func writeTagged(_ path: String) throws {
        let stream = "BT /F1 24 Tf 72 396 Td (Tagged) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r >> 2 << /S /D >>] >>"
                + " /PageLayout /TwoColumnLeft /Lang (en-GB) /MarkInfo << /Marked true >> /StructTreeRoot 7 0 R"
                + " /OCProperties << /OCGs [8 0 R] /D << /Order [8 0 R] >> >> /OutputIntents [9 0 R] >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 10 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 10 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 10 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /StructTreeRoot /K [] >>",
            "<< /Type /OCG /Name (Layer) >>",
            "<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: URL(fileURLWithPath: path))
    }
}

/// **TE201 and TE202 — what a tool's copy keeps, and what each sheet says still goes.** Every copy
/// keeps a file's page labels, viewer settings, language and attached files (decisions BT, BW);
/// its tags, layers and colour output intent go, and the tool names the ones the file has.
@MainActor
@Suite(.serialized) final class EditorPDFCatalogPartsTests {
    let folder = NSTemporaryDirectory() + "editor-pdf-catalog-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    /// Opens `file` and waits — a lane turn at a time, bounded — for the load to be applied.
    private func open(_ file: String) async -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        var loaded = false
        pdf.onLoaded = { _ in loaded = true }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where !loaded {
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !loaded { Issue.record("\((file as NSString).lastPathComponent) never loaded") }
        pdf.onLoaded = nil
        return pdf
    }

    // MARK: The words

    @Test func theNoteNamesOnlyWhatTheFileHas() {
        #expect(EditorPDFTools.droppedPartsNote([]) == nil)
        #expect(EditorPDFTools.droppedPartsNote([.tags]) == "The copy won’t keep this PDF’s tags for screen readers.")
        #expect(EditorPDFTools.droppedPartsNote([.layers, .outputIntent]) == "The copy won’t keep this PDF’s layers or colour output intent.")
        #expect(EditorPDFTools.droppedPartsNote([.tags, .layers, .outputIntent])
                == "The copy won’t keep this PDF’s tags for screen readers, layers or colour output intent.")
    }

    /// Rotate, Protect and filling a form write in place and keep them; so does Clean Metadata on a
    /// file with a form. Every other tool's copy, and any tool in a dragged order, loses them.
    @Test func whichToolsSayIt() {
        let secret = EditorPDFSecret("pw")
        let losing: [EditorPDFTool] = [.deletePages([0]), .reorder([1, 0]), .extract([0]), .compress(.quality(0.5)),
                                       .removePassword(secret), .fillAndSign([]), .arranged(order: [1, 0], then: .rotate(pages: [0], quarterTurns: 1))]
        for tool in losing {
            #expect(tool.dropsCatalogParts(fileHasForm: false), "\(tool.title)")
            #expect(tool.dropsCatalogParts(fileHasForm: true), "\(tool.title)")
        }
        let keeping: [EditorPDFTool] = [.rotate(pages: [0], quarterTurns: 1), .protect(restrictEditing: false, password: secret),
                                        .fillForm(values: [:], items: [])]
        for tool in keeping { #expect(!tool.dropsCatalogParts(fileHasForm: false), "\(tool.title)") }
        #expect(EditorPDFTool.cleanMetadata(.cleared).dropsCatalogParts(fileHasForm: false))
        #expect(!EditorPDFTool.cleanMetadata(.cleared).dropsCatalogParts(fileHasForm: true))
    }

    // MARK: Read with the file

    @Test func anOpenReadsWhatTheCopiesWontKeep() async throws {
        let tagged = path("Tagged.pdf")
        try PDFFixtures.writeTagged(tagged)
        let plain = path("Plain.pdf")
        PDFFixtures.write(plain, pages: 2)
        for (file, expected) in [(tagged, [PDFToolkit.DroppedCatalogPart.tags, .layers, .outputIntent]), (plain, [])] {
            let pdf = await open(file)
            #expect(pdf.tools.droppedParts == expected, "\((file as NSString).lastPathComponent)")
            #expect((pdf.tools.droppedPartsNote != nil) == !expected.isEmpty)
            // Fill & Sign without a form redraws the pages, and its note card says so too.
            #expect(pdf.fill.formNotes == [pdf.tools.droppedPartsNote].compactMap { $0 })
            pdf.close()
            #expect(pdf.tools.droppedParts.isEmpty, "a closed file's parts stayed")
        }
        // A pane menu's probe reads them too, for a sheet raised with no document open.
        let probe = await EditorPDFToolEngine.probe(URL(fileURLWithPath: tagged))
        #expect(probe == .facts(pageCount: 3, encryption: .none, droppedParts: [.tags, .layers, .outputIntent]))
    }

    /// A file locked to open can't be read until it is unlocked, so the sheet says "any"; once the
    /// reader unlocks it, by its password, it names what the file has.
    @Test func aLockedFileSaysAnyUntilItIsUnlocked() async throws {
        let plain = path("plain.pdf")
        try PDFFixtures.writeTagged(plain)
        let locked = path("Locked.pdf")
        try PDFToolkit.encryptData(inputURL: URL(fileURLWithPath: plain), options: .addPassword(restrictEditing: false, password: "pw"))
            .write(to: URL(fileURLWithPath: locked))
        let pdf = await open(locked)
        #expect(pdf.phase == .locked)
        #expect(pdf.tools.droppedParts.isEmpty)
        #expect(EditorPDFToolSheetFrame<EmptyView>.droppedNote(pdf.tools) == EditorPDFTools.droppedPartsUnreadNote)
        #expect(await pdf.unlock(password: "pw"))
        #expect(pdf.tools.droppedParts == [.tags, .layers, .outputIntent])
        #expect(EditorPDFToolSheetFrame<EmptyView>.droppedNote(pdf.tools)
                == "The copy won’t keep this PDF’s tags for screen readers, layers or colour output intent.")
        pdf.close()
    }

    // MARK: The copies

    /// Through Edit's own run: an extract keeps each page's label, the layout and the language —
    /// and the tags, layers and output intent go, as the sheet said.
    @Test func anExtractedCopyKeepsItsPagesLabels() async throws {
        let file = path("Tagged.pdf")
        try PDFFixtures.writeTagged(file)
        let tools = EditorPDFTools()
        tools.attach(path: file, pageCount: 3, encryption: .none, droppedParts: [.tags, .layers, .outputIntent])
        tools.confirm = { _, _ in true }
        let outcome = await tools.run(.extract([2, 0]))
        let copy = path("Tagged (pages 3, 1).pdf")
        #expect(outcome == .wrote(copy))
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: copy)))
        #expect((0..<document.pageCount).map { document.page(at: $0)?.label } == ["1", "i"])
        // The document held while its catalog is read: the catalog is the document's.
        let written = try #require(CGPDFDocument(URL(fileURLWithPath: copy) as CFURL))
        let catalog = try #require(written.catalog)
        var name: UnsafePointer<CChar>?
        #expect(CGPDFDictionaryGetName(catalog, "PageLayout", &name) && name.map { String(cString: $0) } == "TwoColumnLeft")
        var object: CGPDFObjectRef?
        #expect(CGPDFDictionaryGetObject(catalog, "Lang", &object))
        #expect(!CGPDFDictionaryGetObject(catalog, "StructTreeRoot", &object))
        #expect(!CGPDFDictionaryGetObject(catalog, "OCProperties", &object))
        #expect(!CGPDFDictionaryGetObject(catalog, "OutputIntents", &object))
        #expect(PDFToolkit.droppedCatalogParts(at: URL(fileURLWithPath: copy)).isEmpty)
    }
}
