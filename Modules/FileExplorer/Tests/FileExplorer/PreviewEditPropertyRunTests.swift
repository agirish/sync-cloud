import Testing
import AppKit
@testable import FileExplorer

/// **What the property tests found at 50,000 iterations** (TE67, 2026-10-12) — each a seed's
/// failure, made into the smallest case that shows it, through the view as a person drives it.
@MainActor
@Suite(.serialized) struct PreviewEditPropertyRunTests {

    // MARK: F1 — Return on a line that opens two items

    /// **Return on an item whose line opens a second, inner item is refused** — `\t- 2.` is an
    /// empty bullet holding an empty numbered item, drawn as two lines. On either line Return
    /// wrote `\t- ` after the `2.`: a new outer item, below the numbered one — neither the first of
    /// the items under the bullet (TE54) nor the end of the empty numbered list. Markdown has no
    /// way to put a new first item before `2.` without rewriting the line, so nothing is written.
    /// (Seed 46342, step 1.)
    ///
    /// Mutation: take the line's own marker for the item again — the file gains `\n\t- `.
    @Test(arguments: [5, 6])
    func returnOnALineThatOpensTwoItemsIsRefused(at caret: Int) throws {
        let source = "- Café\n\t- 2.\n\nnext"
        let r = PreviewEditRig(source)
        #expect(r.display.hasPrefix("Café\n\n\n"), "\(String(reflecting: r.display))")
        r.view.setSelectedRange(NSRange(location: caret, length: 0))
        try r.run(.returnKey)
        #expect(r.source.text == source, "\(String(reflecting: r.source.text))")
        #expect(r.refusals == [.notSupported])
    }
}

extension PreviewEditPropertyRunTests {

    // MARK: F2 — a space a link's text keeps at a line's edge

    /// **A space inside a link's text is drawn at a line's start, and a deletion elsewhere leaves
    /// it there** — `[ a](u)`: cmark keeps it, unlike the leading spaces of a paragraph's line.
    /// The translator left it alone and the rendering kept it; the property test's reader dropped
    /// it, as it drops every space at a line's edge. (Seed 49198, step 2: a paste of ` more` at the
    /// start of `[#tag]` made `[ moretag]`, and deleting `asta` from `pasta` two lines on failed.)
    @Test func aDeletionElsewhereLeavesALinksLeadingSpace() throws {
        let r = PreviewEditRig("[ a](u) b\n\npasta")
        #expect(r.display == " a b\npasta", "\(String(reflecting: r.display))")
        try r.run(.select("asta"))
        try r.run(.backspace(1))
        #expect(r.source.text == "[ a](u) b\n\np", "\(String(reflecting: r.source.text))")
        #expect(r.display == " a b\np", "\(String(reflecting: r.display))")
    }

    /// **The reader keeps a space the rendering already drew at a line's edge, and drops one the
    /// edit brings there** — which the translator takes with the deletion (T1), link or not.
    ///
    /// Mutation: drop every space at a line's edge, as the reader did — the first two read `a b`
    /// and `b`.
    @Test(arguments: [
        ("[ a](u) b\n\npasta", "asta", " a b\np"),
        ("[ a](u) b", "a", "  b"),
        ("[x a](u) b", "x", "a b"),
        ("q [x a](u)", "q x", "a"),
        ("plain words", "plain", "words"),
    ])
    func theReaderKeepsOnlyTheEdgeSpacesTheRenderingDrew(_ source: String, _ deleted: String, _ expected: String) {
        let p = MarkdownProjection.project(source)
        let range = (p.renderedString as NSString).range(of: deleted)
        let reading = PreviewEditPropertyTests.reading(after: RenderedEdit(range: range, action: .delete), in: p)
        #expect(reading.text == expected, "\(String(reflecting: reading.text))")
        // …and it is what the translator writes renders.
        guard case .apply(let result) = PreviewEditTranslator.translate(RenderedEdit(range: range, action: .delete),
                                                                        in: p, context: PreviewEditContext())
        else { Issue.record("refused"); return }
        #expect(result.projection.renderedString == expected, "\(String(reflecting: result.projection.renderedString))")
    }
}

extension PreviewEditPropertyRunTests {

    // MARK: F3 — an empty item's line, past the part re-read

    /// **A list that runs on into an empty item after the edit's blocks is shown as one list** —
    /// `1. ` typed in Source before `- b` starts a numbered list that the empty `2.` below the blank
    /// line now carries on. The part re-read stops at the `2.`, whose block reads the same; but an
    /// empty item's line is drawn on the break after it, past the part, and that kept the old
    /// list: a list of its own, starting at 2. (Seed 13228 of the wider documents.) The part now
    /// runs on to the block that draws that break — still a part, not the whole.
    ///
    /// Mutation: let the block after the edit prove itself when it draws nothing — the `2.` keeps
    /// the old list.
    @Test(arguments: [("- a\n- b\n\n2.  \nthe\n\n- c", "\n- b", "\n1. - b"),
                      ("- a\n- b\n\n2. \n\nthe", "\n- b", "\n1. b")])
    func aListRunningOnIntoAnEmptyItemAfterTheEditIsOneList(_ text: String, _ target: String, _ replacement: String) {
        let source = EditorSourceStorage(text: text)
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let at = (text as NSString).range(of: target)
        source.replace(at, with: replacement, undoManager: nil)
        PreviewEditSessionReuseTests.expectFresh(session, "\(String(reflecting: text)) → \(String(reflecting: source.text))")
        let old = MarkdownProjection.project(text)
        let next = MarkdownProjection.project(source.text, after: old)
        MarkdownProjectionReuseTests.expectSame(next, MarkdownProjection.project(source.text), "the projection")
        #expect(MarkdownProjectionReuseTests.path(next.reuse) == "partial, first", "\(next.reuse)")
    }
}
