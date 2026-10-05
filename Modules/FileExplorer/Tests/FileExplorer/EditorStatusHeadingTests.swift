import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// TE57: the heading the caret is in, leading the status line, as a menu of the document's headings.
@MainActor
@Suite(.serialized) struct EditorStatusHeadingTests {

    private func entry(_ title: String, level: Int, line: Int, depth: Int? = nil) -> MarkdownOutlineEntry {
        MarkdownOutlineEntry(line: line, level: level, depth: depth ?? level - 1, title: title)
    }

    /// Pasta.md's outline, from the mockup.
    private var pasta: [MarkdownOutlineEntry] {
        [entry("Weeknight pasta", level: 1, line: 1), entry("Ingredients", level: 2, line: 5),
         entry("Method", level: 2, line: 12)]
    }

    private func make(_ outline: [MarkdownOutlineEntry], caretLine: Int, isMarkdown: Bool = true,
                      rail: Bool = false, picked: ((MarkdownOutlineEntry) -> Void)? = nil,
                      showRail: (() -> Void)? = nil) -> EditorStatusHeadings? {
        EditorStatusHeadings.make(outline: outline, caretLine: caretLine, isMarkdown: isMarkdown,
                                  offersRailOutline: rail, accent: .blue,
                                  onSelect: picked ?? { _ in }, onShowRailOutline: showRail ?? {})
    }

    // MARK: - What it says

    @Test func itNamesTheHeadingTheCaretIsIn() throws {
        #expect(try #require(make(pasta, caretLine: 16)).title == "in Method")
        #expect(try #require(make(pasta, caretLine: 12)).title == "in Method")
        #expect(try #require(make(pasta, caretLine: 11)).title == "in Ingredients")
        #expect(try #require(make(pasta, caretLine: 1)).current == 0)
    }

    /// Above the first heading the caret is in no section, and the item says "Headings" rather than
    /// claiming the first one — the rail's rule (`MarkdownOutline.currentEntry`).
    @Test func aboveTheFirstHeadingItNamesNone() throws {
        let outline = [entry("Later", level: 2, line: 5)]
        let item = try #require(make(outline, caretLine: 2))
        #expect(item.title == "Headings")
        #expect(item.current == nil)
    }

    /// **No item without a heading to name**: a plain-text file, or Markdown with none yet.
    @Test func itIsShownOnlyForMarkdownWithHeadings() {
        #expect(make(pasta, caretLine: 3, isMarkdown: false) == nil)
        #expect(make([], caretLine: 3) == nil)
        #expect(make(pasta, caretLine: 3) != nil)
    }

    /// The rail's words for a heading with none — the same name in both places.
    @Test func aHeadingWithNoWordsIsNamedAsTheRailNamesIt() throws {
        #expect(try #require(make([entry("", level: 2, line: 7)], caretLine: 8)).title == "in Untitled heading")
    }

    /// VoiceOver hears the name the line shows, from the same entry — and "Headings" for none,
    /// an index out of range included.
    @Test func voiceOverHearsTheSameName() throws {
        #expect(try #require(make(pasta, caretLine: 16)).accessibilityName == "Section: Method")
        #expect(try #require(make([entry("Later", level: 2, line: 5)], caretLine: 2)).accessibilityName == "Headings")
        var stray = try #require(make(pasta, caretLine: 16))
        stray.current = 9
        #expect(stray.accessibilityName == "Headings")
        #expect(stray.title == "Headings")
    }

    /// **The host's rule for the rail's Outline item**, as `EditorWorkspaceView.statusHeadings`
    /// asks it: only with the rail drawn, and not when it is already on its Outline.
    @Test func theRailsOutlineIsOfferedOnlyWhereItWouldChangeSomething() {
        #expect(EditorStatusHeadings.offersRailOutline(showsRail: true, railTab: .files))
        #expect(!EditorStatusHeadings.offersRailOutline(showsRail: true, railTab: .outline))
        #expect(!EditorStatusHeadings.offersRailOutline(showsRail: false, railTab: .files))
        #expect(!EditorStatusHeadings.offersRailOutline(showsRail: false, railTab: .outline))
    }

