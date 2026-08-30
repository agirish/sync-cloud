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

    /// **The card is balanced top to bottom, at every rung and text size.**
    ///
    /// This is the rule the capsule's retirement broke. The bar's container was pinned to the
    /// NARROWEST rung's height, which was exact only while the provider capsule stood taller than
    /// any rung and absorbed the difference. With the capsule gone the bar was alone on its row, so
    /// a titled rung drew 34pt of content in a 17pt box and escaped it — measured, the bar's ink sat
    /// hard against the card's top padding while 18.5pt went unused below the breadcrumb. Reported
    /// as "a lil crowded", with space going begging underneath.
    ///
    /// Two changes hold it, and **they are pinned by different tests here, which is worth knowing
    /// before editing either**: the row reserves the TALLEST rung it can draw, so nothing overflows
    /// its box — that half is caught by `theBarAndTheTrailKeepTheirGap`, not by this test, because a
    /// bar whose words hang into the gap can still leave the card's outer edges even. And the bar is
    /// `.topLeading` inside that reservation, so a short rung sits at the top of it rather than
    /// floating in the middle and pushing the trail to the card's floor — that half is this test's,
    /// and putting the centring back measures 18 / 10.
    ///
    /// Measured together, every case lands on 9.5 / 10 — or 15 / 15.5 at the 1.35 text scale, where
    /// the content is simply bigger.
    ///
    /// **Asserted as balance rather than as a floor**, because a floor does not discriminate: with
    /// the old pin restored the top gap measures 9.0 against a 9pt padding, so "no ink inside the
    /// padding" passes on the broken layout. The imbalance is the symptom that is actually visible,
    /// and it is what a reader complained about.
    @Test func theHeaderIsBalancedTopToBottom() {
        for (name, scale, width) in [("iCloud Drive", 1.0, CGFloat(250)), ("iCloud Drive", 1.0, 330),
                                     ("iCloud Drive", 1.0, 660), ("iCloud Drive", 1.35, 660),
                                     ("Marketing Team Shared Archive Drive", 1.0, 660)] {
            guard let (top, bottom) = Self.inkGaps(Self.header(name).environment(\.appFontScale, scale),
                                                   width: width) else {
                Issue.record("\(name) @\(scale) \(width): the header painted nothing at all")
                continue
            }
            #expect(abs(top - bottom) <= 2.5,
                    "\(name) @\(scale) \(width)pt: \(top)pt of clear card above the content and \(bottom)pt below — a row is overflowing its box, or floating inside a reservation larger than it")
            // And the floor, which the balance above does not imply: two equally crowded edges would
            // satisfy it. 6pt is under every measured value and well clear of the 9pt padding — and
            // it is what `PaneBarTitleMetrics.rowBudget` is calibrated against, so the two read the
            // same constant rather than each carrying a copy.
            #expect(min(top, bottom) >= Self.headerInkFloor,
                    "\(name) @\(scale) \(width)pt: the content reaches \(min(top, bottom))pt from a card edge")
        }
    }

    /// **The two rows do not crowd each other**, which is the other half of the same complaint and
    /// the half the balance assertion above is blind to.
    ///
    /// Balance is about the card's outer edges; this is about the rule between the bar and the
    /// trail. They are separated by the `VStack`'s 10pt spacing, and that spacing is only real if
    /// the bar's row actually contains the bar: pinned to the narrowest rung, a titled rung's words
    /// hang below their own box and eat the gap, so the two rows read as one block however the
    /// outer edges measure. Reserving the tallest rung is what keeps the gap: with the old pin
    /// restored this measures **4pt** of clear card between a titled bar and the trail, against the
    /// `VStack`'s nominal 10.
    ///
    /// Measured as the widest run of untouched card between the first ink and the last — which is
    /// the gap, since it is the only clear band inside the content.
    @Test func theBarAndTheTrailKeepTheirGap() {
        for (name, scale, width) in [("iCloud Drive", 1.0, CGFloat(250)), ("iCloud Drive", 1.0, 660),
                                     ("Marketing Team Shared Archive Drive", 1.0, 660)] {
            guard let gap = Self.clearBandInsideContent(
                Self.header(name).environment(\.appFontScale, scale), width: width) else {
                Issue.record("\(name) @\(scale) \(width): nothing painted")
                continue
            }
            #expect(gap >= 8,
                    "\(name) @\(scale) \(width)pt: only \(gap)pt of clear card separates the bar from the breadcrumb — the rows read as one crowded block")
        }
    }

    /// The tallest run of un-inked rows strictly between the header's first and last inked row.
    private static func clearBandInsideContent<V: View>(_ view: V, width: CGFloat) -> CGFloat? {
        let height = LiquidGlass.headerHeight
        guard let rows = inkedRows(view, width: width, height: height),
              let first = rows.firstIndex(of: true), let last = rows.lastIndex(of: true) else { return nil }
        var best = 0, run = 0
        for y in first...last {
            if rows[y] { run = 0 } else { run += 1; best = max(best, run) }
        }
        return CGFloat(best) * height / CGFloat(rows.count)
    }

    /// The painted extent of a header rendered at its pinned height: points of clear card above the
    /// first inked row, and below the last.
    private static func inkGaps<V: View>(_ view: V, width: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        let height = LiquidGlass.headerHeight
        guard let rows = inkedRows(view, width: width, height: height),
              let first = rows.firstIndex(of: true), let last = rows.lastIndex(of: true) else { return nil }
        let perRow = height / CGFloat(rows.count)
        return (CGFloat(first) * perRow, height - CGFloat(last) * perRow)
    }

    /// Which rows of a header rendered at its pinned height carry any ink at all.
    private static func inkedRows<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> [Bool]? {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: width, height: height).background(Color.white)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (0..<rep.pixelsHigh).map { y in
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97 { return true }
            }
            return false
        }
    }

    // MARK: - Fixtures

    private static func header(_ providerName: String?,
                               mode: PaneViewMode? = .columns,
                               collapse: Bool = false) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: providerName.map {
                CloudProvider(id: "icloud", displayName: $0, imageName: "icloud-logo",
                              rootPath: "/Users/test/iCloud", type: .iCloud)
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
    ///
    /// **Swept across widths rather than anchored at 250 and 900**, and the reason is the change
    /// that made it necessary. With the provider capsule retired the bar is handed the whole row, so
    /// a 900pt pane no longer steps down to an untitled rung — it reaches rung 0, which is titled and
    /// which this test cannot compare. (A 250pt pane no longer sits on the terminal rung either: it
    /// draws seven controls where it used to manage five.) Two hand-picked widths were a proxy for
    /// "somewhere on the untitled part of the ladder"; the sweep asks for that directly, and the
    /// `matched` counter is what stops it passing by finding nowhere to look.
    @Test func theMeasuredBarAgreesWithRingSpansWhenNothingIsTitled() {
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        var matched = 0
        for width in stride(from: CGFloat(250), through: 900, by: 25) {
            let drawn = barRings(view, width: width)
            guard let first = drawn.first, let trailing = drawn.map(\.maxX).max() else { continue }
            for rung in (ladder.titledRungs)...ladder.terminal {
                let plan = ladder.plan(forRung: rung)
                let leadsWithSwitch = plan.visible.first(where: { !$0.isSpacer }) == .viewMode
                    && !plan.compactsViewMode
                let span = trailing - (first.minX - (leadsWithSwitch ? PaneNavMetrics.segmentPadding : 0))
                let measured = barWidth(view, rung: rung, ladder: ladder)
                #expect(measured > 0, "rung \(rung) measured zero — the fitting size is not reading the bar")
                if abs(measured - span) < 0.5 { matched += 1; break }
            }
        }
        #expect(matched >= 4,
                "only \(matched) of the swept widths drew a bar whose ring span matched an untitled rung's measured width")
    }

    /// The failure mode the ladder exists to prevent, and the one with no loud symptom: a bar that
    /// runs past the pane's trailing edge. Swept rather than spot-checked, because the ladder is not
    /// monotonic.
    ///
    /// It was non-monotonic for a reason that has now gone — the provider capsule's own logo/no-logo
    /// step moved the bar's offer by 38pt, more than a rung — and the sweep stays anyway: `PaneBarLadder`
    /// documents the non-monotonicity as a property of the arithmetic, which is why the ladder must be
    /// walked in order rather than sorted by width, and a sweep costs nothing to keep.
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

    /// **Every rung's arithmetic against the bar that rung actually draws.**
    ///
    /// `aRungOccupiesTheWidthTheLadderComputes` makes exactly this comparison — drawn `barWidth`
    /// against computed `ladder.width(forRung:)` — but only at rungs 0 and terminal, so a rung in
    /// the middle could be mispriced and no test would say so. Measured: adding a constant 40 to
    /// `PaneBarLayout.width(of plan:)` is caught by that test, and NOT by
    /// `theDrawnBarIsAlwaysSomeRungOfTheLadder` below, whose two sides are both drawn measurements
    /// of `barVariant` and therefore agree however the arithmetic drifts. Sweeping the rungs is what
    /// makes the arithmetic half hold everywhere rather than at the two ends.
    @Test func everyRungIsPricedAsTheBarItDraws() {
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        for rung in 0...ladder.terminal {
            // Half a point, for the reason `aRungOccupiesTheWidthTheLadderComputes` gives: a titled
            // rung's arithmetic lands on a half point where `fittingSize` reports whole ones.
            #expect(abs(barWidth(view, rung: rung, ladder: ladder) - ladder.width(forRung: rung)) <= 0.5,
                    "rung \(rung) draws \(barWidth(view, rung: rung, ladder: ladder))pt where the ladder priced \(ladder.width(forRung: rung))pt")
        }
    }

    /// Whatever rung is chosen, the bar drawn is *one of the ladder's rungs* — not some width in
    /// between.
    ///
    /// **What this does NOT catch, stated because its comment used to claim otherwise:** it is a
    /// drawn-against-drawn identity. Both `spans` and the measured bar come from `barVariant`, and
    /// `ViewThatFits` can only ever draw one of the variants `spans` was measured from — so "the
    /// drawn bar is *some* rung" is nearly true by construction, and a constant added to
    /// `PaneBarLayout.width` sails through it (measured). That was equally true of the `+12` version
    /// this replaced; the rewrite made the tolerance honest, not the test sensitive. The arithmetic
    /// drift it used to claim is held by `everyRungIsPricedAsTheBarItDraws` above. What remains here
    /// is still worth having: it is the only check that the rung *selection* lands on a real rung at
    /// every width, rather than on a bar assembled from some other rung's parts.
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
    /// readable "M" to a glyph sliced down the middle. Icon Only is untitled at every rung, and
    /// while it existed the large-text fallback was too, so both were affected.
    ///
    /// **What holds the drawn half of this is `theLadderRendersItsGolden`**, whose 250pt rows pinned
    /// the bar's leading edge at x=77 — the 6pt the capsule lost was exactly that edge moving to 71 —
    /// plus the recorded snapshots. (Those rows read x=17 now: with the capsule retired the bar starts
    /// at the pane's own inset, so a gap change no longer has a capsule to charge itself to. The
    /// *ladder* still steps down at a wider pane, which is what the arithmetic half below measures.) A pixel test counting the name's ink was written for this and
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

        // …and the arithmetic that spends them, **recomputed independently with the literal**.
        //
        // This compared the two modes against each other — `titled - untitled >= gaps * 2` — which
        // is a theorem, not an assertion: `titledWidth` is `max(pill, word)` and so is never
        // narrower than `width`, and the word overhangs alone clear the floor several times over
        // (measured: 32.5pt of overhang against a 12pt floor at rung 0). It passed with the gap
        // difference deleted entirely, in BOTH directions. Only the two constant pins above were
        // ever doing any work.
        //
        // So the untitled rung is priced here from its parts, with `6` written out — the one term
        // that is not shared with the code under test. Every other term deliberately reuses the
        // production helper: the subject is the GAP, and re-deriving item widths would only pin
        // them to a second copy of the same arithmetic.
        let bar = Self.columnsLadder()
        for rung in 0...bar.terminal where !bar.isTitled(forRung: rung) {
            let plan = bar.plan(forRung: rung)
            let size = bar.controlSize(forRung: rung)
            let pill = PaneNavMetrics.pill(size)
            let gaps = (0..<plan.visible.count)
                .filter { PaneBarLayout.needsGap(before: $0, in: plan.visible) }.count
                + ((!plan.overflow.isEmpty && (plan.visible.last.map { $0 != .flexibleSpace } ?? false)) ? 1 : 0)
            let items = plan.visible.reduce(CGFloat(0)) {
                $0 + PaneBarLayout.width(of: $1, pill: pill, compactsViewMode: plan.compactsViewMode)
            }
            let expected = items + CGFloat(gaps) * 6 + (plan.overflow.isEmpty ? 0 : pill.width)
            let priced = PaneBarLayout.width(of: plan, controlSize: size, titled: false)
            #expect(abs(priced - expected) < 0.01,
                    "rung \(rung) prices \(priced) where its parts plus \(gaps) six-point gaps come to \(expected)")
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
    /// It exists because that header draws a plain title rather than the breadcrumb chip, so the bar
    /// itself is what decides the row's height, and the computed path's container cannot report a
    /// height derived from its content. This is reachable in the app: `ContentView` passes
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

    /// The widest rung draws a 26pt view-switch ground, and the container it sits in must be able to
    /// hold it whole.
    ///
    /// It could not, and that is what this now guards. The pin was the NARROWEST rung's height
    /// (17pt), exact only while the provider capsule stood 34pt beside the bar and absorbed the
    /// difference; with the capsule retired the bar was alone on its row and a titled rung escaped
    /// its box by 8.5pt. The pin is `tallestRungHeight` now, so 26pt of ground has 26pt of box.
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
        // **The contiguous band around the control, not every inked row in the column.**
        //
        // This used to take the topmost and bottommost inked pixel anywhere in the column. That was
        // the same measurement while the bar's first control sat to the right of the provider
        // capsule, with nothing but bare header below it; the capsule is retired, the bar starts at
        // the pane's leading edge, and what is now directly underneath that column is the
        // breadcrumb's first crumb — wash, mark and all. Both rows in one span measured 50pt against
        // a 34pt bound, which is a true statement about the header and no statement at all about the
        // control this test is bounding.
        //
        // Growing outward from the ring until a blank row stops it measures the control's own paint,
        // which is what "painted" always meant — and an overflow still grows the band, because ink
        // that runs past the rung's height is contiguous with the ink inside it.
        func rowIsInked(_ y: Int) -> Bool {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let lum = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if c.alphaComponent > 0.05, lum < 0.97 { return true }
            }
            return false
        }
        // Seeded from the topmost inked row in the column rather than from the ring's own midY: the
        // rings come from a second host with its own origin, and a y read off one bitmap and applied
        // to the other lands wherever the two happen to differ. The bar is the header's upper row,
        // so the first ink down this column is its.
        guard let minY = (0..<rep.pixelsHigh).first(where: rowIsInked) else {
            Issue.record("nothing painted in the first control's column at all"); return
        }
        var maxY = minY
        while maxY < rep.pixelsHigh - 1, rowIsInked(maxY + 1) { maxY += 1 }
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
    /// **Where the text-size gate's line belongs, measured rather than argued.**
    ///
    /// `PaneBarTitleMetrics.rowBudget` decides which text sizes wear words, and it cannot be
    /// derived: the arithmetic it gates on (`pill + gap + NSLayoutManager.defaultLineHeight`) is a
    /// type-setting line box that over-reports where ink actually lands, so no sum of the header's
    /// constants reconstructs the drawn row. It is calibrated against this test instead.
    ///
    /// The rule being calibrated to is the header's own, and it is not new: content keeps **6pt**
    /// clear of both card edges, which is what `theHeaderIsBalancedTopToBottom` has always held the
    /// header to.
    ///
    /// **The calibration run, with the gate lifted so every size drew words** — `top / bottom` in
    /// points inside an 81pt header. Only the first four columns are what this test measures today;
    /// the last two are what 120% and above *would* look like titled, which is the observation the
    /// budget was set from and cannot be re-derived from a passing run:
    ///
    /// | 90% | 100% | 110% | 115% | 120% | 135% |
    /// |---|---|---|---|---|---|
    /// | 9.0 / 9.5 | 7.5 / 8.0 | 7.0 / 7.5 | 7.0 / 7.5 | **5.5 / 6.0** | **4.0 / 4.5** |
    ///
    /// So the words fit through 115% and crowd the card from 120% up, and the budget is set between
    /// the row heights those two produce. The old budget put the line at 110% — the first step above
    /// the default — while its own doc claimed Large and Larger; that is the defect this test
    /// exists to have caught, and it is why the check is ink and not arithmetic.
    ///
    /// **What this test guards, and what it does not.** It catches a budget set too *high*: raise it
    /// and the sizes it newly admits are rendered here, and their ink fails the floor at 120% and
    /// above. It cannot catch a budget set too *low*, which is the direction the original defect
    /// went — refuse a size and the header simply renders untitled, which clears the edges easily.
    /// That direction is held by `PaneBarTitleTests.theTextSizesThatGetWords`, whose table names the
    /// percentages that must have words. Neither test is sufficient alone.
    ///
    /// The titled/untitled check below is what keeps the floor honest: an untitled header clears the
    /// edges easily, so without it a gate that had started refusing *every* size would pass here
    /// rather than fail. A titled header's ink starts at **9.0pt or less** from the top edge, an
    /// untitled one's at **13.0pt or more**, and 11 sits in the gap between the two families.
    ///
    /// **What that discriminates is the gate's verdict, not the presence of words**, and the
    /// difference is worth stating because the two look identical from here. What moves the ink is
    /// the row's *reservation*: `PaneHeader.tallestRungHeight` reserves the titled row's height and
    /// the bar sits `.topLeading` inside it, so when the gate says no the reservation shrinks to a
    /// pill and everything drops. Mutating `PaneHeader.barVariant` to pass `titled: false` — words
    /// gone, reservation untouched — moves these numbers **not at all** (7.5 / 8.0 at 100%, same as
    /// green) and passes here; `everyRungIsPricedAsTheBarItDraws`,
    /// `aRungOccupiesTheWidthTheLadderComputes` and `theLadderRendersItsGolden` catch that one.
    /// Mutating `PaneHeader.barLadder` to ignore `appFontScale` — the gate silenced, which is the
    /// shape of the original defect — is caught here and by `theLadderRendersItsGolden`, and by
    /// nothing in `PaneBarTitleTests` at all. Both mutations were run rather than reasoned about.
    @Test(arguments: FontSize.selectablePercents)
    func theTitledHeaderClearsBothEdges(percent: Int) {
        let scale = FontSize(percent: percent).scale
        // Deliberately restating `PaneBarLadder.init`'s gate rather than asking a ladder for it:
        // `PaneHeader.barLadder` takes its scale from the environment, so a ladder built out here
        // would answer for the unscaled header and agree with the render by luck. The
        // `columnsLadder()` term is not part of the gate — it is the check that this test host's
        // `paneBarLabelMode` default is still `iconAndText`, without which every case below would
        // take the untitled branch and pass.
        let titled = Self.columnsLadder().titledRungs == 1 && PaneBarTitleMetrics.rowFits(
            pillHeight: PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height, scale: scale)
        guard let (top, bottom) = Self.inkGaps(
            Self.header("iCloud Drive").environment(\.appFontScale, scale), width: 660) else {
            Issue.record("\(percent)%: the header painted nothing at all")
            return
        }
        #expect(min(top, bottom) >= Self.headerInkFloor,
                "\(percent)%: content reaches \(min(top, bottom))pt from a card edge, inside \(LiquidGlass.headerHeight)pt")
        if titled {
            #expect(top <= Self.titledInkCeiling,
                    "\(percent)%: ink starts \(top)pt down, where an UNTITLED bar starts — the words are not drawn, so the clearance above proves nothing")
        } else {
            #expect(top > Self.titledInkCeiling,
                    "\(percent)%: the gate refused the words, but ink starts \(top)pt down, which is where a TITLED bar starts")
        }
    }

    /// The clearance the header keeps from its own card edges — the same floor
    /// `theHeaderIsBalancedTopToBottom` applies, named here because `rowBudget` is calibrated to it
    /// and a second copy of the number would let the two drift.
    private static let headerInkFloor: CGFloat = 6
    /// How far down a *titled* header's ink may start: 9.0pt at the smallest text size, less as the
    /// words grow, against 13.0pt or more for an untitled bar. 11 is the gap between the two.
    private static let titledInkCeiling: CGFloat = 11

    @Test func onlyATitledRungIsTallerThanAPill() {
        let ladder = Self.columnsLadder()
        #expect(ladder.height(forRung: ladder.terminal) == PaneNavMetrics.pill(.mini).height)
        // The untitled rung at the ceiling: a plain pill, with the switch no longer out-topping it.
        let pill = PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height
        #expect(ladder.height(forRung: ladder.titledRungs) == pill)
        // The titled rung is the pill, the gap and one line of title. What that row is allowed to
        // *cost* is no longer asserted here against a constant — the constant was the retired
        // provider capsule's and was never the header's room; `theTitledHeaderClearsBothEdges`
        // measures the drawn thing instead.
        if ladder.titledRungs > 0 {
            #expect(ladder.height(forRung: 0)
                    == PaneBarTitleMetrics.rowHeight(pillHeight: pill, scale: 1))
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

    /// The end-to-end claim, in the real header: a spacer-heavy no-provider header steps through
    /// every deep rung at pane widths it can actually be given, rather than jumping from a mid rung
    /// straight to full compaction.
    ///
    /// **It outlived the machinery it was written against, which is why it is still here.** It was
    /// the end-to-end half of a set proving `PaneHeader.searchedLadder` declared enough literal
    /// children; that ladder is gone and the header computes its rung now, so the four tests about
    /// slots and stand-ins went with it. This one asserts a property of the *header* — every rung
    /// the ladder can build is reachable at some width — which is exactly as true of a computed rung
    /// as of a searched one, and is the claim a user would notice failing.
    ///
    /// This is the one test that goes through `@AppStorage` and the whole header, so it is also what
    /// says the arrangement a user stored is the arrangement the ladder is built from.
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
    /// **The roots split moved the breadcrumb half of all sixteen rows, and only that half.** The
    /// first crumb names the SOURCE now rather than the root folder, so it went from "iCloud"
    /// (37pt) to "iCloud Drive" (62pt) and pushed the two crumbs behind it right by the difference.
    /// Every row's bar rings are byte-identical to what they were, and no row changed its crumb
    /// COUNT — which is the pair of facts that separates "the crumb is wider" from "the ladder
    /// stepped down", and the reason to read those two things rather than the diff as a whole.
    ///
    /// **Retiring the provider capsule moved all thirty-two halves, and this table is the measurement
    /// of what that bought.** Read three things off it:
    ///
    /// - **Every bar now starts at x 17.** Before, the sixteen rows started anywhere from 77 to 372,
    ///   because the bar began where the capsule stopped and the capsule's width was the source's
    ///   name. The bar's leading edge was a function of what account you were looking at.
    /// - **Controls, at the widths where it matters.** A 250pt pane draws seven where it drew five;
    ///   330pt draws all nine. Nothing shrank — these are the same rungs, handed a row they are not
    ///   sharing.
    /// - **The titled rung arrives at 410pt instead of 570.** Titles are what the bar spends spare
    ///   track on, and this is where the spare track went.
    ///
    /// **And every row lost a crumb ring.** That is not a crumb going missing: the first crumb is a
    /// `Menu` now rather than a `Button`, so it emits no `_FocusRingView` and drops out of a
    /// fingerprint that is built from them. The consequence worth stating is that **this table no
    /// longer pins where the source chip sits** — the remaining crumbs' positions are downstream of
    /// its width, so a chip that grew would still show up here as the trail shifting right, but the
    /// chip itself is measured in `MenuLabelMarkTests`, in the app target, where the brand asset it
    /// draws actually exists.
    ///
    /// **Bringing the source name back to `.callout` moved every row, and moved NOTHING in the
    /// bar.** The name was left at `.body` while the trail around it was set to `.callout`, so the
    /// chip drew one step larger than the crumbs beside it; correcting it is a pure shrink, and the
    /// table is the proof that it was only that:
    ///
    /// - **All sixteen rows' bar rings are byte-identical** — same x, same size, same count. No rung
    ///   stepped, no control moved, which is what separates "the chip got smaller" from "the ladder
    ///   re-fitted".
    /// - **The crumbs behind the chip moved LEFT by exactly the width the chip lost** — 5pt at both
    ///   text sizes for `iCloud`, 15pt for `longName` from 490pt up. This is the same relationship
    ///   the roots split recorded in the other direction.
    /// - **The whole bar dropped 1pt at the 1.0 text size** (469 → 470) and did not move at 0.9. The
    ///   header's height is pinned, so a breadcrumb row that gets 1pt shorter hands that point back
    ///   to the row above it; at 0.9 the label was already below the size where that point exists.
    /// - **Three rows did not move horizontally at all**: both 250pt rows and `longName @ 410`. At
    ///   those widths the chip is truncated to the track available rather than sized by its text, so
    ///   its width is a function of the pane and not of the font — which is the ladder's own
    ///   degradation working, visible here as an absence.
    ///
    /// **Sizing the source chip as a control moved every row again, and again moved NOTHING in the
    /// bar.** The paragraph above records the name at `.callout`; it is `SourceChip.font` — `.body`
    /// — now, one step above the trail, and the chip also gained a mark, padding and a disclosure
    /// indicator. That table was re-recorded without this note, so read the numbers here and not
    /// that paragraph's for the current state:
    ///
    /// - **All sixteen rows' bar rings are byte-identical** — same x, same size, same count. Every
    ///   bar still starts at x 17.
    /// - **The whole bar rose** 2pt at the 0.9 text size (471 → 469) and 3pt at 1.0 (470 → 467),
    ///   the header's height being pinned.
    /// - **The crumbs behind the chip moved RIGHT by the width it gained** — 22pt for `iCloud
    ///   Drive`, 32pt for `longName` from 490pt up.
    /// - **FOUR rows' crumbs did not move**: all three 250pt rows and `longName @ 410`. At those
    ///   widths the chip is truncated to the track available rather than sized by its content. The
    ///   commit that made this change said three; there are three 250pt rows in this table, not two.
    ///
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
        (iCloud, 0.9, 250, "17,469/23x17 43,469/23x17 75,469/27x17 108,469/27x17 141,469/27x17 174,469/27x17 207,469/27x17 93,514/67x15 164,514/50x15"),
        (iCloud, 0.9, 410, "17,469/29x20 49,469/29x20 89,469/33x20 128,469/33x20 169,469/33x20 219,469/33x20 268,469/33x20 309,469/33x20 353,469/29x20 122,514/67x15 193,514/50x15"),
        (iCloud, 0.9, 490, "17,469/29x20 49,469/29x20 89,469/33x20 128,469/33x20 169,469/33x20 219,469/33x20 268,469/33x20 309,469/33x20 353,469/29x20 122,514/67x15 193,514/50x15"),
        (iCloud, 0.9, 710, "17,469/29x20 49,469/29x20 89,469/33x20 128,469/33x20 169,469/33x20 219,469/33x20 268,469/33x20 309,469/33x20 353,469/29x20 122,514/67x15 193,514/50x15"),
        // **The narrowest pane, and the sharpest single number here.** Five controls used to fit
        // a 250pt pane; seven do. The bar is on the same `.mini` rung it always was — nothing got
        // smaller — it simply is not sharing the row with a 180pt provider capsule any more.
        (iCloud, 1.0, 250, "17,467/23x17 43,467/23x17 75,467/27x17 108,467/27x17 141,467/27x17 174,467/27x17 207,467/27x17 91,514/65x17 160,514/54x17"),
        (iCloud, 1.0, 330, "17,467/23x17 43,467/23x17 75,467/27x17 108,467/27x17 141,467/27x17 174,467/27x17 207,467/27x17 240,467/27x17 273,467/23x17 128,514/73x17 205,514/54x17"),
        // **Where the titled rung now begins.** 410pt, against 570 before: a title is only affordable
        // when the bar has track to spare, and the retired capsule is all the track it needed.
        (iCloud, 1.0, 410, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 128,514/73x17 205,514/54x17"),
        (iCloud, 1.0, 490, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 128,514/73x17 205,514/54x17"),
        (iCloud, 1.0, 570, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 128,514/73x17 205,514/54x17"),
        (iCloud, 1.0, 710, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 128,514/73x17 205,514/54x17"),
        (longName, 1.0, 250, "17,467/23x17 43,467/23x17 75,467/27x17 108,467/27x17 141,467/27x17 174,467/27x17 207,467/27x17 91,514/65x17 160,514/54x17"),
        (longName, 1.0, 410, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 243,514/73x17 320,514/54x17"),
        // **`longName @ 1.0 490` is the row that says what this bought.** A wide custom source name
        // used to leave room for five controls here; it leaves room for all nine, because the name
        // is no longer competing with them for the row — it reads on the breadcrumb below, where a
        // long one truncates inside its own chip instead of pushing the bar off the end.
        (longName, 1.0, 490, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 281,514/73x17 358,514/54x17"),
        (longName, 1.0, 570, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 281,514/73x17 358,514/54x17"),
        (longName, 1.0, 650, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 281,514/73x17 358,514/54x17"),
        (longName, 1.0, 710, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 361,467/29x20 281,514/73x17 358,514/54x17"),
    ]

}
