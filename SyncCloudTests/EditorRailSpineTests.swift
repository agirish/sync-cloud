import Testing
@testable import SyncCloud

/// **The spine's second rung is gated on the workspace AND the bit.** The "Just the text" bit is
/// editor-only, but the spine is drawn by every workspace with a collapsible pane, and a stray
/// "Show the text files" rung in Organize would be the first thing anyone clicked.
///
/// The rungs are `ContentView.spineRungs`, a pure function, because `railSpine` reads three
/// property wrappers off a `ContentView` no unit test can construct. The drawn spine is the
/// walkthrough's job.
///
/// **Local-only** — app target, invisible to CI; run by hand and named in the commit body.
@Suite struct EditorRailSpineTests {

    @Test func everySpineHasTheSourcePaneRung() {
        for workspace in Workspace.allCases {
            for bit in [false, true] {
                #expect(ContentView.spineRungs(workspace: workspace, railHidden: bit).first == .sourcePane,
                        "\(workspace.title) with railHidden=\(bit) does not lead with the pane rung")
            }
        }
    }

    /// Browse, whatever the bit says: one rung. The bit can be left set from an Edit session and
    /// must not follow the user into another workspace's spine.
    @Test func otherWorkspacesNeverDrawTheTextFilesRung() {
        for workspace in Workspace.allCases where workspace != .editor {
            #expect(ContentView.spineRungs(workspace: workspace, railHidden: true) == [.sourcePane],
                    "\(workspace.title) draws the text-files rung")
        }
    }

    /// Edit with the bit clear: the rail is on screen, so there is nothing to bring back.
    @Test func editWithTheRailShowingDrawsOneRung() {
        #expect(ContentView.spineRungs(workspace: .editor, railHidden: false) == [.sourcePane])
    }

    /// Edit with the bit set: the way back, under the pane rung.
    @Test func justTheTextAddsTheTextFilesRungInEditAlone() {
        #expect(ContentView.spineRungs(workspace: .editor, railHidden: true) == [.sourcePane, .textFiles])
    }
}
