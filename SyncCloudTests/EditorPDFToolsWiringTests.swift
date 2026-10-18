import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// **The PDF tools' window half.** `ContentView` cannot be built in a test, so the call sites that
/// connect `EditorPDFTools` to the window are read — a rule one revert away from being unused is not
/// covered by its own test (testing law 5).
@MainActor
@Suite struct EditorPDFToolsWiringTests {

    /// **Every route out of the PDF asks before a pending order or a running tool is lost** — and
    /// asks FIRST, before anything about the text document, which is empty while a PDF is open.
    @Test func everyRouteOutOfThePDFAsksFirst() throws {
        let settle = try EditorDiskWatchWiringTests.body("func settleEditorDocument(asksAboutPDFWork: Bool = true) -> Bool")
        let ask = try #require(settle.range(of: "if asksAboutPDFWork { guard editorPDF.tools.mayLeave() else { return false } }"),
                               "settleEditorDocument no longer asks about the PDF's pending work")
        let compose = try #require(settle.range(of: "editorDocument.buffer.source.endComposition()"))
        #expect(ask.lowerBound < compose.lowerBound, "the PDF is asked about after the text document")

        let close = try EditorDiskWatchWiringTests.body("func closeEditorDocument()")
        let closeAsk = try #require(close.range(of: "guard editorPDF.tools.mayLeave() else { return }"),
                                    "closing a PDF no longer asks about its pending work")
        let closePDF = try #require(close.range(of: "EditorOpenRoute.closePDF(editorPDF,"))
        #expect(closeAsk.lowerBound < closePDF.lowerBound)
    }

    /// **A window close does not ask** — the PDF belongs to the app and outlives the window, so its
    /// order is not at risk, and the red close button never asked either.
    @Test func aWindowCloseDoesNotAskAboutThePDF() throws {
        let tabs = CodeText(try EditorDiskWatchWiringTests.source("ContentView+PaneTabs.swift"))
        #expect(tabs.contains("settle: { settleEditorDocument(asksAboutPDFWork: false) }"))
    }

    /// **⌘Q asks too**, from the delegate, which holds the tools the window adopted.
    @Test func quittingAsksAboutThePDF() throws {
        let app = CodeText(try EditorDiskWatchWiringTests.source("SyncCloudApp.swift"))
        #expect(app.contains("if let tools = Self.sharedPDFTools, !tools.mayLeave() {"))
        #expect(app.contains("return .terminateCancel"))
        let view = CodeText(try EditorDiskWatchWiringTests.source("ContentView.swift"))
        #expect(view.contains("SyncCloudAppDelegate.shared?.adoptPDFTools(editorPDF.tools)"),
                "nothing hands the quit guard the PDF's tools — ⌘Q would never ask")
    }

    /// **A written copy re-lists the rail and the panes, and the banner's doors are the window's
    /// own** — Open through the rail click's door (which asks about the open file first), Reveal
    /// through Reveal in Browse, logged as the banner's.
    @Test func theHostIsTheWindowsOwnDoors() throws {
        let editor = CodeText(try EditorDiskWatchWiringTests.editor())
        #expect(editor.contains(".onAppear { editorPDF.tools.host = editorPDFToolHost }"),
                "the tools are never given the window — a copy would re-list nothing")
        #expect(editor.contains("""
            didWrite: { path in
                Task { await refreshEditorRail() }
                rereadPanesAfterEditorWrite(path)
            },
            """))
        #expect(editor.contains("open: { path in openInEditor(path: path, selectsInPane: true) },"))
        #expect(editor.contains("reveal: { path in revealInBrowse(path, from: .pdfToolBanner) })"))
    }

    /// **A pane-launched batch's Reveal selects every copy beside the first** (TE47's debt with
    /// companions) and may replace the set the batch was run on — a one-file run replaces nothing,
    /// so its Reveal is the one-row rule exactly.
    @Test func thePanesBatchRevealOwesEveryCopyBesideTheFirst() throws {
        let editor = try EditorDiskWatchWiringTests.editor()
        let body = CodeText(try declarationBody(of: "func startPanePDFTool(_ request: PDFToolRequest, paths: [String]) {",
                                                in: editor))
        #expect(body.contains("""
            revealInBrowse(first, with: EditorRevealInBrowse.companions(of: copies),
                           replacing: paths.count > 1 ? Set(paths) : [], from: .pdfToolBanner)
            """), "a batch's Reveal no longer owes its copies, or replaces something other than its own files")
        #expect(body.contains("guard let first = copies.first else { return }"))
    }
}
