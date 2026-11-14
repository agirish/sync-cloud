import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// What the Editor's chrome actually measures, at every text size the app offers. The workspace's
/// logic tests can't see a header that wraps, a capsule that outgrows its column, or a rail that
/// stops matching the number the layout clamps against; these rendered tests can.
@MainActor
@Suite(.serialized) struct EditorLayoutTests {

    /// Every Settings ▸ Text size, which is the axis these measurements move along.
    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    private func size<V: View>(_ view: V, width: CGFloat? = nil) -> CGSize {
        let hosted = NSHostingView(rootView: AnyView(
            width.map { AnyView(view.frame(width: $0)) } ?? AnyView(view)
        ))
        return hosted.fittingSize
    }

    // MARK: The rail

    private func rail(entries: [EditorRailEntry], naming: Bool = false,
                      outline: [MarkdownOutlineEntry] = [],
                      tab: EditorRailTab = .files,
                      selected: String?? = nil) -> EditorFileRailView {
        EditorFileRailView(
            folderName: "Notes",
            entries: entries,
            selectedPath: selected ?? entries.first?.path,
            accent: .blue,
            accentFill: .blue,
            onAccent: .white,
            tab: .constant(tab),
            isNaming: .constant(naming),
            typedName: .constant(""),
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            filter: .constant(""),
            filterIsExpanded: .constant(false),
            outline: outline,
            outlineAnchors: .constant([:]),
            onOpen: { _ in },
            onCreate: { _ in true },
            onNewTextFile: nil, folderTrail: nil, onGoToFolder: nil,
            rowActions: .inert)
    }

    private func heading(_ title: String, level: Int = 1, line: Int) -> MarkdownOutlineEntry {
        MarkdownOutlineEntry(line: line, level: level, depth: level - 1, title: title)
    }

    private func entry(_ name: String, size: Int = 120) -> EditorRailEntry {
        EditorRailEntry(path: "/a/\(name)", name: name, size: size, isCloudOnly: false)
    }

