@testable import SyncCloud
import AppKit
import Design
import FileExplorer
import PDFKit
import Sync
import Testing

/// ⌘+, ⌘− and ⌘0 while a PDF's pages have the keyboard: `PDFZoomVerbs` and `TextSizeMenuRoute`.
///
/// Everywhere else these chords are View ▸ Text Size (`TextMarkupMenuTests`, `AppChordTests`).
/// With the reader focused they zoom the PDF and leave the text size; otherwise the reverse. Focus
/// is the page view's to say (`EditorPDFLayoutTests.theFocusIsThePagesOwnAndFollowsTheFirstResponder`).
@MainActor
@Suite(.serialized) final class PDFZoomMenuTests {
    let folder = NSTemporaryDirectory() + "pdf-zoom-" + UUID().uuidString
    private let defaults = TestDefaults().defaults

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    /// A record of what the verbs were asked to do.
    final class Calls {
        var zooms: [Bool] = []
        var actual = 0
    }

    private func verbs(_ calls: Calls) -> PDFZoomVerbs {
        PDFZoomVerbs(zoom: { calls.zooms.append($0) }, actualSize: { calls.actual += 1 })
    }

    // MARK: The rule

    /// Edit, the PDF open, and its pages focused: the find's rule and one more condition.
    @Test func theZoomVerbsNeedThePagesToHaveTheKeyboard() {
        #expect(PDFZoomVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .open, readerHasFocus: true))
        #expect(!PDFZoomVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .open, readerHasFocus: false),
                "offered with the pane or the sidebar holding the keyboard")
        #expect(!PDFZoomVerbs.isOffered(workspace: .browse, hasPDF: true, phase: .open, readerHasFocus: true))
        #expect(!PDFZoomVerbs.isOffered(workspace: .editor, hasPDF: false, phase: .open, readerHasFocus: true))
        #expect(!PDFZoomVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .locked, readerHasFocus: true))
    }

    // MARK: Where the keys go

    /// With the verbs, each item zooms the PDF and leaves the text size alone: nil, not a size,
    /// comes back for the item to store.
    @Test func withThePagesFocusedTheKeysZoomThePDF() {
        let calls = Calls()
        for size in [FontSize.medium, FontSize(percent: 90), FontSize(percent: 135)] {
            #expect(TextSizeMenuRoute.perform(.bigger, pdfZoom: verbs(calls), size: size) == nil)
            #expect(TextSizeMenuRoute.perform(.smaller, pdfZoom: verbs(calls), size: size) == nil)
            #expect(TextSizeMenuRoute.perform(.defaultSize, pdfZoom: verbs(calls), size: size) == nil)
        }
        #expect(calls.zooms == [true, false, true, false, true, false])
        #expect(calls.actual == 3)
        // Live at the text size's ends too: those are not the PDF's ends.
        for verb in TextSizeMenuRoute.Verb.allCases {
            #expect(TextSizeMenuRoute.isEnabled(verb, pdfZoom: verbs(calls), size: FontSize(percent: 135)))
            #expect(TextSizeMenuRoute.isEnabled(verb, pdfZoom: verbs(calls), size: .medium))
        }
    }

    /// Without them, the keys are the text size: the step, the default, and the greying at each
    /// end.
    @Test func withoutThemTheKeysAreTheTextSize() {
        let size = FontSize.medium
        #expect(TextSizeMenuRoute.perform(.bigger, pdfZoom: nil, size: size) == size.bigger)
        #expect(TextSizeMenuRoute.perform(.smaller, pdfZoom: nil, size: size) == size.smaller)
        #expect(TextSizeMenuRoute.perform(.defaultSize, pdfZoom: nil, size: FontSize(percent: 120)) == .medium)
        #expect(!TextSizeMenuRoute.isEnabled(.defaultSize, pdfZoom: nil, size: .medium))
        let top = FontSize(percent: FontSize.selectablePercents.last!)
        #expect(!TextSizeMenuRoute.isEnabled(.bigger, pdfZoom: nil, size: top))
        #expect(TextSizeMenuRoute.isEnabled(.smaller, pdfZoom: nil, size: top))
    }

    /// The titles follow the keys.
    @Test func theTitlesFlipWithTheFocus() {
        let calls = Calls()
        #expect(TextSizeMenuRoute.Verb.allCases.map { TextSizeMenuRoute.title($0, pdfZoom: nil) }
                == ["Bigger", "Smaller", "Default Size"])
        #expect(TextSizeMenuRoute.Verb.allCases.map { TextSizeMenuRoute.title($0, pdfZoom: verbs(calls)) }
                == ["Zoom In", "Zoom Out", "Actual Size"])
        #expect(TextSizeMenuRoute.submenuTitle(pdfZoom: nil) == "Text Size")
        #expect(TextSizeMenuRoute.submenuTitle(pdfZoom: verbs(calls)) == "Zoom")
    }

    // MARK: End to end, minus AppKit's focus

    /// An open PDF: focused, ⌘+ steps its zoom ladder and not the text size; unfocused, the text
    /// size steps and the PDF's scale stays. The verbs are resolved the way the window
    /// resolves them (`shortcutPDFZoom` is `PDFZoomVerbs.resolve`, pinned below).
    @Test func theFocusDecidesWhichOneMoves() async throws {
        let pdf = try await openBlankPDF("zoom.pdf", pages: 2, in: folder, defaults: defaults)
        let size = FontSize.medium

        let focused = PDFZoomVerbs.resolve(workspace: .editor, pdf: pdf, readerHasFocus: true)
        #expect(focused != nil)
        #expect(TextSizeMenuRoute.perform(.bigger, pdfZoom: focused, size: size) == nil,
                "⌘+ changed the text size with the pages focused")
        #expect(pdf.view.scale == 1.25 && pdf.view.fit == nil, "⌘+ did not zoom the PDF")
        #expect(TextSizeMenuRoute.perform(.defaultSize, pdfZoom: focused, size: size) == nil)
        #expect(pdf.view.fit == .actual, "⌘0 is not Actual Size on the PDF")

        let unfocused = PDFZoomVerbs.resolve(workspace: .editor, pdf: pdf, readerHasFocus: false)
        #expect(unfocused == nil)
        let before = pdf.view.scale
        #expect(TextSizeMenuRoute.perform(.bigger, pdfZoom: unfocused, size: size) == size.bigger,
                "⌘+ did not change the text size with the pane focused")
        #expect(pdf.view.scale == before, "⌘+ zoomed a PDF whose pages do not have the keyboard")
        pdf.close()
    }

    // MARK: The items are wired to the rules

    private func block(_ name: String, in source: String) throws -> String {
        try declarationBody(of: "struct \(name): View {", in: source)
    }

    /// The items ask the route, on the platform's chords, and the window publishes the verbs from
    /// the reader's focus: the half no rule test can see.
    @Test func theItemsAndTheWindowAreWiredToTheRules() throws {
        let commands = try macAppCode("ShortcutCommands.swift")
        let items = try block("TextSizeCommands", in: commands)
        #expect(items.contains("@FocusedValue(\\.pdfZoom)"))
        #expect(items.contains("TextSizeMenuRoute.perform(verb, pdfZoom: pdfZoom, size: size)"),
                "the items do not route through TextSizeMenuRoute")
        #expect(items.contains("TextSizeMenuRoute.title(verb, pdfZoom: pdfZoom)"))
        #expect(items.contains(".disabled(!TextSizeMenuRoute.isEnabled(verb, pdfZoom: pdfZoom, size: size))"))
        for chord in ["AppChord.textBigger", "AppChord.textSmaller", "AppChord.textDefaultSize"] {
            #expect(items.contains("item(") && items.contains(chord), "\(chord) is not an item's chord")
        }
        let submenu = try block("TextSizeMenuCommand", in: commands)
        #expect(submenu.contains("Menu(TextSizeMenuRoute.submenuTitle(pdfZoom: pdfZoom))"))
        #expect(commands.contains(".focusedSceneValue(\\.pdfZoom, effectivePDFZoom)"))
        #expect(commands.contains("pdfZoom: shortcutPDFZoom,"))

        let flat = CodeText(try macAppCode("ContentView+Editor.swift"))
        #expect(flat.contains("PDFZoomVerbs.resolve(workspace: selectedWorkspace, pdf: editorPDF, readerHasFocus: editorPDFReaderFocused)"))
        let content = try macAppCode("ContentView.swift")
        #expect(content.contains(".onReceive(editorPDF.view.$hasFocus.removeDuplicates()) { editorPDFReaderFocused = $0 }"),
                "the window never hears the reader's focus")
    }
}
