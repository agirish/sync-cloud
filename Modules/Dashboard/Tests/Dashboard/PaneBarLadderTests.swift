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
    private static func columnsLadder(_ view: PaneHeader = header("iCloud Drive")) -> PaneBarLadder {
        PaneBarLadder(arrangement: .default,
                      available: view.availableItems,
                      ceiling: PaneBarIconSize.regular.ceiling)
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
        let ladder = Self.columnsLadder()
        let rung = isNarrow ? ladder.terminal : 0
        let drawn = barRings(Self.header("iCloud Drive"), width: width)
        #expect(!drawn.isEmpty)

        // The view switch draws its segments inside a 3pt capsule ground, so at any rung that still
        // carries the two-segment switch the bar starts 3pt before the first focus ring.
        let plan = ladder.plan(forRung: rung)
        let leadsWithSwitch = plan.visible.first(where: { !$0.isSpacer }) == .viewMode
            && !plan.compactsViewMode
        let leadingEdge = drawn[0].minX - (leadsWithSwitch ? PaneNavMetrics.segmentPadding : 0)
        let trailingEdge = drawn.map(\.maxX).max() ?? 0

        #expect(trailingEdge - leadingEdge == ladder.width(forRung: rung),
                "rung \(rung) drew \(trailingEdge - leadingEdge)pt, computed \(ladder.width(forRung: rung))pt")
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
        let ladder = Self.columnsLadder()
        let widths = (0...ladder.terminal).map { ladder.width(forRung: $0) }
        for width in stride(from: CGFloat(250), through: 900, by: 25) {
            let drawn = barRings(Self.header("iCloud Drive"), width: width)
            guard let first = drawn.first, let trailing = drawn.map(\.maxX).max() else { continue }
            // Try both leading edges — with and without the switch's capsule ground — and accept if
            // either lands on a rung, since which one applies is exactly what the rung decides.
            let spans = [trailing - first.minX, trailing - first.minX + PaneNavMetrics.segmentPadding]
            #expect(spans.contains(where: { span in widths.contains(where: { abs($0 - span) < 0.5 }) }),
                    "at \(width)pt the bar spans \(spans), no rung of \(widths)")
        }
    }

    // MARK: - The ladder's own arithmetic

    /// `ViewThatFits` takes the FIRST child that fits, and the ladder is deliberately not monotonic:
    /// shedding the preview toggle (a segment wide) to gain a ⋯ pill (a full pill plus its gap) makes
    /// the bar *wider*. A `rung(fitting:)` that sorted by width, or that returned the narrowest rung
    /// that fits, would pick a different bar than the search it replaces.
    @Test func theLadderIsNotMonotonicAndIsWalkedInOrder() {
        let ladder = Self.columnsLadder()
        // Rung 2 sheds the preview toggle and gains ⋯ — measurably wider than rung 1, which sheds
        // nothing. If this ever stops being true the test has lost its subject, not found a bug.
        #expect(ladder.width(forRung: 2) > ladder.width(forRung: 1))
        // Offered exactly rung 1's width, the walk must still answer rung 1 — never the narrower
        // rung 2 that also fits, and never rung 0 that does not.
        #expect(ladder.rung(fitting: ladder.width(forRung: 1)) == 1)
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
        #expect(painted == ladder.height(forRung: 0),
                "switch ground painted \(painted)pt, rung 0 is \(ladder.height(forRung: 0))pt — clipped by the pin?")
    }

    /// Only the view switch is taller than a pill, and only while it is uncompacted. The header pins
    /// its bar container to this, so a wrong answer here moves the breadcrumb.
    @Test func onlyTheUncompactedSwitchIsTallerThanAPill() {
        let ladder = Self.columnsLadder()
        let pillHeight = PaneNavMetrics.pill(.mini).height
        #expect(ladder.height(forRung: ladder.terminal) == pillHeight)
        #expect(ladder.height(forRung: 1) == pillHeight + 6)
        #expect(ladder.height(forRung: 0) == PaneNavMetrics.pill(.small).height + 6)
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
        // Derived, not restated: the ladder's depth is bounded by how long a bar can be.
        #expect(PaneBarLadder.searchedSlotCount == PaneBarArrangement.maxItems + 1)

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

        let ladder = PaneBarLadder(arrangement: worst, available: [.scan], ceiling: .small)
        // The deepest terminal possible: every slot count below `terminal + 1` skips a rung here.
        #expect(ladder.terminal == PaneBarArrangement.maxItems)
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
        (iCloud, 0.9, 710, "363,479/29x20 395,479/29x20 433,479/33x20 472,479/33x20 511,479/33x20 550,479/33x20 589,479/33x20 628,479/33x20 667,479/29x20 10,515/37x13 49,515/58x13 110,515/44x13"),
        (iCloud, 1.0, 250, "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (iCloud, 1.0, 330, "157,481/27x17 190,481/27x17 223,481/27x17 256,481/27x17 289,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (iCloud, 1.0, 410, "212,481/23x17 238,481/23x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        (iCloud, 1.0, 490, "197,481/23x17 223,481/23x17 255,481/27x17 288,481/27x17 321,481/27x17 354,481/27x17 387,481/27x17 420,481/27x17 453,481/23x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        (iCloud, 1.0, 570, "223,479/29x20 255,479/29x20 293,479/33x20 332,479/33x20 371,479/33x20 410,479/33x20 449,479/33x20 488,479/33x20 527,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15"),
        (iCloud, 1.0, 710, "363,479/29x20 395,479/29x20 433,479/33x20 472,479/33x20 511,479/33x20 550,479/33x20 589,479/33x20 628,479/33x20 667,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15"),
        (longName, 1.0, 250, "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (longName, 1.0, 410, "237,481/27x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (longName, 1.0, 490, "317,481/27x17 350,481/27x17 383,481/27x17 416,481/27x17 449,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15"),
        (longName, 1.0, 570, "372,481/23x17 398,481/23x17 430,481/27x17 463,481/27x17 496,481/27x17 529,481/27x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        (longName, 1.0, 650, "357,481/23x17 383,481/23x17 415,481/27x17 448,481/27x17 481,481/27x17 514,481/27x17 547,481/27x17 580,481/27x17 613,481/23x17 10,514/39x15 52,514/63x15 117,514/47x15"),
        (longName, 1.0, 710, "363,479/29x20 395,479/29x20 433,479/33x20 472,479/33x20 511,479/33x20 550,479/33x20 589,479/33x20 628,479/33x20 667,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15"),
    ]

}
