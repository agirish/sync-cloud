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

    private func rail(entries: [EditorRailEntry], naming: Bool = false) -> EditorFileRailView {
        EditorFileRailView(
            folderName: "Notes",
            entries: entries,
            selectedPath: entries.first?.path,
            accent: .blue,
            isNaming: .constant(naming),
            typedName: .constant(""),
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            onOpen: { _ in },
            onCreate: { _ in true })
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
    /// the assertion that found the labelled capsule too wide to sit there at any text size — 185pt
    /// at the default against a 260pt column — which is why the control sheds its words at all.
    @Test func theGlyphRungFitsTheNarrowestDocumentColumnAtEveryTextSize() {
        // What the header must still be able to show of a file name beside the capsule.
        let nameAllowance: CGFloat = 120
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
    @Test func theCapsuleGrowsWithTheAppsTextSize() {
        let smallest = capsule(.labelled, mode: .edit, scale: scales.min() ?? 1).width
        let largest = capsule(.labelled, mode: .edit, scale: scales.max() ?? 1).width
        #expect(largest > smallest,
                "the capsule measures \(smallest) at the smallest text size and \(largest) at the largest — it is not scaling")
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
}
