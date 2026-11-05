import Testing
import SwiftUI
import Sync
import Design
@testable import Dashboard

/// The Info inspector's split between its picture and its details: where a drag lands, where it
/// snaps shut, and the share it starts at.
@Suite struct InspectorSplitTests {
    typealias Split = InspectorSplit<EmptyView, EmptyView>

    /// The preview takes most of the panel until dragged, not half and half, and the default is a
    /// share the split draws as it is, not one it snaps.
    @Test func testThePreviewStartsWithMostOfThePanel() {
        #expect(DetailsSidebar.defaultPreviewFraction > 0.5)
        #expect(Split.settled(DetailsSidebar.defaultPreviewFraction) == DetailsSidebar.defaultPreviewFraction)
    }

    /// Near either end a share snaps shut: the picture folds away at the top, the details at the
    /// bottom. In between it is drawn exactly as dragged.
    @Test func testASharesNearAnEndSnapShut() {
        #expect(Split.settled(Split.foldMargin / 2) == 0)
        #expect(Split.settled(1 - Split.foldMargin / 2) == 1)
        #expect(Split.settled(0.4) == 0.4)
        #expect(Split.settled(-0.3) == 0)
        #expect(Split.settled(1.7) == 1)
    }

    /// A drag moves the share by its translation over the room the two halves share, measured from
    /// where the drag began; down grows the picture.
    @Test func testADragMovesTheShareByItsTranslation() {
        #expect(abs(Split.dragged(anchor: 0.7, translation: -100, room: 500) - 0.5) < 1e-9)
        #expect(abs(Split.dragged(anchor: 0.5, translation: 50, room: 500) - 0.6) < 1e-9)
        #expect(Split.dragged(anchor: 0.3, translation: -200, room: 500) == 0,
                "a drag past the fold margin at the top did not fold the picture away")
        #expect(Split.dragged(anchor: 0.7, translation: 0, room: 0) == 0.7,
                "a split with no room moved — it has nothing to measure a drag against")
    }

    /// A VoiceOver step walks the open range, stops at the edge of each fold, and folds only on the
    /// step after that: never from within 5% of a margin in one go, and never straight back shut
    /// out of a fold.
    @Test func aVoiceOverStepStopsAtTheEdgeOfAFold() {
        let low = Split.foldMargin, high = 1 - Split.foldMargin
        #expect(abs(Split.stepped(0.86, grows: true) - high) < 1e-9, "a step from 0.86 folded the details away")
        #expect(Split.stepped(high, grows: true) == 1)
        #expect(abs(Split.stepped(0.14, grows: false) - low) < 1e-9, "a step from 0.14 folded the picture away")
        #expect(Split.stepped(low, grows: false) == 0)
        #expect(Split.stepped(0, grows: true) == low, "a step out of the fold snapped back shut")
        #expect(Split.stepped(1, grows: false) == high)
        #expect(abs(Split.stepped(0.5, grows: true) - 0.55) < 1e-9)
    }
}
