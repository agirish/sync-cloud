import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// What choosing a rung costs, searched against computed.
///
/// Lays out the header once through a six-child `ViewThatFits` and once through the arithmetic.
/// `ViewThatFits` builds every child to measure it, so the search pays for six whole toolbars (two
/// `Menu`s among them, whose content builders are not lazy) where the arithmetic pays for one row
/// plus a sum. Fails if the search comes back or the arithmetic itself gets expensive.
///
/// The claim is the saving, `searched - computed` in milliseconds, not the ratio. Contention lands
/// on both arms additively, and an additive term doesn't divide out when the arms differ in size:
/// `(a+d)/(b+d) < a/b`, so a ratio bar flakes under load on trees that can't reach this code.
/// Interleaving cancels load that drifts between the arms, not a steady overhead during both. The
/// saving collapses toward zero when the search comes back, and both contention modes push it the
/// safe way: an additive term leaves it unchanged, a multiplicative one widens it.
/// (`docs/flaky-tests.md`, "Load-scaled benchmarks".)
///
/// A saving stays comfortable while the computed arm nearly doubles, so the second regression is
/// measured on its own, against ``maximumRungMicroseconds``. A saving failure is therefore
/// two-valued, and its message says so: the search is back, or the header row got cheap enough
/// that the floor needs re-deriving. The rung ceiling tells them apart.
///
/// An absolute millisecond floor is defensible for the reason `ColumnClickCostBenchmark`'s fixed
/// budget is: the CI runner is the machine these numbers were calibrated on. `.machinePinned`
/// doesn't enforce that: it skips only the reasons in `SYNCCLOUD_SKIP_MACHINE_PINNED`, which CI
/// sets to `referenceImages,liveProfile`, so `calibratedTiming` runs there and on any other Mac.
/// Re-measure both constants if the runner ever moves.
///
/// The load probe is printed for diagnosis only, never used in an assertion: it is not a dependable
/// load signal, and can fail to rise on exactly the contended run a multiplier would be for.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable, .machinePinned(.calibratedTiming))
struct HeaderLadderCostBenchmark {

    /// A realistic comparison: the header's cost is per layout pass and doesn't scale with the row
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

    /// The floor the saving must clear, in milliseconds. Calibrated from nine runs, idle and under
    /// a full CI suite's contention, whose savings spanned 10.40ms to 24.73ms, so this sits 42%
    /// below the smallest. Not tighter, because the regression it guards (the search returning, and
    /// only that) drives the saving to roughly zero, so margin costs almost no sensitivity. The
    /// arithmetic itself getting expensive is not caught by any floor on a difference of two
    /// layouts; ``maximumRungMicroseconds`` measures that directly.
    private static let minimumSavingMs = 6.0

    /// What one `rung(fitting:)` may cost, in microseconds, measured on its own.
    ///
    /// The saving can't guard this: with `searched` ~22ms and `computed` ~9ms, the computed arm can
    /// nearly double before the saving falls to its 6ms floor. A ratio would catch that but breaks
    /// under contention, so the claim is measured where it lives.
    ///
    /// What is timed is `HeaderLadder(facts:scale:)` plus `rung(fitting:)`, not pure arithmetic:
    /// the initializer measures text and SF-symbol widths through `Design.LabelMetrics` (cached,
    /// but real). The pair is the right unit: it is what the computed arm does per layout, and work
    /// moved from `rung` into the initializer is still caught. `rung=` in the output is the pair.
    ///
    /// It excludes view building: no `NSHostingView`, no row. One header row costs ~4-5ms, so a row
    /// reappearing in here is ~4,000µs, an order of magnitude over the ceiling. Calibrated from
    /// four runs: 20–24µs quiet, 41–43µs contended. 400µs is 9x the worst and still ~10x below one
    /// row build, so load can't reach the bar.
    private static let maximumRungMicroseconds = 400.0

    /// How many rungs to compute per sample: enough that one sample is well clear of the clock's
    /// resolution, so the per-call figure is a measurement rather than a rounding.
    private static let rungIterations = 200

    /// One fixed chunk of CPU-bound work (FNV-1a), timed on the calling thread: the load probe. The
    /// iteration count is fixed: sizing it by wall time would absorb the slowdown it measures.
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
    /// scratch every sample, because that is what a `body` re-evaluation costs; a reused hosting
    /// view would measure SwiftUI's caching instead. The window's content is dropped before
    /// returning: each sample retains a SwiftUI graph over the 1,715-row fixture, and leaving them
    /// would weigh down later samples of this benchmark. `ColumnClickCostBenchmark` clears its
    /// `contentView` for the same reason. The release is outside the timed span, so it can't
    /// flatter the number.
    private func layoutMs<V: View>(_ make: () -> V, width: CGFloat) -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        let host = NSHostingView(rootView: AnyView(
            make().modifier(HeaderCardChrome()).frame(width: width)))
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
        // 900pt: wide enough that the search builds and rejects several rungs before settling, the
        // everyday case. Where rung 0 fits at once the search is cheapest and the comparison would
        // flatter it.
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

        // Building the ladder and choosing a rung with no view building near it: the direct form of
        // "choosing a rung is still cheap", which the saving can't express.
        var rungSamples: [Double] = []
        var rungSink = 0
        for _ in 0..<15 {
            let started = CFAbsoluteTimeGetCurrent()
            for _ in 0..<Self.rungIterations {
                let ladder = HeaderLadder(facts: f.facts, scale: 1)
                // Summed, not discarded: a loop whose result nothing reads may be deleted by an
                // optimising build, leaving the ceiling to pass over a measurement that never ran.
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
        // Keeps the accumulator observable, as `probeMs()` does with its FNV sum, and compared
        // against its initial value: an elided loop leaves the sum at 0.
        #expect(rungSink != 0, "the rung loop was optimised away — the ceiling measured nothing")
        // `speedup` and `probe` are printed for diagnosis and neither is asserted on (see the type
        // comment).
        print("BENCH header rung: searched=\(String(format: "%.2f", searchedMedian))ms "
              + "computed=\(String(format: "%.2f", computedMedian))ms "
              + "saving=\(String(format: "%.2f", saving))ms "
              + "speedup=\(String(format: "%.2f", speedup))x "
              + "probe=\(String(format: "%.1f", probeMedian))ms "
              + "rung=\(String(format: "%.2f", rungMicroseconds))µs")

        // A failure here means one of two things. The saving is proportional to what a header row
        // costs, so an edit that makes the row much cheaper shrinks the gap and looks exactly like
        // a regression. The rung ceiling below tells them apart: if it still passes, nothing got
        // expensive and this floor wants re-deriving against the row's new cost.
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
