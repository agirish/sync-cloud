import AppKit
import SwiftUI
import Testing
import Sync
@testable import Dashboard
import Design
import FileExplorerTestSupport

/// The pane bar's narrow-pane ladder, where the rung is computed rather than searched.
/// `PaneBarLadder` picks it by arithmetic over `PaneNavMetrics`, so the claim is that those numbers
/// describe the bar actually drawn. Every geometry assertion here reads the laid-out result from a
/// real hosting view, never a constant against another constant.
///
/// Controls are located by `_FocusRingView`, as in `PaneHeaderHeightTests.buttonCount`: a
/// custom-styled SwiftUI `Button` puts no `NSControl` in the AppKit tree, and an offscreen
/// `NSHostingView` has an empty accessibility tree.
@MainActor
@Suite(.serialized) struct PaneBarLadderTests {

    /// The pane's own trailing inset: `PaneHeader.body`'s `.padding(.horizontal, 14)`.
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
        let found = FocusRings.frames(in: host)
        return found.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The bar's rings only; the breadcrumb sits on a lower row.
    private func barRings<V: View>(_ view: V, width: CGFloat) -> [CGRect] {
        let all = rings(view, width: width)
        guard let top = all.map(\.minY).min() else { return [] }
        return all.filter { $0.minY < top + 5 }
    }

