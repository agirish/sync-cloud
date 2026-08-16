import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// What choosing a rung costs, searched against computed.
///
/// This is the measurement the change exists for, isolated from the app: laying out the header once
/// via the old six-child `ViewThatFits` against laying it out via the arithmetic. `ViewThatFits`
/// builds every child to measure it, so the search pays for six whole toolbars — two `Menu`s among
/// them, whose content builders are **not** lazy — where the arithmetic pays for one row plus a sum.
///
/// The app-level number is in the commit body: this is the unit-level one, kept as the regression net
/// that finding implies. If a future edit puts the search back, or makes the arithmetic itself
/// expensive, this fails.
///
/// **The claim is the SAVING — `searched - computed` in milliseconds — not the ratio.** It used to be
/// a ratio, and the ratio flaked three times (2026-08-03, and twice on 2026-08-14), each time on a
/// commit that could not reach this code. `docs/flaky-tests.md` §6 has the full history; the short
/// version is that a ratio is the wrong statistic for this measurement:
///
/// - Contention lands on the two arms **additively**, and an additive term does not divide out when
///   the arms differ in magnitude — `(a+d)/(b+d) < a/b`. The computed arm is about a third of the
///   searched one, so the same stolen milliseconds cost it three times as much proportionally.
///   Interleaving the samples does not help: it cancels load that *drifts between* the arms, not a
///   steady overhead present during both.
/// - Measured over nine runs spanning idle-and-isolated to contended-CI, the ratio ranged 1.65 to
///   2.78 and crossed its 1.8 bar three times, while the saving stayed within 10.40ms to 24.73ms and
///   never came close to zero. One idle isolated run scored 2.02 — the old bar had 0.22 of margin at
///   the best conditions this machine offers, not the comfortable headroom its comment claimed. The
///   lowest ratio of all, 1.65, was measured on the very commit that fixed this, so the old bar
///   would have gone red a fourth time on its own fix; that run's saving read 10.40ms and passed.
///
/// The saving is the statistic that moves when **the search comes back**: the two arms converge and
/// it collapses toward zero. Both contention modes push it the *safe* way — an additive term leaves
/// it unchanged, and a multiplicative one widens it (the 24.73ms run is a heavily inflated
/// `searched`).
///
/// **It does not cover the other regression this test claims, so that one is measured separately.**
/// A saving is a difference of two layouts, and it stays comfortable while the computed arm nearly
/// doubles — the retired ratio would have caught that, which is the one thing it was better at. So
/// building the ladder and choosing a rung is timed on its own, away from any view building, against
/// ``maximumRungMicroseconds``. That states the claim directly instead of inferring it from a
/// subtraction, with one to two orders of magnitude between the measurement and the regression it
/// guards — see that constant for what is and is not in the timed pair.
///
/// A saving failure is therefore **two-valued and the message says so**: the search is back, or the
/// header row itself became cheap enough that the floor needs re-deriving. The rung ceiling tells
/// them apart.
///
/// An absolute millisecond floor is defensible here for the reason `ColumnClickCostBenchmark`'s
/// fixed budget is: the CI runner IS the machine these numbers were calibrated on. `.machinePinned`
/// does not enforce that — it skips only the reasons in `SYNCCLOUD_SKIP_MACHINE_PINNED`, which CI
/// sets to `referenceImages,liveProfile`, so `calibratedTiming` runs there and on any other Mac. Re-
/// measure both constants if the runner ever moves.
///
/// The probe is kept, but it is **diagnostic only and deliberately not used in the assertion** — the
/// previous comment claimed the bar "stretches by that factor" and no code ever did that. It is also
/// not a dependable load signal: it read 9.2ms on an idle machine and 7.4ms on the contended CI run
/// that failed. It is not simply anti-correlated — the calibration table below has it rising 1.7-1.9x
/// under local contention — it is **unreliable**, and it failed to rise on the one run whose bar
/// depended on it, which is the only case a load multiplier exists for.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable, .machinePinned(.calibratedTiming))
struct HeaderLadderCostBenchmark {

