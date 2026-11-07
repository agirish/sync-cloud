import Testing
@testable import FileExplorer

/// Why `DifferencesView.standardHeader`'s `.onChange(of: syncManager.hasScanned)` sits outside
/// `withScanFreshness`, not inside its closure.
///
/// `withScanFreshness` renders a `TimelineView` only while `lastScanDate` is non-nil.
/// `invalidateDifferencesForPaneRetarget()` clears `lastScanDate` and `hasScanned` in one
/// transaction, so a handler inside the closure is torn down by the change it watches and never
/// fires, leaving the pill expanded over a comparison that no longer exists (fixed in ec0382431).
///
/// A scan of the shipped call site, since the header is private and the hazard needs a retarget
/// transaction to show. Moving the handler inside the closure indents it four more spaces.
@Suite struct CountPillResetObservationTests {
    @Test func theResetHandlerSitsOutsideTheFreshnessClosure() throws {
        let header = try SourceText.body(
            of: "private func standardHeader(",
            in: try SourceText.fileExplorer("DifferencesView.swift"))
        try #require(header.contains("\n        withScanFreshness { dressing in"),
                     "standardHeader no longer opens withScanFreshness — the scan below proves nothing")
        #expect(header.contains("\n        .onChange(of: syncManager.hasScanned)"),
                "the hasScanned reset is not a sibling of withScanFreshness any more")
        #expect(!header.contains("\n            .onChange(of: syncManager.hasScanned)"),
                "the hasScanned reset moved inside the withScanFreshness closure")
    }
}
