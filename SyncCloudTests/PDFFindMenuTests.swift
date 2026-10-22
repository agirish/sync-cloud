@testable import SyncCloud
import AppKit
import Design
import FileExplorer
import Testing

/// **⌘F, ⌘G, ⇧⌘G and ⌘E with a PDF open in Edit** — `FindMenuRoute` and `PDFFindVerbs`.
///
/// The items are views only a running menu bar builds, so the rules live outside them and the
/// items' bodies are pinned to the rules by a scan, the way `theEditorVerbsAreResolvedThroughTheRule`
/// pins the text menus.
@MainActor
@Suite struct PDFFindMenuTests {

    /// A record of what the verbs were asked to do.
    final class Calls {
        var shown = 0
        var steps: [Bool] = []
        var selections = 0
    }

    private func verbs(searchable: Bool = true, _ calls: Calls, selection: Bool = true) -> PDFFindVerbs {
        PDFFindVerbs(isSearchable: searchable, show: { calls.shown += 1 },
                     step: { calls.steps.append($0) },
                     useSelection: { calls.selections += 1; return selection })
    }

    // MARK: ⌘F

    /// **With a PDF open, ⌘F opens its find bar** — and neither the document's nor the pane's.
    @Test func findOpensThePDFBarWhenAPDFIsOpen() {
        let calls = Calls()
        var asked = (document: 0, pane: 0)
        let went = FindMenuRoute.find(pdf: verbs(calls),
                                      showDocumentFind: { asked.document += 1; return true },
                                      beginPaneSearch: { asked.pane += 1 })
        #expect(went == .pdf)
        #expect(calls.shown == 1)
        #expect(asked.document == 0 && asked.pane == 0)
        #expect(FindMenuRoute.findIsEnabled(pdf: verbs(calls), beginPaneSearch: nil))
    }

    /// **With no document open, ⌘F still opens the pane search** — and the text document's bar
    /// when the caret is in one, exactly as before.
    @Test func findStillOpensThePaneSearchWithNoDocument() {
        var pane = 0
        #expect(FindMenuRoute.find(pdf: nil, showDocumentFind: { false }, beginPaneSearch: { pane += 1 }) == .pane)
        #expect(pane == 1)
        #expect(FindMenuRoute.find(pdf: nil, showDocumentFind: { true }, beginPaneSearch: { pane += 1 }) == .document)
        #expect(pane == 1, "the pane search opened over the text document's find bar")
        #expect(FindMenuRoute.find(pdf: nil, showDocumentFind: { false }, beginPaneSearch: nil) == .nowhere)
        #expect(!FindMenuRoute.findIsEnabled(pdf: nil, beginPaneSearch: nil))
        #expect(FindMenuRoute.findIsEnabled(pdf: nil, beginPaneSearch: {}))
    }

    // MARK: When the PDF verbs exist

    /// **Edit, and the PDF open.** A locked PDF offers no find, and ⌘F there goes to the pane.
    @Test func thePDFVerbsAreOfferedOnlyForAnOpenPDFInEdit() {
        #expect(PDFFindVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .open))
        #expect(!PDFFindVerbs.isOffered(workspace: .browse, hasPDF: true, phase: .open), "offered outside Edit")
        #expect(!PDFFindVerbs.isOffered(workspace: .editor, hasPDF: false, phase: .open))
        #expect(!PDFFindVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .locked), "a locked PDF offers find")
        #expect(!PDFFindVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .loading))
        #expect(!PDFFindVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .refused("gone")))
    }

    // MARK: ⌘G, ⇧⌘G, ⌘E

