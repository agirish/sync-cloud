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
/// - Measured over eight runs spanning idle-and-isolated to contended-CI, the ratio ranged 1.72 to
///   2.78 and crossed its 1.8 bar twice, while the saving stayed within 11.15ms to 24.73ms and never
///   came close to zero. One idle isolated run scored 2.02 — the old bar had 0.22 of margin at the
///   best conditions this machine offers, not the comfortable headroom its comment claimed.
///
/// The saving is the statistic the regression actually moves. If a future edit puts the search back,
/// or makes the arithmetic itself expensive, the two arms converge and the saving collapses toward
/// zero. Both contention modes push it the *safe* way — an additive term leaves it unchanged, and a
/// multiplicative one widens it (the 24.73ms run is a heavily inflated `searched`).
///
/// An absolute millisecond floor is legitimate here for the reason `ColumnClickCostBenchmark` may use
/// its 120ms budget: `.machinePinned(.calibratedTiming)` means this suite only runs on the machine
/// these numbers were calibrated on, which is also the CI runner.
///
/// The probe is kept, but it is **diagnostic only and deliberately not used in the assertion** — the
/// previous comment claimed the bar "stretches by that factor" and no code ever did that. It is also
/// not a usable load signal: it read 9.2ms on an idle machine and 7.4ms on the contended CI run that
/// failed, so it is anti-correlated with the starvation it was meant to detect.
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
    /// regression it guards (the search returning, or the arithmetic becoming expensive) drives the
    /// saving to roughly zero, so margin costs almost nothing in sensitivity and buys the headroom
    /// three ratio flakes proved this measurement needs.
    private static let minimumSavingMs = 6.0

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
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
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

        let searchedMedian = searchedSamples.sorted()[searchedSamples.count / 2]
        let computedMedian = computedSamples.sorted()[computedSamples.count / 2]
        let probeMedian = probes.sorted()[probes.count / 2]
        let saving = searchedMedian - computedMedian
        let speedup = searchedMedian / computedMedian
        // `speedup` and `probe` are printed for diagnosis and neither is asserted on — see the type
        // comment for why the ratio was retired and why the probe cannot stand in for load.
        print("BENCH header rung: searched=\(String(format: "%.2f", searchedMedian))ms "
              + "computed=\(String(format: "%.2f", computedMedian))ms "
              + "saving=\(String(format: "%.2f", saving))ms "
              + "speedup=\(String(format: "%.2f", speedup))x "
              + "probe=\(String(format: "%.1f", probeMedian))ms")

        let note = "computing the rung saves only \(String(format: "%.2f", saving))ms over searching "
            + "for it (searched \(String(format: "%.2f", searchedMedian))ms, "
            + "computed \(String(format: "%.2f", computedMedian))ms, "
            + "\(String(format: "%.2f", speedup))x) — the search may be back"
        #expect(saving > Self.minimumSavingMs, "\(note)")
    }
}