    /// A realistic comparison — the header's cost is per layout pass and does not scale with the row
    /// count, but the labels have to be real or the rungs collapse to the same width.
    private func fixture() -> (view: DifferencesView, rows: [FileDifference],
                               targets: DifferenceActionTargets,
                               sections: [DifferenceGrouping.Section],
                               facts: HeaderLadder.Facts,
                               dressing: DifferencesView.CountPillDressing) {
        var rows: [FileDifference] = []
        let folders = ["Documents", "Photos", "Projects"]
        for index in 0..<1_284 {
            rows.append(FileDifference(
                relativePath: "\(folders[index % 3])/right-\(index).txt",
                leftItemPath: "/left/right-\(index).txt", rightItemPath: "/right/right-\(index).txt",
                type: .missingOnRight, action: .copyToRight, description: "x", leftFileSize: 1_024))
        }
        for index in 0..<431 {
            rows.append(FileDifference(
                relativePath: "\(folders[index % 3])/dates-\(index).txt",
                leftItemPath: "/left/dates-\(index).txt", rightItemPath: "/right/dates-\(index).txt",
                type: .differentDates, action: .copyToLeft, description: "x",
                leftFileSize: 4_096, rightFileSize: 4_096))
        }
        let names = PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive")
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = true
        manager.leftItemCount = 1_284
        manager.rightItemCount = 976
        let view = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore(),
                                   paneNames: names, isCollapsed: .constant(false))
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        let dressing = DifferencesView.CountPillDressing(
            semantic: .onAccent(fill: .blue, label: .white), detailStyle: nil,
            detail: "29m ago", spokenDetail: "29m ago", help: "Last scanned 10:15:00")
        let facts = HeaderLadder.Facts(
            differencesCount: rows.count, detail: dressing.detail, detailIsCapsuled: false,
            chevronSymbol: CountPillChevron.symbol(hasScanned: true, expanded: false),
            itemCountsText: nil, sectionCount: sections.count,
            filterName: DifferenceFilter.all.displayName(leftName: names.left, rightName: names.right),
            isSelectionScoped: false, targetCount: targets.targets.count,
            verifiableCount: targets.verifiableCount,
            copyToLeftCount: targets.copyToLeftCount, copyToRightCount: targets.copyToRightCount,
            reverseIsMajority: targets.dominantCopyDirection == .copyToLeft,
            leftName: names.left, rightName: names.right, isMove: false, showsCollapseToggle: true)
        return (view, rows, targets, sections, facts, dressing)
    }

    /// The floor the saving must clear, in milliseconds. Calibrated from nine runs whose savings
    /// spanned 10.40ms to 24.73ms — idle-and-isolated, and under the contention of a full CI suite —
    /// so this sits 42% below the smallest one ever measured. The 10.40ms is the run that validated
    /// this change on CI, and it is the most informative of the nine: it measured a **1.65x** ratio,
    /// lower than either of the two failures this replaced, so the old bar would have taken CI red a
    /// fourth time on the very commit that fixed it. It is deliberately not tighter: the
    /// regression it guards — **the search returning, and only that** — drives the saving to roughly
    /// zero, so margin costs almost nothing in sensitivity and buys the headroom three ratio flakes
    /// proved this measurement needs. The other regression this suite claims to catch, the
    /// arithmetic itself becoming expensive, is NOT covered by any floor on a difference of two
    /// layouts; ``maximumRungMicroseconds`` measures that one directly, and the mutation that proves
    /// the gap passed straight through this bar at 16.07ms.
    private static let minimumSavingMs = 6.0

    /// What one `rung(fitting:)` may cost, in **microseconds**, measured on its own.
    ///
    /// **The saving does not guard the second regression, so it is measured directly here.** The
    /// type comment claims this test catches both "the search came back" and "the arithmetic itself
    /// became expensive"; only the first is true of a saving. With `searched` ~22ms and `computed`
    /// ~9ms, the computed arm can nearly double before the saving falls to a 6ms floor — the ratio
    /// this replaced would have caught that at ~12ms. Bringing the ratio back is not the answer,
    /// because contention is what broke it. Measuring the claim where it lives is.
    ///
    /// **What is timed is `HeaderLadder(facts:scale:)` plus `rung(fitting:)`, and that is not "pure
    /// arithmetic".** The initializer calls `measure(_:scale:)`, which goes through
    /// `Design.LabelMetrics` for text and SF-symbol widths — cached, but real measurement. Timing
    /// the pair is the right unit anyway: it is what the computed arm actually does per layout, and
    /// it means a regression that moves work from `rung` into the initializer is still caught. The
    /// figure printed as `rung=` is therefore the pair, not the method alone.
    ///
    /// What it excludes is view building, which is the whole point: no `NSHostingView`, no row. The
    /// margin is one to two orders of magnitude rather than the three an earlier draft of this
    /// comment claimed — one header row costs ~4-5ms (the searched arm builds six for ~24ms, the
    /// computed arm two for ~10ms), so a single row reappearing in here is ~4,000µs against the
    /// ceiling below, and the mutation that proved it measured 19,611µs. Enough that load cannot
    /// reach the bar; not so much that the number deserves rounding up in prose.
    ///
    /// **Calibrated from four runs rather than guessed, and the first guess was wrong.** 40µs looked
    /// generous against an idle 23.73µs and would have failed outright on a contended run:
    ///
    /// | run | rung | probe | searched | saving | ratio |
    /// |---|---|---|---|---|---|
    /// | quiet | 23.73µs | 8.5ms | 23.97ms | 14.02ms | 2.41x |
    /// | quiet | 20.48µs | 9.0ms | 26.84ms | 15.93ms | 2.46x |
    /// | contended | 43.26µs | 15.1ms | 57.72ms | 26.94ms | 1.88x |
    /// | contended | 41.00µs | 16.2ms | 56.62ms | 23.54ms | **1.71x** |
    ///
    /// 400µs is 9x the worst of those and still ~10x below one row build (~4,000µs). The same runs are why
    /// the saving is the right bar for the other claim: it ranged 14.02-26.94ms against its 6ms
    /// floor while **the retired 1.8x ratio would have failed the last run outright** — a fourth
    /// flake, on an unchanged tree, measured here rather than argued.
    private static let maximumRungMicroseconds = 400.0

    /// How many rungs to compute per sample. Large enough that one sample is well clear of the
    /// clock's resolution, so the per-call figure is a measurement rather than a rounding.
    private static let rungIterations = 200

    /// One fixed chunk of CPU-bound work (FNV-1a), timed on the calling thread — the load probe.
    /// The iteration count is FIXED: sizing it by wall time would absorb the slowdown it measures.
    private static let probeIterations = 100_000

    private func probeMs() -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        var acc: UInt64 = 0xcbf2_9ce4_8422_2325
        for index in 0..<Self.probeIterations {
            acc = (acc ^ UInt64(index)) &* 0x100_0000_01b3
        }
        precondition(acc != 0, "FNV accumulator can never be zero")
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    /// Builds and lays out `view` from scratch in a real window, and reports the wall time. From
    /// scratch on every sample, because that is what a `body` re-evaluation costs — a reused hosting
    /// view would measure SwiftUI's caching instead of the work.
    /// The window and its hosting view are dropped before returning, which is not tidiness: 36 of
    /// them accumulate over one run, each retaining a SwiftUI graph over the 1,715-row fixture, and
    /// the later samples of this very benchmark would then be measured under the weight of the
    /// earlier ones. `ColumnClickCostBenchmark` clears its `contentView` for the same reason and
    /// cites mechanism 8; the release is outside the timed span so it cannot flatter the number.
    private func layoutMs<V: View>(_ make: () -> V, width: CGFloat) -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        let host = NSHostingView(rootView: AnyView(
            make().modifier(HeaderCardChrome(tint: .blue)).frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        window.contentView = nil
        return elapsed
    }

    @Test func computingTheRungBeatsSearchingForIt() {
        let f = fixture()
        // 900pt: wide enough that the search has to build and reject several rungs before settling,
        // which is the everyday case. At a width where rung 0 fits immediately the search is cheapest
        // and the comparison would flatter it.
        let width: CGFloat = 900

        func searched() -> some View {
            func row(_ rung: HeaderCompaction) -> some View {
                f.view.standardHeaderRow(rung, facts: f.facts, dressing: f.dressing,
                                         targets: f.targets, sorted: f.rows, sections: f.sections)
            }
            return ViewThatFits(in: .horizontal) {
                row(.full); row(.foldVerify); row(.foldReview)
                row(.shortReverse); row(.glyphFilter); row(.shortPrimary)
            }
        }
        func computed() -> some View {
            let ladder = HeaderLadder(facts: f.facts, scale: 1)
            let rung = ladder.rung(fitting: width)
            return ViewThatFits(in: .horizontal) {
                f.view.standardHeaderRow(rung, facts: f.facts, dressing: f.dressing,
                                         targets: f.targets, sorted: f.rows, sections: f.sections)
                f.view.standardHeaderRow(ladder.terminal, facts: f.facts, dressing: f.dressing,
                                         targets: f.targets, sorted: f.rows, sections: f.sections)
            }
        }

        // Warm both paths: the first hosting view in a process pays one-off SwiftUI and font setup,
        // and whichever path ran first would otherwise carry it.
        for _ in 0..<3 {
            _ = layoutMs({ searched() }, width: width)
            _ = layoutMs({ computed() }, width: width)
        }

        var searchedSamples: [Double] = []
        var computedSamples: [Double] = []
        var probes: [Double] = []
        // Interleaved, so a drifting machine load lands on both paths equally rather than on
        // whichever ran second.
        for _ in 0..<15 {
            probes.append(probeMs())
            searchedSamples.append(layoutMs({ searched() }, width: width))
            computedSamples.append(layoutMs({ computed() }, width: width))
        }

        // Building the ladder and choosing a rung, with no view building anywhere near it — the
        // direct form of "choosing a rung is still cheap", which the saving cannot express.
        var rungSamples: [Double] = []
        var rungSink = 0
        for _ in 0..<15 {
            let started = CFAbsoluteTimeGetCurrent()
            for _ in 0..<Self.rungIterations {
                let ladder = HeaderLadder(facts: f.facts, scale: 1)
                // Summed, not discarded: `probeMs()` keeps its accumulator observable for exactly
                // this reason, and a loop whose result nothing reads is one an optimising build may
                // delete, leaving the ceiling to pass over a measurement that never happened.
                rungSink &+= ladder.rung(fitting: width).hashValue
            }
            rungSamples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000_000)
        }

        let searchedMedian = searchedSamples.sorted()[searchedSamples.count / 2]
        let computedMedian = computedSamples.sorted()[computedSamples.count / 2]
        let probeMedian = probes.sorted()[probes.count / 2]
        let saving = searchedMedian - computedMedian
        let speedup = searchedMedian / computedMedian
        let rungMicroseconds = rungSamples.sorted()[rungSamples.count / 2] / Double(Self.rungIterations)
        // Keeps the accumulator observable, the same way `probeMs()` does with its FNV sum — and
        // compared against its INITIAL value, not against an arbitrary sentinel. `!= Int.min` was
        // theatre: an elided loop leaves the sum at 0, which passes that test, so the assertion
        // could not detect the one thing it named.
        #expect(rungSink != 0, "the rung loop was optimised away — the ceiling measured nothing")
        // `speedup` and `probe` are printed for diagnosis and neither is asserted on — see the type
        // comment for why the ratio was retired and why the probe cannot stand in for load.
        print("BENCH header rung: searched=\(String(format: "%.2f", searchedMedian))ms "
              + "computed=\(String(format: "%.2f", computedMedian))ms "
              + "saving=\(String(format: "%.2f", saving))ms "
              + "speedup=\(String(format: "%.2f", speedup))x "
              + "probe=\(String(format: "%.1f", probeMedian))ms "
              + "rung=\(String(format: "%.2f", rungMicroseconds))µs")

        // **Read a failure here as one of two things, not one.** The saving is the difference
        // between two layouts, so it is proportional to what building a header row costs: an edit
        // that makes the ROW much cheaper shrinks both arms and the gap between them, and lands here
        // looking exactly like a regression. The rung ceiling below is what tells them apart — if it
        // still passes, nothing got expensive and this floor wants re-deriving against the row's new
        // cost.
        let note = "computing the rung saves only \(String(format: "%.2f", saving))ms over searching "
            + "for it (searched \(String(format: "%.2f", searchedMedian))ms, "
            + "computed \(String(format: "%.2f", computedMedian))ms, "
            + "\(String(format: "%.2f", speedup))x) — either the search is back, or the header row "
            + "itself got cheap enough that this floor needs re-deriving"
        #expect(saving > Self.minimumSavingMs, "\(note)")

        let rungNote = "one HeaderLadder + rung(fitting:) costs "
            + "\(String(format: "%.2f", rungMicroseconds))µs against a "
            + "\(String(format: "%.0f", Self.maximumRungMicroseconds))µs ceiling — the ladder is "
            + "doing layout work, not choosing a rung"
        #expect(rungMicroseconds < Self.maximumRungMicroseconds, "\(rungNote)")
    }
}