    /// **Enabled over a text view, or over a PDF with text** — not over an image-only PDF, and not
    /// with nothing open.
    @Test func theStepsAreEnabledWhereThereIsTextToFind() {
        let calls = Calls()
        let text = EditorVerbs(mode: .edit, canPreview: false, setMode: { _ in }, autosave: nil,
                               canMarkUp: false, canFind: true, goToLine: nil)
        let preview = EditorVerbs(mode: .preview, canPreview: true, setMode: { _ in }, autosave: nil,
                                  canMarkUp: false, canFind: false, goToLine: nil)
        #expect(FindMenuRoute.stepsAreEnabled(verbs: text, pdf: nil))
        #expect(!FindMenuRoute.stepsAreEnabled(verbs: preview, pdf: nil))
        #expect(FindMenuRoute.stepsAreEnabled(verbs: nil, pdf: verbs(calls)))
        #expect(!FindMenuRoute.stepsAreEnabled(verbs: nil, pdf: verbs(searchable: false, calls)),
                "an image-only PDF enables ⌘G")
        #expect(!FindMenuRoute.stepsAreEnabled(verbs: nil, pdf: nil))
    }

    /// **A PDF takes ⌘G / ⇧⌘G / ⌘E**; without one they go to the text find bar as before, ⇧⌘G
    /// as its previous match.
    @Test func theStepsGoToThePDFFirst() {
        let calls = Calls()
        var document: [NSTextFinder.Action] = []
        FindMenuRoute.step(forward: true, pdf: verbs(calls)) { document.append($0); return true }
        FindMenuRoute.step(forward: false, pdf: verbs(calls)) { document.append($0); return true }
        FindMenuRoute.useSelection(pdf: verbs(calls)) { document.append($0); return true }
        #expect(calls.steps == [true, false] && calls.selections == 1)
        #expect(document.isEmpty, "a PDF's find verb reached the text view")

        FindMenuRoute.step(forward: true, pdf: nil) { document.append($0); return true }
        FindMenuRoute.step(forward: false, pdf: nil) { document.append($0); return true }
        FindMenuRoute.useSelection(pdf: nil) { document.append($0); return true }
        #expect(document == [.nextMatch, .previousMatch, .setSearchString])
    }

    /// **⌘E with nothing selected in the PDF beeps** (TE204) — and only then.
    @Test func useSelectionBeepsWithNothingSelected() {
        let calls = Calls()
        var beeps = 0
        FindMenuRoute.useSelection(pdf: verbs(calls), refuse: { beeps += 1 }) { _ in true }
        #expect(calls.selections == 1 && beeps == 0, "a selection that was used beeped")
        FindMenuRoute.useSelection(pdf: verbs(calls, selection: false), refuse: { beeps += 1 }) { _ in true }
        #expect(calls.selections == 2 && beeps == 1, "nothing selected was silent")
    }

    // MARK: The items are wired to the rules

    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(file)")
        return sourceCodeOnly(try String(contentsOf: url, encoding: .utf8))
    }

    /// The body of `struct <name>` up to the next top-level declaration.
    private func block(_ name: String, in source: String) throws -> String {
        let start = try #require(source.range(of: "struct \(name): View {"), "\(name) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func theMenuItemsAskTheRules() throws {
        let pane = try source("ContentView+PaneSearch.swift")
        let find = try block("FindInPaneCommand", in: pane)
        #expect(find.contains("@FocusedValue(\\.pdfFind)"))
        #expect(find.contains("FindMenuRoute.find(pdf: pdfFind,"), "⌘F does not route a PDF first")
        #expect(find.contains(".disabled(!FindMenuRoute.findIsEnabled(pdf: pdfFind, beginPaneSearch: begin))"))

        let commands = try source("ShortcutCommands.swift")
        for (item, call) in [("FindNextCommand", "FindMenuRoute.step(forward: true, pdf: pdfFind)"),
                             ("FindPreviousCommand", "FindMenuRoute.step(forward: false, pdf: pdfFind)"),
                             ("UseSelectionForFindCommand", "FindMenuRoute.useSelection(pdf: pdfFind)")] {
            let body = try block(item, in: commands)
            #expect(body.contains(call), "\(item) does not route through FindMenuRoute")
            #expect(body.contains(".disabled(!FindMenuRoute.stepsAreEnabled(verbs: verbs, pdf: pdfFind))"),
                    "\(item) is not enabled by the rule")
        }
        #expect(commands.contains("FindPreviousCommand()"), "Find Previous is not in the Text menu")
        #expect(commands.contains(".focusedSceneValue(\\.pdfFind, effectivePDFFind)"))
        #expect(commands.contains("pdfFind: shortcutPDFFind,"))
    }

    @Test func theFindVerbsAreResolvedThroughTheRule() throws {
        let editor = try source("ContentView+Editor.swift")
        let start = try #require(editor.range(of: "var shortcutPDFFind: PDFFindVerbs? {"),
                                 "shortcutPDFFind is gone — this scan would be vacuous")
        let rest = editor[start.upperBound...]
        let body = String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("PDFFindVerbs.isOffered(workspace: selectedWorkspace, hasPDF: editorPDF.path != nil, phase: editorPDF.phase)"))
        #expect(flat.contains("isSearchable: pdf.facts?.hasText == true"))
        #expect(flat.contains("pdf.find.useSelection(pdf.view.selectedText())"),
                "⌘E does not hand the reader's selection to the find")
        // The text verbs stay a text document's: no PDF branch pretends one is open.
        let text = try #require(editor.range(of: "var shortcutEditorVerbs: EditorVerbs? {"))
        let textBody = editor[text.upperBound...].prefix(400)
        #expect(textBody.contains("guard let path = editorDocument.path"))
        #expect(!textBody.contains("editorPDF"))
    }
}
