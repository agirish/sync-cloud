import Testing
import AppKit
import SwiftUI
import PDFToolkitCore
@testable import FileExplorer

/// **What Edit's PDF reader says** — the PDF reader group of Edit's small fixes: the spinners'
/// words (TE161, TE188), Clean Metadata's notes (TE162), a file only in the cloud (TE185) and the
/// toolkit's refusals in Edit's words (TE186).
@MainActor
@Suite struct EditorPDFReaderWordsTests {

    /// **A spinner says what it waits for** — the card while a PDF opens, Clean Metadata's sheet
    /// while it reads — in the Pages and Outline tabs' words.
    @Test func theSpinnersSayReadingThePDF() throws {
        #expect(EditorPDFDocument.readingCaption == "Reading the PDF…")
        #expect(EditorPDFRailPages.caption(phase: .loading) == EditorPDFDocument.readingCaption)
        #expect(EditorPDFOutline.emptyCaption(phase: .loading) == EditorPDFDocument.readingCaption)
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        let loading = try #require(card.range(of: "case .loading:")).upperBound
        #expect(card[loading...].prefix(200).contains("EditorPDFReadingSpinner()"), "the card's spinner says nothing")
        let sheets = try ChromeGlassWiringTests.source("EditorPDFToolSheets.swift")
        #expect(sheets.contains("} else if failure == nil {\n                EditorPDFReadingSpinner()"),
                "Clean Metadata's spinner says nothing")
        #expect(ChromeGlassWiringTests.count("ProgressView().controlSize(.small)\n            }", in: sheets) == 0)
    }

    /// **Clean Metadata says what the copy keeps** (TE162): a form PDF's copy holds the five fields
    /// and nothing else, its XMP kept; any other loses its XMP and gets the system's Producer and
    /// dates. Save stays (decision BO).
    @Test func cleanMetadataSaysWhatTheCopyKeeps() {
        var fields = PDFMetadataFields.cleared
        fields.producer = "Quartz PDFContext"
        #expect(EditorPDFMetadataSheet.notes(fields, hasForm: true) == [
            "The copy has only what’s in the five fields above. Producer, the dates and any other entries are "
                + "removed; any embedded (XMP) metadata stays.",
        ])
        #expect(EditorPDFMetadataSheet.notes(fields, hasForm: false) == [
            "Producer (“Quartz PDFContext”) and the created and modified dates are replaced with the system’s own "
                + "when the copy is written.",
            "Any embedded (XMP) metadata is removed from the copy too.",
        ])
        #expect(EditorPDFBatchSheet.cleanMetadataNote.contains(
            "replaced with the system’s own (removed, for a PDF with a fillable form)."))
    }

    /// **A file only in the cloud now says to download it, and offers Download** (TE185) — the
    /// sheet's Download for that failure alone, and for the open file.
    @Test func aCloudOnlyFileOffersDownload() {
        #expect(EditorPDFTools.cloudOnlyReason("Lease.pdf") == "“Lease.pdf” is only in the cloud now. Download it, then try again.")
        let tools = EditorPDFTools()
        #expect(EditorPDFToolSheetFrame<EmptyView>.downloadPath(failure: EditorPDFTools.cloudOnlyReason(""), tools: tools) == nil,
                "Download offered with no file open")
        tools.attach(path: "/tmp/Lease.pdf", pageCount: 1, encryption: .none)
        #expect(EditorPDFToolSheetFrame<EmptyView>.downloadPath(failure: EditorPDFTools.cloudOnlyReason("Lease.pdf"),
                                                                tools: tools) == "/tmp/Lease.pdf")
        #expect(EditorPDFToolSheetFrame<EmptyView>.downloadPath(failure: EditorPDFTools.busyMessage, tools: tools) == nil)

        var asked: [String] = []
        tools.host = EditorPDFToolHost(download: { asked.append($0) })
        tools.host.download("/tmp/Lease.pdf")
        #expect(asked == ["/tmp/Lease.pdf"])
        let view = try? ChromeGlassWiringTests.source("EditorPDFToolViews.swift")
        #expect(view?.contains("if let path = banner.download {") == true, "the banner draws no Download")
    }

    /// **The toolkit's refusals in Edit's words** (TE186), naming the file the reader opened — a
    /// link's, not its target's.
    @Test func theToolkitsWordsAreEdits() {
        let target = URL(fileURLWithPath: "/Volumes/Archive/2019 statement.pdf")
        let compress = EditorPDFTool.compress(.quality(0.6))
        #expect(EditorPDFToolEngine.reason(PDFOperationError.couldNotOpen(target), tool: compress, name: "Statement.pdf")
                == "Couldn’t open “Statement.pdf” — it may be damaged.")
        #expect(EditorPDFToolEngine.reason(PDFOperationError.couldNotOpen(target), tool: compress)
                == "Couldn’t open “2019 statement.pdf” — it may be damaged.")
        #expect(EditorPDFToolEngine.reason(PDFOperationError.incorrectPassword, tool: .removePassword(EditorPDFSecret("x")),
                                           name: "Statement.pdf")
                == "That password didn’t open “Statement.pdf”. Try again.")
        #expect(EditorPDFToolEngine.reason(PDFOperationError.encryptedInput(target), tool: compress, name: "Statement.pdf")
                .hasPrefix("“Statement.pdf” needs a password to open."))
        // The log says the same, with the name.
        #expect(EditorPDFToolEngine.logReason(PDFOperationError.couldNotOpen(target), tool: compress, name: "Statement.pdf")
                == "Couldn’t open “Statement.pdf” — it may be damaged.")
    }

    /// **Clean Metadata's sheet says a file it can't read in the same words**, naming the link it
    /// was opened by.
    @Test func cleanMetadataNamesTheFileItCantRead() async throws {
        let folder = NSTemporaryDirectory() + "pdf-reader-words-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = (folder as NSString).appendingPathComponent("Damaged target.pdf")
        try Data("%PDF-1.7\nnot really\n".utf8).write(to: URL(fileURLWithPath: target))
        let link = (folder as NSString).appendingPathComponent("Statement.pdf")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        guard case .failure(let error) = await EditorPDFMetadataSheet.read(path: link, isCloudOnly: { _ in false }) else {
            Issue.record("a damaged PDF's metadata was read")
            return
        }
        let said = EditorPDFToolEngine.reason(error, tool: .cleanMetadata(.cleared), name: "Statement.pdf")
        #expect(said == "Couldn’t open “Statement.pdf” — it may be damaged.", "said: \(said)")
        let sheets = try ChromeGlassWiringTests.source("EditorPDFToolSheets.swift")
        #expect(sheets.contains("failure = EditorPDFToolEngine.reason(error, tool: .cleanMetadata(.cleared), name: tools.name)"))
    }
}
