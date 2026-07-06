import Testing
import Foundation
@testable import SyncCloud

@Suite struct PaneLogicTests {

    // MARK: activePane

    @Test func testActivePaneFollowsSelectionWithLeftPriority() {
        #expect(PaneLogic.activePane(leftSelection: [], rightSelection: []) == nil)
        #expect(PaneLogic.activePane(leftSelection: ["/l/a"], rightSelection: []) == .left)
        #expect(PaneLogic.activePane(leftSelection: [], rightSelection: ["/r/b"]) == .right)
        // Left wins when both panes have selections.
        #expect(PaneLogic.activePane(leftSelection: ["/l/a"], rightSelection: ["/r/b"]) == .left)
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