    /// **Equal when it draws the same, whatever the closures** — so a keystroke that changes
    /// nothing on the line does not rebuild its five rungs — and unequal when it does not.
    @Test func theLineIsComparedOnWhatItDraws() throws {
        let a = try #require(make(pasta, caretLine: 16, picked: { _ in }))
        let b = try #require(make(pasta, caretLine: 16, picked: { _ in Issue.record("never called") }))
        #expect(line(a) == line(b))
        #expect(line(a) != line(try #require(make(pasta, caretLine: 3))))
        #expect(line(a) != line(nil))
    }

    /// Sections step in under the title, one em per level — the depth the rail indents by.
    @Test func lowerHeadingsAreIndented() {
        #expect(EditorStatusHeadings.menuTitle(pasta[0]) == "Weeknight pasta")
        #expect(EditorStatusHeadings.menuTitle(pasta[2]) == "\u{2003}Method")
        #expect(EditorStatusHeadings.menuTitle(entry("Deep", level: 4, line: 9, depth: 3)) == "\u{2003}\u{2003}\u{2003}Deep")
    }

    /// **The menu's items, as the menu builds them**: the heading the caret is in is ticked and
    /// no other, and choosing any item — the ticked one too — goes to that heading, never another.
    @Test func eachItemTicksItsHeadingAndGoesToIt() throws {
        var picked: [Int] = []
        let item = try #require(make(pasta, caretLine: 16, picked: { picked.append($0.line) }))
        #expect(pasta.indices.map { item.choice($0).wrappedValue } == [false, false, true])
        item.choice(1).wrappedValue = true
        item.choice(2).wrappedValue = false
        #expect(picked == [5, 12])
        // An index the outline no longer has goes nowhere.
        item.choice(7).wrappedValue = true
        #expect(picked == [5, 12])
    }

    /// The menu's last item says what it does, and is the rail's own act.
    @Test func theRailItemShowsTheOutline() throws {
        var shown = 0
        let item = try #require(make(pasta, caretLine: 16, rail: true, showRail: { shown += 1 }))
        #expect(item.offersRailOutline)
        item.onShowRailOutline()
        #expect(shown == 1)
    }

    /// **A setext heading's hard break is not a line in the menu**, and the tooltip speaks of the
    /// heading only when there is one to speak of.
    @Test func aNameIsOneLineAndTheTooltipFitsWhatIsShown() throws {
        #expect(EditorStatusHeadings.name(entry("Two\nlines", level: 1, line: 1)) == "Two lines")
        #expect(EditorStatusHeadings.name(entry("  ", level: 1, line: 1)) == "Untitled heading")
        #expect(try #require(make(pasta, caretLine: 16)).help.hasPrefix("The heading the caret is in"))
        #expect(try #require(make([entry("Later", level: 2, line: 5)], caretLine: 2)).help.hasPrefix("The document's headings"))
    }

    // MARK: - The fit

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    private let facts = EditorDocumentFacts(words: 4_218, characters: 24_907, lines: 412,
                                            lineEnding: .crlf, encoding: "UTF-16 LE")

    private func line(_ headings: EditorStatusHeadings?, rung: EditorStatusLine.Rung? = nil) -> EditorStatusLine {
        EditorStatusLine(facts: facts, caret: EditorCaret(line: 408, column: 118), fileSize: "421 bytes",
                         forcedRung: rung, headings: headings)
    }

    private var long: EditorStatusHeadings {
        EditorStatusHeadings(outline: [entry("Method for the very patient weekend cook", level: 2, line: 12)],
                             current: 0, offersRailOutline: false, accent: .blue,
                             onSelect: { _ in }, onShowRailOutline: {})
    }

    private func ideal<V: View>(_ view: V, scale: CGFloat, glass: Bool) -> CGSize {
        NSHostingView(rootView: AnyView(view.environment(\.appFontScale, scale)
            .environment(\.selectionLensAppearance, glass ? SelectionLensCallSiteTests.probe : .today))).fittingSize
    }

