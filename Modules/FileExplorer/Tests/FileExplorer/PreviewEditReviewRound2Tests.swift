import Testing
import AppKit
@testable import FileExplorer
import EventsTestSupport

/// **The second review of Edit in Preview's fixes** (TE67, round 2, 2026-10-10): what the first
/// round's fixes broke, what fell between its batches, and what they logged too often. The edits a
/// person must be able to make are in ``PreviewEditMustAcceptTests`` (`R…` cases); here are the
/// ones that must be REFUSED, and the log.
@MainActor
@Suite(.serialized) struct PreviewEditReviewRound2Tests {

    // MARK: R3 — a pasted line separator is a line break, not a held ⇧Return

    /// **A paste that starts with U+2028 is a paste of two lines** — Pages and Word put one on the
    /// clipboard for a soft return. The translator took any text starting with it for the line
    /// break the session holds, and wrote a hard break into the paragraph. It comes in as LF now,
    /// as Source takes it in, and several lines pasted into a paragraph are refused.
    ///
    /// Mutation: sniff the text for U+2028 again — the paste writes `one  \nx two`.
    @Test func aPasteStartingWithALineSeparatorIsTwoLines() throws {
        let r = PreviewEditRig("one two")
        try r.run(.caretAfter("one"))
        try r.run(.paste("\u{2028}x"))
        #expect(r.source.text == "one two", "\(String(reflecting: r.source.text))")
        #expect(r.refusals == [.notSupported])
    }

    /// **What follows a held line break may not hold another** — it was written raw, a U+2028 in
    /// the file that the preview draws as a line and every other tool reads as none. Pasted, it
    /// comes in as LF and is several lines; typed — the Character Viewer — it is refused the same.
    ///
    /// Mutation: drop the newline check on the text after the break — the U+2028 is written.
    @Test(arguments: [true, false])
    func textWithALineSeparatorAfterAHeldBreakIsRefused(pasted: Bool) throws {
        let r = PreviewEditRig("one")
        try r.run(.caretAfter("one"))
        try r.run(.shiftReturn)
        #expect(r.session.held?.text == "\u{2028}", "the break is held")
        try r.run(pasted ? .paste("x\u{2028}y") : .type("x\u{2028}y"))
        #expect(r.source.text == "one", "\(String(reflecting: r.source.text))")
        #expect(!r.source.text.contains("\u{2028}"))
        #expect(r.refusals == [.notSupported])
    }

    // MARK: R4 — ⇧Return on an opened paragraph

    /// **⇧Return on the empty paragraph Return opened writes nothing and keeps it open** — it
    /// closed the paragraph and held a line break at the end of the one above, so the next letter
    /// went into THAT paragraph, after a hard break (`Para  \nx`).
    ///
    /// Mutation: let ⇧Return close the opened paragraph as any other key does.
    @Test func shiftReturnOnAnOpenedParagraphKeepsItOpen() throws {
        let r = PreviewEditRig("Para")
        try r.run(.caretAfter("Para"))
        try r.run(.returnKey)
        let opened = try #require(r.session.phantomOffset)
        try r.run(.shiftReturn)
        #expect(r.session.phantomOffset == opened, "the opened paragraph closed")
        #expect(r.session.held == nil, "a line break was held somewhere")
        #expect(r.display == "Para\n", "\(String(reflecting: r.display))")
        #expect(r.view.selectedRange() == NSRange(location: opened + 1, length: 0))
        #expect(r.refusals.isEmpty)
    }

    // MARK: R7 — a line verb on an opened paragraph is checked

    /// **A line verb on the paragraph opened after an HTML block that runs on is refused.** An
    /// HTML block opened with `<pre>` runs until `</pre>`, so the heading the verb wrote after it
    /// was taken into the HTML and drawn as `# ` — written all the same, because the line verbs on
    /// an opened paragraph were not checked against anything. Typing there was already refused.
    ///
    /// Mutation: skip the check — the file gains `\n\n# ` inside the HTML.
    @Test func aLineVerbAfterAnHTMLBlockThatRunsOnIsRefused() throws {
        let r = PreviewEditRig("<pre>\nx")
        try r.run(.caretAfter("x"))
        try r.run(.returnKey)
        #expect(r.session.phantomOffset != nil, "Return opened a paragraph")
        try r.run(.verb(.heading(1)))
        #expect(r.source.text == "<pre>\nx", "\(String(reflecting: r.source.text))")
        #expect(r.refusals == [.unverified])
    }

    // MARK: R8 — the log, once per run

