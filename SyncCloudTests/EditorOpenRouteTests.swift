import Testing
import AppKit
import PDFKit
import Sync
import FileExplorer
@testable import SyncCloud

/// **What is open in Edit: the text document or a PDF, never both** — `EditorOpenRoute`, run as the
/// app runs it, against real files.
///
/// The guarantee these hold is the one the separate PDF model exists for: **no PDF can reach a text
/// save path.** Every write the editor makes needs the text document's path; while a PDF is open
/// that document is empty, so ⌘S, autosave, the settle and the quit flush have nothing to write.
@MainActor
@Suite(.serialized) final class EditorOpenRouteTests {

    let folder = NSTemporaryDirectory() + "open-route-" + UUID().uuidString
    var lines: [String] = []

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func note(_ name: String, _ body: String) throws -> String {
        let file = path(name)
        try body.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A small real PDF with a text layer — small enough that the text reader would once have
    /// decoded it, lossily, and opened it read-only as garbage.
    private func pdfFile(_ name: String, pages: Int = 2) -> String {
        let file = path(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, nil)!
        for index in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Page \(index + 1)" as NSString).draw(at: NSPoint(x: 72, y: 600),
                                                   withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return file
    }

    private func route(_ path: String, _ document: EditorDocument, _ store: EditorUndoStore,
                       _ pdf: EditorPDFDocument) -> EditorOpenRoute.Kind {
        EditorOpenRoute.load(path: path, document: document, undoStore: store, pdf: pdf,
                             log: { [weak self] in self?.lines.append($0) })
    }

    /// Waits for the PDF model's load to come back from the lane — bounded in lane TURNS, not
    /// seconds (`docs/flaky-tests.md`, "The wait that hangs instead of failing"), and a labeled
    /// failure rather than a hang when it never does.
    private func settled(_ pdf: EditorPDFDocument) async {
        for _ in 0..<1000 {
            if pdf.phase != .loading { return }
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the PDF load of \(pdf.path ?? "nothing") never came back in 1000 lane turns")
    }

    // MARK: Routing

    /// **A PDF opens into the PDF model and never into the text document**, whose path stays nil.
    /// Mutation: route a PDF through `EditorDocumentLoad.run` and every expectation here fails.
    @Test func aPDFOpensIntoThePDFModelAndNeverIntoTheTextDocument() async {
        let file = pdfFile("report.pdf", pages: 3)
        let document = EditorDocument(), store = EditorUndoStore()
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(route(file, document, store, pdf) == .pdf)
        await settled(pdf)
        #expect(document.path == nil, "the PDF reached the text document")
        #expect(document.text.isEmpty)
        #expect(pdf.path == file)
        #expect(pdf.phase == .open)
        #expect(lines.last == "Editor opened \(file) (PDF, 3 pages)")
    }

    /// **The defect this fixes, with its control.** The text reader, handed a small PDF, decodes it
    /// lossily and opens it read-only as garbled text — that is what `Open With ▸ Other…` did. The
    /// hand-off, run with the app's load, no longer gets there.
    @Test func aSmallPDFFromOutsideNoLongerOpensAsText() async {
        let file = pdfFile("small.pdf", pages: 1)
        // The control: the text path, asked directly, does produce text for it.
        let control = EditorDocument()
        EditorDocumentLoad.run(path: file, document: control, undoStore: EditorUndoStore(), log: { _ in })
        #expect(control.path == file, "fixture: the text reader no longer opens this PDF at all")

        let document = EditorDocument(), store = EditorUndoStore()
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        let outcome = EditorHandOffRun.run(
            file, pane: .staysPut, syncManager: FileSyncManager(), paneRoot: folder,
            openDocument: nil, isRefused: false,
            paneFolder: { self.folder }, settle: { true }, endNaming: {}, showEdit: {},
            load: { _ = self.route($0, document, store, pdf) }, log: { _ in })
        #expect(outcome == .opened)
        await settled(pdf)
        #expect(document.path == nil && document.text.isEmpty, "the PDF opened as text")
        #expect(pdf.path == file && pdf.phase == .open)
    }

    // MARK: Settling first

    /// **Opening a PDF writes a dirty note first, as text → text does** — the hand-off's settle,
    /// then the route. Asserted on the bytes on disk: the edit must be there after the PDF opens.
    @Test func openingAPDFSettlesADirtyNoteFirst() async throws {
        let notes = try note("notes.md", "first draft")
        let file = pdfFile("invoice.pdf")
        let document = EditorDocument(), store = EditorUndoStore()
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(route(notes, document, store, pdf) == .text)
        document.text = "second draft"
        try #require(document.isDirty)

        var steps: [String] = []
        EditorHandOffRun.run(
            file, pane: .staysPut, syncManager: FileSyncManager(), paneRoot: folder,
            openDocument: EditorOpenRoute.openPath(document: document, pdf: pdf),
            isRefused: EditorOpenRoute.isRefused(document: document, pdf: pdf),
            paneFolder: { self.folder },
            // The host's settle, reduced to its ordinary case: the flush.
            settle: { steps.append("settle"); _ = EditorAutosave.attempt(document); return true },
            endNaming: {}, showEdit: {},
            load: { steps.append("load"); _ = self.route($0, document, store, pdf) }, log: { _ in })
        await settled(pdf)
        #expect(steps == ["settle", "load"])
        #expect(try String(contentsOfFile: notes, encoding: .utf8) == "second draft",
                "the note's edit was lost when the PDF replaced it")
        #expect(document.path == nil)
        #expect(pdf.path == file)
    }

    // MARK: Text after a PDF

    /// **Opening text after a PDF closes the PDF model and lets its document go.**
    /// Mutation: drop `pdf.close()` from the text arm and the model keeps its document.
    @Test func openingTextAfterAPDFClosesThePDFAndReleasesIt() async throws {
        let file = pdfFile("scan.pdf", pages: 6)
        let notes = try note("after.md", "words")
        let document = EditorDocument(), store = EditorUndoStore()
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        route(file, document, store, pdf)
        await settled(pdf)
        try #require(pdf.phase == .open)

        #expect(route(notes, document, store, pdf) == .text)
        #expect(pdf.path == nil)
        #expect(!pdf.canPrint, "the PDF model still holds a document")
        #expect(document.path == notes)
        #expect(document.text == "words")
        #expect(lines.contains("Editor closed \(file) (PDF) to open \(notes)"))
    }

    // MARK: No save path

    /// **No save path runs while a PDF is open**: ⌘S is gated on the text document's path, which is
    /// nil; autosave's attempt and snapshot have nothing to take; the quit flush is the same
    /// attempt and the same dirty test. Mutation: skip `emptyText` and the note stays open,
    /// dirty, under the PDF — and every line below fails.
    @Test func noSavePathRunsWhileAPDFIsOpen() async throws {
        let notes = try note("draft.md", "draft")
        let file = pdfFile("contract.pdf")
        let document = EditorDocument(), store = EditorUndoStore()
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        route(notes, document, store, pdf)
        document.text = "typed but not written"
        // The route does not settle — the host does that first. Asked here without it, so what is
        // measured is the route's own guarantee: nothing of the note is left to write.
        route(file, document, store, pdf)
        await settled(pdf)

        #expect(document.path == nil, "⌘S is offered: `shortcutSaveDocument` reads this path")
        #expect(!document.canSave)
        #expect(!document.isDirty, "the quit guard would ask about a document nobody can see")
        #expect(EditorAutosave.attempt(document) == .nothingToDo)
        #expect(EditorAutosave.snapshot(of: document) == nil)
        #expect(try String(contentsOfFile: file, encoding: .isoLatin1).hasPrefix("%PDF"),
                "something wrote to the PDF")
    }

