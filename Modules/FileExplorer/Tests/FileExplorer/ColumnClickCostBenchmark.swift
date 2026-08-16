import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// What re-rendering a Columns pane costs when a selection changes.
///
/// Built to chase a reported ~290ms click on panes of ~40,000 nodes, and it **cleared the pane**:
/// three open columns over a 40k tree re-render in ~10ms. Two independent results agree that the
/// reported number is not this view's rendering — the same click measured identically in a Release
/// build as in Debug, and optimisation would have moved real computation.
///
/// It stays as the regression net that finding implies: if a pane render ever does start costing
/// what a click was blamed for, this catches it, and the threshold is deliberately far above the
/// measured cost so it fails on a regression rather than on machine noise.
///
/// The fixture has to be REALISTIC or the measurement is worthless: a small tree, or one whose
/// arrays are COW-shared with the assertion, benchmarks at 0.0ms and proves nothing.
///
/// **The budget was load-scaled by a probe that cannot see this machine's load, and is now a fixed
/// number sized against the worst starvation ever measured here.**
///
/// The scaling read `slowdown = max(1.0, probeMedian / 10ms)` and multiplied a 120ms bar by it. The
/// premise — "a genuine render regression is CPU work that slows down with the machine exactly as
/// the probe does" — is contradicted by measurements taken one file over and recorded in
/// `docs/flaky-tests.md` §6. During the CI run where `HeaderLadderCostBenchmark` failed on
/// starvation, **this test reported `slowdown=1.00x`**: the probe sat at nominal while the render
/// arms were inflated, so `max(1.0, …)` floored the multiplier and the bar never stretched. The
/// probe read 9.2ms idle against 7.4ms on that contended run — anti-correlated with the thing it
/// was hired to detect.
///
/// It reads that way because a tight FNV loop and a run-loop-driven render are starved by different
/// things: the loop only wants a core, while the render waits on the main run loop, the window
/// server and everything else on this Mac. So the scaling was protection that existed in prose,
/// never fired, and left the real exposure — the run that pushed this median to 163ms with nothing
/// regressed — sitting above an unstretched 120ms bar.
///
/// The fixed 250ms bar covers that 163ms measurement with half again on top, and still fails the
/// regression this exists for: the reported ~290ms click it was built to chase, against a measured
/// ~10ms render. An absolute number is legitimate here for the same reason the sibling's is —
/// `.machinePinned(.calibratedTiming)` means this only ever runs on the machine it was calibrated
/// on. The probe stays, printed, as diagnosis, and **is deliberately not asserted on**: a probe that
/// feeds no assertion is never checked, and this one was wrong for as long as it was there.
@MainActor
@Suite(.machinePinned(.calibratedTiming)) struct ColumnClickCostBenchmark {

    private struct StubDelegate: FileActionDelegate {
        /// Stands in for `FileSyncManager.isNodeIgnored`, which relativizes the path and tests it
        /// against the effective ignore set — per row, per render.
        let ignored: Set<String>
        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
            ignored.contains(node.id)
        }
    }

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    static let root = "/root"

    /// ~40,000 nodes, three levels deep, matching the shape the panes actually hold (the user's two
    /// sides are 40,177 and 37,894). Distinct strings throughout so nothing is COW-shared.
    private static func bigTree(side: PaneTree.Side) -> PaneTree {
        var top: [FileNode] = []
        top.reserveCapacity(40)
        for a in 0..<40 {
            var mid: [FileNode] = []
            mid.reserveCapacity(25)
            for b in 0..<25 {
                let dir = "\(root)/top\(a)/mid\(b)"
                let files = (0..<40).map { c in
                    FileNode(id: "\(dir)/file-\(a)-\(b)-\(c).pdf",
                             name: "file-\(a)-\(b)-\(c).pdf", isDirectory: false)
                }
                mid.append(FileNode(id: dir, name: "mid\(b)", isDirectory: true, children: files))
            }
            top.append(FileNode(id: "\(root)/top\(a)", name: "top\(a)", isDirectory: true, children: mid))
        }
        return PaneTree(side: side, version: 1, nodes: top)
    }

    /// Counts body evaluations, so a measurement can prove the view actually re-rendered rather
    /// than timing a no-op.
    final class Counter: @unchecked Sendable { var bodies = 0 }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let otherTree: PaneTree
        let index: PaneChildrenIndex
        let diffIndex: DiffStatusIndex
        let delegate: FileActionDelegate
        let counter: Counter
        let downloads: NotificationCenter

        var body: some View {
            counter.bodies += 1
            return FileTreeView(
                tree: tree, otherTree: otherTree, isLoading: false,
                currentPath: ColumnClickCostBenchmark.root,
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: delegate, diffIndex: diffIndex,
                viewMode: .columns, childrenIndex: index,
                browsePath: $box.browsePath,
                onColumnNavigate: { box.browsePath = $0 },
                downloadChannel: downloads
            )
        }
    }

    /// Mounts the pane on a `NotificationCenter` of its own.
    ///
    /// This benchmark wants nothing from `.cloudDownloadRequested`, but a mounted `FileTreeView`
    /// subscribes regardless, and it is machine-pinned — so on `.default` it sits in the process
    /// for a 1.5 s pump accepting the `.left` posts `CloudDownloadWiringTests` makes to prove a
    /// RIGHT pane ignores them, running `CloudOnlyBadgeCache.forget` on that suite's ghosts. See
    /// `docs/flaky-tests.md` mechanism 9.
    private func mount(_ box: Box, counter: Counter) -> NSWindow {
        let tree = Self.bigTree(side: .left)
        let otherTree = Self.bigTree(side: .right)
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let delegate = StubDelegate(ignored: [])
        let host = NSHostingView(rootView: Harness(
            box: box, tree: tree, otherTree: otherTree, index: index,
            diffIndex: .empty, delegate: delegate, counter: counter,
            downloads: NotificationCenter()))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    private func pump(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }

    private func tables(_ view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { found.append(t) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    /// One fixed chunk of CPU-bound work (FNV-1a over a counter), timed on the calling thread.
    /// Its wall time is the load probe: on an idle machine it costs `nominalProbeMs`; when the
    /// scheduler is starving this process it stretches by the same factor the render work does.
    /// The iteration count is FIXED — sizing it by wall time would absorb the very slowdown it
    /// exists to measure.
    private static let probeIterations = 100_000
    /// What one probe costs unloaded, in this test process, debug build, on the CI machine.
    /// Measured 2026-07-28 (samples printed by the test itself). Kept for reading the printed
    /// probe against — it no longer scales anything.
    private static let nominalProbeMs: Double = 10.0

    /// The render budget, in milliseconds. Sized against the worst starvation measured on this
    /// machine (163ms, nothing regressed) rather than against an idle run, because the scaling that
    /// was supposed to absorb that never fired. Still far below the ~290ms click this exists to
    /// catch, and 25x above the ~10ms a healthy render costs.
    private static let budgetMs: Double = 250.0

    private func probeMs() -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        var acc: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<Self.probeIterations {
            acc = (acc ^ UInt64(i)) &* 0x100_0000_01b3
        }
        // The accumulator must stay observable or the loop is dead code to the optimiser.
        precondition(acc != 0, "FNV accumulator can never be zero")
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    /// Wall time from committing the selection to the view graph having re-rendered and laid out.
    /// `layoutIfNeeded` drives `NSHostingView`'s update, so this captures the render the click pays
    /// for. The body counter is checked by the caller: a measurement over a body that never ran is
    /// timing nothing.
    private func renderMs(_ window: NSWindow, _ body: () -> Void) -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        body()
        window.layoutIfNeeded()
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
        window.layoutIfNeeded()
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    @Test func benchmarkSelectionClickCost() throws {
        let box = Box()
        let counter = Counter()
        let window = mount(box, counter: counter)
        // Drops the last reference to the SwiftUI graph, and with it the pane's live subscription,
        // rather than leaving it to ARC. Not `close()` — see mechanism 8.
        defer { window.contentView = nil }
        // Two columns deep, as the user was: /root/top3/mid7 open, its files listed.
        box.browsePath = PaneBrowsePath(components: ["top3", "mid7"])
        pump(window, seconds: 1.5)

        let columns = tables(window.contentView!)
        #expect(columns.count == 3, "expected three columns; got \(columns.count) — fixture is wrong")
        let rowCounts = columns.map(\.numberOfRows)
        #expect(rowCounts.allSatisfy { $0 > 0 }, "a column materialised no rows: \(rowCounts)")

        // Click a file in the deepest column, repeatedly, as the user does walking a folder.
        // Each render sample is paired with a load probe taken moments before it, so the slowdown
        // estimate tracks whatever the machine was doing DURING this loop, not at suite start.
        var samples: [Double] = []
        var probes: [Double] = []
        for i in 0..<8 {
            let target = "\(Self.root)/top3/mid7/file-3-7-\(i).pdf"
            probes.append(probeMs())
            let before = counter.bodies
            samples.append(renderMs(window) { box.selection = [target] })
            #expect(counter.bodies > before, "the pane did not re-render — the sample is vacuous")
        }
        let median = samples.sorted()[samples.count / 2]
        let probeMedian = probes.sorted()[probes.count / 2]
        // The probe is printed for diagnosis and NOT asserted on — see the type comment for the
        // measurement that retired it as a load signal.
        print("BENCH columns=\(rowCounts) render samples=\(samples.map { Int($0) }) median=\(Int(median))ms "
              + "probes=\(probes.map { Int($0) }) probeMedian=\(Int(probeMedian))ms "
              + "budget=\(Int(Self.budgetMs))ms")
        // Measured ~10ms unloaded, and 163ms once under deliberate starvation with nothing
        // regressed. The bar clears that worst case and still catches the ~290ms this was built to
        // chase.
        #expect(median < Self.budgetMs,
                "pane render cost regressed to \(Int(median))ms (was ~10ms; budget \(Int(Self.budgetMs))ms)")
    }
}
