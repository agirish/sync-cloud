import AppKit
import SwiftUI
import Testing
import Sync
@testable import Dashboard
import Design

/// The pane bar's narrow-pane ladder, now that the rung is **computed** rather than searched.
///
/// `PaneHeader.navCluster` used to hand ten candidate bars to `ViewThatFits` and let it build every
/// one to measure it. `PaneBarLadder` replaces the search with arithmetic over `PaneNavMetrics`, so
/// the load-bearing claim is no longer "the layout engine will work it out" but "these numbers
/// describe the bar that is actually drawn". That claim is only worth anything if it is checked
/// against the drawn bar, which is what this suite does — every geometry assertion here reads the
/// LAID-OUT result out of a real hosting view, never a constant against another constant.
///
/// Controls are counted and located by `_FocusRingView`, the same handle
/// `PaneHeaderHeightTests.buttonCount` reaches for: a SwiftUI `Button` with a custom style draws into
/// a layer and puts no `NSControl` in the AppKit tree at all, and an offscreen `NSHostingView` has an
/// empty accessibility tree.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneBarLadderTests {

    /// The pane's own trailing inset — `PaneHeader.body`'s `.padding(.horizontal, 14)`.
    private static let contentInset: CGFloat = 14

    // MARK: - Reading the drawn bar

    /// Every `_FocusRingView` in the laid-out header, in reading order.
    private func rings<V: View>(_ view: V, width: CGFloat) -> [CGRect] {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") {
                found.append(v.convert(v.bounds, to: host))
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        return found.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The bar's rings only — the breadcrumb below it sits on a lower row.
    private func barRings<V: View>(_ view: V, width: CGFloat) -> [CGRect] {
        let all = rings(view, width: width)
        guard let top = all.map(\.minY).min() else { return [] }
        return all.filter { $0.minY < top + 5 }
    }

    /// The laid-out width of one rung's bar, measured from the view that draws it.
    ///
    /// Ring spans were the measure here, and they were exact for as long as every item's box *was*
    /// its pill. Titles ended that: an item is as wide as the wider of its pill and its word, so
    /// where the word wins the pill is centred inside a wider box and the outermost overhang falls
    /// outside the rings entirely — the Preview rung ends 5pt before its box does. Interior
    /// overhangs still show up, because they push their neighbours apart, which is exactly what
    /// makes the shortfall hard to spot by eye: the number is nearly right.
    ///
    /// So measure the bar instead of inferring it from its contents. `barVariant` is an `HStack` of
    /// fixed-width boxes with a `Spacer(minLength: 0)` for the flexible space, so its fitting width
    /// is the rung's minimum — the same quantity `PaneBarLayout.width` computes.
    /// `theMeasuredBarAgreesWithRingSpansWhenNothingIsTitled` is the guard that this method is not
    /// quietly reporting something else.
    private func barWidth(_ view: PaneHeader, rung: Int, ladder: PaneBarLadder) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.barVariant(rung, ladder)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private func fingerprint<V: View>(_ view: V, width: CGFloat) -> String {
        rings(view, width: width)
            .map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded()))/\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            .joined(separator: " ")
    }

    // MARK: - Fixtures

    private static func header(_ providerName: String?,
                               mode: PaneViewMode? = .columns,
                               collapse: Bool = false) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: providerName.map {
                CloudProvider(id: "icloud", displayName: $0, imageName: "icloud-logo",
                              path: "/Users/test/iCloud", type: .iCloud)
            },
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onCollapse: collapse ? {} : nil,
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: mode.map { .constant($0) }, onNewFolder: {})
    }

    /// The ladder a full Columns header actually builds.
    ///
    /// `available` is read off a real `PaneHeader` rather than restated, because the arithmetic under
    /// test is per-ladder: a hand-copied list keeps every assertion below green while the header
    /// quietly builds a different ladder. `ceiling` likewise comes from the icon-size preference's
    /// own mapping instead of a literal `.small`.
    /// **The view's own ladder, not a rebuilt one.** This used to assemble a `PaneBarLadder` from
    /// `.default`, the view's `availableItems` and the icon-size mapping — one parameter short of
    /// what the header builds the moment a new one is added. `labelMode` proved it: the rebuilt
    /// ladder defaulted to `iconOnly` while the header read `iconAndText`, so every assertion below
    /// compared a titled bar against untitled arithmetic. Asking the view removes the class.
    private static func columnsLadder(_ view: PaneHeader = header("iCloud Drive")) -> PaneBarLadder {
        view.barLadder
    }

    // MARK: - The arithmetic against the drawn bar

    /// The claim the whole change rests on: the width `PaneBarLadder` computes for a rung is the width
    /// the bar drawn at that rung actually occupies.
    ///
    /// Anchored at the two ends of the ladder, where which rung is chosen is not in doubt: a 250pt
    /// pane (the split's clamp, and the width the ladder exists for) can only take the narrowest rung,
    /// and a 900pt pane comfortably takes rung 0. The bar is measured from the leading edge of its
    /// first control to the trailing edge of its last.
    @Test(arguments: [(CGFloat(250), true), (CGFloat(900), false)])
    func aRungOccupiesTheWidthTheLadderComputes(width: CGFloat, isNarrow: Bool) {
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        let rung = isNarrow ? ladder.terminal : 0
        #expect(!barRings(view, width: width).isEmpty, "the header drew no controls at all")

        // Half a point of tolerance, and only that: `fittingSize` reports whole points, while a
        // titled rung's arithmetic lands on a half (SwiftUI rounds a text run up to the next half
        // point — see `LabelMetrics.ceilToHalf`). The tolerance covers that rounding and nothing
        // else; a rung that drew a different bar misses by pills, not by fractions.
        let drawn = barWidth(view, rung: rung, ladder: ladder)
        #expect(abs(drawn - ladder.width(forRung: rung)) <= 0.5,
                "rung \(rung) drew \(drawn)pt, computed \(ladder.width(forRung: rung))pt")
    }

    /// That `barWidth` measures the bar and not something adjacent to it.
    ///
    /// A `fittingSize` is only as trustworthy as the view under it — a greedy child reports the
    /// offer rather than the content, which is how `ScrollView` fixtures in this repo have measured
    /// nothing at all. So it is checked against the method it replaces, on the untitled rungs where
    /// ring spans are still exact: there every item's box is its pill, so the two must agree to the
    /// point.
    @Test func theMeasuredBarAgreesWithRingSpansWhenNothingIsTitled() {
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        for rung in (ladder.titledRungs)...ladder.terminal {
            let plan = ladder.plan(forRung: rung)
            let drawn = barRings(view, width: rung == ladder.terminal ? 250 : 900)
            guard let first = drawn.first, let trailing = drawn.map(\.maxX).max() else { continue }
            let leadsWithSwitch = plan.visible.first(where: { !$0.isSpacer }) == .viewMode
                && !plan.compactsViewMode
            let span = trailing - (first.minX - (leadsWithSwitch ? PaneNavMetrics.segmentPadding : 0))
            // Only the rung the header actually picks at this width can be compared against the
            // rings, so accept a match against any rung's measured width and require that the
            // measured and ringed answers name the same one.
            let measured = barWidth(view, rung: rung, ladder: ladder)
            #expect(measured > 0, "rung \(rung) measured zero — the fitting size is not reading the bar")
            if abs(measured - span) < 0.5 { return }
        }
        Issue.record("no untitled rung's measured width matched a ring span")
    }

    /// The failure mode the ladder exists to prevent, and the one with no loud symptom: a bar that
    /// runs past the pane's trailing edge. Swept rather than spot-checked, because the ladder is not
    /// monotonic — the provider capsule's own logo/no-logo step moves the bar's offer by 38pt, which
    /// is more than a rung.
    @Test func theBarNeverOverflowsThePane() {
        for name in ["Box", "Dropbox", "iCloud Drive", "Marketing Team Shared Archive Drive"] {
            for width in stride(from: CGFloat(250), through: 900, by: 25) {
                let drawn = barRings(Self.header(name), width: width)
                guard let trailing = drawn.map(\.maxX).max() else { continue }
                #expect(trailing <= width - Self.contentInset + 0.5,
                        "\(name) at \(width)pt: bar ends at \(trailing), pane content edge is \(width - Self.contentInset)")
            }
        }
    }

    /// Whatever rung is chosen, the bar drawn is *one of the ladder's rungs* — not some width in
    /// between. This is what catches an arithmetic drift that the overflow guard would sit through:
    /// a bar that fits but is not the bar any rung describes.
    @Test func theDrawnBarIsAlwaysSomeRungOfTheLadder() {
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        // Measured from the views themselves, so a rung whose boxes are wider than their pills —
        // any titled rung — is compared against what it actually occupies rather than against the
        // span of its focus rings. See `barWidth`.
        // **Rings compared against RINGS.** This measured each rung with `barWidth` — the width of
        // its BOXES — and then compared it to a span read off the drawn bar's focus RINGS, which is
        // shorter by the outermost title's overhang. The gap was absorbed with a blanket `+ 12` on
        // every rung, titled or not, and adjacent rungs differ by as little as ~4pt (the documented
        // non-monotonic pair): a whole missing 8pt `itemGap` fits inside that window. Measuring the
        // rung's own rings removes the mismatch instead of budgeting for it, so the tolerance goes
        // back to the ±0.5 the untitled ladder always had.
        let spans = (0...ladder.terminal).compactMap { ringSpan(view, rung: $0, ladder: ladder) }
        #expect(spans.count == ladder.terminal + 1,
                "a rung drew no rings at all — \(spans.count) of \(ladder.terminal + 1) measured")
        for width in stride(from: CGFloat(250), through: 900, by: 25) {
            let drawn = barRings(view, width: width)
            guard let first = drawn.first, let trailing = drawn.map(\.maxX).max() else { continue }
            // Both leading edges — with and without the switch's capsule ground.
            let base = [trailing - first.minX, trailing - first.minX + PaneNavMetrics.segmentPadding]
            #expect(base.contains(where: { span in
                spans.contains(where: { abs($0 - span) < 0.5 })
            }), "at \(width)pt the bar spans \(base), no rung of \(spans)")
        }
    }

    // MARK: - The untitled bar is priced as it was before titles

    /// **A gap widened for words must not be charged to a bar that has none.**
    ///
    /// `itemGap` went 6 → 8 as a plain constant when the bar learned titles. Both readers —
    /// `PaneBarLayout.width(of:)` and `PaneHeader.barContent` — charge it at every rung, so every
    /// *untitled* rung silently grew 2pt per gap as well, and the ladder stepped down at a pane
    /// ~16pt wider than it used to. The bill lands on the one element that cannot give way at the
    /// 250pt clamp, which is the provider capsule: its name is drawn by an AppKit menu label that
    /// **clips rather than ellipsises**, so `paneHeaderNarrow250WithColumnsControls` went from a
    /// readable "M" to a glyph sliced down the middle. Icon Only and the Large-text fallback are
    /// both untitled, so both were affected.
    ///
    /// **What holds the drawn half of this is `theLadderRendersItsGolden`**, whose 250pt rows pin
    /// the bar's leading edge at x=77 — the 6pt the capsule lost is exactly that edge moving to 71
    /// — plus the recorded snapshots. A pixel test counting the name's ink was written for this and
    /// then deleted: measured against the mutation that puts the gap back to 8, its count did not
    /// move at all, because a hosting view built here does not render the capsule the way the
    /// snapshot harness does. A test that cannot fail is worse than no test, and the golden already
    /// answers the question exactly.
    @Test func theUntitledLadderIsPricedAsItWasBeforeTitles() {
        // The values, pinned: the untitled gap is what it was before titles existed.
        #expect(PaneNavMetrics.itemGap(titled: false) == 6,
                "an untitled bar is paying for space between words it does not draw")
        #expect(PaneNavMetrics.itemGap(titled: true) == 8,
                "the titled bar lost the word spacing it was widened for")

        // …and the arithmetic that spends them: a rung's width must differ between the two modes by
        // exactly one extra point per gap, and by nothing else the gap can reach.
        let bar = Self.columnsLadder()
        for rung in 0...bar.terminal {
            let plan = bar.plan(forRung: rung)
            let size = bar.controlSize(forRung: rung)
            let gaps = (0..<plan.visible.count)
                .filter { PaneBarLayout.needsGap(before: $0, in: plan.visible) }.count
                + ((!plan.overflow.isEmpty && (plan.visible.last.map { $0 != .flexibleSpace } ?? false)) ? 1 : 0)
            let untitled = PaneBarLayout.width(of: plan, controlSize: size, titled: false)
            let titled = PaneBarLayout.width(of: plan, controlSize: size, titled: true)
            // Every item is at least as wide titled (a word may beat a pill), so the difference is
            // the gaps plus the words — never less than the gaps alone.
            #expect(titled - untitled >= CGFloat(gaps) * 2 - 0.01,
                    "rung \(rung): the titled bar is not charging its wider gaps")
        }
    }

    /// The span of one rung's focus rings, measured from the same view `barWidth` measures the
    /// boxes of — so the drawn bar can be compared like with like.
    private func ringSpan(_ view: PaneHeader, rung: Int, ladder: PaneBarLadder) -> CGFloat? {
        let variant = view.barVariant(rung, ladder)
        let drawn = barRings(variant, width: barWidth(view, rung: rung, ladder: ladder))
        guard let first = drawn.first, let trailing = drawn.map(\.maxX).max() else { return nil }
        return trailing - first.minX
    }

    // MARK: - The ladder's own arithmetic

    /// `ViewThatFits` takes the FIRST child that fits, and the ladder is deliberately not monotonic:
    /// shedding the preview toggle (a segment wide) to gain a ⋯ pill (a full pill plus its gap) makes
    /// the bar *wider*. A `rung(fitting:)` that sorted by width, or that returned the narrowest rung
    /// that fits, would pick a different bar than the search it replaces.
    @Test func theLadderIsNotMonotonicAndIsWalkedInOrder() {
        let ladder = Self.columnsLadder()
        // **Expressed relative to `titledRungs`, not as literals.** The non-monotonic pair is the
        // first `.mini` rung and the one after it — which used to be rungs 1 and 2 and are 2 and 3
        // once a titled rung sits at the head. Written as literals this test kept running and
        // stopped being about shedding: it would have compared the titled rung against an untitled
        // one, where being wider is the whole point rather than the anomaly.
        let firstMini = ladder.titledRungs + 1
        // The rung after the first `.mini` one sheds the preview toggle and gains ⋯ — measurably
        // wider than the rung that sheds nothing. If this ever stops being true the test has lost
        // its subject, not found a bug.
        #expect(ladder.width(forRung: firstMini + 1) > ladder.width(forRung: firstMini))
        // Offered exactly that rung's width, the walk must still answer it — never the narrower
        // rung after it that also fits, and never the wider one before it that does not.
        #expect(ladder.rung(fitting: ladder.width(forRung: firstMini)) == firstMini)
        #expect(ladder.rung(fitting: ladder.width(forRung: 0)) == 0)
        // A hair under rung 0 steps to rung 1, not past it.
        #expect(ladder.rung(fitting: ladder.width(forRung: 0) - 1) == 1)
    }

    /// Nothing fits: the ladder answers its narrowest rung rather than running off the end. This is
    /// the 250pt pane's case, and the reason the header can hand `ViewThatFits` a fallback at all.
    @Test func nothingFitsGivesTheNarrowestRung() {
        let ladder = Self.columnsLadder()
        #expect(ladder.rung(fitting: 0) == ladder.terminal)
        #expect(ladder.rung(fitting: ladder.width(forRung: ladder.terminal)) == ladder.terminal)
        // And the terminal rung is genuinely the narrowest — the property the fallback relies on.
        for rung in 0..<ladder.terminal {
            #expect(ladder.width(forRung: ladder.terminal) <= ladder.width(forRung: rung))
        }
    }

    /// The terminal rung is `maxDepth + 1`, and past it `PaneBarLayout.plan` is idempotent — which is
    /// what makes dropping the old ladder's surplus rungs a no-op rather than a behaviour change.
    @Test func theTerminalRungShedsEverythingSheddable() {
        let available: [PaneBarItem] = [.backForward, .sort, .hiddenFiles, .viewMode, .scan, .newFolder, .preview]
        let ladder = PaneBarLadder(arrangement: .default, available: available, ceiling: .small)
        let terminal = ladder.plan(forRung: ladder.terminal)
        #expect(terminal == PaneBarLayout.plan(arrangement: .default, available: available, depth: .max))
        #expect(terminal.compactsViewMode)
    }

    /// Each item measures what its view draws. These are the numbers every rung width is summed from,
    /// so a drift here is a drift everywhere — and the pill constants are shared with the views
    /// themselves rather than restated, which is what keeps the two in step.
    @Test func everyItemMeasuresWhatItDraws() {
        let pill = PaneNavMetrics.pill(.small)
        // Two segments, hair-spaced, on a padded ground.
        #expect(PaneBarLayout.width(of: .viewMode, pill: pill, compactsViewMode: false)
                == 2 * (pill.width - 4) + 3 + 6)
        // Compacted, it is one ordinary pill.
        #expect(PaneBarLayout.width(of: .viewMode, pill: pill, compactsViewMode: true) == pill.width)
        // One item, two pills.
        #expect(PaneBarLayout.width(of: .backForward, pill: pill, compactsViewMode: false)
                == 2 * pill.width + 6)
        // Styled as the switch's selected segment, so a segment wide.
        #expect(PaneBarLayout.width(of: .preview, pill: pill, compactsViewMode: false) == pill.width - 4)
        // A flexible space must cost the bar's minimum width nothing — that is what lets it pin the
        // bar to the trailing edge without widening it.
        #expect(PaneBarLayout.width(of: .flexibleSpace, pill: pill, compactsViewMode: false) == 0)
        #expect(PaneBarLayout.width(of: .space, pill: pill, compactsViewMode: false) == pill.width)
        #expect(PaneBarLayout.width(of: .sort, pill: pill, compactsViewMode: false) == pill.width)
    }

    /// The header with NO provider takes the *searched* ladder, not the computed rung — a second code
    /// path, and one nothing else here covers. It has to obey the same trailing-edge rule.
    ///
    /// It exists because that header has no provider capsule, so the bar itself is what decides the
    /// row's height, and the computed path's container cannot report a height derived from its
    /// content. This is reachable in the app: `ContentView` passes
    /// `availableProviders.first(where:)`, which is nil whenever a pane's provider has been disabled
    /// or has not loaded yet.
    @Test func theHeaderWithNoProviderStillFitsItsPane() {
        for width in stride(from: CGFloat(250), through: 900, by: 25) {
            let drawn = barRings(Self.header(nil), width: width)
            guard let trailing = drawn.map(\.maxX).max() else { continue }
            #expect(trailing <= width - Self.contentInset + 0.5,
                    "no-provider header at \(width)pt: bar ends at \(trailing)")
        }
    }

    /// The computed path pins its container to the NARROWEST rung's height (17pt) while the widest
    /// rung draws a 26pt view-switch ground — so the ground overflows its box by design.
    ///
    /// Focus rings say nothing about paint, and an overflow that gets clipped would look exactly like
    /// a correct layout to every other assertion in this file. So read the bitmap: measured 26.0pt,
    /// the ground's full height, which is what says nothing clips it.
    @Test func theTallestRungIsNotClippedByThePinnedContainer() {
        let width: CGFloat = 900
        let view = Self.header("iCloud Drive")
            .frame(width: width, height: LiquidGlass.headerHeight)
            .background(Color.white)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: width, height: LiquidGlass.headerHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let bar = barRings(Self.header("iCloud Drive"), width: width)
        guard let first = bar.min(by: { $0.minX < $1.minX }) else { Issue.record("no rings"); return }
        let scale = CGFloat(rep.pixelsHigh) / LiquidGlass.headerHeight
        let x0 = max(0, Int(((first.minX - 3) * scale).rounded()))
        let x1 = min(rep.pixelsWide, Int(((first.maxX + 3) * scale).rounded()))
        var minY = rep.pixelsHigh, maxY = -1
        for x in x0..<x1 {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let lum = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                guard c.alphaComponent > 0.05, lum < 0.97 else { continue }
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let painted = CGFloat(maxY - minY + 1) / scale
        let ladder = Self.columnsLadder()
        // **The untitled rung at the ceiling, not rung 0.** Painted ink is the right measure for a
        // row of pills and the wrong one for a row of words: a title's line box is 12pt while the
        // ink inside it is shorter, so a titled rung paints less than its height by design and an
        // equality here would fail on a bar that is perfectly fine.
        //
        // This is also now the proof of the height equalisation: the switch's ground lost its
        // vertical padding, so it paints exactly a pill tall — 20pt, where it used to paint 26 —
        // and every title therefore lands on one baseline. A regression that put the padding back
        // shows up here as 26 against 20 rather than as a misaligned word nobody measured.
        // The header picks its own rung at this width, and a titled one paints its word too — so
        // the claim is bounded rather than exact: everything the tallest rung can draw is on
        // screen, and nothing is drawing beyond it.
        #expect(painted <= ladder.height(forRung: 0) + 0.5,
                "painted \(painted)pt exceeds the tallest rung's \(ladder.height(forRung: 0))pt")
        #expect(painted >= PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height,
                "painted \(painted)pt is under a pill — the switch is clipped by the pin")
        // The equalisation itself, measured where it is exact: every ring on the bar's row is a
        // pill tall, the view switch's two segments included. A regression that put the ground's
        // vertical padding back shows up here as 26 rather than as a word 6pt out of line.
        let ringHeights = Set(bar.map(\.height))
        #expect(ringHeights == [PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height],
                "the bar's controls are not all a pill tall: \(ringHeights.sorted())")
    }

    /// **Nothing is taller than a pill any more**, the view switch included — and a titled rung is
    /// taller only by the word it carries.
    ///
    /// This asserted the opposite until titles arrived: the switch's ground had `segmentPadding` on
    /// all four edges, so it stood 6pt above its neighbours and the header pinned its container to
    /// that. Nothing showed it, because the 34pt provider capsule sets the row height. A title
    /// hangs on a baseline below its control, so the 6pt became a word sitting 6pt lower than every
    /// other word and a row 6pt over the header's 34pt budget. The ground stays and its vertical
    /// padding went — Finder's rule, where every toolbar ground is one height.
    ///
    /// The header still pins its container to these numbers, so a wrong answer moves the breadcrumb.
    @Test func onlyATitledRungIsTallerThanAPill() {
        let ladder = Self.columnsLadder()
        #expect(ladder.height(forRung: ladder.terminal) == PaneNavMetrics.pill(.mini).height)
        // The untitled rung at the ceiling: a plain pill, with the switch no longer out-topping it.
        let pill = PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height
        #expect(ladder.height(forRung: ladder.titledRungs) == pill)
        // The titled rung is the pill, the gap and one line of title — and must fit the budget the
        // pinned header allows, which is the gate `PaneBarTitleMetrics.rowFits` applies.
        if ladder.titledRungs > 0 {
            #expect(ladder.height(forRung: 0)
                    == PaneBarTitleMetrics.rowHeight(pillHeight: pill, scale: 1))
            #expect(ladder.height(forRung: 0) <= PaneBarTitleMetrics.rowBudget)
        }
    }

    // MARK: - The searched ladder's coverage

    /// The default arrangement plus six fixed spaces — a bar the palette can build today, and the
    /// shape that broke the old searched ladder: spacers are exempt from the duplicate rule, so
    /// they run `maxDepth` past the nine rungs the old ten-literal `ViewThatFits` covered.
    private static let spacerHeavy = PaneBarArrangement(
        PaneBarArrangement.default.items + Array(repeating: .space, count: 6))

    /// The deepest ladder the arrangement normalizer permits: `maxItems` items, all of them
    /// duplicate-exempt spaces except the scan control it forces on and will not shed.
    private static let worstArrangement =
        PaneBarArrangement(Array(repeating: PaneBarItem.space, count: PaneBarArrangement.maxItems - 1)
                           + [.scan])

    private static func ladder(_ arrangement: PaneBarArrangement) -> PaneBarLadder {
        PaneBarLadder(arrangement: arrangement,
                      available: header(nil).availableItems,
                      ceiling: PaneBarIconSize.regular.ceiling)
    }

    /// The three shapes the searched ladder has to serve, by depth: what almost every install runs,
    /// the palette-reachable spacer-heavy bar that falsified the old ten-rung premise, and the
    /// deepest bar the normalizer permits — which is the only fixture that reaches the last slots.
    private static var ladderFixtures: [(String, PaneBarLadder)] {
        [("default", ladder(.default)),
         ("spacer-heavy", ladder(spacerHeavy)),
         ("worst", ladder(worstArrangement))]
    }

    /// The rungs `ViewThatFits` can actually land on: first-fit takes the earliest child that fits,
    /// so a rung no narrower than one before it is unreachable by construction and no assertion may
    /// demand it (see `theLadderIsNotMonotonicAndIsWalkedInOrder`).
    private static func reachableRungs(_ ladder: PaneBarLadder) -> [Int] {
        var narrowest = CGFloat.greatestFiniteMagnitude
        var reachable: [Int] = []
        for rung in 0...ladder.terminal where ladder.width(forRung: rung) < narrowest {
            narrowest = ladder.width(forRung: rung)
            reachable.append(rung)
        }
        return reachable
    }

    /// The contract that was comment-only: the view declares exactly one child per slot.
    ///
    /// `searchedSlotCount` is otherwise production dead code — read only by tests — so nothing
    /// stopped the numbers drifting apart. Raise `maxItems` to 24 and the derived count becomes 25
    /// while `PaneHeader.searchedLadder` still lists seventeen literals, silently reinstating the
    /// rung-skipping hole; this counts the children of the real view and fails when it does.
    ///
    /// The count is read by reflection because a `ViewThatFits`'s children are only its generic
    /// `TupleView` — the check has to fail loudly if that shape ever changes, hence the `Optional`
    /// rather than a silent zero.
    @Test func theSearchedLadderDeclaresOneChildPerSlot() {
        // Derived, not restated: the ladder's depth is bounded by how long a bar can be, plus the
        // one rung `titledRungs` can add at its head.
        #expect(PaneBarLadder.searchedSlotCount == PaneBarArrangement.maxItems + 2)

        let view = Self.header(nil)
        let children = Self.viewThatFitsChildCount(view.searchedLadder(Self.ladder(.default)))
        #expect(children != nil, "cannot read ViewThatFits's children — the reflection path broke")
        #expect(children == PaneBarLadder.searchedSlotCount,
                "searchedLadder declares \(children.map(String.init) ?? "?") children, the contract says \(PaneBarLadder.searchedSlotCount)")
    }

    /// How many children a `ViewThatFits` declares, read off the view itself: its content is a
    /// `TupleView` whose `value` is the literal tuple of children. `nil` when that shape is not what
    /// this walks, so a broken reflection path is a failure and never a quiet pass.
    private static func viewThatFitsChildCount<V: View>(_ view: V) -> Int? {
        guard let tree = Mirror(reflecting: view).children.first(where: { $0.label == "_tree" })?.value,
              let content = Mirror(reflecting: tree).children.first(where: { $0.label == "content" })?.value,
              let tuple = Mirror(reflecting: content).children.first(where: { $0.label == "value" })?.value
        else { return nil }
        let mirror = Mirror(reflecting: tuple)
        guard mirror.displayStyle == .tuple else { return nil }
        return mirror.children.count
    }

    /// The slot arithmetic checked against the DEEPEST ladder the normalizer permits: 15
    /// duplicate-exempt spaces beside the pinned scan control, which is `maxDepth` 15 and so
    /// `terminal` 16.
    ///
    /// The old ladder declared ten literals under a comment claiming "`terminal` is at most 9 for
    /// any arrangement the palette can build" — false exactly here.
    ///
    /// The bound is asserted as an inequality over adversarial arrangements rather than only against
    /// a hand-written worst case, because the failure this guards is `maxItems` moving: a fixture
    /// that restates today's 16 would be updated alongside it and go green again.
    @Test func theSearchedSlotsCoverTheDeepestLadderAnyArrangementCanBuild() {
        let worst = Self.worstArrangement
        #expect(worst.items.count == PaneBarArrangement.maxItems)

        // **Built with titles on**, because that is the deepest ladder the slots must cover: the
        // titled rung sits at the head and pushes every other rung one further out. Built without
        // them this fixture measures a ladder one shorter than the worst case and would happily
        // certify a slot count that skips the terminal rung whenever the preference is on.
        let ladder = PaneBarLadder(arrangement: worst, available: [.scan], ceiling: .small,
                                   labelMode: .iconAndText, scale: 1)
        #expect(ladder.titledRungs == 1, "the worst case must include the titled rung")
        // The deepest terminal possible: every slot count below `terminal + 1` skips a rung here.
        #expect(ladder.terminal == PaneBarArrangement.maxItems + 1)
        #expect(ladder.terminal + 1 == PaneBarLadder.searchedSlotCount)

        let covered = Set((0..<PaneBarLadder.searchedSlotCount).map { ladder.searchedRung(forSlot: $0) })
        #expect(covered == Set(0...ladder.terminal),
                "slots cover \(covered.sorted()), ladder runs 0...\(ladder.terminal)")

        // No arrangement the normalizer will produce — spacer-packed, switch-carrying, or built for
        // a host that cannot even offer the scan control the normalizer forces on — outruns the
        // slots. These are the shapes that maximise `maxDepth`: sheddable items, plus the switch.
        let spaces = Array(repeating: PaneBarItem.space, count: PaneBarArrangement.maxItems)
        let adversarial: [(String, PaneBarArrangement, [PaneBarItem])] = [
            ("all spaces", PaneBarArrangement(spaces), Self.header(nil).availableItems),
            ("spaces + switch", PaneBarArrangement([.viewMode] + spaces), Self.header(nil).availableItems),
            ("spaces + every control", PaneBarArrangement(PaneBarItem.allCases + spaces),
             Self.header(nil).availableItems),
            ("no scan available", PaneBarArrangement(spaces), [.backForward, .sort, .hiddenFiles]),
            ("worst, full palette", worst, PaneBarItem.allCases),
        ]
        for (name, arrangement, available) in adversarial {
            let deep = PaneBarLadder(arrangement: arrangement, available: available, ceiling: .small)
            #expect(deep.terminal + 1 <= PaneBarLadder.searchedSlotCount,
                    "\(name): terminal \(deep.terminal) needs \(deep.terminal + 1) slots, the ladder declares \(PaneBarLadder.searchedSlotCount)")
        }
    }

    /// The rule this path is built on: a slot draws a real bar exactly where the rung it would draw
    /// is one no earlier slot draws, and every slot past `terminal` is inert — a stand-in that
    /// measures like the terminal bar and builds nothing.
    ///
    /// That is what keeps the provider-less header from building seventeen bars per layout pass for
    /// a default arrangement whose ladder has seven rungs. The last slot is the deliberate
    /// exception: `ViewThatFits` renders its last child when nothing fits, so it stays a real bar.
    ///
    /// (This replaces a test that asserted `PaneBarLayout.plan` differs at every rung — true, but
    /// owned by the arrangement's fold arithmetic and already pinned by `PaneBarArrangementTests`,
    /// not by anything the searched ladder does.)
    @Test func theSearchedLadderBuildsABarOnlyWhereTheRungChanges() {
        for (name, ladder) in Self.ladderFixtures {
            let last = PaneBarLadder.searchedSlotCount - 1
            var drawn: [Int] = []
            for slot in 0..<PaneBarLadder.searchedSlotCount {
                if ladder.searchedSlotDrawsBar(slot) { drawn.append(slot) }
                // Inert exactly past the terminal, and never at the fallback slot.
                #expect(ladder.searchedSlotIsInert(slot) == (slot > ladder.terminal && slot != last),
                        "\(name): slot \(slot) against terminal \(ladder.terminal)")
            }
            // One real bar per rung, plus the terminal bar again as the nothing-fits fallback.
            #expect(drawn == Array(0...ladder.terminal) + (ladder.terminal == last ? [] : [last]),
                    "\(name): builds bars at \(drawn)")
            // The stand-ins measure as the bar they replace, which is what makes them unreachable.
            for slot in 0..<PaneBarLadder.searchedSlotCount where ladder.searchedSlotIsInert(slot) {
                #expect(ladder.searchedRung(forSlot: slot) == ladder.terminal)
            }
        }
    }

    /// The claim on drawn pixels, exactly: offered a rung's own width, the searched ladder draws
    /// THAT rung's bar — the same view `barVariant` builds for it, ring for ring.
    ///
    /// Offering the rung's exact width is what makes this precise rather than a sampling: for a
    /// first-fit-reachable rung every earlier child is strictly wider, so that width selects it and
    /// nothing else. The old version of this test swept header widths in 5pt steps, which asserted
    /// the same thing only while every rung's fit band stayed wider than the stride — a fixture
    /// property, not a code property — and its spacer-heavy fixture stopped at `terminal` 12, so the
    /// last four slots were never exercised at all. The worst-case fixture reaches slot 16.
    ///
    /// A stand-in slot being selected would draw an empty bar, so the ring count is asserted
    /// non-empty: an all-empty comparison would otherwise pass by matching nothing against nothing.
    @Test func theSearchedLadderDrawsTheRungEachOfferSelects() {
        let view = Self.header(nil)
        for (name, ladder) in Self.ladderFixtures {
            for rung in Self.reachableRungs(ladder) {
                let width = ladder.width(forRung: rung)
                let searched = fingerprint(view.searchedLadder(ladder), width: width)
                let direct = fingerprint(view.barVariant(rung, ladder), width: width)
                #expect(!direct.isEmpty, "\(name) rung \(rung): the bar itself drew nothing")
                #expect(searched == direct,
                        "\(name) at \(width)pt (rung \(rung)) drew \(searched), rung \(rung) is \(direct)")
            }

            // Nothing fits — the 250pt pane's case. `ViewThatFits` falls through to its LAST child,
            // which is why that slot stays a real bar however far past `terminal` it sits: an inert
            // stand-in there would leave the narrowest pane with no bar at all.
            let squeezed = ladder.width(forRung: ladder.terminal) - 20
            let fallback = fingerprint(view.searchedLadder(ladder), width: squeezed)
            let terminal = fingerprint(view.barVariant(ladder.terminal, ladder), width: squeezed)
            #expect(!terminal.isEmpty, "\(name): the terminal bar itself drew nothing")
            #expect(fallback == terminal,
                    "\(name) squeezed to \(squeezed)pt drew \(fallback), the terminal rung is \(terminal)")
        }
    }

    /// The end-to-end half, in the real header: a spacer-heavy no-provider header steps through
    /// every deep rung — the ones past the old ladder's ninth — at pane widths it can actually be
    /// given, rather than jumping from rung 8 to full compaction. Reverting `searchedLadder` to ten
    /// literals fails this; rungs 10 and 11 never appear at any width.
    ///
    /// This is the one test that goes through `@AppStorage` and the whole header, so it is also what
    /// says the arrangement a user stored is the arrangement the ladder is built from. The exact
    /// per-rung claim, free of the header's own geometry, is
    /// `theSearchedLadderDrawsTheRungEachOfferSelects`.
    ///
    /// Sampling a stride makes the fixture load-bearing — a rung whose band of pane widths is
    /// narrower than the stride would fall between two samples and fail for a fixture reason rather
    /// than a code one. So the premise is asserted rather than assumed: the narrowest gap between
    /// consecutive reachable rungs is checked against the stride before the sweep runs.
    @Test func theNoProviderHeaderReachesTheDeepRungs() {
        let defaults = ScratchDefaults("PaneBarLadderTests-spacerHeavy")
        defaults.set(Self.spacerHeavy.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        let view = Self.header(nil).defaultAppStorage(defaults)
        let ladder = Self.ladder(Self.spacerHeavy)
        let reachable = Self.reachableRungs(ladder)
        let deep = reachable.filter { $0 > 8 && $0 < ladder.terminal }
        // The premise: there IS something between rung 8 and the terminal to skip.
        #expect(!deep.isEmpty, "the fixture has no deep rungs — it has lost its subject")

        let step: CGFloat = 10
        for (wider, narrower) in zip(reachable, reachable.dropFirst()) {
            #expect(ladder.width(forRung: wider) - ladder.width(forRung: narrower) > step,
                    "rungs \(wider)/\(narrower) are \(ladder.width(forRung: wider) - ladder.width(forRung: narrower))pt apart, the sweep steps \(step)pt")
        }

        var seen = Set<Int>()
        for width in stride(from: CGFloat(250), through: 900, by: step) {
            let drawn = barRings(view, width: width)
            guard let first = drawn.min(by: { $0.minX < $1.minX }),
                  let trailing = drawn.map(\.maxX).max() else { continue }
            let span = trailing - first.minX
            for rung in deep where abs(span - ladder.width(forRung: rung)) < 0.5
                || abs(span + PaneNavMetrics.segmentPadding - ladder.width(forRung: rung)) < 0.5 {
                seen.insert(rung)
            }
        }
        #expect(seen == Set(deep),
                "the header drew rungs \(seen.sorted()) of the deep rungs \(deep) between 250 and 900pt")
    }

    // MARK: - Golden

    /// The laid-out header, pinned whole, at the widths and text sizes that move the ladder.
    ///
    /// Recorded by rendering the ladder BEFORE it was computed rather than searched, so this table is
    /// the old ten-rung `ViewThatFits`'s own output: every entry here is a bar the search produced.
    /// The one difference the change does make is deliberate and is called out in the commit — at the
    /// Small text size the breadcrumb can sit 1pt higher, because the bar's container is now pinned to
    /// the narrowest rung's height and a 0.9-scaled provider name is shorter than a rung carrying the
    /// view switch. No control moves.
    ///
    /// Two changes have re-recorded it since, and the *shape* of each re-recording is the useful part.
    ///
    /// **Titles moved exactly two of these sixteen rows** — only `iCloud` at 710pt, at both text
    /// sizes. Every narrower row is on a `.mini` rung where titles have already shed, and `longName`
    /// at 710pt was *unchanged* because its wider provider capsule leaves too little track for the
    /// titled rung, so the ladder fell through to the untitled one and drew precisely what it drew
    /// before. That row was the evidence that the titled rung is a ceiling rather than a pin.
    ///
    /// **Widening the gap from 6 to 8pt moved all sixteen**, which is what a constant paid at every
    /// gap of every rung does. Fifteen of them moved and kept their shape; the two flagged in the
    /// table shed the Preview toggle into ⋯ at a width that used to hold it. A row that changes ring
    /// *count* is the one worth reading — it is the ladder stepping down, not the bar sliding.
    /// One golden row, as data rather than a string to be re-parsed.
    ///
    /// The keys used to be `"columns-icloud|0.9|250"`, split apart and force-unwrapped at read time.
    /// That was two hazards for nothing: a malformed key crashed the whole test host on a `!`, and the
    /// provider name came from `parts[0] == "columns-icloud" ? … : longName`, so ANY key that was not
    /// exactly that string silently tested the long name instead. Adding a third fixture would have
    /// looked like a golden mismatch rather than a typo.
    private struct Golden {
        let name: String
        let scale: CGFloat
        let width: CGFloat
        let rings: String
    }

    @Test func theLadderRendersItsGolden() {
        for row in Self.golden {
            let view = Self.header(row.name).environment(\.appFontScale, row.scale)
            #expect(fingerprint(view, width: row.width) == row.rings,
                    "\(row.name) @ scale \(row.scale), width \(row.width)")
        }
    }

    private static let iCloud = "iCloud Drive"
    private static let longName = "Marketing Team Shared Archive Drive"

    private static let golden: [Golden] = goldenTable.map {
        Golden(name: $0.0, scale: $0.1, width: $0.2, rings: $0.3)
    }

    private static let goldenTable: [(String, CGFloat, CGFloat, String)] = [
        (iCloud, 0.9, 250, "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/37x13 49,508/58x13 110,508/44x13"),
        (iCloud, 0.9, 410, "212,481/23x17 238,481/23x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,515/37x13 49,515/58x13 110,515/44x13"),
        (iCloud, 0.9, 490, "197,481/23x17 223,481/23x17 255,481/27x17 288,481/27x17 321,481/27x17 354,481/27x17 387,481/27x17 420,481/27x17 453,481/23x17 10,515/37x13 49,515/58x13 110,515/44x13"),
        // **A titled row, and one of only two rows here that is not identical to `v4.0`.** The bar
        // starts further left of its trailing edge because words are wider than their pills, and
        // its controls sit 6pt higher to make room for the title line beneath them. Ring heights
        // are unchanged at 20 — the switch is a pill tall in both modes. This row legitimately
        // differs from `v4.0`, which had no titles; its sibling is (iCloud, 1.0, 710). Every other
        // row in this table was checked byte-for-byte against `v4.0` when the untitled gap was put
        // back to 6, and matched.
        (iCloud, 0.9, 710, "329,473/29x20 361,473/29x20 401,473/33x20 440,473/33x20 481,473/33x20 530,473/33x20 580,473/33x20 621,473/33x20 665,473/29x20 10,515/37x13 49,515/58x13 110,515/44x13"),
        (iCloud, 1.0, 250, "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (iCloud, 1.0, 330, "157,481/27x17 190,481/27x17 223,481/27x17 256,481/27x17 289,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (iCloud, 1.0, 410, "212,481/23x17 238,481/23x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        // **This row is the one to read if the untitled gap is ever widened again.** Charging the
        // titled bar's 8pt gap to this untitled rung cost it a control: nine rings became eight as
        // the trailing 23-wide segment — the Preview toggle — was shed into ⋯ at a width that had
        // always held it. It is nine again here, matching `v4.0` exactly, and its sibling
        // (longName, 650) with it. Nothing was ever *lost* (Preview stays in the menu), which is
        // why a ladder stepping down early is so easy to ship: it is only visible as a control
        // that used to be on the bar and now is not.
        (iCloud, 1.0, 490, "197,481/23x17 223,481/23x17 255,481/27x17 288,481/27x17 321,481/27x17 354,481/27x17 387,481/27x17 420,481/27x17 453,481/23x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        (iCloud, 1.0, 570, "223,479/29x20 255,479/29x20 293,479/33x20 332,479/33x20 371,479/33x20 410,479/33x20 449,479/33x20 488,479/33x20 527,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15"),
        (iCloud, 1.0, 710, "319,472/29x20 351,472/29x20 391,472/33x20 430,472/33x20 471,472/33x20 523,472/33x20 575,472/33x20 617,472/33x20 663,472/29x20 10,514/39x15 52,514/63x15 117,514/47x15"),
        (longName, 1.0, 250, "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (longName, 1.0, 410, "237,481/27x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (longName, 1.0, 490, "317,481/27x17 350,481/27x17 383,481/27x17 416,481/27x17 449,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (longName, 1.0, 570, "372,481/23x17 398,481/23x17 430,481/27x17 463,481/27x17 496,481/27x17 529,481/27x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        // The second of the two — same cause, same shed control, 160pt further out because this
        // provider name eats that much of the row before the bar sees any of it.
        (longName, 1.0, 650, "357,481/23x17 383,481/23x17 415,481/27x17 448,481/27x17 481,481/27x17 514,481/27x17 547,481/27x17 580,481/27x17 613,481/23x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        (longName, 1.0, 710, "363,479/29x20 395,479/29x20 433,479/33x20 472,479/33x20 511,479/33x20 550,479/33x20 589,479/33x20 628,479/33x20 667,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15"),
    ]

}
