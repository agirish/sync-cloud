import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// `PaneActionDelegate`'s half of the tab verbs — the answers the pane's own background menu asks
/// it for, none of which had a test.
///
/// `PaneTabWiringTests.thePaneBackgroundMenuOffersANewTab` asserts the menu *consults*
/// `canCloseTab`; it says nothing about what the delegate answers. A delegate that answered `true`
/// everywhere passed the whole suite — and then the background menu offers "Close Tab" on a pane
/// with one tab, where the verb closes the WINDOW. That is the trap the property exists to prevent,
/// asserted here in both directions because a net over one state proves nothing about the other.
@MainActor
@Suite struct PaneTabDelegateTests {

    private func delegate(syncManager: FileSyncManager, isLeft: Bool = true,
                          onOpenInNewTab: @escaping (FileNode) -> Void = { _ in }) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: syncManager, settings: SettingsManager(), isLeft: isLeft,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in },
            ignoreStateToken: [], keptNamesToken: [],
            homeBadgeCoverage: nil, onFindDuplicatesOf: { _ in },
            onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in },
            onOpenInNewTab: onOpenInNewTab, onNewTabHere: { _ in }, onCloseTab: { })
    }

    private func tab(_ path: String) -> PaneTab {
        PaneTab(providerId: "iCloud", relativePath: path)
    }

    /// At one tab the answer is no; past a second it is yes.
    @Test func closeTabIsOfferedOnlyPastASecondTab() {
        let manager = FileSyncManager()
        let d = delegate(syncManager: manager)
        #expect(!d.canCloseTab,
                "the background menu offers Close Tab on a lone tab, where the verb closes the window")

        manager.openTab(tab("Second"), isLeft: true, currentProviderId: "iCloud")
        #expect(d.canCloseTab, "Close Tab is withheld even though the pane has two tabs")
    }

    /// The DOWNWARD direction — two tabs back to one, on the delegate built when there were two.
    ///
    /// **Its subject is not isolated, and the doc used to claim it was.** `canCloseTab` is a
    /// computed property over a class reference, so it is live by construction, and the test above
    /// already re-reads the same instance after the strip grows — a value snapshotted at
    /// construction fails that one too. What is only here is closing back down to one tab, which is
    /// the state where the wrong answer closes the window.
    @Test func theAnswerFollowsTheStripRatherThanTheRenderItWasBuiltIn() {
        let manager = FileSyncManager()
        let d = delegate(syncManager: manager)
        manager.openTab(tab("Second"), isLeft: true, currentProviderId: "iCloud")
        #expect(d.canCloseTab)

        // …and back down again, on the same delegate instance.
        let remaining = manager.leftPaneTabs.active.id
        manager.closeTab(id: remaining, isLeft: true, currentProviderId: "iCloud")
        #expect(!d.canCloseTab,
                "the delegate captured the count at build time — the menu goes stale on the render it opens in")
    }

    /// The pane it was built for, not always the left one.
    @Test func eachPaneAnswersForItsOwnStrip() {
        let manager = FileSyncManager()
        let left = delegate(syncManager: manager, isLeft: true)
        let right = delegate(syncManager: manager, isLeft: false)
        manager.openTab(tab("Second"), isLeft: true, currentProviderId: "iCloud")

        #expect(left.canCloseTab)
        #expect(!right.canCloseTab,
                "the right pane's delegate answers from the left pane's strip")
    }

    /// Open in New Tab is for folders. Asserted at the delegate as well as at the menu, because the
    /// guarantee is supposed to travel with the handler rather than with its one respectful caller
    /// — and nothing tested that it does.
    @Test func openInNewTabRefusesAFile() {
        var opened: [String] = []
        let d = delegate(syncManager: FileSyncManager(), onOpenInNewTab: { opened.append($0.id) })

        d.handleOpenInNewTab(FileNode(id: "/r/Notes.txt", name: "Notes.txt", isDirectory: false))
        #expect(opened.isEmpty, "a file was opened as a tab — a tab is a location")

        // The control: the same call with a folder does reach the host, so the check above is not
        // passing because the callback was never wired.
        d.handleOpenInNewTab(FileNode(id: "/r/Photos", name: "Photos", isDirectory: true))
        #expect(opened == ["/r/Photos"], "a folder no longer reaches the host's opener")
    }
}
