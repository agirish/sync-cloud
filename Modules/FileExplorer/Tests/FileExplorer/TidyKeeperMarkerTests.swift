import Testing
@testable import FileExplorer

/// Pins the pure marker mapping behind the Tidy card's keeper column: only rows the user can
/// actually pick draw a radio; groups without a keeper choice get a plain dot instead.
@Suite struct TidyKeeperMarkerTests {
    @Test func keeperShowsFilledRadioRegardlessOfChoice() {
        #expect(TidyKeeperMarker.style(allowsKeeperChoice: true, isKeeper: true) == .keeper)
        #expect(TidyKeeperMarker.style(allowsKeeperChoice: false, isKeeper: true) == .keeper)
    }

    @Test func nonKeeperIsSelectableOnlyWhenGroupAllowsChoice() {
        #expect(TidyKeeperMarker.style(allowsKeeperChoice: true, isKeeper: false) == .selectable)
        #expect(TidyKeeperMarker.style(allowsKeeperChoice: false, isKeeper: false) == .inert)
    }

    @Test func accessibilityLabelsReadSensibly() {
        #expect(TidyKeeperMarker.keeper.accessibilityLabel == "Kept copy")
        #expect(TidyKeeperMarker.selectable.accessibilityLabel == "Keep this copy")
        #expect(TidyKeeperMarker.inert.accessibilityLabel == nil)
    }
}