    /// How far the menu's focus ring reaches past the space the line gives it: its hover wash's
    /// padding, taken back outside it (`EditorHeadingMenu`). Measured, not assumed.
    private func outset(scale: CGFloat, glass: Bool) throws -> CGFloat {
        let menu = EditorHeadingMenu(headings: long).scaledFont(.system(size: 10))
        let host = NSHostingView(rootView: AnyView(menu.fixedSize().environment(\.appFontScale, scale)
            .environment(\.selectionLensAppearance, glass ? SelectionLensCallSiteTests.probe : .today)))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 40)
        host.layoutSubtreeIfNeeded()
        let ring = try #require(rings(in: host).first)
        return ring.width - ideal(menu, scale: scale, glass: glass).width
    }

    private func rings(in host: NSView) -> [NSRect] {
        var rings: [NSRect] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains("FocusRing") {
                rings.append(view.convert(view.bounds, to: host))
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return rings
    }

    /// The heading menu's DRAWN width inside a line `width` points wide — read off its focus ring,
    /// the one handle a hosted SwiftUI button leaves (see `OpenInEditorVerbTests`).
    private func drawnHeading(width: CGFloat, scale: CGFloat, glass: Bool,
                              headings: EditorStatusHeadings? = nil, caret: EditorCaret? = nil) -> CGRect? {
        let line = EditorStatusLine(facts: facts, caret: caret ?? EditorCaret(line: 408, column: 118),
                                    fileSize: "421 bytes", headings: headings ?? long)
        let host = NSHostingView(rootView: AnyView(line.frame(width: width)
            .environment(\.appFontScale, scale)
            .environment(\.selectionLensAppearance, glass ? SelectionLensCallSiteTests.probe : .today)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 40)
        host.layoutSubtreeIfNeeded()
        let found = rings(in: host)
        return found.count == 1 ? found[0] : nil
    }

    /// **The heading truncates FIRST: short of room for everything, the name shrinks and both
    /// counts stay.** At a width 40pt short of the full line, the heading is drawn exactly as wide
    /// as the FULL rung leaves it — if the character count had gone instead, it would have had room
    /// for its whole name.
    @Test(arguments: [false, true])
    func theHeadingTruncatesBeforeAnyCountGoes(glass: Bool) throws {
        for scale in [CGFloat(1), FontSize.allCases.last!.scale] {
            let full = ideal(line(nil, rung: .full), scale: scale, glass: glass).width
            let whole = ideal(EditorHeadingMenu(headings: long).scaledFont(.system(size: 10)),
                              scale: scale, glass: glass).width
            let width = full + EditorStatusLine.spacing + whole - 40
            let drawn = try #require(drawnHeading(width: width, scale: scale, glass: glass),
                                     "no heading drawn at scale \(scale)")
            // What the FULL rung leaves (`full` carries the line's padding once). A truncated name
            // is a whole number of glyphs, so it can come in under that by up to one — and had the
            // counts rung been chosen instead, it would be 40pt OVER it, with room for every letter.
            let left = width - full - EditorStatusLine.spacing + (try outset(scale: scale, glass: glass))
            #expect(drawn.width <= left + 1 && drawn.width >= left - 12,
                    "at scale \(scale) the heading is \(drawn.width)pt; the full rung leaves \(left)")
            #expect(drawn.width < whole - 30, "the heading was not truncated at scale \(scale)")
        }
    }

    /// **And at the narrowest column the layout allows, the heading still fits beside the narrowest
    /// rung at its floor, at every text size** — nothing past the line's edge.
    @Test(arguments: [false, true])
    func theHeadingFitsBesideTheNarrowestRung(glass: Bool) throws {
        let width = EditorLayoutMetrics.minDocumentWidth
        for scale in scales {
            let caret = ideal(line(nil, rung: .caret), scale: scale, glass: glass).width
            #expect(caret + EditorStatusLine.spacing + EditorStatusLine.headingFloor(scale: scale) <= width,
                    "the caret rung (\(caret)pt) and the heading's floor overflow \(width)pt at scale \(scale)")
            let drawn = try #require(drawnHeading(width: width, scale: scale, glass: glass))
            #expect(drawn.width - (try outset(scale: scale, glass: glass)) >= EditorStatusLine.headingFloor(scale: scale) - 2,
                    "the heading fell below its floor at scale \(scale): \(drawn.width)pt")
            #expect(drawn.maxX <= width - caret + 14 + 4, "the heading ran into the caret at scale \(scale)")
        }
    }

    /// **The floor is held: where the full rung fits but leaves the name less than its floor, the
    /// character count goes instead** — the heading is never squeezed to an ellipsis beside counts
    /// that could have given way.
    @Test(arguments: [false, true])
    func theFloorIsHeldBeforeTheCharacterCountIsKept(glass: Bool) throws {
        for scale in [CGFloat(1), FontSize.allCases.last!.scale] {
            let full = ideal(line(nil, rung: .full), scale: scale, glass: glass).width
            let floor = EditorStatusLine.headingFloor(scale: scale)
            let width = full + EditorStatusLine.spacing + floor / 2
            let drawn = try #require(drawnHeading(width: width, scale: scale, glass: glass))
            #expect(drawn.width - (try outset(scale: scale, glass: glass)) >= floor - 2,
                    "at scale \(scale) the heading was squeezed to \(drawn.width)pt beside the full rung")
        }
    }

    /// **A caret longer than the narrowest rung was measured with still fits** — "Line 12408,
    /// Col 11800" at the largest text size, in the narrowest column: the heading gives up its name
    /// (the last rung) rather than push the line past the column.
    @Test(arguments: [false, true])
    func aLongCaretNeverPushesTheLinePastTheColumn(glass: Bool) throws {
        let width = EditorLayoutMetrics.minDocumentWidth
        let longCaret = EditorCaret(line: 12_408, column: 11_800)
        for scale in scales {
            let caretRung = ideal(EditorStatusLine(facts: facts, caret: longCaret, fileSize: "421 bytes",
                                                   forcedRung: .caret), scale: scale, glass: glass).width
            let drawn = try #require(drawnHeading(width: width, scale: scale, glass: glass, caret: longCaret),
                                     "no heading drawn at scale \(scale)")
            // 14 = the line's leading padding; the caret rung's own width carries both paddings.
            #expect(drawn.maxX - (try outset(scale: scale, glass: glass)) / 2 + EditorStatusLine.spacing
                    <= width - (caretRung - 28) - 14 + 1,
                    "at scale \(scale) the heading ends at \(drawn.maxX) and the caret needs \(caretRung - 28)pt")
        }
    }

    /// **A name shorter than the floor costs only its own width**: the full rung is kept wherever
    /// the name and the counts fit, floor or no floor.
    @Test func aShortNameCostsOnlyItsWidth() throws {
        let short = EditorStatusHeadings(outline: [entry("A", level: 1, line: 1)], current: 0,
                                         offersRailOutline: false, accent: .blue,
                                         onSelect: { _ in }, onShowRailOutline: {})
        let natural = ideal(EditorHeadingMenu(headings: short).scaledFont(.system(size: 10)), scale: 1, glass: false).width
        #expect(natural < EditorStatusLine.headingFloor(scale: 1), "the name is not short, so this proves nothing")
        let full = ideal(line(nil, rung: .full), scale: 1, glass: false).width
        let width = full + EditorStatusLine.spacing + natural + 1
        let drawn = try #require(drawnHeading(width: width, scale: 1, glass: false, headings: short))
        #expect(abs(drawn.width - (try outset(scale: 1, glass: false)) - natural) <= 2,
                "the short name was drawn \(drawn.width)pt, not its own \(natural)pt")
        // **And the counts beside it are the FULL rung's**: drawn at this width and at a width with
        // room to spare, the line's first `width` points are the same pixels. Had the character
        // count gone, they would not be.
        let tight = try #require(render(line(short), width: width))
        let roomy = try #require(render(line(short), width: width + 200))
        #expect(differingPixels(tight, roomy, width: width) == 0,
                "the line changed rung at \(width)pt with a name narrower than the floor")
    }

    /// The positive control for the pixel comparison: a width that DOES drop the character count
    /// renders differently from one with room, so "the same pixels" above can fail.
    @Test func thePixelComparisonSeesARungChange() throws {
        let full = ideal(line(nil, rung: .full), scale: 1, glass: false).width
        let width = full - 40
        let tight = try #require(render(line(nil), width: width))
        let roomy = try #require(render(line(nil), width: width + 200))
        #expect(differingPixels(tight, roomy, width: width) > 50)
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

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, width: CGFloat) -> Int {
        let columns = min(Int(width * a.size.width == 0 ? 0 : CGFloat(a.pixelsWide) / a.size.width * width),
                          a.pixelsWide, b.pixelsWide)
        var count = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<columns where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
        }
        return count
    }

    /// The positive control: with room for everything, the whole name is drawn.
    @Test func withRoomTheWholeNameIsDrawn() throws {
        let whole = ideal(EditorHeadingMenu(headings: long).scaledFont(.system(size: 10)), scale: 1, glass: false).width
        let drawn = try #require(drawnHeading(width: 1_200, scale: 1, glass: false))
        #expect(abs(drawn.width - (try outset(scale: 1, glass: false)) - whole) <= 2, "drawn \(drawn.width)pt of \(whole)pt")
    }
}