    /// **A key held down in text Preview cannot edit logs its first refusal at INFO and the
    /// auto-repeats at debug** — one INFO line per repeat filled the log. Each one still raises
    /// the hint, and after an edit is made the next refusal is news again.
    ///
    /// Mutation: log every refusal at INFO — four lines, not two.
    @Test func aHeldKeyInReadOnlyTextLogsItsFirstRefusalAtInfo() async throws {
        // A paragraph of 1,234 characters first, so the offsets in the lines are this case's own.
        let r = PreviewEditRig(String(repeating: "w", count: 1_234) + "\n\n<div>\nhi\n</div>")
        let log = LogCapture()
        try r.run(.caretAfter("h"))
        for _ in 0..<3 { try r.run(.type("x")) }
        try r.run(.caretAfter("ww"))
        try r.run(.type("y"))
        try r.run(.caretAfter("h"))
        try r.run(.type("x"))
        #expect(r.refusals.count == 4, "every repeat still says why: \(r.refusals)")
        let lines = await log.entries.filter { $0.message.contains("[edit] preview refused typing in HTML at source 1") }
        #expect(lines.map(\.level) == [.info, .debug, .debug, .info], "\(lines.map { "\($0.level) \($0.message)" })")
    }

    /// **A refused Markup verb writes one INFO line**, not the session's and then the view's: the
    /// session's names the verb as the menu does, with the site.
    ///
    /// Mutation: put the view's own line back — two INFO lines.
    @Test func aRefusedMarkupVerbWritesOneInfoLine() async throws {
        let r = PreviewEditRig("one\n\ntwo")
        let log = LogCapture()
        r.view.setSelectedRange(NSRange(location: 1, length: 4))
        try r.run(.verb(.strikethrough))
        #expect(r.refusals == [.crossesBlocks], "the verb was not refused — this case proves nothing")
        let lines = await log.entries.filter { $0.level == .info && $0.message.contains("Strikethrough") }
        #expect(lines.count == 1, "\(lines.map(\.message))")
        #expect(lines.first?.message.contains("[edit] preview refused Markup ▸ Strikethrough in paragraph at source 1: crossesBlocks") == true,
                "\(lines.map(\.message))")
    }

    /// **A stream of style changes from AppKit — the Colors panel dragged across the text — logs
    /// its first at INFO, the rest at debug**, until something is typed.
    ///
    /// Mutation: log each at INFO — three lines.
    @Test func aStreamOfStyleChangesLogsItsFirstAtInfo() async throws {
        let r = PreviewEditRig("one two")
        let log = LogCapture()
        // 1,357 ranges: a count no other case asks for, so the lines are this one's.
        let ranges = (0..<1_357).map { NSValue(range: NSRange(location: 0, length: 1 + $0 % 2)) }
        for _ in 0..<3 {
            #expect(!r.coordinator.textView(r.view, shouldChangeTextInRanges: ranges, replacementStrings: nil))
        }
        try r.run(.caretAfter("one"))
        try r.run(.type("x"))
        #expect(!r.coordinator.textView(r.view, shouldChangeTextInRanges: ranges, replacementStrings: nil))
        #expect(r.source.text == "onex two")
        let lines = await log.entries.filter { $0.message.contains("ignored over 1357 range(s)") }
        #expect(lines.map(\.level) == [.info, .debug, .debug, .info], "\(lines.map { "\($0.level) \($0.message)" })")
    }

    // MARK: R11 — the [edit] line is the keystroke's own

    /// **The `[edit]` line says what THIS keystroke redrew** — a text-size change set the count and
    /// left it, so the next keystroke, refused and redrawing nothing, reported the restyle's.
    ///
    /// Mutation: stop clearing the count at the start of an edit.
    @Test func theEditLineDoesNotCarryARestylesRedraw() async throws {
        // 2,478 characters, for a line this case alone writes.
        let r = PreviewEditRig(String(repeating: "w", count: 2_461) + "\n\n<div>\nhi\n</div>")
        r.session.style = MarkdownProjection.Style(scale: 1.25, columnWidth: r.session.style.columnWidth)
        let log = LogCapture()
        try r.run(.caretAfter("h"))
        try r.run(.type("y"))
        #expect(r.refusals.count == 1, "the keystroke was not refused — this case proves nothing")
        let line = try #require(await log.entries.last { $0.message.contains("2478 characters") }?.message)
        #expect(line.hasSuffix("nothing redrawn"), "\(line)")
    }

    /// **Held text and an opened paragraph are never on screen together** — so what the display
    /// holds of its own is one range, which every mapping uses. Holding a space ends the opened
    /// paragraph, and opening a paragraph drops held spaces.
    @Test func heldTextAndAnOpenedParagraphNeverStandTogether() throws {
        let r = PreviewEditRig("one\n\ntwo")
        try r.run(.caretAfter("one"))
        try r.run(.type(" "))
        #expect(r.session.held != nil, "the space is held")
        try r.run(.caretAfter("two"))
        try r.run(.returnKey)
        #expect(r.session.held == nil && r.session.phantomOffset != nil)
        #expect(r.session.overlay == NSRange(location: try #require(r.session.phantomOffset), length: 1))
        PreviewEditSessionReuseTests.expectFresh(r.session, "an opened paragraph after a held space")
    }
    // MARK: R6 — speed, kept equal

    /// **Halving finds the segment a walk found**, at every offset of notes with empty anchors —
    /// an empty item, an empty cell, an empty heading — pictures, tables, breaks and quotes.
    ///
    /// Mutation: halve on `<` — an offset at a segment's start finds the segment before it.
    @Test func theSegmentAtAnOffsetIsFoundByHalvingAsByWalking() {
        let notes = [PreviewEditSpeedTests.note(bytes: 4_000), PreviewEditSpeedTests.list(bytes: 2_000),
                     "- \n- [ ] \n- x\n\n## \n\n| a |  |\n|---|---|\n|  | b |\n\n> q  \n> r\n\n![i](a) t\n\n```\n\n```",
                     "", "x", "---\na: b\n---\n\ntext <b>bold</b> &amp; more"]
        // And the property test's random documents, every kind of block side by side.
        var random = SplitMix(seed: 67)
        let documents = (0..<300).map { _ in PreviewEditPropertyTests.document(&random) }
        #expect(documents.contains { MarkdownProjection.project($0).segments.contains { $0.rendered.length == 0 } },
                "no empty anchor anywhere — this case proves less")
        for note in notes + documents {
            let p = MarkdownProjection.project(note)
            for offset in 0...(p.renderedString as NSString).length {
                let walked = p.segments.first { $0.rendered.location <= offset && offset < NSMaxRange($0.rendered) }
                #expect(PreviewEditRules.segment(containing: offset, in: p) == walked,
                        "offset \(offset) of \(String(reflecting: note.prefix(40)))")
            }
        }
    }

    /// **A whole re-read made only to check an edit does not keep the lists** — the session keeps
    /// them, for the projection it keeps (`typingInALongListInANoteReReadWholeReplacesOnlyThatItem`).
    ///
    /// Mutation: keep the lists in `project(_:style:after:)` again.
    @Test func aWholeReReadLeavesTheListsToTheSession() {
        let before = MarkdownProjection.project("- a\n- b\n\n[r]: /u")
        let after = MarkdownProjection.project("- ax\n- b\n\n[r]: /u", after: before)
        #expect(after.reuse == .whole("definition"))
        #expect(after.lineage.base == nil, "the lists were kept for a projection only checked")
        #expect(after.keepingLists(of: before).reuse == .whole("definition"), "keeping the lists forgot how it was read")
    }

    /// **The same picture set again keeps the copy it has** — a copy per keystroke for the picture
    /// below a paragraph being typed in — and a new alt makes a new one, which says it.
    ///
    /// Mutation: copy whatever is set.
    @Test func thePictureSetAgainIsNotCopiedAgain() throws {
        let attachment = PreviewImageAttachment()
        attachment.alt = "cat"
        let picture = NSImage(size: NSSize(width: 4, height: 4))
        attachment.image = picture
        let first = try #require(attachment.image)
        #expect(first !== picture && first.accessibilityDescription == "cat")
        attachment.image = picture
        #expect(attachment.image === first, "copied again")
        attachment.alt = "dog"
        attachment.image = picture
        #expect(attachment.image !== first && attachment.image?.accessibilityDescription == "dog")
        let other = NSImage(size: NSSize(width: 2, height: 2))
        attachment.image = other
        #expect(attachment.image?.size == other.size)
    }

    /// **The read-only pieces of the projection a translation starts from are worked out once**,
    /// however many checks the keystroke makes — and still compared by what they say.
    @Test func theReadOnlyPiecesAreWorkedOutOnce() {
        let p = MarkdownProjection.project("x <b> y <i>")
        #expect(p.memo.readOnlyPieces == nil)
        let pieces = PreviewEditTranslator.readOnlyPieces(p)
        #expect(p.memo.readOnlyPieces != nil)
        #expect(pieces.isSubset(of: PreviewEditTranslator.readOnlyPieces(MarkdownProjection.project("y <i> x <b>"))))
        #expect(!pieces.isSubset(of: PreviewEditTranslator.readOnlyPieces(MarkdownProjection.project("x <b> y <u>"))))
    }
}
