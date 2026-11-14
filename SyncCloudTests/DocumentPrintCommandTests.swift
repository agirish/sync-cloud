import AppKit
import Design
import FileExplorer
import Testing
import Foundation
@testable import SyncCloud

/// File ▸ Print… and File ▸ Export as PDF…: where they sit, when they are live, and what they act
/// on. The menu half is read off the running app's `NSApp.mainMenu`, since an item in the wrong
/// menu, or a second item claiming ⌘P, is invisible to a source scan.
@MainActor
@Suite struct DocumentPrintCommandTests {

    // MARK: Where the two items are

    /// Both items are in File, below Save, in the mockup's order. Both titles end in an ellipsis,
    /// because both open a dialog before anything happens, as `New Text File…` does.
    @Test func thePrintPairSitsUnderSave() throws {
        let titles = try appMenu("File").items.map(\.title).filter { !$0.isEmpty }
        let save = try #require(titles.firstIndex(of: "Save"), "File ▸ Save is gone")
        let export = try #require(titles.firstIndex(of: "Export as PDF…"),
                                  "File ▸ Export as PDF… is gone")
        let print = try #require(titles.firstIndex(of: "Print…"), "File ▸ Print… is gone")
        #expect(save < export && export < print,
                "the group reads \(titles[save...print]) — RD9 puts Export then Print under Save")
        #expect(!titles.contains("Print") && !titles.contains("Export as PDF"))
    }

    /// Exactly one item claims ⌘P, and it is Print. Two would leave one dead, and AppKit, not the
    /// app, picks which: the rule `theFileMenuIsInTheRoadmapsOrder` holds ⌘W to. Export
    /// deliberately has no key equivalent; see `AppChord.printDocument`.
    @Test func onlyPrintRegistersTheChord() throws {
        let menu = try appMenu("File")
        let claimants = menu.items.filter { $0.keyEquivalent == "p" }
        #expect(claimants.count == 1, "\(claimants.count) File items register ⌘P")
        #expect(claimants.first?.title == "Print…")
        #expect(claimants.first?.keyEquivalentModifierMask == .command,
                "Print's chord is not a bare ⌘P")
        let export = try #require(menu.items.first { $0.title == "Export as PDF…" })
        #expect(export.keyEquivalent.isEmpty, "Export as PDF… has acquired a chord")
    }

    /// Export names the document it exports, so it can't be read as Save as PDF, which writes the
    /// selected pane rows and counts them as PDF Tools does. Greyed, with nothing to export, it
    /// keeps the plain title the menu checks above read.
    @Test func exportNamesItsDocumentAndSaveAsPDFCountsItsFiles() {
        #expect(ExportPDFCommand.title(name: "Plan.md") == "Export “Plan.md” as PDF…")
        #expect(ExportPDFCommand.title(name: nil) == "Export as PDF…")
        #expect(ExportPDFCommand.title(name: "") == "Export as PDF…")
        let long = String(repeating: "a", count: 60) + ".md"
        let title = ExportPDFCommand.title(name: long)
        #expect(title.hasSuffix("a.md” as PDF…"), "a long name lost its extension: \(title)")
        #expect(ExportPDFCommand.shortened(long).count == ExportPDFCommand.longestName)
        #expect(SaveAsPDFOffer.several(paths: ["/a.md", "/b.md", "/c.md"]).title == "Save as PDF · 3 files")
        #expect(PanePDFToolOffer.several(paths: ["/a.pdf", "/b.pdf", "/c.pdf"]).title == "PDF Tools · 3 files")
    }

    /// The window hands Export the open document's name, and only where Export is offered.
    @Test func theWindowHandsExportTheDocumentsName() throws {
        let code = CodeText(try macAppFile("EditorPrinting.swift"))
        #expect(code.contains("export: { exportEditorDocumentAsPDF() }, exportName: editorDocument.name)"))
        #expect(code.contains("DocumentPrintActions(print: { printEditorPDF() }, export: nil)"),
                "a PDF is offered Export, or handed a name to export")
    }

    /// ⌘P is Print, in the plain form.
    @Test func printKeepsThePlainForm() {
        #expect(AppChord.printDocument.display == "⌘P")
    }

    // MARK: When they are live

    /// The gate: Edit on screen, a document open, and something openable in it.
    @Test func theItemsAreOfferedOnlyInEditWithADocument() {
        #expect(DocumentPrintActions.isOffered(workspace: .editor, hasDocument: true, isRefused: false))
        #expect(!DocumentPrintActions.isOffered(workspace: .browse, hasDocument: true, isRefused: false),
                "Print is live from Browse, aimed at a document nobody is looking at")
        #expect(!DocumentPrintActions.isOffered(workspace: .editor, hasDocument: false, isRefused: false))
        #expect(!DocumentPrintActions.isOffered(workspace: .editor, hasDocument: true, isRefused: true),
                "a refused document — cloud-only, too large, not text — has nothing to print")
    }

    /// The rule is the verbs' rule, not a copy. Two rules that agree today are two rules to keep
    /// agreeing; this pins that there is one.
    @Test func theRuleIsTheEditorVerbsOwn() throws {
        let source = try macAppFile("EditorPrinting.swift")
        #expect(sourceCodeOnly(source).contains("EditorVerbs.isOffered("),
                "the print items have grown a second copy of the offered rule")
    }

    /// The call site actually consults the rule; a rule nothing calls can't fail.
    @Test func theActionsAreResolvedThroughTheRule() throws {
        let body = try declarationBody(of: "var shortcutDocumentPrint: DocumentPrintActions?",
                                       in: macAppFile("EditorPrinting.swift"))
        #expect(body.contains("DocumentPrintActions.isOffered("),
                "shortcutDocumentPrint decides availability without the rule")
    }

    // MARK: What they act on

    /// The buffer, not the file on disk. They differ exactly when there is unsaved typing, and
    /// printing the saved version while a newer one is on screen is a mistake nobody sees until it
    /// is printed.
    @Test func theJobCarriesTheBufferRatherThanTheSavedText() throws {
        let body = try declarationBody(of: "var editorPrintJob: DocumentPDF.Job?",
                                       in: macAppFile("EditorPrinting.swift"))
        #expect(body.contains("text: editorDocument.text"),
                "the print job no longer reads the buffer")
        #expect(!body.contains("savedText"),
                "the print job reads the version on disk rather than the one on screen")
    }

    /// The export goes through the atomic write path, not `Data.write(to:)`: a half-written PDF
    /// over a good one is the same loss as a half-written note. The panel opens on the rail's
    /// folder with the document's name, and the render waits for its answer, so a cancel is free.
    @Test func theExportWritesThroughTheStoreAfterThePanel() throws {
        let body = try declarationBody(of: "func exportEditorDocumentAsPDF()", in: macAppFile("EditorPrinting.swift"))
        #expect(body.contains("EditorFileStore.write("),
                "the export writes bytes without the staging, flush and read-back every other write here gets")
        #expect(!body.contains("data.write(to:"), "the export bypasses the store")
        #expect(body.contains("panel.directoryURL = URL(fileURLWithPath: editorFolder)"),
                "the save panel no longer opens on the folder the rail is reading")
        #expect(body.contains("panel.nameFieldStringValue = job.exportName"),
                "the save panel no longer suggests the document's own name")
        let panel = try #require(body.range(of: "panel.runModal()"))
        let render = try #require(body.range(of: "DocumentPDF.data("))
        #expect(panel.lowerBound < render.lowerBound,
                "the document is rendered before the panel opens — a cancel pays for it anyway")
    }
}
