import AppKit
import SwiftUI
import Testing
@testable import SyncCloud

/// The menu-bar chords' window-side plumbing: the destination-pick suspension, and the ⌘/
/// window still showing the whole reference it exists to show.
@MainActor
@Suite struct ShortcutCommandsTests {

    /// A publisher with every value present, so the suspended case cannot pass vacuously.
    private func loadedPublisher(suspended: Bool) -> ShortcutValuePublisher {
        ShortcutValuePublisher(
            workspace: .constant(.compare),
            goBack: {}, goForward: {}, rescan: {}, newFolder: {},
            hiddenFiles: .constant(false),
            previewColumn: .constant(true),
            inspector: .constant(false),
            differencesList: .constant(true),
            delete: {},
            switchPaneFocus: PaneFocusSwitch(targetName: "Dropbox", run: {}),
            suspended: suspended
        )
    }

    /// While the destination picker is up its overlay blocks the mouse from every control these
    /// chords mirror; the keyboard must not tunnel under it. One flag silences all eleven.
    @Test func suspensionSilencesEveryPublishedValue() {
        let publisher = loadedPublisher(suspended: true)
        #expect(publisher.effectiveWorkspace == nil)
        #expect(publisher.effectiveGoBack == nil)
        #expect(publisher.effectiveGoForward == nil)
        #expect(publisher.effectiveRescan == nil)
        #expect(publisher.effectiveNewFolder == nil)
        #expect(publisher.effectiveHiddenFiles == nil)
        #expect(publisher.effectivePreviewColumn == nil)
        #expect(publisher.effectiveInspector == nil)
        #expect(publisher.effectiveDifferencesList == nil)
        #expect(publisher.effectiveDelete == nil)
        #expect(publisher.effectiveSwitchPaneFocus == nil)
    }

    /// ...and the guard the test above depends on: unsuspended, the same loaded publisher passes
    /// every value through — proving the nils really came from `suspended`, not from a fixture
    /// that never carried values to silence.
    @Test func anUnsuspendedPublisherPassesEveryValueThrough() {
        let publisher = loadedPublisher(suspended: false)
        #expect(publisher.effectiveWorkspace != nil)
        #expect(publisher.effectiveGoBack != nil)
        #expect(publisher.effectiveGoForward != nil)
        #expect(publisher.effectiveRescan != nil)
        #expect(publisher.effectiveNewFolder != nil)
        #expect(publisher.effectiveHiddenFiles != nil)
        #expect(publisher.effectivePreviewColumn != nil)
        #expect(publisher.effectiveInspector != nil)
        #expect(publisher.effectiveDifferencesList != nil)
        #expect(publisher.effectiveDelete != nil)
        #expect(publisher.effectiveSwitchPaneFocus != nil)
    }

    /// The ⌘/ window is `.contentSize`-resizable — the user cannot enlarge it — so the whole
    /// reference must fit its fixed frame at the default text size. It stopped fitting when the
    /// twelve menu-bar chords nearly doubled the row count, and nothing failed: the ScrollView
    /// swallowed the overflow. Measured on the laid-out content, at the window's width, against
    /// the window's height; the floor guards against a render that measured nothing.
    @Test func theReferenceFitsItsWindowWithoutScrolling() {
        let host = NSHostingView(rootView:
            ShortcutsReferenceContent().frame(width: ShortcutsReferenceView.windowSize.width))
        let height = host.fittingSize.height
        #expect(height > 400, "the reference measured implausibly small — the fixture is broken")
        #expect(height <= ShortcutsReferenceView.windowSize.height,
                "the reference needs \(height)pt but the window shows \(ShortcutsReferenceView.windowSize.height)pt — raise windowSize or trim rows")
    }
}
