import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// **TE60 — the status line counts the selection.** The counts themselves (one rule with the
/// document's), what each rung says, and the ladder the selection joins: its line count goes first,
/// and nothing it adds may push the line past its column.
@MainActor
@Suite struct EditorSelectionCountTests {

    // MARK: The counts

    @Test func aBareCaretHasNoSelectionCounts() {
        #expect(EditorSelectionFacts.of("one two", selection: NSRange(location: 3, length: 0)) == nil)
    }

    /// The selected range alone, by the document's rules: a word cut by the edge is one word, and the
    /// characters are graphemes — the emoji is one.
    @Test func itCountsTheSelectedRangeByTheDocumentsRules() throws {
        let text = "alpha beta 👍 gamma delta"
        // "ta 👍 ga" — part of beta, the emoji, part of gamma.
        let start = (text as NSString).range(of: "ta 👍").location
        let counted = try #require(EditorSelectionFacts.of(text, selection: NSRange(location: start, length: 8)))
        #expect(counted == EditorSelectionFacts(words: 3, characters: 7, lines: 1))
    }

    /// **The lines a selection touches, with a trailing break opening none** — a triple-clicked line
    /// (its text and its newline) is one line, and a selection from the middle of line 1 to the
    /// middle of line 3 is three. CRLF counts as one break, as the document's count has it.
    @Test func itCountsTheLinesTheSelectionTouches() throws {
        let text = "first line\r\nsecond line\r\nthird line\r\n"
        let ns = text as NSString
        let second = ns.range(of: "second line\r\n")
        #expect(EditorSelectionFacts.of(text, selection: second)?.lines == 1,
                "a triple-clicked line read as two")
        let across = NSRange(location: 3, length: ns.range(of: "third").location + 2 - 3)
        #expect(EditorSelectionFacts.of(text, selection: across)?.lines == 3)
        let inLine = NSRange(location: 0, length: 5)
        #expect(EditorSelectionFacts.of(text, selection: inLine)?.lines == 1)
    }

    /// **A selection reported against a longer text than the one read is clamped, never trapped
    /// on** — the two are read at different moments.
    @Test func aSelectionPastTheEndIsClamped() {
        #expect(EditorSelectionFacts.of("abc", selection: NSRange(location: 1, length: 50))
                == EditorSelectionFacts(words: 1, characters: 2, lines: 1))
        #expect(EditorSelectionFacts.of("abc", selection: NSRange(location: 9, length: 5)) == nil)
    }

    /// **⌘A takes the document's own counts when they describe this text**, rather than walking a
    /// 4 MiB buffer for numbers already on screen — and counts afresh when they do not. The facts
    /// handed in are deliberately WRONG for the text, so the two answers differ and the test can
    /// tell which one was given (a fixture whose fallback answers the same cannot fail).
    @Test func aSelectAllReusesTheDocumentsCountsOnlyWhenTheyAreCurrent() {
        let text = "one two three"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let marker = EditorDocumentFacts(words: 900, characters: 901, lines: 902, lineEnding: nil, encoding: nil)
        #expect(EditorSelectionFacts.of(text, selection: all, facts: (marker, 7), version: 7)
                == EditorSelectionFacts(words: 900, characters: 901, lines: 902),
                "a select-all re-counted the buffer")
        #expect(EditorSelectionFacts.of(text, selection: all, facts: (marker, 6), version: 7)
                == EditorSelectionFacts(words: 3, characters: 13, lines: 1),
                "a select-all took counts taken of another text")
        #expect(EditorSelectionFacts.of(text, selection: NSRange(location: 0, length: 3), facts: (marker, 7), version: 7)
                == EditorSelectionFacts(words: 1, characters: 3, lines: 1),
                "a partial selection took the whole document's counts")
    }

    /// **The same length is not the same text** (review): one character typed over a one-character
    /// selection leaves counts of the right length for the wrong text, and a select-all straight
    /// after took them — "one twoxthree"'s 2 words for "one two three"'s 3, and they stayed.
    @Test func aSelectAllAfterALengthPreservingEditCountsTheNewText() throws {
        let before = "one twoxthree"
        let after = "one two three"
        try #require((before as NSString).length == (after as NSString).length)
        let stale = EditorDocumentFacts.of(before, encoding: nil)
        let all = NSRange(location: 0, length: (after as NSString).length)
        #expect(EditorSelectionFacts.of(after, selection: all, facts: (stale, 41), version: 42)?.words == 3)
    }

    /// **The text the app hands over is a text storage's string, not a native one** — and the count
    /// is the same through it: the slice is taken as a Swift string, never through `NSString`, which
    /// walked four times slower (measured, see `EditorSelectionFacts.of`). Edges inside an emoji's
    /// surrogate pair round to the character, as the caret does.
    @Test func aTextStoragesStringCountsTheSameAsANativeOne() throws {
        let native = "naïve 👍 café\nsecond line\n"
        let storage = NSTextStorage(string: native)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "")
        let bridged = storage.string
        for range in [NSRange(location: 2, length: 15), NSRange(location: 7, length: 3), NSRange(location: 0, length: 27)] {
            #expect(EditorSelectionFacts.of(bridged, selection: range) == EditorSelectionFacts.of(native, selection: range),
                    "the storage's string counted \(range) differently")
        }
        #expect(EditorSelectionFacts.of(native, selection: NSRange(location: 2, length: 15))
                == EditorSelectionFacts(words: 4, characters: 14, lines: 2))
    }

    // MARK: What each rung says

    private let facts = EditorDocumentFacts(words: 78, characters: 412, lines: 9, lineEnding: .lf, encoding: "UTF-8")

    /// With no selection the line reads exactly as it did before TE60.
    @Test func withNoSelectionTheCountsAreTheDocuments() {
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: nil, rung: .full, lines: true)
                == ["78 words", "412 characters"])
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: nil, rung: .counts, lines: true)
                == ["78 words"])
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: nil, rung: .caret, lines: true) == [])
    }

    @Test func eachRungSaysTheSelectionInItsOwnWords() {
        let one = EditorSelectionFacts(words: 12, characters: 64, lines: 1)
        let three = EditorSelectionFacts(words: 12, characters: 64, lines: 3)
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: one, rung: .full, lines: true)
                == ["12 of 78 words", "64 characters selected"],
                "a one-line selection grew a line count")
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: three, rung: .full, lines: true)
                == ["12 of 78 words", "64 characters", "3 lines selected"])
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: three, rung: .full, lines: false)
                == ["12 of 78 words", "64 characters selected"])
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: three, rung: .counts, lines: true)
                == ["12 of 78 words selected"])
        #expect(EditorStatusLine.countCaptions(facts: facts, selection: three, rung: .caret, lines: true) == [])
    }

    /// Singular where it is one — "1 of 1 word", "1 character selected" — through the document's own
    /// `count`, so "1 words" cannot come back through this door.
    @Test func oneIsSingular() {
        let tiny = EditorDocumentFacts(words: 1, characters: 1, lines: 1, lineEnding: nil, encoding: nil)
        let sel = EditorSelectionFacts(words: 1, characters: 1, lines: 1)
        #expect(EditorStatusLine.countCaptions(facts: tiny, selection: sel, rung: .full, lines: true)
                == ["1 of 1 word", "1 character selected"])
    }

    /// VoiceOver hears the whole selection — line count included — whatever the rung had room for.
    @Test func voiceOverHearsTheSelection() {
        let label = EditorStatusLine.accessibilityLabel(facts: facts, caret: EditorCaret(line: 4, column: 2),
                                                        selection: EditorSelectionFacts(words: 12, characters: 64, lines: 3))
        #expect(label.hasPrefix("12 of 78 words, 64 characters, 3 lines selected, Line 4, Col 2"), "heard: \(label)")
    }

    /// The line is `.equatable()` — compared on what it draws — so a selection that changed must
    /// make it unequal, or the strip would keep the last selection's counts.
    @Test func aChangedSelectionRedrawsTheLine() {
        let a = EditorStatusLine(facts: facts, caret: EditorCaret(line: 1, column: 1),
                                 selection: EditorSelectionFacts(words: 1, characters: 3, lines: 1))
        var b = a
        b.selection = EditorSelectionFacts(words: 2, characters: 7, lines: 1)
        #expect(a != b)
        b.selection = nil
        #expect(a != b)
    }

    // MARK: The ladder

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }
    private let wide = EditorDocumentFacts(words: 4_218, characters: 24_907, lines: 412,
                                           lineEnding: .crlf, encoding: "UTF-16 LE")
    private let multi = EditorSelectionFacts(words: 1_204, characters: 7_311, lines: 118)

    private func line(_ selection: EditorSelectionFacts?, rung: EditorStatusLine.Rung? = nil,
                      dropsLines: Bool = false, headings: EditorStatusHeadings? = nil) -> EditorStatusLine {
        EditorStatusLine(facts: wide, caret: EditorCaret(line: 408, column: 118), fileSize: "421 bytes",
                         forcedRung: rung, headings: headings, selection: selection,
                         forcedDropsSelectionLines: dropsLines)
    }

    private func ideal(_ view: EditorStatusLine, scale: CGFloat = 1) -> CGFloat {
        NSHostingView(rootView: AnyView(view.environment(\.appFontScale, scale))).fittingSize.width
    }

    /// **Strictly narrowing, with the selection's line count first to go** — or `ViewThatFits`
    /// could never reach a rung — at every text size.
    @Test func theSelectionRungsNarrowInOrder() {
        for scale in scales {
            let widths = [ideal(line(multi, rung: .full), scale: scale),
                          ideal(line(multi, rung: .full, dropsLines: true), scale: scale),
                          ideal(line(multi, rung: .counts), scale: scale),
                          ideal(line(multi, rung: .caret), scale: scale)]
            #expect(widths == widths.sorted(by: >) && Set(widths).count == 4,
                    "at scale \(scale) the selection's rungs measure \(widths)")
        }
    }

    /// **The caret rung is the same with a selection as without** — so the narrowest column the
    /// layout allows still holds the line at every text size, selection or not.
    @Test func theNarrowestRungIsTheCaretAloneWithASelection() {
        for scale in scales {
            let with = ideal(line(multi, rung: .caret), scale: scale)
            #expect(abs(with - ideal(line(nil, rung: .caret), scale: scale)) < 0.5)
            #expect(with <= EditorLayoutMetrics.minDocumentWidth, "at scale \(scale) the caret rung is \(with)pt")
        }
    }

    private func render(_ view: EditorStatusLine, width: CGFloat) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, alignment: .leading)
            .background(Color.white).environment(\.colorScheme, .light)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    /// **Short of room for "118 lines", the line count goes and both counts stay.** Laid out by
    /// width (no forced rung) a little narrower than the rung with lines, the line draws exactly what
    /// the rung without lines draws — the same pixels. With room, it draws the lines (positive
    /// control: the two forced rungs really do differ, so "the same pixels" can fail).
    @Test func theSelectionsLineCountIsTheFirstThingToGo() throws {
        let withLines = ideal(line(multi, rung: .full))
        let without = ideal(line(multi, rung: .full, dropsLines: true))
        let width = (withLines + without) / 2
        let chosen = try #require(render(line(multi), width: width))
        let dropped = try #require(render(line(multi, rung: .full, dropsLines: true), width: width))
        let counts = try #require(render(line(multi, rung: .counts), width: width))
        #expect(differingPixels(chosen, dropped) == 0, "the line did not drop just the line count")
        #expect(differingPixels(chosen, counts) > 50, "the character count went instead of the line count")
        let roomy = try #require(render(line(multi), width: withLines + 40))
        let full = try #require(render(line(multi, rung: .full), width: withLines + 40))
        #expect(differingPixels(roomy, full) == 0, "with room, the line count was not drawn")
        #expect(differingPixels(full, try #require(render(line(multi, rung: .full, dropsLines: true),
                                                          width: withLines + 40))) > 50)
    }

    /// **Beside a heading, too, the line count goes before the counts do** — and the heading still
    /// gives way first: at a width that fits the heading's floor and the counts but not the lines,
    /// the character count is still drawn (the line differs from the counts-only rung).
    @Test func besideAHeadingTheLineCountStillGoesFirst() throws {
        let headings = EditorStatusHeadings(
            outline: [MarkdownOutlineEntry(line: 1, level: 2, depth: 0, title: "Method for the very patient weekend cook")],
            current: 0, offersRailOutline: false, accent: .blue, onSelect: { _ in }, onShowRailOutline: {})
        let floor = EditorStatusLine.headingFloor(scale: 1)
        let without = ideal(line(multi, rung: .full, dropsLines: true))
        let width = without + EditorStatusLine.spacing + floor + 4
        let chosen = try #require(render(line(multi, headings: headings), width: width))
        let counts = try #require(render(line(multi, rung: .counts, headings: headings), width: width))
        let floorFull = try #require(render(line(multi, rung: .full, dropsLines: true, headings: headings), width: width))
        #expect(differingPixels(chosen, counts) > 50, "the character count went before the line count")
        #expect(differingPixels(chosen, floorFull) == 0, "the line did not settle on the heading's floor without lines")
        // …and with room, the line count IS drawn beside the heading: the same counts over one line
        // draw differently from over 118.
        let roomy = without + EditorStatusLine.spacing + 600
        let oneLine = EditorSelectionFacts(words: multi.words, characters: multi.characters, lines: 1)
        #expect(differingPixels(try #require(render(line(multi, headings: headings), width: roomy)),
                                try #require(render(line(oneLine, headings: headings), width: roomy))) > 50,
                "beside a heading, a multi-line selection never shows its line count")
    }

    // MARK: The call site

    /// **The rule is wired**: the workspace hands the line its counted selection and keeps the
    /// selection's length whatever the format bar is doing — a count gated on the bar would be
    /// blank in every plain-text file. Read from the source, comments stripped.
    ///
    /// **And the length is held, not observed** — the workspace keeps the box in `@State` and never
    /// reads its length, so a forward drag's ticks re-render only ``EditorSelectionDerivations``
    /// (measured 11 ms a tick against 0.5 ms, see ``EditorLiveSelection``). `@StateObject`, or a
    /// read of the length in the workspace's body, would bring every tick back to the workspace.
    @Test func theWorkspaceHandsTheLineItsSelection() throws {
        let source = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        #expect(source.contains("selection: selectionFacts, goToLine: statusGoToLine"),
                "the status line is not handed the selection and the Go to Line door")
        #expect(source.contains("EditorSelectionDerivations(document: document, live: liveSelection,"),
                "nothing derives the selection's counts")
        #expect(source.contains("selectionFacts: $selectionFacts, formatState: $formatState)"))
        #expect(ChromeGlassWiringTests.count("liveSelection.set(length: $0.length)", in: source) == 1,
                "Source's selection length is not kept unconditionally")
        #expect(ChromeGlassWiringTests.count("liveSelection.set(length: selection.length)", in: source) == 1,
                "Preview's selection length is not kept unconditionally")
        #expect(!source.contains("showsFormatBar { liveSelection") && !source.contains("showsFormatBar, liveSelection"),
                "the length is still kept only for the bar")
        #expect(source.contains("@State private var liveSelection = EditorLiveSelection()"),
                "the workspace observes the live selection, so every drag tick re-renders it")
        #expect(!source.contains("liveSelection.length"), "the workspace reads the live length")
        let derivations = try ChromeGlassWiringTests.source("EditorSelectionDerivations.swift")
        #expect(derivations.contains("EditorSelectionFacts.of(source, selection: selection, facts: whole, version: current)"))
        // Go to Line's two doors in the workspace answer to the one rule (TE61).
        #expect(source.contains("guard offersGoToLine else { return nil }"), "the status line offers Go to Line in Preview")
        #expect(source.contains("guard offersGoToLine else { return }"), "the menu's press opens the field in Preview")
    }
}
