import Testing
@testable import SyncCloud

/// **In Edit, the open source pane is the file list, so one click opens** — and the five guards
/// that keep that from meaning anything else, one case each.
///
/// The rule is `ContentView.paneSelectionOpens`, a pure function, because the observer that calls
/// it hangs off `ContentView`'s body and cannot be driven from a unit test. What the observer
/// adds — that arrow keys move the same selection, and that the path goes to `openInEditor` rather
/// than the re-rooting hand-off — is stated on the function and checked by the walkthrough.
///
/// **Local-only.** `SyncCloudTests` is the app target and CI runs package tests alone; this suite
/// was run by hand and named in the commit body.
@Suite struct EditorPaneClickTests {

    private func opens(workspace: Workspace = .editor, paneHidden: Bool = false,
                       paths: Set<String> = ["/a/notes.md"], isDirectory: Bool? = false) -> String? {
        ContentView.paneSelectionOpens(workspace: workspace, paneHidden: paneHidden,
                                       paths: paths, isDirectory: isDirectory)
    }

    /// The one positive case, and the control for every negative one below: each of those changes
    /// exactly one input from this.
    @Test func aSingleTextFileInEditsOpenPaneOpens() {
        #expect(opens() == "/a/notes.md")
    }

    /// Browse's pane selects, as it always has. The same click in Edit is the positive case.
    @Test func browseIsNotEdit() {
        #expect(opens(workspace: .browse) == nil)
        #expect(opens(workspace: .filing) == nil)
        #expect(opens(workspace: .compare) == nil)
    }

    /// Collapsed, the rail is the list and the pane has no rows on screen to click — a selection
    /// change then is the manager's own doing, not the user's.
    @Test func aCollapsedPaneDoesNotOpen() {
        #expect(opens(paneHidden: true) == nil)
    }

    /// Two paths is a multi-selection for the pane's own verbs; it opens nothing and stays.
    @Test func aMultiSelectionDoesNotOpen() {
        #expect(opens(paths: ["/a/notes.md", "/a/other.md"]) == nil)
        #expect(opens(paths: []) == nil)
    }

    /// A folder leads out of the listing rather than into the editor. `nil` — the selection could
    /// not be resolved to a node — refuses too, rather than guessing.
    @Test func aFolderDoesNotOpen() {
        #expect(opens(isDirectory: true) == nil)
        #expect(opens(isDirectory: nil) == nil)
    }

    /// The kind gate is `EditableText.isText`, the same predicate the row menu and the preview
    /// column ask. A PDF row is dimmed in this pane, and a click on it opens nothing.
    @Test func aKindEditCannotOpenDoesNotOpen() {
        #expect(opens(paths: ["/a/report.pdf"]) == nil)
        #expect(opens(paths: ["/a/photo.jpg"]) == nil)
        // The control: the predicate is really being asked, not the extension's length or case.
        #expect(opens(paths: ["/a/README"]) != nil || opens(paths: ["/a/notes.txt"]) != nil)
    }
}
