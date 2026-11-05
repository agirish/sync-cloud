import Testing
import Foundation
@testable import SyncCloud

/// A new folder starts unfiltered. The filter and its field live on `ContentView` so a trip to
/// Browse and back keeps them; without a reset, a filter typed in one folder would stay on in the
/// next, which would look empty ("No files here match…"). The rule is
/// `ContentView.railFilterClears`, pure; its call site is scanned, because the view that calls it
/// can't be built in a unit test.
@Suite struct EditorRailFilterResetTests {

    /// Another folder clears; the same folder (the trip to Browse and back) keeps. Answering a
    /// constant `false` or `true` must fail it.
    @Test func onlyAnotherFolderClearsTheFilter() {
        #expect(ContentView.railFilterClears(listedFolder: "/c/Notes", folder: "/c/Travel"))
        #expect(!ContentView.railFilterClears(listedFolder: "/c/Notes", folder: "/c/Notes"),
                "a trip to another workspace and back lost the filter")
        #expect(ContentView.railFilterClears(listedFolder: nil, folder: "/c/Notes"),
                "the first folder listed kept whatever was in the filter")
    }

    /// The rule runs when Edit's folder changes and when Edit appears (for a folder changed from
    /// another workspace, where the rail didn't exist). It clears the words and the field, then
    /// remembers the folder.
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
