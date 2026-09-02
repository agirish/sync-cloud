import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// What the Editor's chrome actually measures, at every text size the app offers.
///
/// **The class of test the branch shipped without.** Every other assertion about this workspace is
/// pure logic — what the store writes, what the walk produces — and none of it can see a header
/// that wraps, a capsule that outgrows the column it sits in, or a rail that stops matching the
/// number the layout clamps against. Browse shipped with a rendered test; this is Editor's.
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
            onCreate: { _ in true })
    }

    private func heading(_ title: String, level: Int = 1, line: Int) -> MarkdownOutlineEntry {
        MarkdownOutlineEntry(line: line, level: level, depth: level - 1, title: title)
    }

    private func entry(_ name: String, size: Int = 120) -> EditorRailEntry {
        EditorRailEntry(path: "/a/\(name)", name: name, size: size, isCloudOnly: false)
    }

    /// **The drawn rail is the width the layout reserves — and the rows are really in it.**
    ///
    /// The width half alone is a tautology and was one: `EditorFileRailView.body` ends in
    /// `.frame(width: Self.width)` and `Self.width` IS `EditorLayoutMetrics.railWidth`, so the
    /// assertion compared a constant to itself through a hard frame and would have passed with the
    /// header deleted, every row deleted, or `railWidth` set to 500. The height is what makes it a
    /// measurement: it is the axis the frame does not pin, so a rail that stopped drawing its rows
    /// fails here.
    @Test func theRailDrawsAtTheReservedWidthWithItsRowsInIt() {
        let one = size(rail(entries: [entry("one.md")]))
        let three = size(rail(entries: [entry("one.md"), entry("two.md"), entry("three.md")]))

        #expect(abs(one.width - EditorLayoutMetrics.railWidth) < 0.51,
                "the rail draws \(one.width)pt against the \(EditorLayoutMetrics.railWidth)pt the layout reserves")
        #expect(abs(three.width - EditorLayoutMetrics.railWidth) < 0.51,
                "three rows widened the rail to \(three.width)pt")
        #expect(three.height > one.height,
                "three rows measure the same as one (\(three.height)pt) — the rows are not drawn, so the width assertion above is measuring an empty frame")
    }

    /// **A long file name truncates rather than wrapping**, measured in HEIGHT.
    ///
    /// Width cannot see this and the earlier version of this test asked in width: the rail is hard
    /// framed, so a name that wrapped to three lines measured exactly as wide as one that did not,
    /// and deleting `lineLimit(1)` and `truncationMode(.middle)` from the row changed nothing the
    /// assertion could read. What a wrap actually does is make the ROW taller, so that is the axis.
    /// The two-row control below is what stops this passing on a rail that draws nothing at all.
    @Test func aLongFileNameTruncatesRatherThanWrappingTheRow() {
        let short = size(rail(entries: [entry("a.md")])).height
        let long = size(rail(entries: [entry(String(repeating: "verylongname", count: 12) + ".md")])).height
        let two = size(rail(entries: [entry("a.md"), entry("b.md")])).height

        #expect(abs(short - long) < 0.51,
                "a long name grew the row from \(short)pt to \(long)pt — it is wrapping, not truncating")
        #expect(two > short,
                "a second row did not make the rail taller (\(two)pt vs \(short)pt) — height is not measuring the rows, so the comparison above proves nothing")
    }

    /// **The two cards really do cost a `cardGutter`, measured rather than restated.**
    ///
    /// `minWorkspaceWidth` is defined as `railWidth + minDocumentWidth + 2 * cardGutter`, so
    /// asserting that equality is the definition typed twice — it cannot fail. What can fail is the
    /// claim underneath it: that `bottomSectionCard` insets its content by half a gutter on each
    /// side, which is where the `2 *` comes from. That is a fact about a Design component this file
    /// does not own, and if it ever changes, the workspace floor silently starts promising a
    /// document column it then shaves points off.
    @Test func aCardCostsExactlyTheGutterTheWorkspaceMinimumBudgetsForIt() {
        let bare = size(Color.clear.frame(width: 200, height: 40))
        let carded = size(Color.clear.frame(width: 200, height: 40)
            .bottomSectionCard(.unified, level: .frosted, hue: .graphite, tint: 0))

        #expect(abs((carded.width - bare.width) - LiquidGlass.cardGutter) < 0.51,
                "a card costs \(carded.width - bare.width)pt of width, not the \(LiquidGlass.cardGutter)pt `minWorkspaceWidth` budgets two of")
        #expect(EditorLayoutMetrics.minWorkspaceWidth >= EditorLayoutMetrics.railWidth
                    + EditorLayoutMetrics.minDocumentWidth + 2 * (carded.width - bare.width),
                "the workspace floor does not cover the chrome the two cards actually draw")
    }

    /// **The rail row wears the row variant, and both of its arms wear the same shape.**
    ///
    /// It shipped as `isSelected ? .filled : .inline`. `.inline` is documented for "a small dismiss
    /// glyph riding inside a field or chip", and its default shape is a **circle** — which in a
    /// full-width row collapses to the row's height and centres itself, so hovering a file drew a
    /// grey disc in the middle of the row rather than a wash across it. The selected arm was wrong
    /// in the same breath: `.filled` defaults to a capsule, so the ring traced a pill around a
    /// rounded rectangle.
    ///
    /// **Nothing in the repo could have caught it.** `HoverAffordanceTests` pins each variant's own
    /// metrics; which variant a given control should wear is decided per call site, by hand — the
    /// `.segment` census in `HoverAffordanceShape` is a doc comment, not an assertion. So this is
    /// the check for this row, in the shape the duplicate card's own scan uses.
    ///
    /// A source scan because hover state does not render offscreen (`HoverTintRenderTests` drives
    /// the phase directly rather than through a pointer). The value assertions below are the half
    /// that is not string matching: the shape this row names must be exactly what `.row` would have
    /// chosen for itself, which is what makes passing it explicitly a fix for the `.filled` arm
    /// rather than a second opinion about the unselected one.
    @Test func theRailRowWearsTheRowHoverVariantInOneShape() throws {
        #expect(EditorFileRailView.rowShape == HoverAffordanceShape.default(for: .row),
                "the row names a shape .row would not have chosen — one of the two is wrong")
        #expect(EditorFileRailView.rowShape != HoverAffordanceShape.default(for: .filled),
                "the shape is passed explicitly BECAUSE .filled defaults to something else; if the two now agree the argument is redundant and the comment above is stale")
        #expect(EditorFileRailView.rowShape != HoverAffordanceShape.default(for: .inline),
                "the shape .inline would have chosen is the defect this test exists for")

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/EditorFileRailView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read EditorFileRailView.swift — this scan would be vacuous")
        try #require(source.count > 500, "the file is implausibly short — the scan would be near-vacuous")
        // Scoped to the row builder, so a `.glyph` elsewhere in the file — the ＋ button and the
        // naming row legitimately have their own — cannot satisfy or break this. `row(_:)` is the
        // last member of the type, so "to the end" IS its body; asserted rather than assumed,
        // because a member added after it would silently widen this scan.
        let start = try #require(source.range(of: "private func row(_ entry: EditorRailEntry)"),
                                 "the row builder is gone or renamed — this scan is not reading it")
        let whole = String(source[start.upperBound...])
        #expect(!whole.contains("\n    private func ") && !whole.contains("\n    var "),
                "row(_:) is no longer the last member, so this scan now covers more than the row")
        // **Comment lines dropped before anything is asserted**, and this is not tidiness. The
        // paragraph above the button style explains the defect by naming `.inline`, so a scan of the
        // raw text finds the very spelling it is asserting the absence of — it failed on its own
        // explanation the first time it ran. A scan that reads prose is a scan that can be satisfied
        // or broken by prose.
        let code = whole.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
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

    /// **Only the OPEN row wears the unsaved dot.**
    ///
    /// The rail lists every text file in the folder and exactly one of them is the document, so a
    /// dot resolved from a document-wide status without checking which row it is would mark the
    /// whole folder as unsaved. That mistake is invisible in the obvious place to look — a folder
    /// with one file in it — which is why it is asserted here rather than left to a screenshot.
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
        // A stop is the warning colour here as it is in the header — one rule, two places.
        #expect(EditorFileRailView.dotColour(rowPath: open, selectedPath: open,
                                             status: .stopped("x"), accent: .blue) == .orange)
    }

    // MARK: The split divider

    /// **The clamp both the divider and the drag now ask.**
    ///
    /// This arithmetic has shipped a bug in each direction. `min(max(x, lower), 1 - lower)` is not
    /// a clamp when `lower > 1 - lower`: it collapses to the constant `1 - lower`, which froze the
    /// divider at the window floor. The display path was guarded and the drag handler kept its own
    /// unguarded copy, so every drag at that width committed a fraction nobody chose — invisible
    /// until the window was widened and the divider jumped. Being a named function is what let this
    /// be tested at all; it was inline in a `GeometryReader` closure.
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

        // The property that matters at every width the window can be: neither column is ever
        // squeezed past the other's minimum, and the fraction is always a fraction.
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
        size(EditorModeBar(mode: .constant(mode), accent: .blue, onAccent: .white, forcedRung: rung)
            .environment(\.appFontScale, scale))
    }

    /// **The narrow rung has to fit beside a filename in the narrowest document column.**
    ///
    /// The capsule sits at the trailing end of the editor's header row and the header's other half
    /// is the file name; `minDocumentWidth` is what the split clamp guarantees that column. This is
    /// the assertion that found the labelled capsule too wide to sit there at any text size — 208pt
    /// at the default against a 260pt column — which is why the control sheds its words at all.
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

    /// The document column at the app's 760pt window floor, with the folder sidebar at its own
    /// 150pt minimum. **Deliberately the conservative reading** — `EditorLayoutMetrics` puts the
    /// real column at ~391pt there, and anything that clears this clears that, so the test cannot
    /// pass on an over-generous estimate of the room available.
    private static var documentWidthAtWindowFloor: CGFloat {
        760 - 150 - EditorLayoutMetrics.railWidth - 2 * LiquidGlass.cardGutter
    }

    /// **Where the words survive at the narrowest window the app allows — pinned as a boundary,
    /// not as a verdict.**
    ///
    /// `minDocumentWidth` (260) is the split clamp's floor and the labelled rung has never fitted
    /// it; that is what the glyph rung above is for. This asks the other question: at the 760pt
    /// window floor, with the folder sidebar at its own 150pt minimum, does the reader still get
    /// the words? Not at every text size — so what is pinned is the percent where it turns over.
    ///
    /// **Swept over `selectablePercents`, not `allCases`.** The four named presets are what the UI
    /// offers by name; the slider lands on every step from 90 to 135. A four-row table would have
    /// reported "Large fits, Largest does not" and left the six steps between them unmeasured.
    /// Measured 2026-08-31 on this code, the last percent that fits is **130** — so the shed is
    /// confined to **135 alone**, the top of the range and the `Largest` preset, where the rung is
    /// 251pt and 251 + 120 = 371 against a 368pt column. Three points over.
    ///
    /// That corner is new, and it is what two changes landing together cost: "Edit" became
    /// "Source" (+15 to +20pt across the range) and the glyph box started scaling with the type
    /// ramp instead of sitting in a pinned 13×13. **Neither alone crossed it** — with "Edit" at
    /// 135 the rung was 231, and 231 + 120 = 351 fitted. Above the boundary the names stay
    /// reachable through the tooltip and the accessibility label, which is the bargain the
    /// workspace bar strikes too, and only at the narrowest window the app allows.
    ///
    /// Pinning the boundary is what makes this fail in BOTH directions: a longer label drags it
    /// down through the presets, and anything that buys width back pushes it up — and either way
    /// the failure names the percent rather than only saying "too wide".
    @Test func theWordsShedAtTheNarrowestWindowOnlyAtTheTopOfTheTextRange() {
        let column = Self.documentWidthAtWindowFloor
        let fitting = FontSize.selectablePercents.filter { percent in
            capsule(.labelled, scale: FontSize(percent: percent).scale).width
                + Self.nameAllowance <= column
        }
        // Contiguous from the bottom, or "the last one that fits" is not a boundary at all.
        #expect(fitting == Array(FontSize.selectablePercents.prefix(fitting.count)),
                "the percents that fit are \(fitting) — not a contiguous run, so there is no single boundary")
        #expect(fitting.last == 130, """
                the labelled capsule sheds its words above \(fitting.last.map(String.init) ?? "no")% \
                rather than 130% — at the 760pt window floor the \(column)pt document column takes \
                the rung plus a \(Self.nameAllowance)pt name up to there. Re-measure and move this \
                number deliberately; do not widen the allowance to make it go away.
                """)
    }

    /// …and the labelled rung is genuinely wider, or the ladder has nothing to choose between and
    /// the check above is measuring the only rung there is.
    @Test func theLabelledRungIsTheWiderOneItShedsFrom() {
        for scale in scales {
            let labelled = capsule(.labelled, scale: scale).width
            let glyphs = capsule(.glyphOnly, scale: scale).width
            #expect(labelled > glyphs + 40,
                    "at scale \(scale) the two rungs measure \(labelled) and \(glyphs) — the words cost almost nothing, so shedding them buys almost nothing")
        }
    }

    /// The capsule is one width whichever segment is selected — a control that resized as the
    /// selection moved would shift the filename beside it on every click. It did: the selected
    /// segment was semibold and the others medium, and weight changes width.
    @Test func theCapsuleIsOneWidthWhicheverModeIsSelected() {
        for rung in [EditorModeBar.Rung.labelled, .glyphOnly] {
            let widths = EditorMode.allCases.map { capsule(rung, mode: $0).width }
            #expect(Set(widths.map { ($0 * 100).rounded() }).count == 1,
                    "the \(rung) capsule measures \(widths) across the three selections")
        }
    }

    /// It grows with the app's type rather than staying pinned — the failure that would make the
    /// ceiling check above vacuous.
    ///
    /// **Both rungs, and the glyph-only one is why this test was rewritten.** It measured the
    /// labelled rung alone, which scaled the whole time because its words are `Text` — so it went
    /// green over a glyph-only rung that measured **85pt at every one of the four sizes**, its
    /// symbols framed at a hard `13×13` while the glyphs inside them grew and overflowed. A rung
    /// the ceiling checks above are asked about is a rung this has to be asked about too.
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
        let sizes = (1...6).map { MarkdownPreview.headingSize($0) }
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

    /// **The rungs have to be strictly narrower in order, or `ViewThatFits` never reaches them.**
    ///
    /// It takes the first candidate that fits, so a "narrower" rung that measures wider than the
    /// one before it is dead code that no width can select — the failure mode is silent, and the
    /// strip simply truncates at the size the shedding was written for.
    @Test func eachStatusRungIsNarrowerThanTheOneBeforeIt() {
        for scale in scales {
            let widths = EditorStatusLine.Rung.allCases.map {
                size(statusLine($0).environment(\.appFontScale, scale)).width
            }
            #expect(widths == widths.sorted(by: >),
                    "at scale \(scale) the rungs measure \(widths), which is not strictly narrowing")
        }
    }

    /// The narrowest rung has to fit the narrowest column the layout will ever give it, at every
    /// text size — otherwise the strip truncates in a window the app itself allows.
    @Test func theNarrowestStatusRungFitsTheNarrowestDocumentColumn() {
        for scale in scales {
            let width = size(statusLine(.caret).environment(\.appFontScale, scale)).width
            #expect(width <= EditorLayoutMetrics.minDocumentWidth,
                    "the caret-only rung is \(width)pt against a \(EditorLayoutMetrics.minDocumentWidth)pt column at scale \(scale)")
        }
    }

    /// A five-figure count is wider than a one-figure count, so the rung widths above are a
    /// property of the numbers as well as of the layout. This is the positive control for the two
    /// tests above: without it they would pass over a strip that rendered no numbers at all.
    @Test func theStatusLineReallyDrawsItsNumbers() {
        let small = size(statusLine(.full, words: 1, characters: 4)).width
        let large = size(statusLine(.full, words: 4_218, characters: 24_907)).width
        #expect(large > small + 20,
                "the full rung measured \(small) with tiny numbers and \(large) with large ones")
    }

    // MARK: The rail's tabs

    /// **The words fit both halves at every text size — measured, not assumed.**
    ///
    /// The bar spans a rail that is 232pt and cannot be anything else, in two equal halves, so what
    /// decides whether "Text Files" truncates is the widest label in HALF the bar. An ideal-width
    /// reading of the real bar would answer about the sum of the two, which is a different and more
    /// forgiving number — hence `tabs:`, which puts the widest title in both halves and measures the
    /// layout's actual worst case. `fittingSize` overstates a symbol's ink by a few points, so this
    /// errs toward failing early, which is the safe direction for a ceiling.
    @Test func theRailTabsFitTheRailAtEveryTextSize() {
        let widest = EditorRailTab.allCases.max { $0.title.count < $1.title.count } ?? .files
        // What the bar is actually handed: the rail, less the 10pt it is inset by on each side.
        let available = EditorLayoutMetrics.railWidth - 20
        for scale in scales {
            let bar = EditorRailTabBar(tab: .constant(.files),
                                       tabs: [widest, widest],
                                       accent: .blue, onAccent: .white)
                .environment(\.appFontScale, scale)
            let measured = size(bar).width
            #expect(measured <= available,
                    "“\(widest.title)” in both halves measured \(measured) against \(available) at scale \(scale) — the label truncates")
        }
    }

    /// Both tabs draw at the one width the layout reserves — the rail is hard-framed, so this is
    /// really asking that neither half's content escapes the frame and pushes it.
    @Test func eitherTabDrawsAtTheReservedWidth() {
        let files = size(rail(entries: [entry("one.md")], tab: .files))
        let outlined = size(rail(entries: [entry("one.md")],
                                 outline: (1...3).map { heading("Row \($0)", line: $0) },
                                 tab: .outline))
        #expect(abs(files.width - EditorLayoutMetrics.railWidth) < 0.51,
                "the files tab drew at \(files.width)")
        #expect(abs(outlined.width - EditorLayoutMetrics.railWidth) < 0.51,
                "the outline tab drew at \(outlined.width)")
    }

    // MARK: The outline tab

    /// **The eight-row cap is gone with the stack that needed it**, which is half the point of the
    /// tabs: the outline has the whole card, so its twelfth row is drawn as surely as its fourth.
    /// Twelve against four, either side of the old ceiling.
    @Test func theOutlineTabDrawsPastTheRowCapTheStackImposed() {
        let four = size(rail(entries: [entry("one.md")],
                             outline: (1...4).map { heading("Row \($0)", line: $0) },
                             tab: .outline))
        let twelve = size(rail(entries: [entry("one.md")],
                               outline: (1...12).map { heading("Row \($0)", line: $0) },
                               tab: .outline))
        #expect(twelve.height > four.height,
                "twelve outline rows measured \(twelve.height) against four rows' \(four.height) — something is still capping the section")
    }

    /// The rows are really drawn rather than reserved: one row is shorter than four.
    @Test func theOutlineGrowsWithItsRows() {
        let one = size(rail(entries: [entry("one.md")], outline: [heading("A", line: 1)],
                            tab: .outline))
        let four = size(rail(entries: [entry("one.md")],
                             outline: (1...4).map { heading("Row \($0)", line: $0) },
                             tab: .outline))
        #expect(four.height > one.height,
                "four outline rows measured \(four.height) against one row's \(one.height)")
    }

    /// **The two empties are different questions.** Nothing open, and something open with no
    /// headings in it — a `.txt`, or a note that never types a `#`. The second is where "there are
    /// none" is unhelpful, so it says what makes one.
    @Test func theEmptyOutlineSaysWhichEmptyItIs() {
        let noFile = EditorFileRailView.outlineEmptyCaption(hasDocument: false)
        let noHeadings = EditorFileRailView.outlineEmptyCaption(hasDocument: true)
        #expect(noFile != noHeadings, "both empties say the same thing: \(noFile)")
        #expect(noFile.lowercased().contains("open"),
                "the no-document caption does not say to open something: \(noFile)")
        #expect(noHeadings.contains("#"),
                "the no-headings caption does not say what makes a heading: \(noHeadings)")
    }

    /// An empty outline is a caption, not a blank card.
    ///
    /// **Asserted as a difference between the two captions, not as a height floor.** A floor is
    /// what this was first written as — `> 60pt` — and the tabs and the context line clear that on
    /// their own, so it passed with the caption replaced by an empty string. The two captions are
    /// different lengths and wrap to different numbers of lines in a 232pt rail, so comparing them
    /// is a measurement of the words themselves: blank either one and the heights collapse together.
    @Test func theEmptyOutlineTabDrawsTheCaptionAndNotJustSpace() {
        let noHeadings = size(rail(entries: [entry("one.md")], tab: .outline))
        let noFile = size(rail(entries: [], tab: .outline, selected: .some(nil)))
        #expect(noHeadings.height > noFile.height,
                "the two empty captions laid out to the same height — \(noHeadings.height) and \(noFile.height) — so at least one of them is not being drawn")
    }

    // MARK: The document header

    private func document(named name: String, text: String = "hello") throws -> EditorDocument {
        let folder = NSTemporaryDirectory() + "hdr-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: path, into: document)
        return document
    }

    private func workspace(_ document: EditorDocument) -> EditorWorkspaceView {
        EditorWorkspaceView(
            document: document,
            autosavePolicy: EditorAutosavePolicy(),
            folder: "/n",
            entries: [],
            accent: .blue,
            onAccent: .white,
            mode: .constant(.edit),
            splitFraction: .constant(0.5),
            isNaming: .constant(false),
            typedName: .constant(""),
            railFilter: .constant(""),
            railFilterIsExpanded: .constant(false),
            railTab: .constant(.files),
            railOutlineAnchors: .constant([:]),
            undoManager: UndoManager(),
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            onOpen: { _ in },
            onCreate: { _ in true },
            onRevealInBrowse: { _ in })
    }

    /// **A `.md` and a `.txt` header must be the same height**, or the document column below them
    /// starts at two different places depending on which file you opened — which is what it did:
    /// the mode capsule is the tallest thing in the top row and a plain-text file has no capsule,
    /// so its header was measurably shorter.
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

    /// **The assumption the reservation rests on, and it was unpinned.** The hidden capsule sits
    /// inside a zero-width frame, so its `ViewThatFits` is proposed no width and picks the NARROWEST
    /// rung — the glyph-only one. That only reserves the right height because both rungs happen to
    /// be the same height: measured, 22 · 23 · 27 · 28pt across the four text sizes. Change the
    /// labelled rung's padding or its font and that stops being true, the reservation quietly
    /// under-reserves, and the two headers diverge again with nothing failing.
    @Test func bothCapsuleRungsAreTheSameHeight() {
        for scale in scales {
            let labelled = size(EditorModeBar(mode: .constant(.edit), accent: .blue,
                                              onAccent: .white, forcedRung: .labelled)
                                .environment(\.appFontScale, scale))
            let glyph = size(EditorModeBar(mode: .constant(.edit), accent: .blue,
                                           onAccent: .white, forcedRung: .glyphOnly)
                             .environment(\.appFontScale, scale))
            #expect(abs(labelled.height - glyph.height) < 0.51,
                    "at scale \(scale) the rungs are \(labelled.height)pt and \(glyph.height)pt tall")
            // The positive control: they differ in WIDTH, which is what the rungs are for.
            #expect(labelled.width > glyph.width + 10,
                    "the two rungs measure the same width — the shedding is not happening")
        }
    }

    /// The mechanism the fix rests on, pinned on its own: a hidden capsule inside a zero-width
    /// frame still contributes its HEIGHT. If `.frame(width: 0)` ever flattened the height too, the
    /// test above would go green only because both headers had lost the reservation together.
    @Test func aZeroWidthHiddenCapsuleStillReservesItsHeight() {
        for scale in scales {
            let visible = size(EditorModeBar(mode: .constant(.edit), accent: .blue, onAccent: .white)
                                .environment(\.appFontScale, scale))
            let reserved = size(EditorModeBar(mode: .constant(.edit), accent: .blue, onAccent: .white)
                                .hidden().frame(width: 0)
                                .environment(\.appFontScale, scale))
            #expect(abs(visible.height - reserved.height) < 0.51,
                    "at scale \(scale) the reservation is \(reserved.height)pt against \(visible.height)")
            #expect(reserved.width < 0.51,
                    "the reservation is holding \(reserved.width)pt of width it should not")
        }
    }

}
