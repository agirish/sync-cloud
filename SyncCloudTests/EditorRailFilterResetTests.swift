import Testing
import Foundation
@testable import SyncCloud

/// **A new folder starts unfiltered** (TE109). The filter and its field are held on `ContentView`
/// so a trip to Browse and back keeps them, and nothing ever cleared them — so a filter typed in one
/// folder stayed on in the next, which then looked empty ("No files here match…").
///
/// The rule is `ContentView.railFilterClears`, pure; its call site is scanned, because the view that
/// calls it cannot be built in a unit test.
///
/// **Local-only** — app target, invisible to CI; run by hand and named in the commit body.
@Suite struct EditorRailFilterResetTests {

    /// Another folder clears; the same folder — the trip to Browse and back — keeps. Mutation:
    /// answer `false` always and the first line fails; `true` always and the second does.
    @Test func onlyAnotherFolderClearsTheFilter() {
        #expect(ContentView.railFilterClears(listedFolder: "/c/Notes", folder: "/c/Travel"))
        #expect(!ContentView.railFilterClears(listedFolder: "/c/Notes", folder: "/c/Notes"),
                "a trip to another workspace and back lost the filter")
        #expect(ContentView.railFilterClears(listedFolder: nil, folder: "/c/Notes"),
                "the first folder listed kept whatever was in the filter")
    }

    /// The rule runs when Edit's folder changes and when Edit appears — a folder changed from
    /// another workspace, where the rail did not exist — and it clears both the words and the
    /// field, then remembers the folder.
    @Test func theRailNotesItsFolderOnArrivalAndOnEveryChange() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        let builder = CodeText(try declarationBody(
            of: "func editorWorkspace(showsRail: Bool, railWidth: CGFloat = EditorLayoutMetrics.railWidth) -> some View {",
            in: editor))
        #expect(builder.contains(".onChange(of: editorFolder, initial: true) { _, folder in noteEditorRailFolder(folder) }"),
                "the rail's folder is not noted on arrival and on every change")
        let note = CodeText(try declarationBody(of: "func noteEditorRailFolder(_ folder: String) {", in: editor))
        #expect(note.contains("if Self.railFilterClears(listedFolder: editorRailListedFolder, folder: folder) {"))
        #expect(note.contains("editorRailFilter = \"\"") && note.contains("editorRailFilterIsExpanded = false"),
                "a new folder keeps the filter's words or its field")
        #expect(note.contains("editorRailListedFolder = folder"), "the folder listed is never remembered")
    }
}
