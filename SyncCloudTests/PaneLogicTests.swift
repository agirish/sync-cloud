import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

@Suite struct PaneLogicTests {

    // MARK: copyTargetName

    @Test func testCopyTargetIsTheOppositePane() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")
        // Selection in the left pane copies to the right provider, and vice versa.
        #expect(PaneLogic.copyTargetName(activePane: .left, paneNames: names) == "Dropbox")
        #expect(PaneLogic.copyTargetName(activePane: .right, paneNames: names) == "iCloud")
    }

    @Test func testCopyTargetIsNilWithoutSelection() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")
        #expect(PaneLogic.copyTargetName(activePane: nil, paneNames: names) == nil)
    }

    @Test func testCopyTargetDisambiguatesSameProviderPanes() {
        // Both panes on the same provider: the target must still say which side.
        let names = PaneProviderNames(leftName: "iCloud", rightName: "iCloud")
        #expect(PaneLogic.copyTargetName(activePane: .left, paneNames: names) == "iCloud (right)")
        #expect(PaneLogic.copyTargetName(activePane: .right, paneNames: names) == "iCloud (left)")
    }

    // MARK: activePane

    @Test func testActivePaneFollowsSelectionWithLeftPriority() {
        #expect(PaneLogic.activePane(leftSelection: [], rightSelection: []) == nil)
        #expect(PaneLogic.activePane(leftSelection: ["/l/a"], rightSelection: []) == .left)
        #expect(PaneLogic.activePane(leftSelection: [], rightSelection: ["/r/b"]) == .right)
        // Left wins when both panes have selections.
        #expect(PaneLogic.activePane(leftSelection: ["/l/a"], rightSelection: ["/r/b"]) == .left)
    }

    // MARK: primarySelectionPath

    @Test func testPrimarySelectionPathIsAlphabeticalNotHashOrder() {
        // A multi-item selection must always preview the same (alphabetically first) file.
        #expect(PaneLogic.primarySelectionPath(
            leftSelection: ["/l/b.txt", "/l/a.txt", "/l/c.txt"],
            rightSelection: []) == "/l/a.txt")
        #expect(PaneLogic.primarySelectionPath(
            leftSelection: [],
            rightSelection: ["/r/b.txt", "/r/a.txt"]) == "/r/a.txt")
    }

    @Test func testPrimarySelectionPathPrefersLeftPaneAndHandlesEmpty() {
        #expect(PaneLogic.primarySelectionPath(
            leftSelection: ["/l/z.txt"],
            rightSelection: ["/r/a.txt"]) == "/l/z.txt")
        #expect(PaneLogic.primarySelectionPath(leftSelection: [], rightSelection: []) == nil)
    }

    // MARK: fullPath

    @Test func testFullPathAppendsRelativePath() {
        #expect(PaneLogic.fullPath(root: "/docs", relativePath: "sub/dir") == "/docs/sub/dir")
    }

    @Test func testFullPathEmptyOrAbsoluteRelativeYieldsRoot() {
        // Empty relative path -> root.
        #expect(PaneLogic.fullPath(root: "/docs", relativePath: "") == "/docs")
        // An absolute "relative" path must not escape the pane root.
        #expect(PaneLogic.fullPath(root: "/docs", relativePath: "/etc") == "/docs")
    }

    @Test func testFullPathExpandsTildeInRoot() {
        let home = NSHomeDirectory()
        #expect(PaneLogic.fullPath(root: "~/Documents", relativePath: "x") == "\(home)/Documents/x")
    }

    // MARK: relativeIgnoreTargets

    @Test func testIgnoreTargetsStripBasePathAndLeadingSlash() {
        let targets = PaneLogic.relativeIgnoreTargets(
            nodeIds: ["/root/docs/a.txt", "/root/docs/sub/b.txt"],
            basePath: "/root/docs")
        #expect(targets == ["a.txt", "sub/b.txt"])
    }

    @Test func testIgnoreTargetsOutsideBasePassThrough() {
        let targets = PaneLogic.relativeIgnoreTargets(
            nodeIds: ["/elsewhere/c.txt"],
            basePath: "/root/docs")
        #expect(targets == ["/elsewhere/c.txt"])
    }

    // MARK: toggledIgnoredPaths

    @Test func testTogglingUnignoredTargetsIgnoresThem() {
        let updated = PaneLogic.toggledIgnoredPaths(targets: ["a", "b"], ignoredPaths: ["c"])
        #expect(updated == ["a", "b", "c"])
    }

    @Test func testTogglingFullyIgnoredTargetsUnignoresThem() {
        let updated = PaneLogic.toggledIgnoredPaths(targets: ["a", "b"], ignoredPaths: ["a", "b", "c"])
        #expect(updated == ["c"])
    }

    @Test func testMixedTargetsAreAllIgnoredNotToggledIndividually() {
        // "a" is already ignored, "b" is not -> the action ignores ALL (a stays ignored).
        let updated = PaneLogic.toggledIgnoredPaths(targets: ["a", "b"], ignoredPaths: ["a"])
        #expect(updated == ["a", "b"])
    }
}
