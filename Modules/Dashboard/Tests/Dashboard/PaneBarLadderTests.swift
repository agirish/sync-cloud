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
@Suite(.serialized) struct PaneBarLadderTests {

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
                               collapse: Bool = false) -> some View {
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

    /// The ladder a full Columns header actually builds — the same `availableItems` the view derives,
    /// restated here because that property is private to the view.
    private static var columnsLadder: PaneBarLadder {
        PaneBarLadder(arrangement: .default,
                      available: [.backForward, .sort, .hiddenFiles, .viewMode, .scan, .newFolder, .preview],
                      ceiling: .small)
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
        let ladder = Self.columnsLadder
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
        let ladder = Self.columnsLadder
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
        let ladder = Self.columnsLadder
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
        let ladder = Self.columnsLadder
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

    /// Only the view switch is taller than a pill, and only while it is uncompacted. The header pins
    /// its bar container to this, so a wrong answer here moves the breadcrumb.
    @Test func onlyTheUncompactedSwitchIsTallerThanAPill() {
        let ladder = Self.columnsLadder
        let pillHeight = PaneNavMetrics.pill(.mini).height
        #expect(ladder.height(forRung: ladder.terminal) == pillHeight)
        #expect(ladder.height(forRung: 1) == pillHeight + 6)
        #expect(ladder.height(forRung: 0) == PaneNavMetrics.pill(.small).height + 6)
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
    @Test func theLadderRendersItsGolden() {
        for (key, expected) in Self.golden {
            let parts = key.split(separator: "|")
            let name = parts[0] == "columns-icloud" ? "iCloud Drive" : "Marketing Team Shared Archive Drive"
            let scale = CGFloat(Double(parts[1])!)
            let width = CGFloat(Int(parts[2])!)
            let view = Self.header(name).environment(\.appFontScale, scale)
            #expect(fingerprint(view, width: width) == expected, "\(key)")
        }
    }

    private static let golden: [String: String] = [
        "columns-icloud|0.9|250": "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/37x13 49,508/58x13 110,508/44x13",
        "columns-icloud|0.9|410": "212,481/23x17 238,481/23x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,515/37x13 49,515/58x13 110,515/44x13",
        "columns-icloud|0.9|490": "197,481/23x17 223,481/23x17 255,481/27x17 288,481/27x17 321,481/27x17 354,481/27x17 387,481/27x17 420,481/27x17 453,481/23x17 10,515/37x13 49,515/58x13 110,515/44x13",
        "columns-icloud|0.9|710": "363,479/29x20 395,479/29x20 433,479/33x20 472,479/33x20 511,479/33x20 550,479/33x20 589,479/33x20 628,479/33x20 667,479/29x20 10,515/37x13 49,515/58x13 110,515/44x13",
        "columns-icloud|1.0|250": "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15",
        "columns-icloud|1.0|330": "157,481/27x17 190,481/27x17 223,481/27x17 256,481/27x17 289,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15",
        "columns-icloud|1.0|410": "212,481/23x17 238,481/23x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,514/39x15 52,514/63x15 117,514/47x15",
        "columns-icloud|1.0|490": "197,481/23x17 223,481/23x17 255,481/27x17 288,481/27x17 321,481/27x17 354,481/27x17 387,481/27x17 420,481/27x17 453,481/23x17 10,514/39x15 52,514/63x15 117,514/47x15",
        "columns-icloud|1.0|570": "223,479/29x20 255,479/29x20 293,479/33x20 332,479/33x20 371,479/33x20 410,479/33x20 449,479/33x20 488,479/33x20 527,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15",
        "columns-icloud|1.0|710": "363,479/29x20 395,479/29x20 433,479/33x20 472,479/33x20 511,479/33x20 550,479/33x20 589,479/33x20 628,479/33x20 667,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15",
        "columns-long|1.0|250": "77,481/27x17 110,481/27x17 143,481/27x17 176,481/27x17 209,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15",
        "columns-long|1.0|410": "237,481/27x17 270,481/27x17 303,481/27x17 336,481/27x17 369,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15",
        "columns-long|1.0|490": "317,481/27x17 350,481/27x17 383,481/27x17 416,481/27x17 449,481/27x17 10,508/39x15 52,508/63x15 117,508/47x15",
        "columns-long|1.0|570": "372,481/23x17 398,481/23x17 430,481/27x17 463,481/27x17 496,481/27x17 529,481/27x17 10,514/39x15 52,514/63x15 117,514/47x15",
        "columns-long|1.0|650": "357,481/23x17 383,481/23x17 415,481/27x17 448,481/27x17 481,481/27x17 514,481/27x17 547,481/27x17 580,481/27x17 613,481/23x17 10,514/39x15 52,514/63x15 117,514/47x15",
        "columns-long|1.0|710": "363,479/29x20 395,479/29x20 433,479/33x20 472,479/33x20 511,479/33x20 550,479/33x20 589,479/33x20 628,479/33x20 667,479/29x20 10,514/39x15 52,514/63x15 117,514/47x15",
    ]
}
