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

/// Pins the wording gate for the card's unverified-content caveat: it appears only when a group
/// really contains copies whose hash was skipped (too large / cloud-only / unreadable), pluralizes
/// correctly, and never fires for a fully verified group.
@Suite struct TidyUnverifiedNoteTests {
    @Test func noNoteWhenEveryCopyIsVerified() {
        #expect(TidyUnverifiedNote.text(unverifiedCount: 0) == nil)
    }

    @Test func singularAndPluralWording() {
        let one = TidyUnverifiedNote.text(unverifiedCount: 1)
        #expect(one?.hasPrefix("1 copy couldn't be content-verified") == true)
        let three = TidyUnverifiedNote.text(unverifiedCount: 3)
        #expect(three?.hasPrefix("3 copies couldn't be content-verified") == true)
    }
}

/// Pins the cursor-stack bookkeeping behind the selectable radio's hover effect: NSCursor's
/// stack is global, so a push must happen exactly once per hovered state and a pop only for a
/// push we made — even when SwiftUI repeats an onHover callback without a state change.
@Suite struct HoverCursorTransitionTests {
    @Test func pushesOnlyOnEnterTransition() {
        #expect(HoverCursorTransition.decide(wasHovering: false, isNowInside: true) == .push)
        // Repeated onHover(true) without an intervening false must not double-push.
        #expect(HoverCursorTransition.decide(wasHovering: true, isNowInside: true) == .none)
    }

    @Test func popsOnlyOnExitTransition() {
        #expect(HoverCursorTransition.decide(wasHovering: true, isNowInside: false) == .pop)
        // Repeated onHover(false) must not pop a cursor someone else pushed.
        #expect(HoverCursorTransition.decide(wasHovering: false, isNowInside: false) == .none)
    }
}
