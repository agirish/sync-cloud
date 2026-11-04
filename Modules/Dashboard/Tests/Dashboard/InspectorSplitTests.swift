import Testing
import SwiftUI
import Sync
import Design
@testable import Dashboard

/// The Info inspector's split between its picture and its details (TE318 B): where a drag lands,
/// where it snaps shut, and the share it starts at.
@Suite struct InspectorSplitTests {
    typealias Split = InspectorSplit<EmptyView, EmptyView>

    /// The preview takes most of the panel until it is dragged — he asked for it not to be half and
    /// half — and the default is a share the split draws as it is, not one it snaps.
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

    /// The pane bar's Preview button is not offered where the host says so, as in the app, where
    /// the preview is the window's Info inspector; offered by default, so every other header is the
    /// bar it was.
    @MainActor
    @Test func testAHeaderThatOffersNoPreviewHasNoPreviewButton() {
        func header(offersPreview: Bool) -> PaneHeader {
            PaneHeader(
                title: "Left",
                provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                        rootPath: "/Users/test/iCloud", type: .iCloud),
                rootPath: "/Users/test/iCloud", relativePath: "Documents",
                canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
                onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
                onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
                viewMode: .constant(.columns), offersPreview: offersPreview)
        }
        #expect(header(offersPreview: true).availableItems.contains(.preview))
        #expect(!header(offersPreview: false).availableItems.contains(.preview))
    }
}
