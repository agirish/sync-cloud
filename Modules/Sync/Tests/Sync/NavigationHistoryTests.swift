import Testing
import Foundation
import Combine
@testable import Sync

@Suite struct NavigationHistoryTests {

    @MainActor
    @Test func testBackForwardHistory() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let root = "/src"
        try mockFM.createDirectory(at: URL(fileURLWithPath: root), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "\(root)/folder1"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "\(root)/folder1/sub"), withIntermediateDirectories: true)

        // 1. Initial State
        #expect(manager.leftRelativePath == "")
        #expect(!manager.leftHistory.canGoBack)
        #expect(!manager.leftHistory.canGoForward)

        // 2. Navigate to folder1
        manager.focusOn(relativePath: "folder1", isLeft: true)
        #expect(manager.leftRelativePath == "folder1")
        #expect(manager.leftHistory.canGoBack)
        #expect(!manager.leftHistory.canGoForward)

        // 3. Navigate to sub
        manager.focusOn(relativePath: "folder1/sub", isLeft: true)
        #expect(manager.leftRelativePath == "folder1/sub")
        #expect(manager.leftHistory.index == 2)

        // 4. Go Back
        manager.goBack(isLeft: true, drawsColumns: true)
        #expect(manager.leftRelativePath == "folder1")
        #expect(manager.leftHistory.canGoBack)
        #expect(manager.leftHistory.canGoForward)

        // 5. Go Back to Root
        manager.goBack(isLeft: true, drawsColumns: true)
        #expect(manager.leftRelativePath == "")
        #expect(!manager.leftHistory.canGoBack)
        #expect(manager.leftHistory.canGoForward)

        // 6. Go Forward
        manager.goForward(isLeft: true, drawsColumns: true)
        #expect(manager.leftRelativePath == "folder1")
        #expect(manager.leftHistory.canGoBack)
        #expect(manager.leftHistory.canGoForward)
    }

    @MainActor
    @Test func testHistoryTrimming() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        manager.focusOn(relativePath: "a", isLeft: true)
        manager.focusOn(relativePath: "a/b", isLeft: true)

        #expect(manager.leftHistory.entries.count == 3) // Root, a, a/b

        manager.goBack(isLeft: true, drawsColumns: true) // Now at "a"
        #expect(manager.leftRelativePath == "a")

        // Navigate to new path "c"
        manager.focusOn(relativePath: "c", isLeft: true)

        // Forward history "a/b" should be trimmed
        #expect(manager.leftHistory.entries.count == 3)
        #expect(manager.leftHistory.entries.last == "c")
        #expect(!manager.leftHistory.canGoForward)
    }

    @MainActor
    @Test func testHistoriesAreIndependentPerPane() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        // Navigating the left pane leaves the right pane's path AND history untouched.
        manager.focusOn(relativePath: "common", isLeft: true)

        #expect(manager.leftRelativePath == "common")
        #expect(manager.rightRelativePath == "")
        #expect(!manager.rightHistory.canGoBack)

        // Back in the right pane is a no-op; back in the left pane undoes only the left move.
        manager.goBack(isLeft: false, drawsColumns: true)
        #expect(manager.leftRelativePath == "common")
        manager.goBack(isLeft: true, drawsColumns: true)
        #expect(manager.leftRelativePath == "")
        #expect(manager.rightRelativePath == "")
    }

    @MainActor
    @Test func testFocusOnRightPaneWithUnknownPathNavigatesClearsIgnoredAndFiresRefresh() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "somewhere", isLeft: true)
        manager.ignoredPaths = ["noise.txt"]

        var refreshCount = 0
        let subscription = manager.refreshSubject.sink { _ in refreshCount += 1 }
        defer { subscription.cancel() }

        // The focused path exists on no disk: focusOn does not validate it, it just re-focuses
        // the one pane, resets the per-folder ignore list, appends to that pane's history, and
        // fires the refresh subject (which is what triggers the follow-up tree load and scan).
        manager.focusOn(relativePath: "does/not/exist", isLeft: false)

        #expect(manager.rightRelativePath == "does/not/exist")
        #expect(manager.leftRelativePath == "somewhere") // the other pane is untouched
        #expect(manager.ignoredPaths.isEmpty)
        #expect(refreshCount == 1)
        #expect(manager.rightHistory.entries.count == 2)
        #expect(manager.rightHistory.canGoBack)
        #expect(!manager.rightHistory.canGoForward)
    }

    @MainActor
    @Test func testAncestorFocusAppendsToHistoryLikeAnyFocus() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        manager.focusOn(relativePath: "docs", isLeft: true)
        manager.focusOn(relativePath: "docs/projects/app", isLeft: true)

        // Breadcrumb jump to an ancestor is a plain focus: it appends a new history
        // entry rather than rewinding, so Back returns to the deeper folder.
        manager.focusOn(relativePath: "docs/projects", isLeft: true)

        #expect(manager.leftRelativePath == "docs/projects")
        #expect(manager.leftHistory.entries.count == 4)
        #expect(manager.leftHistory.canGoBack)
        #expect(!manager.leftHistory.canGoForward)

        manager.goBack(isLeft: true, drawsColumns: true)
        #expect(manager.leftRelativePath == "docs/projects/app")
        manager.goForward(isLeft: true, drawsColumns: true)
        #expect(manager.leftRelativePath == "docs/projects")
    }

    @MainActor
    @Test func testFocusBothMovesBothPanesWithOneEntryPerPane() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "docs/a", isLeft: true)
        manager.focusOn(relativePath: "docs/b", isLeft: false)
        manager.ignoredPaths = ["noise.txt"]

        var refreshCount = 0
        let subscription = manager.refreshSubject.sink { _ in refreshCount += 1 }
        defer { subscription.cancel() }

        // ⌥-click on a breadcrumb: both panes converge on the same relative path,
        // one new entry in each pane's own history.
        manager.focusBoth(relativePath: "docs")

        #expect(manager.leftRelativePath == "docs")
        #expect(manager.rightRelativePath == "docs")
        #expect(manager.ignoredPaths.isEmpty)
        #expect(refreshCount == 1)
        #expect(manager.leftHistory.entries == ["", "docs/a", "docs"])
        #expect(manager.rightHistory.entries == ["", "docs/b", "docs"])

        // Back in each pane independently undoes that pane's part of the jump.
        manager.goBack(isLeft: true, drawsColumns: true)
        #expect(manager.leftRelativePath == "docs/a")
        #expect(manager.rightRelativePath == "docs")
        manager.goBack(isLeft: false, drawsColumns: true)
        #expect(manager.rightRelativePath == "docs/b")
    }

    @MainActor
    @Test func testFocusBothSkipsPanesAlreadyAtTarget() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "shared", isLeft: true)

        // Left is already at "shared": only the right pane gets a history entry.
        manager.focusBoth(relativePath: "shared")
        #expect(manager.leftHistory.entries == ["", "shared"])
        #expect(manager.rightHistory.entries == ["", "shared"])

        var refreshCount = 0
        let subscription = manager.refreshSubject.sink { _ in refreshCount += 1 }
        defer { subscription.cancel() }

        // Both already there: complete no-op.
        manager.focusBoth(relativePath: "shared")
        #expect(manager.leftHistory.entries.count == 2)
        #expect(manager.rightHistory.entries.count == 2)
        #expect(refreshCount == 0)
    }

    @MainActor
    @Test func testFocusBothTrimsForwardHistory() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "a", isLeft: true)
        manager.focusOn(relativePath: "a/b", isLeft: true)
        manager.goBack(isLeft: true, drawsColumns: true)

        manager.focusBoth(relativePath: "c")

        #expect(manager.leftHistory.entries == ["", "a", "c"])
        #expect(manager.rightHistory.entries == ["", "c"])
        #expect(!manager.leftHistory.canGoForward)
    }

    /// A source switch replaces the history of the pane it switched, and **only** that pane's.
    ///
    /// The switched pane's Back stack points into a tree that is being taken off screen, so it has
    /// to go. The sibling's points into a tree that is still there — this used to clear it anyway,
    /// so picking a source on one pane silently emptied the other pane's Back button.
    @MainActor
    @Test func testRetargetPaneClearsOnlyItsOwnHistory() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "a", isLeft: true)
        manager.focusOn(relativePath: "b", isLeft: false)

        manager.retargetPane(isLeft: true, landing: "")

        #expect(manager.leftRelativePath == "")
        #expect(manager.leftHistory == PaneNavigationHistory())
        #expect(!manager.leftHistory.canGoBack)

        #expect(manager.rightRelativePath == "b", "the untouched pane was re-homed by the other pane's switch")
        #expect(manager.rightHistory.entries == ["", "b"])
        #expect(manager.rightHistory.canGoBack, "the untouched pane lost the Back stack it had earned")
    }

    /// The mirror. Polarity in this method is four separate `isLeft` branches — history, selection,
    /// browse path, reload scope — and a test on one side cannot see a flip in any of them.
    @MainActor
    @Test func testRetargetPaneClearsOnlyItsOwnHistoryOnTheRight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "a", isLeft: true)
        manager.focusOn(relativePath: "b", isLeft: false)

        manager.retargetPane(isLeft: false, landing: "")

        #expect(manager.rightRelativePath == "")
        #expect(manager.rightHistory == PaneNavigationHistory())
        #expect(!manager.rightHistory.canGoBack)

        #expect(manager.leftRelativePath == "a", "the untouched pane was re-homed by the other pane's switch")
        #expect(manager.leftHistory.entries == ["", "a"])
        #expect(manager.leftHistory.canGoBack, "the untouched pane lost the Back stack it had earned")
    }

    /// **The selection, both ways round.** The app-target test covers the left switch; this is the
    /// half that would have gone unmeasured, and the fixture deliberately puts a selection in BOTH
    /// panes — a state the one-pane-selected invariant forbids, and the only fixture that can tell
    /// "cleared the pane that switched" from "cleared whichever pane it reached first".
    @MainActor
    @Test func testRetargetPaneClearsOnlyItsOwnSelection() async throws {
        for switchedIsLeft in [true, false] {
            let manager = FileSyncManager(fileManager: MockFileManager())
            manager.selectedLeftPaths = ["/l/a.txt"]
            manager.selectedRightPaths = ["/r/b.txt"]

            manager.retargetPane(isLeft: switchedIsLeft, landing: "")

            let cleared = switchedIsLeft ? manager.selectedLeftPaths : manager.selectedRightPaths
            let kept = switchedIsLeft ? manager.selectedRightPaths : manager.selectedLeftPaths
            #expect(cleared.isEmpty, "isLeft: \(switchedIsLeft) — the switched pane kept a selection under a root it no longer shows")
            #expect(kept.count == 1, "isLeft: \(switchedIsLeft) — a switch on one pane cleared the other pane's selection")
        }
    }
}
