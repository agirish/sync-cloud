import AppKit
import SwiftUI
import Testing
@testable import FileExplorer

/// Why `DifferencesView.countPillToggle`'s `.onChange(of: hasScanned)` sits OUTSIDE
/// `withScanFreshness` rather than inside the closure with everything else.
///
/// `withScanFreshness` renders a `TimelineView` only while `lastScanDate` is non-nil, and falls back
/// to a plain render when it is nil. `FileSyncManager+Navigation`'s
/// `invalidateDifferencesForPaneRetarget()` clears `lastScanDate` and `hasScanned` in ONE
/// transaction — so a handler living inside that closure is torn down by the very change it is
/// watching for, and never fires. The reset it owes (`showItemCounts`, `isCountPillHovered`) is then
/// silently skipped, leaving the pill expanded over a comparison that no longer exists.
///
/// Asserted rather than argued, because the placement reads like a style choice — an `.onChange`
/// tucked in with the `.help` and the accessibility modifiers looks tidier, and nothing about the
/// call site says it must not be. This suite is the note that says it must.
///
/// The four cases form their own control. The one that fails is exactly the shipped shape under
/// exactly the retarget transaction; the "branch survives" row proves the harness CAN see a handler
/// fire from inside the closure, so the empty result in the first row is a real miss and not a rig
/// that never observes anything.
///
/// **What this does NOT pin.** `countPillToggle` is private and its `showItemCounts` is `@State`, so
/// nothing here reaches the shipped view: moving that `.onChange` back inside the closure would
/// leave this suite green. What is pinned is the HAZARD — so anyone who makes that move and runs the
/// suite finds the reason not to, spelled out, instead of rediscovering it from a bug report.
@MainActor
@Suite(.serialized) struct CountPillResetObservationTests {

    /// Stands in for the two `FileSyncManager` fields involved. `ObservableObject` with `@Published`
    /// because that is what `FileSyncManager` is — the observation mechanism is half of what is
    /// being characterised here, so substituting `@Observable` would test a different thing.
    private final class Model: ObservableObject {
        @Published var lastScanDate: Date?
        @Published var hasScanned: Bool
        init(lastScanDate: Date?, hasScanned: Bool) {
            self.lastScanDate = lastScanDate
            self.hasScanned = hasScanned
        }
    }

    private final class Recorder: @unchecked Sendable {
        var fired: [Bool] = []
    }

    /// Reproduces `countPillToggle`'s shape: `withScanFreshness` verbatim, with the handler placed
    /// on either side of it.
    private struct Specimen: View {
        @ObservedObject var model: Model
        let recorder: Recorder
        let handlerInsideBranch: Bool

        @ViewBuilder
        private func withScanFreshness(@ViewBuilder _ content: @escaping (String) -> some View) -> some View {
            if let scanDate = model.lastScanDate {
                TimelineView(.periodic(from: scanDate, by: 30)) { _ in content("fresh") }
            } else {
                content("none")
            }
        }

        var body: some View {
            if handlerInsideBranch {
                withScanFreshness { detail in
                    Text(detail)
                        .onChange(of: model.hasScanned) { _, now in recorder.fired.append(now) }
                }
            } else {
                withScanFreshness { detail in Text(detail) }
                    .onChange(of: model.hasScanned) { _, now in recorder.fired.append(now) }
            }
        }
    }

    /// Hosts the specimen, applies the state change, and returns what the handler saw.
    ///
    /// `clearsScanDate` is the whole variable: true is `invalidateDifferencesForPaneRetarget()`
    /// (both fields in one transaction), false is a reset that leaves the freshness branch standing.
    private func observedResets(handlerInsideBranch: Bool, clearsScanDate: Bool) -> [Bool] {
        let model = Model(lastScanDate: Date(timeIntervalSince1970: 1_780_315_200), hasScanned: true)
        let recorder = Recorder()
        let host = NSHostingView(rootView: AnyView(
            Specimen(model: model, recorder: recorder, handlerInsideBranch: handlerInsideBranch)
                .frame(width: 300, height: 60)))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        // Borderless and never ordered in: nothing appears on the machine running this.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        pump(host)

        if clearsScanDate { model.lastScanDate = nil }
        model.hasScanned = false
        pump(host)
        return recorder.fired
    }

    /// SwiftUI applies state changes on the main run loop, not on `layoutSubtreeIfNeeded` alone.
    private func pump(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// **The bug.** Inside the branch, the retarget transaction is missed entirely.
    ///
    /// This pins a SwiftUI behaviour rather than our own code, so it is the one test here that could
    /// start failing because the framework improved. That failure would be worth reading, not
    /// silencing: it would mean the hazard this placement works around is gone.
    @Test func aHandlerInsideTheFreshnessBranchMissesTheRetargetTransaction() {
        #expect(observedResets(handlerInsideBranch: true, clearsScanDate: true) == [])
    }

    /// **The fix.** Outside, the same transaction is observed — the handler hangs off the branch
    /// SWITCH instead of off either branch.
    @Test func aHandlerOutsideTheFreshnessBranchObservesTheRetargetTransaction() {
        #expect(observedResets(handlerInsideBranch: false, clearsScanDate: true) == [false])
    }

    /// The control that makes the two above mean something. When `lastScanDate` survives, the branch
    /// survives, and BOTH placements observe the change — so the empty result above is the teardown,
    /// not a rig that cannot see handlers fire.
    ///
    /// It is also why the defect went unnoticed: every path that resets `hasScanned` WITHOUT
    /// clearing the scan date works exactly as written.
    @Test func bothPlacementsObserveAResetThatLeavesTheBranchStanding() {
        #expect(observedResets(handlerInsideBranch: true, clearsScanDate: false) == [false])
        #expect(observedResets(handlerInsideBranch: false, clearsScanDate: false) == [false])
    }
}