    /// The drawn rail is the width the layout reserves, and the rows are really in it. The width
    /// alone is a tautology (the body ends in `.frame(width: Self.width)`, which is `railWidth`);
    /// the height, which the frame doesn't pin, is what fails if the rail stops drawing its rows.
    @Test func theRailDrawsAtTheReservedWidthWithItsRowsInIt() {
        let one = size(rail(entries: [entry("one.md")]))
        let three = size(rail(entries: [entry("one.md"), entry("two.md"), entry("three.md")]))
        // The outline tab draws at the same width: neither tab's content escapes the hard frame.
        let outlined = size(rail(entries: [entry("one.md")],
                                 outline: (1...3).map { heading("Row \($0)", line: $0) },
                                 tab: .outline))

        #expect(abs(one.width - EditorLayoutMetrics.railWidth) < 0.51,
                "the rail draws \(one.width)pt against the \(EditorLayoutMetrics.railWidth)pt the layout reserves")
        #expect(abs(three.width - EditorLayoutMetrics.railWidth) < 0.51,
                "three rows widened the rail to \(three.width)pt")
        #expect(three.height > one.height,
                "three rows measure the same as one (\(three.height)pt) — the rows are not drawn, so the width assertion above is measuring an empty frame")
        #expect(abs(outlined.width - EditorLayoutMetrics.railWidth) < 0.51,
                "the outline tab drew at \(outlined.width)")
    }

    /// A long file name truncates rather than wrapping, measured in height: the rail is hard
    /// framed, so a wrapped name is no wider, only taller. The two-row control stops this passing
    /// on a rail that draws nothing.
    @Test func aLongFileNameTruncatesRatherThanWrappingTheRow() {
        let short = size(rail(entries: [entry("a.md")])).height
        let long = size(rail(entries: [entry(String(repeating: "verylongname", count: 12) + ".md")])).height
        let two = size(rail(entries: [entry("a.md"), entry("b.md")])).height

        #expect(abs(short - long) < 0.51,
                "a long name grew the row from \(short)pt to \(long)pt — it is wrapping, not truncating")
        #expect(two > short,
                "a second row did not make the rail taller (\(two)pt vs \(short)pt) — height is not measuring the rows, so the comparison above proves nothing")
    }

    /// A card really costs a `cardGutter`, measured rather than restated. `minDocumentOnlyWidth`
    /// budgets one per card, which rests on `bottomSectionCard` (a Design component) insetting half
    /// a gutter each side in Cards. If that changes, the floor would promise a document column it
    /// then shaves. In Unified the cards sit flush and cost nothing, which the floor also covers.
    @Test func aCardCostsExactlyTheGutterTheWorkspaceMinimumBudgetsForIt() {
        let bare = size(Color.clear.frame(width: 200, height: 40))
        let carded = size(Color.clear.frame(width: 200, height: 40)
            .bottomSectionCard(.cards, level: .frosted, hue: .graphite, tint: 0))
        let flush = size(Color.clear.frame(width: 200, height: 40)
            .bottomSectionCard(.unified, level: .frosted, hue: .graphite, tint: 0))
        #expect(flush == bare, "a Unified section costs \(flush.width - bare.width)pt; it should sit flush")

        #expect(abs((carded.width - bare.width) - LiquidGlass.cardGutter) < 0.51,
                "a card costs \(carded.width - bare.width)pt of width, not the \(LiquidGlass.cardGutter)pt `minDocumentOnlyWidth` budgets for it")
    }

    /// The rail row wears the `.row` hover variant in one shape: `.inline` would draw a grey disc
    /// across a full-width row, `.filled` a pill. A source scan, since hover state doesn't render
    /// offscreen, and the variant is chosen per call site, beyond `HoverAffordanceTests`.
    @Test func theRailRowWearsTheRowHoverVariantInOneShape() throws {
        #expect(EditorFileRailView.rowShape == HoverAffordanceShape.default(for: .row),
                "the row names a shape .row would not have chosen — one of the two is wrong")
        #expect(EditorFileRailView.rowShape != HoverAffordanceShape.default(for: .filled),
                "the shape is passed explicitly BECAUSE .filled defaults to something else; if the two now agree the argument is redundant and the comment above is stale")
        #expect(EditorFileRailView.rowShape != HoverAffordanceShape.default(for: .inline),
                "the shape .inline would have chosen is the defect this test exists for")

        let source = try SourceText.fileExplorer("EditorFileRailView.swift")
        // Scoped to the row builder, so a `.glyph` elsewhere (the ＋ button and the naming row have
        // their own) can't satisfy or break this. `row(_:)` is the type's last member, so "to the
        // end" is its body; asserted, because a member added after it would widen the scan.
        let start = try #require(source.range(of: "private func row(_ entry: EditorRailEntry)"),
                                 "the row builder is gone or renamed — this scan is not reading it")
        let whole = String(source[start.upperBound...])
        #expect(!whole.contains("\n    private func ") && !whole.contains("\n    var "),
                "row(_:) is no longer the last member, so this scan now covers more than the row")
        // Comment lines dropped first: the comment above the button style names `.inline`, so a
        // scan of the raw text would find the spelling it asserts is absent.
        let code = SourceText.codeOnly(whole)
        try #require(code.contains("buttonStyle"), "the comment filter ate the code as well")
        let body = code
        #expect(body.contains(".hoverAffordance(isSelected ? .filled : .row,"),
                "the rail row no longer wears the .row variant")
        #expect(body.contains("shape: Self.rowShape"),
                "the row's shape is left to the variant defaults again — the selected arm will wear a capsule")
        #expect(body.contains(".contentShape(Self.rowOutline)"),
                "the hit shape has drifted from the wash's shape; they are meant to be one value")
        #expect(!body.contains(".inline"),
                "the row is back on the dismiss-glyph variant, which washes in ink and draws a circle")
    }

    /// Only the open row wears the unsaved dot. The rail lists every text file in the folder and
    /// one is the document, so a dot taken from the document's status without checking the row
    /// would mark the whole folder unsaved, unseen in a folder of one file.
    @Test func onlyTheOpenRowShowsTheUnsavedDot() {
        let open = "/a/open.md"
        let other = "/a/other.md"
        let unsaved = EditorSaveStatus.unsaved

        #expect(EditorFileRailView.dotColour(rowPath: open, selectedPath: open,
                                             status: unsaved, accent: .blue) != nil)
        #expect(EditorFileRailView.dotColour(rowPath: other, selectedPath: open,
                                             status: unsaved, accent: .blue) == nil,
                "a file that is not open is being marked unsaved")
        // Nothing open at all: no row is the document, so no row has a dot.
        #expect(EditorFileRailView.dotColour(rowPath: open, selectedPath: nil,
                                             status: unsaved, accent: .blue) == nil)
        // Saved and read-only draw nothing, which is what makes the dot mean something.
        #expect(EditorFileRailView.dotColour(rowPath: open, selectedPath: open,
                                             status: .saved, accent: .blue) == nil)
        #expect(EditorFileRailView.dotColour(rowPath: open, selectedPath: open,
                                             status: .readOnly, accent: .blue) == nil)
        // A stop is the warning colour here as in the header: one rule, two places.
        #expect(EditorFileRailView.dotColour(rowPath: open, selectedPath: open,
                                             status: .stopped("x"), accent: .blue) == .orange)
    }

    // MARK: The split divider

    /// The one clamp both the divider and the drag ask. `min(max(x, lower), 1 - lower)` is not a
    /// clamp when `lower > 1 - lower`: it collapses to `1 - lower` and freezes the divider at the
    /// window floor, and a drag would commit a fraction nobody chose.
    @Test func theSplitClampNeverInvertsAndNeverLeavesAColumnUnusable() {
        let minimum = EditorLayoutMetrics.minSplitColumnWidth

        // Wide enough for two minimums: the clamp is a real clamp, and it bites on both sides.
        let wide: CGFloat = 1000
        #expect(EditorLayoutMetrics.splitFraction(0.5, in: wide) == 0.5)
        #expect(EditorLayoutMetrics.splitFraction(0.01, in: wide) == minimum / wide)
        #expect(EditorLayoutMetrics.splitFraction(0.99, in: wide) == 1 - minimum / wide)

        // Too narrow for two minimums: half, rather than the collapsed constant.
        for width in stride(from: CGFloat(0), through: 2 * minimum - 1, by: 37) {
            for raw in [CGFloat(-2), 0, 0.3, 0.5, 0.8, 3] {
                #expect(EditorLayoutMetrics.splitFraction(raw, in: width) == 0.5,
                        "at \(width)pt a raw \(raw) resolved to something other than half")
            }
        }

        // At every width the window can be: neither column is squeezed past the other's minimum,
        // and the fraction is always a fraction.
        for width in stride(from: CGFloat(1), through: 2400, by: 13) {
            for raw in [CGFloat(-5), 0, 0.2, 0.5, 0.9, 1, 4] {
                let f = EditorLayoutMetrics.splitFraction(raw, in: width)
                #expect(f > 0 && f < 1, "at \(width)pt a raw \(raw) resolved to \(f)")
                guard width >= 2 * minimum else { continue }
                #expect(width * f >= minimum - 0.001 && width * (1 - f) >= minimum - 0.001,
                        "at \(width)pt a raw \(raw) left a \(width * f)/\(width * (1 - f)) split")
            }
        }
    }

    // MARK: The mode capsule

    private func capsule(_ rung: EditorModeBar.Rung, mode: EditorMode = .split,
                         scale: CGFloat = 1) -> CGSize {
        size(EditorModeBar(mode: .constant(mode), accentFill: .blue, onAccent: .white, forcedRung: rung)
            .environment(\.appFontScale, scale))
    }

    /// The narrow rung must fit beside a filename in the narrowest document column
    /// (`minDocumentWidth`, the split clamp's guarantee). The labelled capsule is too wide for that
    /// column at every text size, which is why the control sheds its words.
    @Test func theGlyphRungFitsTheNarrowestDocumentColumnAtEveryTextSize() {
        let nameAllowance = Self.nameAllowance
        for scale in scales {
            let width = capsule(.glyphOnly, scale: scale).width
            #expect(width + nameAllowance <= EditorLayoutMetrics.minDocumentWidth,
                    """
                    at text scale \(scale) the glyph-only capsule is \(width)pt, leaving \
                    \(EditorLayoutMetrics.minDocumentWidth - width)pt for the file name in a \
                    \(EditorLayoutMetrics.minDocumentWidth)pt column — under the \(nameAllowance)pt it needs
                    """)
        }
    }

    /// What the header must still be able to show of a file name beside the capsule.
    private static let nameAllowance: CGFloat = 120

    /// The document column at the app's 760pt window floor, with the folder sidebar at its 150pt
    /// minimum. Deliberately conservative: `EditorLayoutMetrics` puts the real column at ~391pt, so
    /// anything that clears this clears that.
    private static var documentWidthAtWindowFloor: CGFloat {
        760 - 150 - EditorLayoutMetrics.railWidth - 2 * LiquidGlass.cardGutter
    }

    /// At the 760pt window floor the labelled rung fits up to 130% and sheds only at 135%, the
    /// `Largest` preset, pinned as a boundary both ways over every slider step. Above it the names
    /// stay reachable through the tooltip and accessibility label.
    @Test func theWordsShedAtTheNarrowestWindowOnlyAtTheTopOfTheTextRange() {
        let column = Self.documentWidthAtWindowFloor
        let fitting = FontSize.selectablePercents.filter { percent in
            capsule(.labelled, scale: FontSize(percent: percent).scale).width
                + Self.nameAllowance <= column
        }
        // Contiguous from the bottom, or "the last one that fits" is not a boundary.
        #expect(fitting == Array(FontSize.selectablePercents.prefix(fitting.count)),
                "the percents that fit are \(fitting) — not a contiguous run, so there is no single boundary")
        #expect(fitting.last == 130, """
                the labelled capsule sheds its words above \(fitting.last.map(String.init) ?? "no")% \
                rather than 130% — at the 760pt window floor the \(column)pt document column takes \
                the rung plus a \(Self.nameAllowance)pt name up to there. Re-measure and move this \
                number deliberately; do not widen the allowance to make it go away.
                """)
    }

    /// …and the labelled rung is genuinely wider, or the ladder has nothing to choose between.
    @Test func theLabelledRungIsTheWiderOneItShedsFrom() {
        for scale in scales {
            let labelled = capsule(.labelled, scale: scale).width
            let glyphs = capsule(.glyphOnly, scale: scale).width
            #expect(labelled > glyphs + 40,
                    "at scale \(scale) the two rungs measure \(labelled) and \(glyphs) — the words cost almost nothing, so shedding them buys almost nothing")
        }
    }

    /// The capsule is one width whichever segment is selected, or the filename beside it would
    /// shift on every click (a bolder selected segment would widen it).
    @Test func theCapsuleIsOneWidthWhicheverModeIsSelected() {
        for rung in [EditorModeBar.Rung.labelled, .glyphOnly] {
            let widths = EditorMode.allCases.map { capsule(rung, mode: $0).width }
            #expect(Set(widths.map { ($0 * 100).rounded() }).count == 1,
                    "the \(rung) capsule measures \(widths) across the three selections")
        }
    }

    /// Both rungs grow with the app's type rather than staying pinned, or the ceiling checks above
    /// would be vacuous. The glyph-only rung especially: it has no `Text` to scale, so a
    /// hard-framed glyph box would stay one width while the glyphs inside overflowed.
    @Test func bothRungsGrowWithTheAppsTextSize() {
        for rung in [EditorModeBar.Rung.labelled, .glyphOnly] {
            let widths = scales.map { capsule(rung, mode: .edit, scale: $0).width }
            // Ascending scales, so the widths may not go backwards anywhere along them...
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 },
                    "the \(rung) capsule measures \(widths) across \(scales) — it shrinks as the text grows")
            // ...and the ends must actually differ, which is the half a pinned frame fails.
            #expect((widths.last ?? 0) > (widths.first ?? 0),
                    "the \(rung) capsule measures \(widths) across \(scales) — it is not scaling")
        }
    }

    // MARK: The preview's type ramp

    /// Six heading levels, each no larger than the one above it and the smallest still readable.
    /// A ramp that inverted anywhere would render an `###` bigger than the `##` over it.
    @Test func theHeadingRampNeverGrowsAsItGoesDeeper() {
        let sizes = (1...6).map { MarkdownBlockView.headingSize($0) }
        for (level, pair) in zip(sizes, sizes.dropFirst()).enumerated() {
            #expect(pair.0 >= pair.1,
                    "h\(level + 1) is \(pair.0)pt and h\(level + 2) is \(pair.1)pt")
        }
        #expect(sizes.first! > 13, "h1 is not larger than body text")
        #expect(sizes.last! >= 11, "h6 has fallen below a readable size")
    }

    // MARK: The status line

    private func statusLine(_ rung: EditorStatusLine.Rung,
                            words: Int = 4_218, characters: Int = 24_907) -> EditorStatusLine {
        EditorStatusLine(
            facts: EditorDocumentFacts(words: words, characters: characters, lines: 412,
                                       lineEnding: .crlf, encoding: "UTF-16 LE"),
            caret: EditorCaret(line: 408, column: 118),
            forcedRung: rung)
    }

    /// The rungs must be strictly narrower in order, or `ViewThatFits`, which takes the first that
    /// fits, never reaches them, and the strip silently truncates instead.
    @Test func eachStatusRungIsNarrowerThanTheOneBeforeIt() {
        for scale in scales {
            let widths = EditorStatusLine.Rung.allCases.map {
                size(statusLine($0).environment(\.appFontScale, scale)).width
            }
            #expect(widths == widths.sorted(by: >),
                    "at scale \(scale) the rungs measure \(widths), which is not strictly narrowing")
        }
    }

    /// The narrowest rung fits the narrowest column the layout ever gives it, at every text size,
    /// or the strip truncates in a window the app allows.
    @Test func theNarrowestStatusRungFitsTheNarrowestDocumentColumn() {
        for scale in scales {
            let width = size(statusLine(.caret).environment(\.appFontScale, scale)).width
            #expect(width <= EditorLayoutMetrics.minDocumentWidth,
                    "the caret-only rung is \(width)pt against a \(EditorLayoutMetrics.minDocumentWidth)pt column at scale \(scale)")
        }
    }

    /// A five-figure count is wider than a one-figure count: the positive control for the two tests
    /// above, which would otherwise pass over a strip that drew no numbers.
    @Test func theStatusLineReallyDrawsItsNumbers() {
        let small = size(statusLine(.full, words: 1, characters: 4)).width
        let large = size(statusLine(.full, words: 4_218, characters: 24_907)).width
        #expect(large > small + 20,
                "the full rung measured \(small) with tiny numbers and \(large) with large ones")
    }

    // MARK: The rail's tabs

    /// The words fit every segment at every text size. The bar splits the fixed-width rail in equal
    /// segments, so the widest label decides; `tabs:` puts one title in every segment to measure
    /// the worst case (``EditorRailTab/title`` has the numbers).
    @Test func theRailTabsFitTheRailAtEveryTextSize() {
        // What the bar is handed: the rail, less its 10pt inset on each side.
        let available = EditorLayoutMetrics.railWidth - 20
        // Every title in every segment of the widest bar (the three a PDF brings), not the longest
        // by character count, which needn't be the widest in every font.
        let widestBar = EditorRailTab.shown(pdfIsOpen: true, pdfHasOutline: true, markdownIsOpen: false)
        #expect(widestBar.count == 3, "the PDF bar is the widest case and has \(widestBar.count) tabs")
        for scale in scales {
            for title in EditorRailTab.allCases {
                let bar = EditorRailTabBar(tab: .constant(.files),
                                           tabs: Array(repeating: title, count: widestBar.count),
                                           accentFill: .blue, onAccent: .white)
                    .environment(\.appFontScale, scale)
                let measured = size(bar).width
                #expect(measured <= available,
                        "“\(title.title)” in all \(widestBar.count) segments measured \(measured) against \(available) at scale \(scale) — the label truncates")
            }
        }
    }

    // MARK: The outline tab

    /// The outline has the whole card, with no row cap, so its twelfth row is drawn as surely as
    /// its fourth. Twelve against four, either side of an eight-row cap; one row against four shows
    /// the rows are really drawn rather than reserved.
    @Test func theOutlineTabDrawsPastTheRowCapTheStackImposed() {
        let one = size(rail(entries: [entry("one.md")], outline: [heading("A", line: 1)],
                            tab: .outline))
        let four = size(rail(entries: [entry("one.md")],
                             outline: (1...4).map { heading("Row \($0)", line: $0) },
                             tab: .outline))
        let twelve = size(rail(entries: [entry("one.md")],
                               outline: (1...12).map { heading("Row \($0)", line: $0) },
                               tab: .outline))
        #expect(four.height > one.height,
                "four outline rows measured \(four.height) against one row's \(one.height)")
        #expect(twelve.height > four.height,
                "twelve outline rows measured \(twelve.height) against four rows' \(four.height) — something is still capping the section")
    }

    /// The empty outline is a note with no headings yet, the only empty the tab can show since it
    /// is offered only for Markdown, so it says what makes one rather than "there are none".
    @Test func theEmptyOutlineSaysWhatMakesAHeading() {
        #expect(EditorFileRailView.outlineEmptyCaption.contains("#"),
                "the no-headings caption does not say what makes a heading: \(EditorFileRailView.outlineEmptyCaption)")
    }

    /// The rail's four empties, kept apart: no folder chosen; a filter that matched nothing; a
    /// folder that really is empty; a folder of files the editor doesn't open, which must not read
    /// as an empty one. Collapsing any two arms shrinks the set.
    @Test func theEmptyRailKeepsItsFourAnswersApart() {
        let noFolder = EditorFileRailView.fileEmptyCaption(folderName: "", anyEntries: false,
                                                           filter: "", otherFiles: nil)
        let noMatch = EditorFileRailView.fileEmptyCaption(folderName: "Notes", anyEntries: true,
                                                          filter: "zzz", otherFiles: nil)
        let empty = EditorFileRailView.fileEmptyCaption(folderName: "Notes", anyEntries: false,
                                                        filter: "", otherFiles: 0)
        let others = EditorFileRailView.fileEmptyCaption(folderName: "Scans", anyEntries: false,
                                                         filter: "", otherFiles: 12)

        let all = [noFolder, noMatch, empty, others]
        #expect(Set(all).count == 4,
                "two of the rail's empties say the same thing: \(all.joined(separator: " / "))")
        #expect(noMatch.contains("zzz"), "the filter caption does not name the filter: \(noMatch)")
        #expect(others.contains("12"),
                "the caption does not say how many files are in the folder: \(others)")
        #expect(!empty.contains("0"),
                "the empty folder's caption counts files that are not there: \(empty)")
    }

    /// An uncounted folder reads as an empty one. `nil` means nobody asked, which happens only when
    /// the rail has rows and this caption isn't on screen, so there's no third sentence to reach.
    @Test func anUncountedFolderReadsAsAnEmptyOne() {
        #expect(EditorFileRailView.fileEmptyCaption(folderName: "Notes", anyEntries: false,
                                                    filter: "", otherFiles: nil)
                == EditorFileRailView.fileEmptyCaption(folderName: "Notes", anyEntries: false,
                                                       filter: "", otherFiles: 0))
    }

    /// One file is ordinary (a PDF in a folder of its own), and a single pluralised template would
    /// render it "None of the 1 file in this folder are".
    @Test func theEmptyRailReadsAsEnglishForOneFile() {
        let one = EditorFileRailView.fileEmptyCaption(folderName: "Scans", anyEntries: false,
                                                      filter: "", otherFiles: 1)
        #expect(!one.contains("the 1 file"), "reads as a filled-in template: \(one)")
        #expect(!one.contains("files"), "the singular caption uses the plural noun: \(one)")
        #expect(one != EditorFileRailView.fileEmptyCaption(folderName: "Scans", anyEntries: false,
                                                           filter: "", otherFiles: 0),
                "one unopenable file reads the same as an empty folder: \(one)")
    }

    /// A count past a thousand is grouped: "None of the 1,200 files", not "1200".
    @Test func theEmptyRailGroupsALargeCount() throws {
        let grouped = 1_200.formatted()
        try #require(grouped != "1200", "this locale groups no digits — this measures nothing")
        let many = EditorFileRailView.fileEmptyCaption(folderName: "Scans", anyEntries: false,
                                                       filter: "", otherFiles: 1_200)
        #expect(many == "None of the \(grouped) files in this folder are ones Edit opens. The + button makes a text file.",
                "\(many)")
        #expect(!many.contains("1200"), "\(many)")
    }

    /// An empty outline is a caption, not a blank card. Asserted as a difference, not a height
    /// floor, which the tabs and context line clear on their own: the empty Outline tab against the
    /// same rail with the caption blanked. Blank it in the source and the heights match.
    @Test func theEmptyOutlineTabDrawsTheCaptionAndNotJustSpace() {
        let drawn = size(rail(entries: [entry("one.md")], tab: .outline), width: EditorLayoutMetrics.railWidth)
        let list = { (caption: String) in
            EditorRailOutlineList(rows: [], currentIndex: nil, path: "/n/one.md", emptyCaption: caption,
                                  outlineAnchors: .constant([:]), accent: .blue, onSelect: { _ in })
        }
        let captioned = size(list(EditorFileRailView.outlineEmptyCaption), width: EditorLayoutMetrics.railWidth)
        let blank = size(list(""), width: EditorLayoutMetrics.railWidth)
        #expect(captioned.height > blank.height + 10,
                "the empty outline's caption laid out at \(captioned.height)pt against a blank one's \(blank.height)pt")
        #expect(drawn.height >= captioned.height, "the rail's Outline tab is shorter than its own caption")
    }

    // MARK: The document header

    private func document(named name: String, text: String = "hello") throws -> EditorDocument {
        try TestTextFiles.document(named: name, text: text)
    }

    private func workspace(_ document: EditorDocument, showsRail: Bool = true,
                           railIsHidden: Bool = false, naming: Bool = false) -> EditorWorkspaceView {
        .fixture(document: document, showsRail: showsRail, railIsHidden: railIsHidden, isNaming: naming)
    }

    /// A `.md` and a `.txt` header are the same height, or the document column would start at two
    /// places: the mode capsule is the top row's tallest thing, and a plain-text file has none.
    @Test func theHeaderIsTheSameHeightForEveryKindOfTextFile() throws {
        let markdown = try document(named: "note.md")
        let plain = try document(named: "note.txt")
        #expect(markdown.isMarkdown, "the fixture is not being seen as Markdown")
        #expect(!plain.isMarkdown, "the plain-text fixture is being seen as Markdown")

        for scale in scales {
            let a = size(workspace(markdown).headerContent.environment(\.appFontScale, scale),
                         width: 520)
            let b = size(workspace(plain).headerContent.environment(\.appFontScale, scale),
                         width: 520)
            #expect(abs(a.height - b.height) < 0.51,
                    "at scale \(scale) Markdown's header is \(a.height)pt and plain text's is \(b.height)")
        }
    }

    /// The assumption the reservation rests on: the hidden capsule sits in a zero-width frame, so
    /// its `ViewThatFits` picks the narrowest, glyph-only rung. That reserves the right height only
    /// while both rungs are the same height; a change to the labelled rung's padding or font would
    /// quietly under-reserve.
    @Test func bothCapsuleRungsAreTheSameHeight() {
        for scale in scales {
            let labelled = size(EditorModeBar(mode: .constant(.edit), accentFill: .blue,
                                              onAccent: .white, forcedRung: .labelled)
                                .environment(\.appFontScale, scale))
            let glyph = size(EditorModeBar(mode: .constant(.edit), accentFill: .blue,
                                           onAccent: .white, forcedRung: .glyphOnly)
                             .environment(\.appFontScale, scale))
            #expect(abs(labelled.height - glyph.height) < 0.51,
                    "at scale \(scale) the rungs are \(labelled.height)pt and \(glyph.height)pt tall")
        }
    }

    /// A hidden capsule inside a zero-width frame still contributes its height. If
    /// `.frame(width: 0)` flattened it, the header test above would pass only because both headers
    /// lost the reservation together.
    @Test func aZeroWidthHiddenCapsuleStillReservesItsHeight() {
        for scale in scales {
            let visible = size(EditorModeBar(mode: .constant(.edit), accentFill: .blue, onAccent: .white)
                                .environment(\.appFontScale, scale))
            let reserved = size(EditorModeBar(mode: .constant(.edit), accentFill: .blue, onAccent: .white)
                                .hidden().frame(width: 0)
                                .environment(\.appFontScale, scale))
            #expect(abs(visible.height - reserved.height) < 0.51,
                    "at scale \(scale) the reservation is \(reserved.height)pt against \(visible.height)")
            #expect(reserved.width < 0.51,
                    "the reservation is holding \(reserved.width)pt of width it should not")
        }
    }

    /// Both header rows reserve the dot's column, one named constant, which gives them one left
    /// edge. A source scan, comments stripped: a view's position in a hosted SwiftUI tree isn't
    /// reachable here.
    @Test func bothHeaderRowsReserveTheDotColumn() throws {
        let source = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        let code = SourceText.codeOnly(source)

        try #require(code.contains("static let dotColumnWidth"),
                     "the shared constant is gone — the two rows can no longer agree by construction")
        let uses = code.components(separatedBy: "Self.dotColumnWidth").count - 1
        #expect(uses >= 2,
                "only \(uses) row(s) reserve the dot column; the header's two left edges will differ")

        // The subtitle's reservation has to be an unconditional shape. An `if` around it
        // contributes nothing to layout, which would leave the subtitle flush left while the title
        // stayed indented.
        let metaRow = try #require(source.range(of: "private var metaRow: some View {"))
        let end = try #require(source.range(of: "static let dotColumnWidth", range: metaRow.upperBound..<source.endIndex))
        let body = String(source[metaRow.upperBound..<end.lowerBound])
        #expect(body.contains("Color.clear"),
                "the subtitle's reservation is not a drawn shape, so it takes no part in layout")
    }
}

// MARK: - Fewer columns

/// What the document gets when the rail is not drawn, and where ⌘N's row goes. Measured on the
/// mounted AppKit tree, because a rail hidden by `.opacity(0)` would pass any presence check while
/// still taking its width.
@MainActor
@Suite(.serialized) struct EditorFewerColumnsLayoutTests {

    private static let size = CGSize(width: 800, height: 400)

    private func document(named name: String) throws -> EditorDocument {
        try TestTextFiles.document(named: name)
    }

    private func workspace(_ document: EditorDocument, showsRail: Bool, railIsHidden: Bool = false,
                           naming: Bool = false) -> EditorWorkspaceView {
        .fixture(document: document, folder: "/n/Downloads", showsRail: showsRail,
                 railIsHidden: railIsHidden, isNaming: naming)
    }

    /// The workspace mounted at a fixed width, so the columns divide a known number.
    private func mounted<V: View>(_ view: V) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: Self.size.width, height: Self.size.height)
            .editorTestDefaults("EditorFewerColumnsLayoutTests")))
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The first descendant of `type`, with its frame in the host's coordinates; a raw frame is in
    /// the superview's space, and the nesting here is deep.
    private func first<T: NSView>(_ type: T.Type, in host: NSView) -> (view: T, frame: CGRect)? {
        var found: (T, CGRect)?
        func walk(_ v: NSView) {
            if found != nil { return }
            if let match = v as? T { found = (match, v.convert(v.bounds, to: host)); return }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    /// Every `NSTextField` whose placeholder is the naming row's, with frames in host coordinates.
    private func nameFields(in host: NSView) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField, field.placeholderString == "Name" {
                found.append(v.convert(v.bounds, to: host))
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    /// Without the rail the document is wider by the rail and its card, measured on the text view
    /// AppKit mounted: `railWidth + gutter`, where the gutter is one in Cards (as
    /// `minDocumentOnlyWidth` is built) and none in the fixture's default Unified.
    @Test func withoutTheRailTheDocumentTakesItsWidth() throws {
        let doc = try document(named: "note.txt")
        let withRail = try #require(first(NSTextView.self, in: mounted(workspace(doc, showsRail: true))),
                                    "no text view mounted with the rail")
        let without = try #require(first(NSTextView.self, in: mounted(workspace(doc, showsRail: false))),
                                   "no text view mounted without the rail")
        let gained = without.frame.width - withRail.frame.width
        let expected = EditorLayoutMetrics.railWidth + LiquidGlass.gutter(.unified)
        #expect(abs(gained - expected) < 1,
                "the document gained \(gained)pt without the rail; the rail and its card are \(expected)pt")
        // And it is the left edge that moved: the rail was on the left, so the text starts where
        // the rail started.
        #expect(without.frame.minX < withRail.frame.minX - EditorLayoutMetrics.railWidth + 1,
                "the text still starts at x=\(without.frame.minX) without the rail (with: \(withRail.frame.minX))")
    }

    /// ⌘N's row is in the rail while there is one, and at the top of the document when there isn't:
    /// one row, never two, never none. Told apart by width: the rail's field is in a 232pt column,
    /// the document's spans the row.
    @Test func theNamingRowMovesToTheDocumentWhenThereIsNoRail() throws {
        let doc = try document(named: "note.txt")
        let inRail = nameFields(in: mounted(workspace(doc, showsRail: true, naming: true)))
        #expect(inRail.count == 1, "\(inRail.count) naming fields with the rail drawn")
        #expect((inRail.first?.width ?? 0) < EditorLayoutMetrics.railWidth,
                "the field measures \(inRail.first?.width ?? 0)pt — wider than the rail it should be inside")

        let inDocument = nameFields(in: mounted(workspace(doc, showsRail: false, naming: true)))
        #expect(inDocument.count == 1, "\(inDocument.count) naming fields with no rail")
        #expect((inDocument.first?.width ?? 0) > EditorLayoutMetrics.railWidth,
                "the field measures \(inDocument.first?.width ?? 0)pt — rail-sized, in a row with no rail")
        // Above the text, not below it: the row leads the column.
        let text = try #require(first(NSTextView.self, in: mounted(workspace(doc, showsRail: false, naming: true))))
        #expect((inDocument.first?.minY ?? .infinity) < text.frame.minY,
                "the naming row sits at y=\(inDocument.first?.minY ?? -1), under the text at y=\(text.frame.minY)")

        // The control: no ⌘N, no field, in either home.
        #expect(nameFields(in: mounted(workspace(doc, showsRail: false))).isEmpty)
        #expect(nameFields(in: mounted(workspace(doc, showsRail: true))).isEmpty)
    }

    /// Expand names its next act: "Expand" while the rail is there, "Files" once it isn't, in its
    /// word, label, tooltip and arrows. Pinned on the statics the view draws from: a hosted SwiftUI
    /// tree exposes no labels or tooltips under `swift test`.
    @Test func theExpandButtonNamesItsNextAct() {
        #expect(EditorWorkspaceView.expandTitle(railIsHidden: false) == "Expand")
        #expect(EditorWorkspaceView.expandTitle(railIsHidden: true) == "Files")
        #expect(EditorWorkspaceView.expandSymbol(railIsHidden: false) == "arrow.up.left.and.arrow.down.right")
        #expect(EditorWorkspaceView.expandSymbol(railIsHidden: true) == "arrow.down.right.and.arrow.up.left")
        #expect(EditorWorkspaceView.expandHelp(railIsHidden: false).contains("put away the file list"))
        // The sidebar too: it stays beside Edit's folded pane, so the ordinary layout can have one
        // on screen for the button to put away.
        #expect(EditorWorkspaceView.expandHelp(railIsHidden: false).contains("sidebar"))
        // Leaving gives back what was there, not only the list.
        #expect(EditorWorkspaceView.expandHelp(railIsHidden: true).contains("as they were"))
        for hidden in [false, true] {
            for text in [EditorWorkspaceView.expandTitle(railIsHidden: hidden),
                         EditorWorkspaceView.expandHelp(railIsHidden: hidden)] {
                #expect(!text.localizedCaseInsensitiveContains("just the text"), "“\(text)” still says Just the text")
            }
            #expect(NSImage(systemSymbolName: EditorWorkspaceView.expandSymbol(railIsHidden: hidden),
                            accessibilityDescription: nil) != nil,
                    "\(EditorWorkspaceView.expandSymbol(railIsHidden: hidden)) is not a symbol — the button draws nothing")
        }
    }

    /// The button lights with its wash and moves nothing else; its word and glyph stay label colour,
    /// since accent words on their own wash read at 2.3:1 on Green. The wash is counted alone, in
    /// square points, since the glyph and word change too.
    @Test(.machinePinned(.pixelSampling))
    func theExpandButtonLightsWhenTheRailIsHidden() throws {
        let doc = try document(named: "note.txt")
        let off = try #require(Rendered(workspace(doc, showsRail: true, railIsHidden: false).headerContent,
                                        size: Self.headerSize))
        let offAgain = try #require(Rendered(workspace(doc, showsRail: true, railIsHidden: false).headerContent,
                                             size: Self.headerSize))
        let on = try #require(Rendered(workspace(doc, showsRail: false, railIsHidden: true).headerContent,
                                       size: Self.headerSize))
        #expect(on.differingBox(from: off) != nil, "the rail bit changed nothing")
        #expect(off.differingBox(from: offAgain) == nil, "two renders of the same header differ — the detector is noise")
        let row = off.nameRowRings
        try #require(row.count == 4, "a plain-text header draws \(row.count) buttons — ＋, Find, Expand and × expected")
        let expand = row[row.count - 2]
        let wash: (CGFloat, CGFloat, CGFloat) -> Bool = { r, g, b in
            b > 0.95 && (0.6...0.93).contains(r) && g > r
        }
        let litWash = CGFloat(on.pixels(in: expand, matching: wash)) / on.pixelsPerPoint
        let unlitWash = CGFloat(off.pixels(in: expand, matching: wash)) / off.pixelsPerPoint
        let ringArea = expand.width * expand.height
        print("[expand-lit] wash \(Int(litWash))pt² lit, \(Int(unlitWash))pt² unlit, in a \(Int(ringArea))pt² ring")
        #expect(unlitWash < 1, "the unlit button wears \(unlitWash)pt² of the wash")
        #expect(litWash > ringArea * Self.expandWashShare,
                "the lit button's wash covers \(litWash)pt² of its \(ringArea)pt² — the wash is not drawn")
        #expect(on.nameRowRings == row, "lighting Expand moved the row's buttons: \(row) → \(on.nameRowRings)")
        // "Files" starts where "Expand" did: laid out from the leading edge of the wider word's
        // room, not centred, so the word begins the same distance in lit as unlit. Read as inked
        // columns in the ring: the word begins at the first ink after a blank run of at least 2pt
        // (the arrow's strokes leave narrower gaps; arrow-to-word spacing is 4pt).
        func wordStart(_ r: Rendered, ink: @escaping (CGFloat, CGFloat, CGFloat) -> Bool) -> CGFloat? {
            let step: CGFloat = 0.5
            var inked: [Bool] = []
            var x = expand.minX
            while x < expand.maxX {
                inked.append(r.pixels(in: CGRect(x: x, y: expand.minY + 3, width: step, height: expand.height - 6),
                                      matching: ink) > 0)
                x += step
            }
            guard var i = inked.firstIndex(of: true) else { return nil }
            var blank = 0
            while i < inked.count {
                if inked[i] { if blank >= 4 { return CGFloat(i) * step }; blank = 0 } else { blank += 1 }
                i += 1
            }
            return nil
        }
        let unlitStart = try #require(wordStart(off) { r, g, b in max(r, g, b) < 0.6 },
                                      "no word found after the arrow in the unlit button")
        // Label colour lit too: the dark ink the unlit word is found by, not the accent.
        let litStart = try #require(wordStart(on) { r, g, b in max(r, g, b) < 0.6 },
                                    "no word found after the arrow in the lit button")
        #expect(abs(litStart - unlitStart) < 1.5,
                "lit, the word begins \(litStart)pt into the button against \(unlitStart)pt unlit — “Files” is not where “Expand” was")
        let box = try #require(on.differingBox(from: off))
        #expect(expand.insetBy(dx: -2, dy: -2).contains(box),
                "lighting Expand changed pixels at \(box), outside its own button \(expand)")
    }

    /// For ``theExpandButtonLightsWhenTheRailIsHidden``: the lit wash covers at least this share of
    /// the button's ring, the pill less its glyph, word and anti-aliased edge.
    static let expandWashShare: CGFloat = 0.4

    private static let headerSize = CGSize(width: 520, height: 44)
}
