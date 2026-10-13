import Testing
import Foundation
import AppKit
@testable import FileExplorer
import EventsTestSupport

/// **A session typed into for a while still shows what a fresh one would** (TE67 §3.7, 2026-10-07).
///
/// Each keystroke now re-reads part of the source and re-decorates part of the page, so an error
/// would not show at once: it would sit in the kept part and surface later. Chains of random
/// keystrokes, then — Preview's own, and Source's in Split, which reach the session as a change
/// under it — and after each one the session must hold the whole re-read of its source, and its
/// display what decorating that re-read afresh gives — with every list one list to TextKit.
@MainActor
@Suite struct PreviewEditSessionReuseTests {

    private static var iterations: Int {
        (ProcessInfo.processInfo.environment["TE67_PROPERTY_ITERATIONS"].flatMap(Int.init) ?? 2_000) / 4
    }

    @Test func aSessionTypedIntoShowsWhatAFreshOneWould() {
        var steps = 0
        var written = 0
        var overlaid = 0
        let seeds = ProcessInfo.processInfo.environment["TE67_PROPERTY_SEED"].flatMap(UInt64.init).map { [$0] }
            ?? Array(1...UInt64(Self.iterations))
        for seed in seeds {
            var random = SplitMix(seed: seed &+ 0x5E55)
            // Half the seeds: the wider documents (`MarkdownProjectionReuseTests.document`).
            let text = seed % 2 == 0
                ? (0..<random.int(1...3)).map { _ in PreviewEditPropertyTests.document(&random) }.joined(separator: "\n\n")
                : MarkdownProjectionReuseTests.document(&random)
            let source = EditorSourceStorage(text: text)
            let session = PreviewEditSession(source: source, undoManager: UndoManager())
            // Where the last edit left the caret: half the keystrokes go there, as a person types on
            // — which is the only way into a held space or an opened paragraph (review, 2026-10-09:
            // random places never typed into either, so a space held in the wrong place never showed).
            var caret: Int?
            for step in 0..<random.int(2...8) {
                let before = source.text
                let what: String
                let roll = random.int(0...15)
                if roll == 0 {
                    // The window resized: a width every table fits, or one some do not.
                    let width: CGFloat = [120, 300, 676][random.int(0...2)]
                    session.columnWidth = width
                    what = "seed \(seed) step \(step) column \(width): \(String(reflecting: before))"
                } else if roll <= 3 {
                    // Typed in Source, beside: any edit at all, not only one Preview would make.
                    let length = source.textStorage.length
                    let at = random.int(0...length)
                    let cut = random.int(0...2) == 0 ? min(length - at, random.int(1...6)) : 0
                    let inserts = MarkdownProjectionReuseTests.inserts
                    let text = random.int(0...3) == 0 ? "" : inserts[random.int(0...inserts.count - 1)]
                    source.replace(NSRange(location: at, length: cut), with: text, undoManager: nil)
                    caret = nil
                    what = "seed \(seed) step \(step) Source \(at)+\(cut) \(String(reflecting: text)): \(String(reflecting: before)) → \(String(reflecting: source.text))"
                } else {
                    let edit: RenderedEdit
                    if roll <= 5, let at = caret {
                        // On from where the last keystroke left the caret: after a held space, into
                        // an opened paragraph — a letter, or a space (T18's keystroke).
                        edit = RenderedEdit(range: NSRange(location: at, length: 0),
                                            text: random.int(0...2) == 0 ? " " : "a", action: .typing)
                    } else if roll <= 7, !session.projection.blocks.isEmpty {
                        // At a block's end: a space, which is held there, or Return, which opens a
                        // paragraph after it.
                        let block = session.projection.blocks[random.int(0...session.projection.blocks.count - 1)]
                        let at = NSRange(location: NSMaxRange(block.rendered), length: 0)
                        edit = random.int(0...1) == 0 ? RenderedEdit(range: at, text: " ", action: .typing)
                            : RenderedEdit(range: at, action: .returnKey)
                    } else {
                        edit = PreviewEditPropertyTests.edit(&random, in: session.projection).0
                    }
                    if case .select(let selection) = session.perform(edit) { caret = selection.location } else { caret = nil }
                    if source.text != before { written += 1 }
                    what = "seed \(seed) step \(step) \(edit): \(String(reflecting: before)) → \(String(reflecting: source.text))"
                }
                steps += 1
                if session.overlay != nil { overlaid += 1 }
                guard Self.expectFresh(session, what) else { break }
            }
        }
        print("[session] \(written) of \(steps) keystrokes wrote, \(overlaid) left a held space or an opened paragraph")
        // One replayed seed may refuse every keystroke; across them all, most must write.
        if seeds.count > 1 { #expect(written > steps / 4, "only \(written) of \(steps) keystrokes wrote") }
        // And the display is compared with what it holds of its own, too.
        if seeds.count > 1 { #expect(overlaid > steps / 50, "only \(overlaid) of \(steps) keystrokes left an overlay") }
    }

    /// **A space typed at a paragraph's start is neither held nor written** — it renders as nothing
    /// whatever follows it, so the next character went in after it and was refused (review,
    /// 2026-10-09). Held, it once also took the paragraph's spacing away (seeds 806 and 2751,
    /// 2026-10-08): the display must stay what a fresh one would show.
    ///
    /// Mutation: hold the space wherever it renders as nothing, as before.
    @Test func aSpaceAtAParagraphsStartIsNotHeld() {
        let source = EditorSourceStorage(text: "# Title\n\nWords here.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        var refusals: [PreviewRefusal] = []
        session.onRefusal = { reason, _ in refusals.append(reason) }
        let start = (session.projection.renderedString as NSString).range(of: "Words").location
        session.perform(RenderedEdit(range: NSRange(location: start, length: 0), text: " ", action: .typing))
        #expect(!session.display.string.contains(" Words"), "the space is not held")
        Self.expectFresh(session, "after a space at the paragraph's start")
        session.perform(RenderedEdit(range: NSRange(location: start, length: 0), text: "x", action: .typing))
        #expect(source.text == "# Title\n\nxWords here.")
        #expect(refusals.isEmpty, "no hint for a space that could never show")
        Self.expectFresh(session, "after the letter")
    }

    /// **A list split in Source, with a paragraph opened above it, is two lists on screen** — the
    /// redraw compared its far item first, took the old list and the new second half for one, and
    /// kept it: both halves stayed one list and numbered on (seed 1737, 2026-10-10).
    ///
    /// Mutation: widen to whole lists from the redraw's side only (`PreviewListIdentity.oneWay`).
    @Test func aListSplitInSourceUnderAnOpenedParagraphIsTwoLists() {
        let source = EditorSourceStorage(text: "# Title\n## Sub\n\n- the\n\n  > a quote\n- the")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let end = NSMaxRange(session.projection.blocks[1].rendered)
        session.perform(RenderedEdit(range: NSRange(location: end, length: 0), action: .returnKey))
        #expect(session.phantomOffset != nil, "Return opened a paragraph")
        let quote = (source.text as NSString).range(of: "  > a").location
        source.replace(NSRange(location: quote, length: 0), with: "1. ", undoManager: nil)
        Self.expectFresh(session, "a list split in Source under an opened paragraph")
    }

    /// **A keystroke in a long list replaces that item, not the list** — the list keeps its
    /// `NSTextList`, in the projection and on screen, so nothing else is laid out again; 340 ms a
    /// keystroke on a 256 KB note that is one list, when each re-read made the list anew.
    ///
    /// Mutation: replace the whole re-read part in `reprojected`, not `PreviewListIdentity.patch`'s,
    /// and the view's storage takes the whole list.
    @Test func typingInALongListReplacesOnlyThatItem() {
        Self.expectTypingInALongListReplacesOnlyThatItem(after: "End.")
    }

    /// **And where the note is re-read whole at every keystroke** — a reference definition anywhere
    /// in it is enough. The whole re-read made every list anew, and the one typed in was replaced
    /// whole on screen: the 340 ms case, back for any note with a reference link (review, 2026-10-09).
    ///
    /// Mutation: return the whole re-read as it is made, in the session's `kept(_:)`.
    @Test func typingInALongListInANoteReReadWholeReplacesOnlyThatItem() throws {
        let source = "End [x][r].\n\n[r]: https://example.com"
        let old = MarkdownProjection.project("a\n\n" + source)
        #expect((try? old.reread("ab\n\n" + source).get()) == nil, "a definition no longer sends a note the whole way — find another")
        Self.expectTypingInALongListReplacesOnlyThatItem(after: source)
    }

    static func expectTypingInALongListReplacesOnlyThatItem(after tail: String,
                                                            sourceLocation: SourceLocation = #_sourceLocation) {
        let items = (1...200).map { "- Item \($0) with a **bold** word" }.joined(separator: "\n")
        let source = EditorSourceStorage(text: "# Title\n\n\(items)\n\n\(tail)")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        func list() -> NSTextList? {
            (session.display.attribute(.paragraphStyle, at: (session.display.string as NSString).range(of: "Item 1 ").location,
                                       effectiveRange: nil) as? NSParagraphStyle)?.textLists.first
        }
        let before = list()
        var edited = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: session.display, queue: nil) { note in
            edited = max(edited, (note.object as! NSTextStorage).editedRange.length)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let at = (session.display.string as NSString).range(of: "Item 100 ").location + 4
        session.perform(RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing))
        #expect(source.text.contains("Itemx 100 "), sourceLocation: sourceLocation)
        #expect(list() === before, "the list is still the list it was", sourceLocation: sourceLocation)
        #expect(edited < 40, "\(edited) characters of the view's storage replaced", sourceLocation: sourceLocation)
        expectFresh(session, "a keystroke in a long list", sourceLocation: sourceLocation)
    }

    /// **A new column width re-reads nothing, and leaves the typing where it was** (review,
    /// 2026-10-09). Every frame of a live resize re-read the note whole, decorated it whole and
    /// compared it whole; it dropped the space just typed at a line's end; and since the display
    /// kept its lists while the decoration took new ones, the next keystroke in each list replaced
    /// that list on screen. Only what spans the column — a rule — is sized again.
    ///
    /// Mutation: re-read the source on every new width, as `followSource` does.
    @Test func aNewColumnWidthReReadsNothing() throws {
        let items = (1...60).map { "- Item \($0) noted" }.joined(separator: "\n")
        let source = EditorSourceStorage(text: "# Title\n\nWords here\n\n\(items)\n\n---\n\n| a | b |\n|---|---|\n| c | d |\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let rendered = session.projection.rendered
        let end = NSMaxRange((session.display.string as NSString).range(of: "Words here"))
        session.perform(RenderedEdit(range: NSRange(location: end, length: 0), text: " ", action: .typing))
        #expect(session.display.string.contains("Words here \n"), "the space is held")
        let wide = try #require(Self.rule(in: session)).bounds.width

        for width: CGFloat in [600, 500, 420] { session.columnWidth = width }
        #expect(session.projection.rendered === rendered, "re-read for a width no table cares about")
        #expect(session.projection.style.columnWidth == 420)
        #expect(session.display.string.contains("Words here \n"), "the held space is still there")
        let narrow = try #require(Self.rule(in: session)).bounds.width
        #expect(narrow < wide && narrow <= 420, "the rule spans the new column")
        Self.expectFresh(session, "after a resize")

        session.perform(RenderedEdit(range: NSRange(location: end + 1, length: 0), text: "x", action: .typing))
        #expect(source.text.contains("Words here x\n"), "typed after the held space")
        var edited = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: session.display, queue: nil) { note in
            edited = max(edited, (note.object as! NSTextStorage).editedRange.length)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let item = (session.display.string as NSString).range(of: "Item 30 ").location + 4
        session.perform(RenderedEdit(range: NSRange(location: item, length: 0), text: "x", action: .typing))
        #expect(source.text.contains("Itemx 30 "))
        #expect(edited < 40, "\(edited) characters of the view's storage replaced by a keystroke in the list")
        Self.expectFresh(session, "a keystroke after a resize")
    }

    /// **Where a table no longer fits, or fits again, it is re-read** — and what the display holds
    /// of its own stays: the text does not change, only whether the table can be typed in.
    ///
    /// Mutation: keep the projection whatever the width (`restyled` never declining), and the
    /// table stays editable in a column it no longer fits.
    @Test func aColumnATableNoLongerFitsReReadsIt() throws {
        let source = EditorSourceStorage(text: "Words here\n\n| some words here | more words here |\n|---|---|\n| c | d |\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let table = try #require(session.projection.blocks.firstIndex { if case .table = $0.kind { true } else { false } })
        #expect(session.projection.blocks[table].readOnly == nil)
        let end = NSMaxRange((session.display.string as NSString).range(of: "Words here"))
        session.perform(RenderedEdit(range: NSRange(location: end, length: 0), text: " ", action: .typing))
        session.columnWidth = 120
        #expect(session.projection.blocks[table].readOnly == .wideTable)
        #expect(session.display.string.contains("Words here \n"), "the held space is still there")
        Self.expectFresh(session, "a table too wide")
        session.columnWidth = 600
        #expect(session.projection.blocks[table].readOnly == nil)
        #expect(session.display.string.contains("Words here \n"))
        Self.expectFresh(session, "a table that fits again")
    }

    static func rule(in session: PreviewEditSession) -> NSTextAttachment? {
        (0..<session.display.length).lazy.compactMap {
            session.display.attribute(.previewAttachment, at: $0, effectiveRange: nil) as? String == "rule"
                ? session.display.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment : nil
        }.first
    }

    /// **A slow keystroke says why** (review, 2026-10-09): the `[edit]` line names how the source was
    /// re-read — in part, or whole and why — and how much of the display it replaced. A part re-read
    /// declined in seven places, and none of them said so.
    ///
    /// Mutation: leave `redrawNote` out of the line.
    @Test(arguments: [("Para.\n\nWords here.\n\nEnd.", "reuse=partial, redrew 1 of "),
                      ("Para [x][r].\n\nWords here.\n\n[r]: /u", "reuse=whole(definition), redrew 1 of "),
                      ("Words here.\r\n", "reuse=")])
    func aKeystrokeSaysHowItWasReRead(text: String, says: String) async throws {
        // A length no other test's note has, for its line to be told from theirs: they log beside it.
        let filler = String(repeating: "z", count: 7_919 + text.utf16.count)
        let source = EditorSourceStorage(text: filler + "\n\n" + text)
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let at = NSMaxRange((session.display.string as NSString).range(of: "Words"))
        let log = LogCapture()
        session.perform(RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing))
        #expect(source.text.contains("Wordsx"))
        let line = try #require(await log.line(containing: ", \(source.textStorage.length) characters, "))
        #expect(line.hasPrefix("[edit] preview edit "), "\(line)")
        #expect(line.contains(says), "\(line)")
        #expect(line.contains("of \(session.display.length)"), "\(line)")
        #expect(!line.contains("Words"), "the note's text stays out of the log: \(line)")
    }

    /// **A list split in two, or two joined, still numbers right** — the one case where a list
    /// cannot keep its identity, because one new list continues two old ones, or two one. The
    /// first: `1)` starts a list of its own, numbered 1 and 2 again, and every item renders as it
    /// did — compared item by item, nothing changed, and Preview went on showing 3 and 4.
    ///
    /// Mutation: compare lists by shape alone, not by how they pair, and the first case shows 3, 4.
    @Test(arguments: [("1. a\n2. b\n1. c\n2. d", "1. c", "1) c"),
                      ("1. a\n2. b\n1) c\n2) d", "1) c\n2) d", "1. c\n2. d"),
                      ("1. a\n2. b\n3. c\n4. d", "3. c", "c"),
                      ("1. a\n2. b\n\nPara\n\n3. c\n4. d", "\n\nPara\n\n", "\n"),
                      ("- a\n- b\n- c\n- d", "- c", "* c"),
                      ("- a\n- b\n* c\n- d", "* c", "- c")])
    func aListSplitOrJoinedStillNumbersRight(text: String, target: String, replacement: String) {
        let source = EditorSourceStorage(text: "Intro.\n\n\(text)\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        source.replace((source.text as NSString).range(of: target), with: replacement, undoManager: nil)
        Self.expectFresh(session, "\(target) → \(replacement)")
    }

    /// **And after a keystroke elsewhere**, when the display is the last decoration and is compared
    /// only where the decoration changed: a join that shows only in how the items pair — `1)` made
    /// `1.` — looked the same there, item by item, and the display kept two lists (review of the
    /// window, 2026-10-09).
    ///
    /// Mutation: take a window that compares the same for the whole answer, in `splice`.
    @Test(arguments: [("1. a\n2. b\n1. c\n2. d", "1. c", "1) c"),
                      ("1. a\n2. b\n1) c\n2) d", "1) c\n2) d", "1. c\n2. d"),
                      ("- a\n- b\n* c\n- d", "* c", "- c")])
    func aListSplitOrJoinedAfterAKeystrokeStillNumbersRight(text: String, target: String, replacement: String) {
        let source = EditorSourceStorage(text: "Intro.\n\n\(text)\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        session.perform(RenderedEdit(range: NSRange(location: 5, length: 0), text: "s", action: .typing))
        #expect(source.text.hasPrefix("Intros."))
        source.replace((source.text as NSString).range(of: target), with: replacement, undoManager: nil)
        Self.expectFresh(session, "\(target) → \(replacement), after a keystroke")
    }

    /// **Lists that each changed identity are all taken in, in one pass** (review, 2026-10-09) — a
    /// whole re-read used to make every list anew, and widening to whole lists then took in one more
    /// list per round, each round reading the whole rendering: quadratic in the lists. Here every
    /// list is another projection's, and they stand one under another, so each round borders the
    /// next: the closure is the whole note, and its time is printed.
    ///
    /// Mutation: one round only — return after the first widening — and the closure stops short.
    @Test func adjacentListsThatAllChangedAreTakenInWhole() {
        let text = (1...400).map { $0 % 2 == 0 ? "- item \($0)" : "1. item \($0)" }.joined(separator: "\n")
        let session = PreviewEditSession(source: EditorSourceStorage(text: text), undoManager: nil)
        let old = session.decorated(MarkdownProjection.project(text, style: session.style).rendered)
        let fresh = MarkdownProjection.project(text, style: session.style).rendered
        let units = PreviewAttributeShape.units(fresh)
        let first = PreviewEditSession.paragraphs(around: NSRange(location: 0, length: 0), in: units)
        let started = DispatchTime.now().uptimeNanoseconds
        let whole = PreviewListIdentity.wholeLists(around: first, in: fresh, against: old,
                                                   widening: { PreviewEditSession.paragraphs(around: $0, in: units) })
        print("[lists] 400 adjacent lists taken in, \(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)) ms")
        #expect(whole == NSRange(location: 0, length: fresh.length), "\(whole) of \(fresh.length)")
    }

    /// **Marked text the input method left in the display is taken away**, even where it is as long
    /// as what it covered — the display is compared only where the decoration changed while it is
    /// the decoration, and an edit this session did not make means it is not (review, 2026-10-09).
    ///
    /// Mutation: stop watching the display for edits made outside the session.
    @Test func whatAnInputMethodLeftInTheDisplayIsTakenAway() {
        let source = EditorSourceStorage(text: "Para.\n\nWords here.\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let at = NSMaxRange((session.display.string as NSString).range(of: "Words"))
        session.perform(RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing))
        #expect(source.text.contains("Wordsx here."))
        // AppKit puts a composition in the display itself, over the selection: here as long as it.
        let here = (session.display.string as NSString).range(of: "here")
        session.display.replaceCharacters(in: here, with: "にほん")
        session.display.replaceCharacters(in: NSRange(location: here.location, length: 3), with: "ねこ")
        session.display.replaceCharacters(in: NSRange(location: here.location, length: 2), with: "abcd")
        session.redisplay()
        #expect(session.display.string == session.projection.renderedString, "\(String(reflecting: session.display.string))")
        Self.expectFresh(session, "after a composition was cancelled")
    }

    /// **An empty item above a quote ends the list there** — the empty item leaves the
    /// quote below as the list's end, and the next item starts a list of its own. Seen only in how
    /// the items pair, and the window the display was compared in held only the new one: the
    /// display kept the two items one list (seeds 551, 617 and 619 at 10,000, 2026-10-09).
    ///
    /// The empty item is typed in Source now: Return itself no longer writes it, because `- 2.`
    /// opens two items on one line and the bullet it carried on was the outer one, below the
    /// inner (2026-10-12, the 50,000-run; `MarkdownListEdits.returnEdit`).
    ///
    /// Mutation: let `holdsTheSameLists` answer yes, always — **no longer red**, by Return or by
    /// Source, measured 2026-10-12 on the tree before that change too: the display's whole-list
    /// widening (`PreviewListIdentity`) now catches the split on its own.
    @Test func anEmptyItemAboveAQuoteSplitsTheList() {
        let text = "Title\n===\n\n- 2. one f(x)\n\n  > quoted\n- 2. two f(x)\n\nEnd."
        let source = EditorSourceStorage(text: text)
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        source.replace(NSRange(location: NSMaxRange((text as NSString).range(of: "one f(x)")), length: 0),
                       with: "\n- ", undoManager: nil)
        #expect(source.text.contains("one f(x)\n- \n"), "\(String(reflecting: source.text))")
        Self.expectFresh(session, "an empty item above a quote")
    }

    /// **A paragraph that was the tail of a longer one is redrawn too** — a fence typed into a
    /// quote's second line ends the quote's paragraph at its first, and the break that ended the
    /// whole paragraph is now a paragraph of its own; kept as it was, it still wore the quote's
    /// style, which the text system gives a paragraph's last character from its first (seed 2815).
    ///
    /// Mutation: stop `paragraphs(around:in:)` at the paragraph the change ends in.
    @Test func aParagraphCutShortRedrawsTheRestOfIt() {
        let source = EditorSourceStorage(text: "> **pasta**\n>   a b Café\n\n1. one\n2. two\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        source.replace(NSRange(location: 13, length: 0), with: "~~~", undoManager: nil)
        #expect(source.text.hasPrefix("> **pasta**\n>~~~ "))
        Self.expectFresh(session, "a fence typed into a quote")
    }

    /// **A block that turns read-only says so on every line** — a code block in a list, given a tab
    /// in Source that the parser expands, can no longer be mapped and is read-only; only the line
    /// typed on changed, and the decoration redone for it alone left the others looking editable.
    /// And back again when the tab goes.
    ///
    /// Mutation: leave `.previewReadOnly` to the decoration, and line `a` keeps the editable look.
    @Test func aBlockThatTurnsReadOnlyIsMarkedSoOnEveryLine() throws {
        let source = EditorSourceStorage(text: "Intro.\n\n- item\n\n  ```\n  a\n  b\n  ```\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        func readOnly(_ text: String) -> Bool {
            let at = (session.display.string as NSString).range(of: text).location
            return session.display.attribute(.previewReadOnly, at: at, effectiveRange: nil) != nil
                && session.display.attribute(.toolTip, at: at, effectiveRange: nil) as? String
                    == PreviewEditSession.readOnlyTip
        }
        #expect(!readOnly("a\n"))
        source.replace((source.text as NSString).range(of: "  b"), with: "\tb", undoManager: nil)
        let code = try #require(session.projection.blocks.first { if case .codeBlock = $0.kind { true } else { false } })
        #expect(code.readOnly == .unalignable, "the parser no longer expands this tab — find another way in")
        #expect(readOnly("a\n"), "the line not typed on")
        Self.expectFresh(session, "a code block turned read-only")
        source.replace((source.text as NSString).range(of: "\tb"), with: "  b", undoManager: nil)
        #expect(!readOnly("a\n"), "and editable again")
        Self.expectFresh(session, "a code block editable again")
    }

    /// **A picture that could not be shown is looked for again as you type anywhere** — the file
    /// may be written, or downloaded, after the note names it. Every keystroke decorated the whole
    /// page and asked again; once only the changed paragraphs were, a picture elsewhere never was.
    ///
    /// Mutation: drop `retryFailedImages()`, and the picture stays a placeholder.
    @Test func aPictureThatCouldNotBeShownIsLookedForAgainAsYouType() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("te67-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = EditorSourceStorage(text: "![pic](pic.png)\n\nWords.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager(), documentFolder: folder.path)
        var loads = 0
        session.onImageLoaded = { _ in loads += 1 }
        func picture() -> NSImage? {
            let at = (session.display.string as NSString).range(of: "\u{FFFC}").location
            return (session.display.attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment)?.image
        }
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        try await settle { loads == 1 }
        #expect(loads == 1, "the first look, which finds nothing")
        #expect(picture()?.size != NSSize(width: 40, height: 30))

        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try #require(image?.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("pic.png"))
        session.imageRetry = 0
        let words = (session.display.string as NSString).range(of: "Words").location
        session.perform(RenderedEdit(range: NSRange(location: words + 5, length: 0), text: "!", action: .typing))
        #expect(source.text.hasSuffix("Words!."), "the keystroke was written")
        try await settle { loads == 2 }
        #expect(loads == 2, "looked for again")
        #expect(picture()?.size == NSSize(width: 40, height: 30))
    }

    /// **A picture that can never be shown is not looked for again** (review, 2026-10-09) — a
    /// remote URL is refused whatever is on disk, and a README with ten badges was ten loads and ten
    /// whole-display redraws every five seconds of typing.
    ///
    /// Mutation: retry every refusal, as before.
    @Test func aPictureThatCanNeverBeShownIsNotLookedForAgain() async throws {
        let source = EditorSourceStorage(text: "![badge](https://example.com/b.png)\n\nWords.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager(), documentFolder: "/tmp")
        var loads = 0
        session.onImageLoaded = { _ in loads += 1 }
        try await Self.settle { loads == 1 }
        #expect(loads == 1, "the first look")
        session.imageRetry = 0
        for _ in 0..<3 {
            let at = (session.display.string as NSString).range(of: "ords.").location
            session.perform(RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(source.text.hasSuffix("Wxxxords."))
        #expect(loads == 1, "\(loads) looks for a remote picture")
    }

    /// **A picture looked for again and still missing changes nothing on screen** — it was set to
    /// "not looked for" first, so the paragraph typed beside it drew the bare "Image" label until the
    /// look came back, and then every attachment for it was redrawn, the same as before.
    ///
    /// Mutation: forget the refusal before looking again; redraw whatever the look finds.
    @Test func aPictureStillMissingIsNotRedrawn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("te67-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = EditorSourceStorage(text: "Words.\n\n![pic](pic.png)\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager(), documentFolder: folder.path)
        var loads = 0
        session.onImageLoaded = { _ in loads += 1 }
        try await Self.settle { loads == 1 }
        // The picture's alt leads its refusal's label, so the measure is taken with it.
        let refused = PreviewImageAttachment()
        refused.alt = "pic"
        PreviewAttachments.dress(refused, as: .image, scale: 1, columnWidth: session.columnWidth,
                                 reason: "Not found.")
        func width() -> CGFloat? {
            let at = (session.display.string as NSString).range(of: "\u{FFFC}").location
            return (session.display.attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment)?.bounds.width
        }
        #expect(width() == refused.bounds.width, "the first look says why")

        var redrawn = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: session.display, queue: nil) { note in
            if (note.object as! NSTextStorage).editedMask == .editedAttributes { redrawn += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        session.imageRetry = 0
        session.perform(RenderedEdit(range: NSRange(location: 5, length: 0), text: "s", action: .typing))
        #expect(source.text.hasPrefix("Wordss."))
        #expect(width() == refused.bounds.width, "while it is looked for again, it still says why")
        try await Self.settle { loads == 2 }
        #expect(loads == 2, "looked for again")
        #expect(width() == refused.bounds.width)
        #expect(redrawn == 0, "redrawn \(redrawn) times for the same refusal")
    }

    /// **A note given a folder looks again for what it had nowhere to look** — a path with no
    /// folder to resolve against is otherwise never looked for again, and a note saved for the
    /// first time gets one.
    ///
    /// Mutation: leave `documentFolder`'s `didSet` out.
    @Test func aNewFolderLooksAgainForEveryPicture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("te67-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try #require(image?.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("pic.png"))
        let source = EditorSourceStorage(text: "![pic](pic.png)\n\nWords.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager(), documentFolder: nil)
        var loads = 0
        session.onImageLoaded = { _ in loads += 1 }
        try await Self.settle { loads == 1 }
        session.imageRetry = 0
        session.documentFolder = folder.path
        let at = (session.display.string as NSString).range(of: "ords.").location
        session.perform(RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing))
        try await Self.settle { loads == 2 }
        #expect(loads == 2, "looked for again in the new folder")
        let attachment = (session.display.string as NSString).range(of: "\u{FFFC}").location
        #expect((session.display.attribute(.attachment, at: attachment, effectiveRange: nil) as? NSTextAttachment)?
            .image?.size == NSSize(width: 40, height: 30))
    }

    static func settle(until done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Where two renderings first differ, and in what — for a failure to say.
    static func firstDifference(_ a: NSAttributedString, _ b: NSAttributedString) -> String {
        var at = 0
        while at < min(a.length, b.length) {
            var left = NSRange(), right = NSRange()
            let x = a.attributes(at: at, effectiveRange: &left), y = b.attributes(at: at, effectiveRange: &right)
            if !PreviewAttributeShape.same(a.attributedSubstring(from: NSRange(location: at, length: 1)),
                                           b.attributedSubstring(from: NSRange(location: at, length: 1))) {
                let keys = Set(x.keys).union(y.keys).filter {
                    !(x[$0].map { String(describing: $0) } == y[$0].map { String(describing: $0) })
                }
                return " — first at \(at) \(String(reflecting: (a.string as NSString).substring(with: NSRange(location: at, length: 1)))), in \(keys.map(\.rawValue).sorted())" + (ProcessInfo.processInfo.environment["TE67_DETAIL"] != nil ? "\nDISPLAY \(x)\nFRESH \(y)" : "")
            }
            at = min(NSMaxRange(left), NSMaxRange(right))
        }
        return " — in length, \(a.length) against \(b.length)"
    }

    /// The session against a fresh read of its own source.
    @discardableResult
    static func expectFresh(_ session: PreviewEditSession, _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let full = MarkdownProjection.project(session.source.text, style: session.style)
        guard MarkdownProjectionReuseTests.expectSame(session.projection, full, what, sourceLocation: sourceLocation)
        else { return false }
        // Held spaces and an opened paragraph are in the display only — and it must show them
        // where the person put them: a space held into an opened paragraph sat before its line
        // break, and only the next keystroke showed it (review, 2026-10-09).
        // Never both at once, which is what lets every mapping past them be one (round 2).
        guard session.held == nil || session.phantomOffset == nil else {
            Issue.record("held text and an opened paragraph at once: \(what)", sourceLocation: sourceLocation)
            return false
        }
        var meant = full.renderedString as NSString
        if let held = session.held {
            meant = meant.replacingCharacters(in: NSRange(location: min(held.at, meant.length), length: 0), with: held.text) as NSString
        }
        if let phantom = session.phantomOffset {
            meant = meant.replacingCharacters(in: NSRange(location: min(phantom, meant.length), length: 0), with: "\n") as NSString
        }
        guard session.display.string == meant as String else {
            Issue.record("the display reads \(String(reflecting: session.display.string)), not what was typed, \(String(reflecting: meant)): \(what)",
                         sourceLocation: sourceLocation)
            return false
        }
        // Then its look, compared without them. It used to be compared only when there were none,
        // and then not at all (review, 2026-10-09).
        let display = NSMutableAttributedString(attributedString: session.display)
        if let overlay = session.overlay { display.deleteCharacters(in: overlay) }
        guard display.string == full.renderedString else {
            Issue.record("the display's text, held spaces and opened paragraph aside, is not the source's rendering: \(String(reflecting: display.string)) against \(String(reflecting: full.renderedString)): \(what)",
                         sourceLocation: sourceLocation)
            return false
        }
        let fresh = session.decorated(full.rendered)
        guard PreviewAttributeShape.same(display, fresh) else {
            Issue.record("the display differs from a fresh decoration\(firstDifference(display, fresh)): \(what)",
                         sourceLocation: sourceLocation)
            return false
        }
        if fresh.length <= MarkdownProjectionReuseTests.byHandLimit,
           let why = MarkdownProjectionReuseTests.differenceByHand(display, fresh) {
            Issue.record("the display differs from a fresh decoration, compared by hand (\(why)): \(what)",
                         sourceLocation: sourceLocation)
            return false
        }
        guard MarkdownProjectionReuseTests.sameLists(display, fresh) else {
            Issue.record("a list is split across two NSTextLists: \(what)", sourceLocation: sourceLocation)
            return false
        }
        return true
    }
}