    // MARK: Already open, refused, closed

    /// "Already open" and "refused, so let it through again" are asked of whichever model holds
    /// the file — the hand-off's guard, for a PDF as for text.
    @Test func theHandOffGuardAsksWhicheverModelIsOpen() async throws {
        let good = pdfFile("good.pdf")
        let broken = path("broken.pdf")
        try Data("nope".utf8).write(to: URL(fileURLWithPath: broken))
        let document = EditorDocument(), store = EditorUndoStore()
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })

        route(good, document, store, pdf)
        await settled(pdf)
        #expect(EditorOpenRoute.openPath(document: document, pdf: pdf) == good)
        #expect(!EditorHandOffRun.opens(good, openDocument: EditorOpenRoute.openPath(document: document, pdf: pdf),
                                        isRefused: EditorOpenRoute.isRefused(document: document, pdf: pdf)),
                "an open, readable PDF was opened a second time")

        route(broken, document, store, pdf)
        await settled(pdf)
        #expect(EditorOpenRoute.isRefused(document: document, pdf: pdf))
        #expect(EditorHandOffRun.opens(broken, openDocument: EditorOpenRoute.openPath(document: document, pdf: pdf),
                                       isRefused: true),
                "a refused PDF could not be tried again")
    }

    /// The × for a PDF: the model is emptied and the pane's selection of it cleared.
    @Test func closingAPDFClearsThePanesSelectionOfIt() async {
        let file = pdfFile("closing.pdf")
        let document = EditorDocument(), store = EditorUndoStore()
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        route(file, document, store, pdf)
        await settled(pdf)
        var selection: Set<String> = [file]
        #expect(EditorOpenRoute.closePDF(pdf, paneSelection: { selection }, setPaneSelection: { selection = $0 },
                                         log: { self.lines.append($0) }))
        #expect(pdf.path == nil && !pdf.canPrint)
        #expect(selection.isEmpty)
        #expect(lines.last == "Editor closed \(file)")
        #expect(!EditorOpenRoute.closePDF(pdf, paneSelection: { [] }, setPaneSelection: { _ in }, log: { _ in }))
    }
}