    /// The laid-out width of one rung's bar, measured from the view that draws it. Ring spans miss
    /// titles: an item is as wide as the wider of its pill and its word, so an outermost word can
    /// overhang the rings and the span comes out nearly right. `barVariant` is an `HStack` of
    /// fixed-width boxes with a `Spacer(minLength: 0)` for the flexible space, so its fitting width
    /// is the rung's minimum, the quantity `PaneBarLayout.width` computes.
    /// `theMeasuredBarAgreesWithRingSpansWhenNothingIsTitled` guards that this measures the bar.
    private func barWidth(_ view: PaneHeader, rung: Int, ladder: PaneBarLadder) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.barVariant(rung, ladder)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// The laid-out height of one rung's bar, off the same host `barWidth` reads. No scale
    /// parameter: a bar built through `barVariant` draws at the unhosted struct's default
    /// `appFontScale`, so one would be accepted and ignored
    /// (`theEnvironmentDoesNotReachABarBuiltOffTheStruct`).
    private func barHeight(_ view: PaneHeader, rung: Int, ladder: PaneBarLadder) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.barVariant(rung, ladder)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func fingerprint<V: View>(_ view: V, width: CGFloat) -> String {
        rings(view, width: width)
            .map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded()))/\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            .joined(separator: " ")
    }

    /// The card is balanced top to bottom at every rung and text size. Two rules hold it, pinned by
    /// different tests, which matters before editing either. The bar's row reserves the tallest
    /// rung it can draw, so nothing overflows its box (`theBarAndTheTrailKeepTheirGap` catches
    /// that, since words hanging into the gap can leave the outer edges even). And the bar is
    /// `.topLeading` in that reservation, so a short rung sits at the top instead of floating and
    /// pushing the trail to the card's floor: this test's half.
    ///
    /// Asserted as balance, not just a floor: a bar pinned to the narrowest rung's height still
    /// clears the top padding, but its imbalance is what a person sees.
    @Test(.machinePinned(.pixelSampling)) func theHeaderIsBalancedTopToBottom() {
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
            // And the floor, which balance doesn't imply: two equally crowded edges would pass it.
            // `PaneBarTitleMetrics.rowBudget` is calibrated against the same constant.
            #expect(min(top, bottom) >= Self.headerInkFloor,
                    "\(name) @\(scale) \(width)pt: the content reaches \(min(top, bottom))pt from a card edge")
        }
    }

    /// The bar and the trail don't crowd each other, which the balance test can't see. The
    /// `VStack`'s 10pt spacing is real only if the bar's row contains the bar: pinned to the
    /// narrowest rung, a titled rung's words hang below their box and eat the gap. Measured as the
    /// tallest clear band between the first ink and the last, the only one inside the content.
    @Test(.machinePinned(.pixelSampling)) func theBarAndTheTrailKeepTheirGap() {
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

    /// The ladder a full Columns header builds, asked of the view rather than rebuilt here. A
    /// rebuilt ladder falls a parameter short whenever the header gains one, and every assertion
    /// below would then compare the drawn bar against different arithmetic.
    private static func columnsLadder(_ view: PaneHeader = header("iCloud Drive")) -> PaneBarLadder {
        view.barLadder
    }

    // MARK: - The arithmetic against the drawn bar

    /// That `barWidth` measures the bar and not something next to it: a greedy child makes
    /// `fittingSize` report the offer, not the content. Checked against ring spans on the untitled
    /// rungs, where every item's box is its pill and the two must agree to the point. Swept across
    /// widths to find the untitled part of the ladder, and `matched` stops it passing by finding
    /// nowhere to look.
    @Test(.machinePinned(.pixelSampling)) func theMeasuredBarAgreesWithRingSpansWhenNothingIsTitled() {
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

    /// The failure the ladder exists to prevent, with no loud symptom: a bar running past the
    /// pane's trailing edge. Swept rather than spot-checked, because `PaneBarLadder` documents its
    /// widths as non-monotonic, which is why it is walked in order rather than sorted.
    ///
    /// The header with no provider (`nil`) obeys the same rule. It draws a plain title instead of
    /// the breadcrumb chip, and is reachable in the app: `ContentView` passes
    /// `availableProviders.first(where:)`, nil whenever a pane's provider is disabled or not yet
    /// loaded.
    @Test(.machinePinned(.pixelSampling)) func theBarNeverOverflowsThePane() {
        let names: [String?] = ["Box", "Dropbox", "iCloud Drive", "Marketing Team Shared Archive Drive", nil]
        for name in names {
            for width in stride(from: CGFloat(250), through: 900, by: 25) {
                let drawn = barRings(Self.header(name), width: width)
                guard let trailing = drawn.map(\.maxX).max() else { continue }
                #expect(trailing <= width - Self.contentInset + 0.5,
                        "\(name ?? "no-provider header") at \(width)pt: bar ends at \(trailing), pane content edge is \(width - Self.contentInset)")
            }
        }
    }

    /// The core claim: the width `PaneBarLadder` computes for a rung is the width the bar drawn at
    /// that rung occupies, for every rung, so a middle one can't be mispriced unnoticed.
    /// `theDrawnBarIsAlwaysSomeRungOfTheLadder` can't see mispricing: both its sides are drawn
    /// measurements.
    @Test(.machinePinned(.pixelSampling)) func everyRungIsPricedAsTheBarItDraws() {
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        for rung in 0...ladder.terminal {
            // Half a point of tolerance, and only that: `fittingSize` reports whole points while a
            // titled rung's arithmetic lands on a half (`LabelMetrics.ceilToHalf`). A rung that drew
            // a different bar misses by pills, not fractions.
            #expect(abs(barWidth(view, rung: rung, ladder: ladder) - ladder.width(forRung: rung)) <= 0.5,
                    "rung \(rung) draws \(barWidth(view, rung: rung, ladder: ladder))pt where the ladder priced \(ladder.width(forRung: rung))pt")
        }
    }

    /// The height half of the test above. `PaneBarLayout.height(of:titled:)` is what
    /// `PaneHeader.tallestRungHeight` reserves as the bar container's `minHeight`/`maxHeight`, and
    /// SwiftUI doesn't clip a child to a `maxHeight`, so a short answer only lets a word hang into
    /// the gap `theBarAndTheTrailKeepTheirGap` guards, with nothing going red.
    ///
    /// This covers one text size: hosting `barVariant` under `.environment(\.appFontScale, …)`
    /// silently changes nothing (`theEnvironmentDoesNotReachABarBuiltOffTheStruct`). The other
    /// sizes are held by a chain: `LabelMetricsTests.lineHeightMatchesTheDrawnLineBox` checks
    /// `lineHeight` against a drawn `Text` at every slider scale, `rowHeight` is pill + gap + that,
    /// and `theTitledHeaderClearsBothEdges` renders every size and measures the result.
    @Test(.machinePinned(.pixelSampling)) func everyRungIsReservedAsTallAsTheBarItDraws() {
        // The host's label-mode default, asserted as in `theTitledHeaderClearsBothEdges`: under
        // `iconOnly` no rung is titled and this would pass on untitled ones alone.
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        #expect(ladder.titledRungs == 1, "the test host is not in `iconAndText`, so no rung here is titled")
        for rung in 0...ladder.terminal {
            let drawn = barHeight(view, rung: rung, ladder: ladder)
            #expect(drawn == ladder.height(forRung: rung),
                    "rung \(rung)\(ladder.isTitled(forRung: rung) ? " (titled)" : ""): the bar draws \(drawn)pt where the ladder reserved \(drawn == ladder.height(forRung: rung) ? drawn : ladder.height(forRung: rung))pt")
        }
    }

    /// Why the test above takes no text size, measured. `PaneHeader` reads `appFontScale` as an
    /// `@Environment` property, and `barVariant` is a method on the struct, so its bar draws at the
    /// default; an `.environment(_:_:)` on the returned view comes too late for the font
    /// `titledItem` already resolved. A sweep would report identical numbers and read as passes.
    @Test(.machinePinned(.pixelSampling)) func theEnvironmentDoesNotReachABarBuiltOffTheStruct() {
        let view = Self.header("iCloud Drive")
        var drawn: [Int: CGFloat] = [:], reserved: [Int: CGFloat] = [:]
        for percent in FontSize.selectablePercents {
            let scale = FontSize(percent: percent).scale
            let ladder = PaneBarLadder(arrangement: .default, available: view.availableItems,
                                       ceiling: PaneBarIconSize.regular.ceiling,
                                       labelMode: .iconAndText, scale: scale)
            // Only sizes whose rung 0 is titled. Above the gate it is a bare pill, one height for
            // reasons unrelated to the environment, which would make this fail for the wrong one.
            guard ladder.isTitled(forRung: 0) else { continue }
            let host = NSHostingView(rootView: AnyView(
                view.barVariant(0, ladder).environment(\.appFontScale, scale)))
            host.layoutSubtreeIfNeeded()
            drawn[percent] = host.fittingSize.height
            reserved[percent] = ladder.height(forRung: 0)
        }
        #expect(drawn.count >= 4, "too few titled sizes (\(drawn.count)) for this to say anything")
        // The ladder does follow the scale; only the drawn half is stuck.
        #expect(Set(reserved.values).count > 1,
                "the reservation stopped following the text size, so the sweep this rules out would have been vacuous for a second reason")
        #expect(Set(drawn.values).count == 1,
                "the environment now reaches a bar built off the struct (\(drawn.sorted { $0.key < $1.key })) — `everyRungIsReservedAsTallAsTheBarItDraws` can take its text-size sweep back")
    }

    /// Whatever rung is chosen, the bar drawn is one of the ladder's rungs, not some width between.
    /// It doesn't catch mispricing: both sides are drawn from `barVariant`, so a constant added to
    /// `PaneBarLayout.width` passes (`everyRungIsPricedAsTheBarItDraws` holds that). It is the only
    /// check that the selection lands on a real rung at every width, not on a bar built from
    /// another rung's parts.
    @Test(.machinePinned(.pixelSampling)) func theDrawnBarIsAlwaysSomeRungOfTheLadder() {
        let view = Self.header("iCloud Drive")
        let ladder = view.barLadder
        // Rings against rings: each rung's own ring span, compared with the drawn bar's. Box widths
        // against ring spans would differ by the outermost title's overhang, and a tolerance wide
        // enough to absorb that would hide a missing gap, since adjacent rungs can differ by ~4pt.
        let spans = (0...ladder.terminal).compactMap { ringSpan(view, rung: $0, ladder: ladder) }
        #expect(spans.count == ladder.terminal + 1,
                "a rung drew no rings at all — \(spans.count) of \(ladder.terminal + 1) measured")
        for width in stride(from: CGFloat(250), through: 900, by: 25) {
            let drawn = barRings(view, width: width)
            guard let first = drawn.first, let trailing = drawn.map(\.maxX).max() else { continue }
            // Both leading edges, with and without the switch's capsule ground.
            let base = [trailing - first.minX, trailing - first.minX + PaneNavMetrics.segmentPadding]
            // Within one backing pixel at 2x, inclusive: the rings snap to the pixel grid, and the
            // titled rung's own fit lands on a half point.
            #expect(base.contains(where: { span in
                spans.contains(where: { abs($0 - span) <= 0.5 })
            }), "at \(width)pt the bar spans \(base), no rung of \(spans)")
        }
    }

    // MARK: - The untitled bar is priced as it was before titles

    /// A gap widened for words must not be charged to a bar that has none. `itemGap` is 8 between
    /// titled items and 6 between untitled ones; charging 8 everywhere would make every untitled
    /// rung (all of Icon Only) wider, so the ladder would step down at a wider pane. The drawn half
    /// is held by `theLadderRendersItsGolden`.
    @Test func theUntitledLadderIsPricedAsItWasBeforeTitles() {
        // The values, pinned.
        #expect(PaneNavMetrics.itemGap(titled: false) == 6,
                "an untitled bar is paying for space between words it does not draw")
        #expect(PaneNavMetrics.itemGap(titled: true) == 8,
                "the titled bar lost the word spacing it was widened for")

        // …and the arithmetic that spends them, recomputed with the literal. Comparing titled and
        // untitled widths proves nothing, since word overhangs alone make titled wider. So each
        // untitled rung is priced from its parts with `6` written out; every other term reuses the
        // production helpers, because the subject is the gap, not the item widths.
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

    /// The span of one rung's focus rings, from the same view `barWidth` measures, so the drawn bar
    /// is compared like with like.
    private func ringSpan(_ view: PaneHeader, rung: Int, ladder: PaneBarLadder) -> CGFloat? {
        let variant = view.barVariant(rung, ladder)
        let drawn = barRings(variant, width: barWidth(view, rung: rung, ladder: ladder))
        guard let first = drawn.first, let trailing = drawn.map(\.maxX).max() else { return nil }
        return trailing - first.minX
    }

    // MARK: - The ladder's own arithmetic

    /// The rung is the first that fits, and the ladder doesn't narrow at every rung: shedding a
    /// control no wider than the ⋯ pill it brings in leaves the bar no narrower. A
    /// `rung(fitting:)` that sorted by width, or took the narrowest fit, would pick a different bar.
    @Test func theLadderIsWalkedInOrder() {
        let ladder = Self.columnsLadder()
        // Relative to `titledRungs`, not literals: the first `.mini` rung and the one after it sit
        // after however many titled rungs head the ladder.
        let firstMini = ladder.titledRungs + 1
        // The rung after the first `.mini` one sheds a pill-wide control and gains ⋯, so it is no
        // narrower: the case "first" decides.
        #expect(ladder.width(forRung: firstMini + 1) >= ladder.width(forRung: firstMini))
        // Offered exactly that rung's width, the walk answers it: not a later rung that also fits,
        // nor the wider one before it.
        #expect(ladder.rung(fitting: ladder.width(forRung: firstMini)) == firstMini)
        #expect(ladder.rung(fitting: ladder.width(forRung: 0)) == 0)
        // A hair under rung 0 steps to rung 1, not past it.
        #expect(ladder.rung(fitting: ladder.width(forRung: 0) - 1) == 1)
    }

    /// When nothing fits, the ladder answers its narrowest rung rather than running off the end.
    @Test func nothingFitsGivesTheNarrowestRung() {
        let ladder = Self.columnsLadder()
        #expect(ladder.rung(fitting: 0) == ladder.terminal)
        #expect(ladder.rung(fitting: ladder.width(forRung: ladder.terminal)) == ladder.terminal)
        // And the terminal rung is the narrowest, which the fallback relies on.
        for rung in 0..<ladder.terminal {
            #expect(ladder.width(forRung: ladder.terminal) <= ladder.width(forRung: rung))
        }
    }

    /// The terminal rung sheds everything sheddable: it is the plan at any depth past the end.
    @Test func theTerminalRungShedsEverythingSheddable() {
        let available: [PaneBarItem] = [.backForward, .sort, .hiddenFiles, .viewMode, .scan, .newFolder]
        let ladder = PaneBarLadder(arrangement: .default, available: available, ceiling: .small)
        let terminal = ladder.plan(forRung: ladder.terminal)
        #expect(terminal == PaneBarLayout.plan(arrangement: .default, available: available, depth: .max))
        #expect(terminal.compactsViewMode)
    }

    /// Each item measures what its view draws. Every rung width is summed from these, so a drift
    /// here is a drift everywhere; the pill constants are shared with the views to keep them in step.
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
        // A flexible space costs the bar's minimum width nothing, so it can push controls to the
        // trailing edge without widening the bar.
        #expect(PaneBarLayout.width(of: .flexibleSpace, pill: pill, compactsViewMode: false) == 0)
        #expect(PaneBarLayout.width(of: .space, pill: pill, compactsViewMode: false) == pill.width)
        #expect(PaneBarLayout.width(of: .sort, pill: pill, compactsViewMode: false) == pill.width)
    }

    /// The bar's container, pinned to `tallestRungHeight`, holds the tallest rung whole. Focus rings
    /// say nothing about paint, and a clipped overflow looks like a correct layout to every other
    /// assertion here, so this reads the bitmap.
    @Test(.machinePinned(.pixelSampling)) func theTallestRungIsNotClippedByThePinnedContainer() {
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
        // The contiguous band around the control, not every inked row in the column: the
        // breadcrumb's first crumb sits directly below this column. Growing down until a blank row
        // measures the control's own paint, and an overflow still grows the band, because ink past
        // the rung's height is contiguous with the ink inside it.
        func rowIsInked(_ y: Int) -> Bool {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let lum = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if c.alphaComponent > 0.05, lum < 0.97 { return true }
            }
            return false
        }
        // Seeded from the topmost inked row, not the ring's midY: the rings come from a second host
        // with its own origin. The bar is the header's upper row, so the first ink down is its.
        guard let minY = (0..<rep.pixelsHigh).first(where: rowIsInked) else {
            Issue.record("nothing painted in the first control's column at all"); return
        }
        var maxY = minY
        while maxY < rep.pixelsHigh - 1, rowIsInked(maxY + 1) { maxY += 1 }
        let painted = CGFloat(maxY - minY + 1) / scale
        let ladder = Self.columnsLadder()
        // Bounded, not exact: a title's ink is shorter than its line box, so a titled rung paints
        // less than its height by design. Nothing draws beyond the tallest rung, and at least a
        // pill is on screen.
        #expect(painted <= ladder.height(forRung: 0) + 0.5,
                "painted \(painted)pt exceeds the tallest rung's \(ladder.height(forRung: 0))pt")
        #expect(painted >= PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height,
                "painted \(painted)pt is under a pill — the switch is clipped by the pin")
        // Every ring on the bar's row is a pill tall, the view switch's segments included, so every
        // title lands on one baseline. Vertical padding back on the switch's ground fails here.
        let ringHeights = Set(bar.map(\.height))
        #expect(ringHeights == [PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height],
                "the bar's controls are not all a pill tall: \(ringHeights.sorted())")
    }

    /// Where the text-size gate's line belongs, measured. `PaneBarTitleMetrics.rowBudget` decides
    /// which text sizes wear words. It gates on the row's box, while the rule here is about where
    /// the ink lands (6pt clear of both card edges, as `theHeaderIsBalancedTopToBottom` holds), so
    /// no sum of constants reconstructs it and it is calibrated against this test.
    ///
    /// The calibration run with the gate lifted, `top / bottom` in points: words fit through 115%
    /// and crowd the card from 120% up, so the budget sits between those row heights.
    ///
    /// | 90% | 95% | 100% | 105% | 110% | 115% | 120% | 125% | 130% | 135% |
    /// |---|---|---|---|---|---|---|---|---|---|
    /// | 9.0 / 9.5 | 8.0 / 8.5 | 7.0 / 7.5 | 7.0 / 7.5 | 6.5 / 7.0 | 6.5 / 7.0 | 5.5 / 6.0 | 5.0 / 5.5 | 4.0 / 4.5 | 4.0 / 4.5 |
    ///
    /// This catches a budget set too high, since newly admitted sizes fail the floor. A budget set
    /// too low renders untitled and clears the edges easily;
    /// `PaneBarTitleTests.theTextSizesThatGetWords` holds that direction. The titled/untitled check
    /// keeps the floor honest: titled ink starts 9.0pt or less from the top, untitled 13.0pt or
    /// more. It reads the gate's verdict through the row's reservation, not the words themselves;
    /// ignoring `appFontScale` in `PaneHeader.barLadder` must fail here.
    @Test(.machinePinned(.pixelSampling), arguments: FontSize.selectablePercents)
    func theTitledHeaderClearsBothEdges(percent: Int) {
        let scale = FontSize(percent: percent).scale
        // Restates `PaneBarLadder.init`'s gate rather than asking a ladder: `PaneHeader.barLadder`
        // takes its scale from the environment, so a ladder built here would answer for the
        // unscaled header. The `columnsLadder()` term checks the host's label mode is still
        // `iconAndText`, or every case would take the untitled branch and pass.
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

    /// The clearance the header keeps from its card edges, shared by both tests that apply it
    /// because `rowBudget` is calibrated to it.
    private static let headerInkFloor: CGFloat = 6
    /// How far down a titled header's ink may start: 9.0pt or less, against 13.0pt or more for an
    /// untitled bar. 11 sits in the gap.
    private static let titledInkCeiling: CGFloat = 11

    /// Nothing is taller than a pill, the view switch included, and a titled rung is taller only by
    /// its word. The header pins its container to these numbers, so a wrong answer moves the
    /// breadcrumb.
    @Test func onlyATitledRungIsTallerThanAPill() {
        let ladder = Self.columnsLadder()
        #expect(ladder.height(forRung: ladder.terminal) == PaneNavMetrics.pill(.mini).height)
        // The untitled rung at the ceiling: a plain pill, the switch no taller.
        let pill = PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height
        #expect(ladder.height(forRung: ladder.titledRungs) == pill)
        // The titled rung is the pill, the gap and one line of title. What that row may cost is
        // measured by `theTitledHeaderClearsBothEdges`, not asserted against a constant.
        if ladder.titledRungs > 0 {
            #expect(ladder.height(forRung: 0)
                    == PaneBarTitleMetrics.rowHeight(pillHeight: pill, scale: 1))
        }
    }

    // MARK: - The searched ladder's coverage

    /// The default arrangement plus six fixed spaces, a bar the palette can build. Spacers are
    /// exempt from the duplicate rule, so they push `maxDepth` deep.
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

    /// Three ladders by depth: what almost every install runs, the palette-reachable spacer-heavy
    /// bar, and the deepest bar the normalizer permits.
    private static var ladderFixtures: [(String, PaneBarLadder)] {
        [("default", ladder(.default)),
         ("spacer-heavy", ladder(spacerHeavy)),
         ("worst", ladder(worstArrangement))]
    }

    /// The rungs `ViewThatFits` can actually land on: first-fit takes the earliest child that fits,
    /// so a rung no narrower than one before it is unreachable by construction and no assertion may
    /// demand it (see `theLadderIsWalkedInOrder`).
    private static func reachableRungs(_ ladder: PaneBarLadder) -> [Int] {
        var narrowest = CGFloat.greatestFiniteMagnitude
        var reachable: [Int] = []
        for rung in 0...ladder.terminal where ladder.width(forRung: rung) < narrowest {
            narrowest = ladder.width(forRung: rung)
            reachable.append(rung)
        }
        return reachable
    }

    /// End to end in the real header: a spacer-heavy no-provider header steps through every deep
    /// rung at widths it can be given, rather than jumping from a mid rung to full compaction. The
    /// one test that goes through `@AppStorage` and the whole header, so it also shows the stored
    /// arrangement is the one the ladder is built from.
    ///
    /// A rung whose band of widths is narrower than the sweep's stride would fall between samples,
    /// so the gap between consecutive reachable rungs is checked against the stride first.
    @Test(.machinePinned(.pixelSampling)) func theNoProviderHeaderReachesTheDeepRungs() {
        let defaults = ScratchDefaults("PaneBarLadderTests-spacerHeavy")
        defaults.set(Self.spacerHeavy.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        let view = Self.header(nil).defaultAppStorage(defaults)
        let ladder = Self.ladder(Self.spacerHeavy)
        let reachable = Self.reachableRungs(ladder)
        let deep = reachable.filter { $0 > 8 && $0 < ladder.terminal }
        // The premise: there is something between rung 8 and the terminal to skip.
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

    /// One golden row, as data: the source name, text scale, pane width and ring fingerprint.
    private struct Golden {
        let name: String
        let scale: CGFloat
        let width: CGFloat
        let rings: String
    }

    /// The laid-out header, pinned whole, at the widths and text sizes that move the ladder. When
    /// it changes, read the bar rings and the crumb rings separately: a change in a row's ring count
    /// is the ladder stepping, while shifted positions with the same count are the bar or the trail
    /// sliding. The first crumb is the source chip, a `Menu` with no focus ring, so this table pins
    /// it only through the trail's position; `MenuLabelMarkTests` in the app target measures it.
    @Test(.machinePinned(.pixelSampling)) func theLadderRendersItsGolden() {
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
        (iCloud, 0.9, 410, "17,469/29x20 49,469/29x20 89,469/33x20 128,469/33x20 169,469/33x20 219,469/33x20 268,469/33x20 309,469/33x20 122,514/67x15 193,514/50x15"),
        (iCloud, 0.9, 490, "17,469/29x20 49,469/29x20 89,469/33x20 128,469/33x20 169,469/33x20 219,469/33x20 268,469/33x20 309,469/33x20 122,514/67x15 193,514/50x15"),
        (iCloud, 0.9, 710, "17,469/29x20 49,469/29x20 89,469/33x20 128,469/33x20 169,469/33x20 219,469/33x20 268,469/33x20 309,469/33x20 122,514/67x15 193,514/50x15"),
        // The narrowest pane: seven controls on a `.mini` rung, with the whole row to themselves.
        (iCloud, 1.0, 250, "17,467/23x17 43,467/23x17 75,467/27x17 108,467/27x17 141,467/27x17 174,467/27x17 207,467/27x17 91,514/65x17 160,514/54x17"),
        (iCloud, 1.0, 330, "17,467/29x20 49,467/29x20 87,467/33x20 126,467/33x20 165,467/33x20 204,467/33x20 243,467/33x20 282,467/33x20 128,514/73x17 205,514/54x17"),
        // Where the titled rung begins: a title is affordable only once the bar has track to spare.
        (iCloud, 1.0, 410, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 128,514/73x17 205,514/54x17"),
        (iCloud, 1.0, 490, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 128,514/73x17 205,514/54x17"),
        (iCloud, 1.0, 570, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 128,514/73x17 205,514/54x17"),
        (iCloud, 1.0, 710, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 128,514/73x17 205,514/54x17"),
        (longName, 1.0, 250, "17,467/23x17 43,467/23x17 75,467/27x17 108,467/27x17 141,467/27x17 174,467/27x17 207,467/27x17 91,514/65x17 160,514/54x17"),
        (longName, 1.0, 410, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 243,514/73x17 320,514/54x17"),
        // A long source name leaves the bar every control: the name reads on the breadcrumb below,
        // where it truncates inside its own chip instead of pushing the bar off the end.
        (longName, 1.0, 490, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 281,514/73x17 358,514/54x17"),
        (longName, 1.0, 570, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 281,514/73x17 358,514/54x17"),
        (longName, 1.0, 650, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 281,514/73x17 358,514/54x17"),
        (longName, 1.0, 710, "17,467/29x20 49,467/29x20 89,467/33x20 128,467/33x20 169,467/33x20 221,467/33x20 273,467/33x20 315,467/33x20 281,514/73x17 358,514/54x17"),
    ]

}
