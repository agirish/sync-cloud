import Testing
import Foundation
@testable import FileExplorer

/// **The two view-side doors of TE77: the rail's fold button, and the empty page's Show Text Files.**
///
/// The fold rule itself — which bit, what the strip's buttons do — lives in the app target and is
/// pinned there (`EditorRailSpineTests`, `TopPaneVisibilityTests`, local-only). These are the halves
/// CI can see: that the doors are wired to what the host hands this package, and drawn where the
/// rule says. Read over code only, so a comment naming a call cannot satisfy a scan.
@Suite struct EditorRailFoldDoorsTests {

    /// The fold button sits on the line under the tabs, AFTER the files-only capsule closes, so it
    /// is drawn on both tabs at the same place; and only when the host passes the act.
    @Test func theFoldButtonIsDrawnOnBothTabsAndOnlyWhenHandedAnAct() throws {
        let rail = try ChromeGlassWiringTests.source("EditorFileRailView.swift")
        let filesOnly = try #require(rail.range(of: "if shownTab == .files {"), "the context row's files-only block moved")
        let fold = try #require(rail.range(of: "if let onFold {"), "the rail draws no fold button")
        #expect(filesOnly.upperBound < fold.lowerBound, "the fold button is drawn before the files-only block")
        let between = String(rail[filesOnly.upperBound..<fold.lowerBound])
        // The block opened just before `between` begins, so it has closed when `between` holds
        // more closing braces than opening ones.
        let opens = between.filter { $0 == "{" }.count, closes = between.filter { $0 == "}" }.count
        #expect(closes > opens, "the fold button is inside the files-only block — the Outline tab would draw none")
        #expect(rail.contains("Button(action: onFold) {"), "the fold button does not run the host's act")
        #expect(ChromeGlassWiringTests.count("if let onFold {", in: rail) == 1)
    }

    /// The workspace hands the rail its host's fold act, and the empty page its Show Text Files —
    /// withheld while no folder is chosen, when there is no list to show.
    @Test func theWorkspacePassesBothDoorsThrough() throws {
        let workspace = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("onFold: onFoldRail)"), "the rail is not handed the host's fold act")
        #expect(workspace.contains("showTextFiles: folder.isEmpty ? nil : onShowTextFiles)"),
                "the empty page's Show Text Files is not the host's act, or is offered with no folder")
        #expect(workspace.contains("Button(action: showTextFiles) {"), "the empty page's button does not run its act")
        #expect(EditorWorkspaceView.showTextFilesTitle == "Show Files")
    }
}
