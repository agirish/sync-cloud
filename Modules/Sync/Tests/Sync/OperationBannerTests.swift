import Testing
@testable import Sync

/// Pins OperationBanner's per-publish identity: two banners with identical user-visible
/// content must still compare unequal, so SwiftUI `onChange` observers (and the dismiss
/// timer behind them) register every publish — including "Deleted \"x\"" twice in a row.
struct OperationBannerTests {

    @Test func identicalContentIsStillADistinctPublish() {
        let first = OperationBanner.success("Deleted \"x\"")
        let second = OperationBanner.success("Deleted \"x\"")
        #expect(first.message == second.message)
        #expect(first.severity == second.severity)
        #expect(first != second)
        #expect(first.id != second.id)
    }

    @Test func equalityHoldsForTheSameValue() {
        let banner = OperationBanner.warning("Partially copied")
        let copy = banner
        #expect(banner == copy)
    }

    @Test func factoriesSetSeverity() {
        #expect(OperationBanner.success("s").severity == .success)
        #expect(OperationBanner.warning("w").severity == .warning)
        #expect(OperationBanner.error("e").severity == .error)
    }
}
