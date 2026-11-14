import Testing
@testable import SyncCloud

/// In Edit the open source pane is the file list, so one click opens, and the guards that keep it
/// from meaning anything else, one case each. `ContentView.paneSelectionOpens` is pure because its
/// observer hangs off `ContentView`'s body and can't be driven from a test.
@Suite struct EditorPaneClickTests {
    private func opens(workspace: Workspace = .editor, paneHidden: Bool = false,
                       paths: Set<String> = ["/a/notes.md"], isDirectory: Bool? = false) -> String? {
        ContentView.paneSelectionOpens(workspace: workspace, paneHidden: paneHidden,
                                       paths: paths, isDirectory: isDirectory)
    }

    /// The one positive case, and the control for every negative one below: each changes exactly
    /// one input from this.
    @Test func aSingleTextFileInEditsOpenPaneOpens() {
        #expect(opens() == "/a/notes.md")
        // The kind gate's control: the predicate is really being asked, not the extension's length
        // or case.
        #expect(opens(paths: ["/a/README"]) != nil || opens(paths: ["/a/notes.txt"]) != nil)
    }

    /// `(reason, workspace, paneHidden, paths, isDirectory)`: one input changed from the positive
    /// case, and the click opens nothing.
    @Test(arguments: [
        // Browse's pane selects; the same click in Edit is the positive case.
        ("Browse is not Edit", .browse, false, ["/a/notes.md"], false),
        ("Organize is not Edit", .filing, false, ["/a/notes.md"], false),
        ("Compare is not Edit", .compare, false, ["/a/notes.md"], false),
        // Collapsed, the rail is the list and the pane has no rows on screen, so a selection
        // change is the manager's doing, not the user's.
        ("a collapsed pane", .editor, true, ["/a/notes.md"], false),
        // Two paths is a multi-selection for the pane's own verbs; it opens nothing and stays.
        ("a multi-selection", .editor, false, ["/a/notes.md", "/a/other.md"], false),
        ("no selection", .editor, false, [], false),
        // A folder leads out of the listing, not into the editor. `nil` (the selection didn't
        // resolve to a node) refuses too, rather than guessing.
        ("a folder", .editor, false, ["/a/notes.md"], true),
        ("an unresolved node", .editor, false, ["/a/notes.md"], nil),
        // The kind gate is `EditableText.opensInEdit`, the same predicate the row menu and the
        // preview column ask. A JPEG row is dimmed in this pane, and a click on it opens nothing.
        ("a JPEG", .editor, false, ["/a/photo.jpg"], false),
        ("a zip", .editor, false, ["/a/archive.zip"], false),
    ] as [(String, Workspace, Bool, Set<String>, Bool?)])
    func aClickThatIsNotAnEditOpenOpensNothing(reason: String, workspace: Workspace, paneHidden: Bool,
                                               paths: Set<String>, isDirectory: Bool?) {
        #expect(opens(workspace: workspace, paneHidden: paneHidden, paths: paths, isDirectory: isDirectory) == nil,
                "\(reason) opened a file")
    }

    /// A PDF opens, read-only, into Edit's PDF model.
    @Test func aPDFOpens() {
        #expect(opens(paths: ["/a/report.pdf"]) == "/a/report.pdf")
        #expect(opens(paths: ["/a/REPORT.PDF"]) == "/a/REPORT.PDF")
    }
}
