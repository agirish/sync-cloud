import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// Why `DifferencesView.countPillToggle`'s `.onChange(of: hasScanned)` sits outside
/// `withScanFreshness`, not inside its closure.
///
/// `withScanFreshness` renders a `TimelineView` only while `lastScanDate` is non-nil.
/// `invalidateDifferencesForPaneRetarget()` clears `lastScanDate` and `hasScanned` in one
/// transaction, so a handler inside the closure is torn down by the change it watches and never
/// fires, leaving the pill expanded over a comparison that no longer exists.
///
/// The "branch survives" cases prove the harness can see a handler fire inside the closure, so the
/// empty result is a real miss. This pins the hazard, not the shipped view: `countPillToggle` is
/// private, so moving the `.onChange` back inside would leave this suite green.
@MainActor
@Suite(.serialized) struct CountPillResetObservationTests {

    /// Stands in for the two `FileSyncManager` fields. `ObservableObject` with `@Published`, as
    /// `FileSyncManager` is: the observation mechanism is half of what is characterised here.
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
                TimelineView(ScanFreshnessSchedule(anchor: scanDate)) { _ in content("fresh") }
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
    /// `clearsScanDate` true is the retarget (both fields in one transaction); false leaves the
    /// freshness branch standing.
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

    /// Inside the branch, the retarget transaction is missed entirely. This pins SwiftUI behaviour,
    /// so it could fail because the framework improved; that would mean the hazard is gone.
    @Test func aHandlerInsideTheFreshnessBranchMissesTheRetargetTransaction() {
        #expect(observedResets(handlerInsideBranch: true, clearsScanDate: true) == [])
    }

    /// Outside, the same transaction is observed: the handler hangs off the branch switch, not
    /// either branch.
    @Test func aHandlerOutsideTheFreshnessBranchObservesTheRetargetTransaction() {
        #expect(observedResets(handlerInsideBranch: false, clearsScanDate: true) == [false])
    }

    /// The control: when `lastScanDate` survives, the branch survives and both placements observe
    /// the change, so the empty result above is the teardown. Every reset of `hasScanned` that
    /// keeps the scan date works either way, which is why the inside placement looks safe.
    @Test func bothPlacementsObserveAResetThatLeavesTheBranchStanding() {
        #expect(observedResets(handlerInsideBranch: true, clearsScanDate: false) == [false])
        #expect(observedResets(handlerInsideBranch: false, clearsScanDate: false) == [false])
    }
}
