import Foundation
import Testing
@testable import Sync
@testable import FileExplorer

/// **Compare's count pill says "scanning…" only once the scan is shown as running.**
///
/// The pill read `isScanning`, and most rescans finish in a few hundred milliseconds, so it flashed
/// "scanning…" over the count and straight back. `ScanShownTests` holds when `isScanShown` rises;
/// this holds that the pill reads it — the call-site half, without which the rule could be right
/// and unused.
@MainActor
@Suite struct CompareScanShownPillTests {

    private func dressing(isScanning: Bool, isScanShown: Bool) -> DifferencesView.CountPillDressing {
        let manager = FileSyncManager()
        // A previous scan exists, so the pill has an age to show when it is not scanning.
        manager.lastScanDate = Date()
        manager.isScanning = isScanning
        manager.isScanShown = isScanShown
        return DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore())
            .countPillDressing(at: Date())
    }

    /// The flash itself: a scan inside its wait keeps the previous scan's age on the pill.
    @Test func aScanNotYetShownLeavesThePillOnTheLastScan() {
        let pill = dressing(isScanning: true, isScanShown: false)
        #expect(pill.detail != "scanning…", "the pill flashed scanning… for a scan still inside its wait")
        #expect(pill.spokenDetail != "scanning for changes")
    }

    /// And a scan past its wait does say so, in words and to VoiceOver.
    @Test func aShownScanSaysScanning() {
        let pill = dressing(isScanning: true, isScanShown: true)
        #expect(pill.detail == "scanning…")
        #expect(pill.spokenDetail == "scanning for changes")
    }
}
