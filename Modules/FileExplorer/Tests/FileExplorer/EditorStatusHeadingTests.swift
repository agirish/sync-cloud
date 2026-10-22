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
    /// asks it: everywhere but on a list already showing its Outline (TE180) — with the list put
    /// away, whatever tab it would come back on, the item is the way back to it.
    @Test func theRailsOutlineIsOfferedOnlyWhereItWouldChangeSomething() {
        #expect(EditorStatusHeadings.offersRailOutline(showsRail: true, railTab: .files))
        #expect(!EditorStatusHeadings.offersRailOutline(showsRail: true, railTab: .outline))
        #expect(EditorStatusHeadings.offersRailOutline(showsRail: false, railTab: .files))
        #expect(EditorStatusHeadings.offersRailOutline(showsRail: false, railTab: .outline))
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
        #expect(try #require(make([entry("Later", level: 2, line: 5)], caretLine: 2)).help.hasPrefix("The document’s headings"))
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

    // MARK: - The jump, answered once

    /// What the workspace hands the read-only Preview: its blocks and the standing scroll request,
    /// held where the test can change them without rebuilding the preview — as a reload does.
    final class PreviewInput: ObservableObject {
        @Published var blocks: [MarkdownBlock]
        @Published var request: EditorScrollRequest?
        init(blocks: [MarkdownBlock], request: EditorScrollRequest?) {
            self.blocks = blocks
            self.request = request
        }
    }

    private struct PreviewHarness: View {
        @ObservedObject var input: PreviewInput
        var body: some View {
            MarkdownPreview(blocks: input.blocks, accent: .blue, scrollRequest: input.request)
        }
    }

    /// Sixty sections, each a heading and a paragraph — and optionally a paragraph added near the top,
    /// as a save from another app would add one.
    static func sections(addingAParagraph: Bool) -> String {
        var lines: [String] = []
        for i in 0..<60 {
            lines += ["## Section \(i)", "", "Paragraph \(i), with enough words to give it some height.", ""]
        }
        if addingAParagraph { lines.insert(contentsOf: ["Added elsewhere.", ""], at: 2) }
        return lines.joined(separator: "\n")
    }

    private func pump(_ window: NSWindow, _ seconds: Double = 0.5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
    }

    /// Pumps until the preview's offset has held still for half a second, and returns it. A
    /// `scrollTo` into a lazy stack is not one move: SwiftUI keeps re-aiming it as rows are measured,
    /// for longer on a loaded machine — measured: a scroll home taken before it settled was undone,
    /// back to 2582pt, in a full-package run beside two others.
    private func settled(_ scroll: NSScrollView, in window: NSWindow, upTo seconds: Double = 15) async -> CGFloat {
        var last = scroll.contentView.bounds.origin.y
        var still = 0
        let deadline = Date().addingTimeInterval(seconds)
        while still < 5, Date() < deadline {
            await pump(window, 0.1)
            let now = scroll.contentView.bounds.origin.y
            still = now == last ? still + 1 : 0
            last = now
        }
        return last
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView { return found }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    /// **A heading chosen in Preview is gone to once (CHR-1).** Choose one, scroll back up by hand,
    /// and then the file changes elsewhere and gains a paragraph — TE59's quiet reload, which moves
    /// the block count. The reader stays where they scrolled: the request was answered, and the
    /// count is in the scroll's key only so a request made before the blocks arrive is answered
    /// when they do. It sent the reader back to the old line, by then a different block.
    ///
    /// The read-only Preview reads no setting, but Edit in Preview is ON by default, so the suite is
    /// pinned to it off all the same: this is the Preview a reader without editing sees.
    @Test func aChangeFromElsewhereDoesNotGoBackToTheHeadingChosen() async throws {
        let defaults = ScratchDefaults("EditorStatusHeadingTests")
        defaults.set(false, forKey: EditorTextSettings.editsInPreviewKey)
        let before = MarkdownBlocks.blocks(from: Self.sections(addingAParagraph: false))
        let chosen = MarkdownOutline.entries(from: before)[40]
        let input = PreviewInput(blocks: before, request: EditorScrollRequest(line: chosen.line, token: 1))
        let host = NSHostingView(rootView: PreviewHarness(input: input).defaultAppStorage(defaults))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        await pump(window)
        let scroll = try #require(scrollView(in: host), "no scroll view under the preview")
        try #require(await settled(scroll, in: window) > 100, "the heading was not gone to — the test sees nothing")

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try #require(await settled(scroll, in: window) < 1, "the scroll home did not hold")

        input.blocks = MarkdownBlocks.blocks(from: Self.sections(addingAParagraph: true))
        let afterReload = await settled(scroll, in: window)
        #expect(afterReload < 1, "the reload went back to the heading chosen: y = \(afterReload)")

        // And the next choice is still gone to — a new token is a new request.
        input.request = EditorScrollRequest(line: chosen.line, token: 2)
        #expect(await settled(scroll, in: window) > 100, "a second choice of the same heading went nowhere")
    }

    /// The rule on its own: a request is scrolled for until it has been, and again only when a new
    /// one — a new token — arrives.
    @Test func aRequestIsAnsweredOnce() {
        let request = EditorScrollRequest(line: 12, token: 3)
        #expect(MarkdownPreview.shouldScroll(request, answered: nil))
        #expect(!MarkdownPreview.shouldScroll(request, answered: request))
        #expect(MarkdownPreview.shouldScroll(EditorScrollRequest(line: 12, token: 4), answered: request))
        #expect(!MarkdownPreview.shouldScroll(nil, answered: request))
    }

    // MARK: - A jump to where the heading is now

    /// **A finished parse lands unless a later one already has, or the file changed** (CHR-4). A
    /// keystroke during the parse used to throw it away, so steady typing in a long note kept the
    /// outline — and with it this line's "in …" and its menu — on the text before the first key.
    @Test func aFinishedParseLandsUnlessALaterOneHas() {
        #expect(EditorParseLanding.lands(ticket: 4, takenOn: "/n/a.md", current: "/n/a.md", shown: 3),
                "a parse a keystroke overtook was thrown away")
        #expect(!EditorParseLanding.lands(ticket: 4, takenOn: "/n/a.md", current: "/n/a.md", shown: 5),
                "an older parse put its blocks back over a newer one's")
        #expect(!EditorParseLanding.lands(ticket: 6, takenOn: "/n/a.md", current: "/n/b.md", shown: 5),
                "one file's parse landed on another")
        #expect(!EditorParseLanding.lands(ticket: 5, takenOn: "/n/a.md", current: "/n/a.md", shown: 5))
    }

    /// **What the workspace does with the two rules**: the heading menu's jump — the rail's too —
    /// sends the line the heading is on NOW, in Source and in Preview, and the parse lands by the
    /// rule above rather than by whether its task was cancelled.
    @Test func theWorkspaceJumpsToWhereTheHeadingIsAndKeepsAFinishedParse() throws {
        let workspace = try EditorFormatBarTests.source("EditorWorkspaceView.swift")
        let jump = try EditorFormatBarTests.slice(workspace, from: "private func goToHeading(", to: "\n    }\n")
        #expect(jump.contains("let line = MarkdownOutline.line(of: entry, in: document.text)"),
                "the jump does not look for the heading in the text as it stands")
        #expect(jump.contains("EditorScrollRequest(line: line, token: scrollToken)"))
        #expect(jump.contains("utf16Offset(ofLine: line,"), "Preview's caret goes to the outline's line")
        #expect(!jump.contains("entry.line"), "the jump still sends the outline's own line")
        let parse = try EditorFormatBarTests.slice(workspace, from: "MarkdownBlocks.blocks(from: source)",
                                                   to: "outline = MarkdownOutline.entries(from: parsed)")
        #expect(parse.contains("EditorParseLanding.lands("), "the parse lands without the rule")
        #expect(!parse.contains("Task.isCancelled"), "a finished parse is thrown away when a keystroke overtook it")
    }

    // MARK: - The menu, built when it opens

    /// **The line carries the label, and no view per heading** (CHR-7). The item was a SwiftUI
    /// `Menu` with a `Toggle` per heading, drawn in every rung `ViewThatFits` measures — so each
    /// move of the caret into another section re-evaluated every heading up to seven times. Read off
    /// the item's own body type: no `ForEach`, no `Toggle`, no `Menu`.
    @Test func theLineCarriesNoViewPerHeading() throws {
        let many = (0..<50).map { entry("Section \($0)", level: 2, line: $0 * 3 + 1) }
        let item = try #require(make(many, caretLine: 40))
        let drawn = String(describing: type(of: EditorHeadingMenu(headings: item).body))
        #expect(!drawn.contains("ForEach") && !drawn.contains("Toggle"),
                "the heading item builds a view per heading: \(drawn.prefix(240))")
        #expect(!drawn.contains("Menu<"), "the heading item is a SwiftUI Menu again: \(drawn.prefix(240))")
    }

    /// **The menu built at the press is the outline as it stands**: every heading in order, stepped
    /// in by level, the one the caret is in ticked and no other, choosing any — the ticked one too —
    /// going to it, and the rail's Outline item last, after a divider, only where it is offered.
    @Test func theMenuBuiltAtThePressIsTheOutline() throws {
        var picked: [Int] = []
        var shown = 0
        let item = try #require(make(pasta, caretLine: 16, rail: true,
                                     picked: { picked.append($0.line) }, showRail: { shown += 1 }))
        let menu = EditorHeadingMenu.menu(for: item)
        // A menu item's action is sent through the application; run alone, this suite has none yet.
        _ = NSApplication.shared
        #expect(menu.items.map(\.title) == pasta.map(EditorStatusHeadings.menuTitle) + ["", EditorStatusHeadings.railOutlineTitle])
        #expect(menu.items.prefix(3).map(\.state) == [.off, .off, .on])
        #expect(menu.items[3].isSeparatorItem)
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 2)
        #expect(picked == [5, 12], "choosing went to \(picked)")
        menu.performActionForItem(at: 4)
        #expect(shown == 1)

        let later = entry("Later", level: 2, line: 5)
        let above = try #require(make([later], caretLine: 2))
        let plain = EditorHeadingMenu.menu(for: above)
        #expect(plain.items.map(\.title) == [EditorStatusHeadings.menuTitle(later)],
                "the rail's item was offered, or a heading was missing")
        #expect(plain.items.allSatisfy { $0.state == .off }, "a heading is ticked above the first one")
    }

    // MARK: - Through the parse the workspace runs (CHR-8)

    /// What the line says with the caret `extra` UTF-16 units into 1-based `line` of `source` —
    /// through the parse, the outline and the caret derivation the workspace itself runs, rather
    /// than an outline written by hand, which is all the tests above give it.
    private func named(_ source: String, line: Int, extra: Int = 0) throws -> String? {
        let outline = MarkdownOutline.entries(from: MarkdownBlocks.blocks(from: source))
        let start = try #require(EditorCaret.utf16Offset(ofLine: line, in: source), "no line \(line)")
        let caret = EditorCaret.at(utf16Offset: start + extra, in: source)
        return make(outline, caretLine: caret.line)?.title
    }

    /// Each case: a note, where the caret is, and what the line should say. Front matter in all
    /// three line endings, a setext heading and its underline, a `#` in a fenced block, closing
    /// `#`s, emoji and CJK — measured in UTF-16, as the text view reports the caret — headings in a
    /// list item and a quote, and a heading carrying inline HTML.
    nonisolated static let pipelineCases: [(source: String, line: Int, extra: Int, says: String)] = [
        ("---\ntitle: Plan\n---\n\n# Real\nbody\n", 2, 0, "Headings"),
        ("---\ntitle: Plan\n---\n\n# Real\nbody\n", 6, 0, "in Real"),
        ("---\r\ntitle: Plan\r\n---\r\n\r\n# Real\r\nbody\r\n", 2, 0, "Headings"),
        ("---\r\ntitle: Plan\r\n---\r\n\r\n# Real\r\nbody\r\n", 6, 0, "in Real"),
        ("---\rtitle: Plan\r---\r\r# Real\rbody\r", 2, 0, "Headings"),
        ("---\rtitle: Plan\r---\r\r# Real\rbody\r", 6, 0, "in Real"),
        ("Title\n=====\n\npara\n\nSub\n---\n\nmore\n", 2, 0, "in Title"),
        ("Title\n=====\n\npara\n\nSub\n---\n\nmore\n", 7, 0, "in Sub"),
        ("# One\n\n```sh\n# not a heading\n```\n\ntext\n", 4, 0, "in One"),
        ("## Setup ##\n\n# 🎉 発表 — 準備\n\n😀😀 text\n", 1, 0, "in Setup"),
        ("## Setup ##\n\n# 🎉 発表 — 準備\n\n😀😀 text\n", 5, 5, "in 🎉 発表 — 準備"),
        ("- item\n\n  ## Nested\n\n  text\n\n> # Quoted\n> more\n", 5, 0, "in Nested"),
        ("- item\n\n  ## Nested\n\n  text\n\n> # Quoted\n> more\n", 8, 0, "in Quoted"),
        ("## Setup <a id=\"setup\"></a>\n\ntext\n", 3, 0, "in Setup"),
    ]

    /// **The heading the line names, through the real parse** (CHR-8). Mutations: put block lines
    /// back in the body's numbering rather than the file's, or name the section by the last
    /// heading strictly BEFORE the caret's line — each fails cases here.
    @Test(arguments: pipelineCases)
    func theLineNamesTheSectionThroughTheRealParse(_ example: (source: String, line: Int, extra: Int, says: String)) throws {
        let said = try named(example.source, line: example.line, extra: example.extra)
        #expect(said == example.says,
                "\(example.source.debugDescription), caret on line \(example.line): said \(said ?? "nothing")")
    }
}
