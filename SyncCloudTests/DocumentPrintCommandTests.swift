import AppKit
import Design
import FileExplorer
import Testing
import Foundation
@testable import SyncCloud

/// File ▸ Print… and File ▸ Export as PDF… — where they sit, when they are live, and what they act
/// on (roadmap RD9).
///
/// **The menu half is read off the running app**, as `theFileMenuIsInTheRoadmapsOrder` is and for
/// the same reason: the test host IS the app, so `NSApp.mainMenu` is the menu AppKit built from the
/// `.commands` declarations. A `CommandGroup(replacing: .printItem)` that landed in the wrong menu,
/// or a second item quietly claiming ⌘P, is invisible to a source scan and would ship.
@MainActor
@Suite struct DocumentPrintCommandTests {

    private func fileMenu() throws -> NSMenu {
        try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu,
                     "the app has no File menu — this check would be vacuous")
    }

    // MARK: Where the two items are

    /// Both items are in File, below Save, in the mockup's order.
    @Test func thePrintPairSitsUnderSave() throws {
        let titles = try fileMenu().items.map(\.title).filter { !$0.isEmpty }
        let save = try #require(titles.firstIndex(of: "Save"), "File ▸ Save is gone")
        let export = try #require(titles.firstIndex(of: "Export as PDF…"),
                                  "File ▸ Export as PDF… is gone")
        let print = try #require(titles.firstIndex(of: "Print…"), "File ▸ Print… is gone")
        #expect(save < export && export < print,
                "the group reads \(titles[save...print]) — RD9 puts Export then Print under Save")
    }

    /// **Exactly one item claims ⌘P**, and it is Print. Two would leave one of them dead, and which
    /// AppKit picks is not something this app decides — the same rule `theFileMenuIsInTheRoadmapsOrder`
    /// holds ⌘W to.
    @Test func onlyPrintRegistersTheChord() throws {
        let menu = try fileMenu()
        let claimants = menu.items.filter { $0.keyEquivalent == "p" }
        #expect(claimants.count == 1, "\(claimants.count) File items register ⌘P")
        #expect(claimants.first?.title == "Print…")
        #expect(claimants.first?.keyEquivalentModifierMask == .command,
                "Print's chord is not a bare ⌘P")
    }

    /// Export deliberately has no key equivalent — see `AppChord.printDocument`.
    @Test func exportHasNoChord() throws {
        let export = try #require(try fileMenu().items.first { $0.title == "Export as PDF…" })
        #expect(export.keyEquivalent.isEmpty, "Export as PDF… has acquired a chord")
    }

    /// **Both titles end in an ellipsis**, because both open a dialog before anything happens —
    /// the convention `New Text File…` and `Delete Selection…` already follow here.
    @Test func bothTitlesPromiseTheDialogTheyOpen() throws {
        let titles = try fileMenu().items.map(\.title)
        #expect(titles.contains("Print…") && !titles.contains("Print"))
        #expect(titles.contains("Export as PDF…") && !titles.contains("Export as PDF"))
    }

    /// **⇧⌘P is still the preview column.** ⌘P was taken on the strength of the shifted form being
    /// somebody else's; if these two ever collide the reader loses one of them silently.
    @Test func thePreviewColumnKeepsTheShiftedForm() {
        #expect(AppChord.previewColumn.display == "⇧⌘P")
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

    /// **The rule is the verbs' rule, not a copy of it.** Two rules that happen to agree today are
    /// two rules to keep agreeing; this pins that there is one.
    @Test func theRuleIsTheEditorVerbsOwn() throws {
        let source = try Self.source("EditorPrinting.swift")
        #expect(Self.codeOnly(source).contains("EditorVerbs.isOffered("),
                "the print items have grown a second copy of the offered rule")
    }

    /// The call site actually consults the rule — a rule nothing calls is a rule that cannot fail.
    @Test func theActionsAreResolvedThroughTheRule() throws {
        let body = try Self.memberBody("var shortcutDocumentPrint: DocumentPrintActions?",
                                       in: Self.source("EditorPrinting.swift"))
        #expect(body.contains("DocumentPrintActions.isOffered("),
                "shortcutDocumentPrint decides availability without the rule")
    }

    // MARK: What they act on

    /// **The buffer, not the file on disk.** They differ exactly when there is unsaved typing, and
    /// printing the saved version while a newer one is on screen is the one wrong answer a reader
    /// cannot check without printing it.
    @Test func theJobCarriesTheBufferRatherThanTheSavedText() throws {
        let body = try Self.memberBody("var editorPrintJob: DocumentPDF.Job?",
                                       in: Self.source("EditorPrinting.swift"))
        #expect(body.contains("text: editorDocument.text"),
                "the print job no longer reads the buffer")
        #expect(!body.contains("savedText"),
                "the print job reads the version on disk rather than the one on screen")
    }

    /// **The export goes through the atomic write path**, not through `Data.write(to:)` — a
    /// half-written PDF over a good one is the same loss as a half-written note.
    @Test func theExportWritesThroughTheStore() throws {
        let body = Self.codeOnly(try Self.memberBody("func exportEditorDocumentAsPDF()",
                                                     in: Self.source("EditorPrinting.swift")))
        #expect(body.contains("EditorFileStore.write("),
                "the export writes bytes without the staging, flush and read-back every other write here gets")
        #expect(!body.contains("data.write(to:"), "the export bypasses the store")
    }

    /// The panel opens on the folder the rail is reading, with the document's own name — RD9's
    /// "into the folder the rail is reading", offered rather than imposed.
    @Test func theExportPanelStartsInTheRailsFolder() throws {
        let body = Self.codeOnly(try Self.memberBody("func exportEditorDocumentAsPDF()",
                                                     in: Self.source("EditorPrinting.swift")))
        #expect(body.contains("panel.directoryURL = URL(fileURLWithPath: editorFolder)"),
                "the save panel no longer opens on the folder the rail is reading")
        #expect(body.contains("panel.nameFieldStringValue = job.exportName"),
                "the save panel no longer suggests the document's own name")
    }

    /// **Rendered after the panel is answered.** A cancel must not cost the render, which on a long
    /// document is seconds.
    @Test func theRenderHappensAfterThePanelIsAnswered() throws {
        let body = Self.codeOnly(try Self.memberBody("func exportEditorDocumentAsPDF()",
                                                     in: Self.source("EditorPrinting.swift")))
        let panel = try #require(body.range(of: "panel.runModal()"))
        let render = try #require(body.range(of: "DocumentPDF.data("))
        #expect(panel.lowerBound < render.lowerBound,
                "the document is rendered before the panel opens — a cancel pays for it anyway")
    }

    // MARK: Source helpers

    /// The positive control: every scan above asserts a presence in one file, so a reader that
    /// silently returned the wrong text would make them all pass.
    @Test func theScanCanActuallyFail() throws {
        let source = try Self.source("EditorPrinting.swift")
        #expect(!source.contains("theTextThisFileDoesNotContain"))
        #expect(source.contains("exportEditorDocumentAsPDF"),
                "the scan is not reading EditorPrinting.swift at all")
    }

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return text
    }

    /// Lines with their comments removed, so a scan cannot be satisfied by prose describing the
    /// thing it is looking for — the decoy `ShortcutCommandsTests` documents.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// One member's body: its declaration to the first closing brace at member indentation — the
    /// same slicer the other wiring suites use, so a growing file cannot make a fixed window answer
    /// with a neighbour's text.
    private static func memberBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }")
        return String(rest[..<(end?.upperBound ?? rest.endIndex)])
    }
}
