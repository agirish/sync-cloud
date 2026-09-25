import Testing
import Foundation
import Sync
import FileExplorer
@testable import SyncCloud

/// The app half of the Edit header's location (TE43): what it says, built from the pane's own
/// breadcrumb model, and what a press on it does to the left pane — driven against a real
/// `FileSyncManager`, the `DuplicateRevealCoordinatorTests` way.
@MainActor
@Suite struct EditorHeaderLocationTests {

    // MARK: What it says

    /// **The pane breadcrumb's words.** The source's display name first — never the root folder's
    /// last component — then the folders under the root, each with the combined path the pane's
    /// crumb for it navigates to.
    @Test func theLocationSpeaksThePaneBreadcrumbsVocabulary() throws {
        let location = try #require(EditorHeaderLocation.location(
            documentPath: "/Users/me/Cloud/Documents/Finance/Test.md",
            // A different folder in the pane: an open document is placed by its OWN folder.
            paneFolder: "/Users/me/Cloud/Photos", sourceRoot: "/Users/me/Cloud",
            providerName: "iCloud", paneIsOpen: false, links: [:]))
        #expect(location.segments == [
            .init(name: "iCloud", target: ""),
            .init(name: "Documents", target: "Documents"),
            .init(name: "Finance", target: "Documents/Finance"),
        ])
        #expect(location.help == "iCloud › Documents › Finance")
        #expect(location.style == .crumb)
    }

    /// The reading follows the pane: open → the folder's name, collapsed → the crumb.
    @Test func thePaneStateChoosesTheReading() throws {
        let open = try #require(EditorHeaderLocation.location(
            documentPath: "/r/A/f.md", paneFolder: "/r/A", sourceRoot: "/r", providerName: "Drive",
            paneIsOpen: true, links: [:]))
        let collapsed = try #require(EditorHeaderLocation.location(
            documentPath: "/r/A/f.md", paneFolder: "/r/A", sourceRoot: "/r", providerName: "Drive",
            paneIsOpen: false, links: [:]))
        #expect(open.style == .folderName)
        #expect(collapsed.style == .crumb)
    }

    /// **iCloud Drive's `Documents` is `~/Documents` on disk**, linked into the container. A file
    /// the pane lists under `iCloud › Documents` must be placed there — through the hand-off's own
    /// root test — not refused as outside the source.
    @Test func aLinkedFolderIsPlacedUnderTheLinkName() throws {
        let location = try #require(EditorHeaderLocation.location(
            documentPath: "/home/Documents/Finance/Test.md", paneFolder: "", sourceRoot: "/c",
            providerName: "iCloud",
            paneIsOpen: false, links: ["/c": ["Documents": "/home/Documents"]]))
        #expect(location.segments.map(\.name) == ["iCloud", "Documents", "Finance"])
        #expect(location.segments.last?.target == "Documents/Finance")
    }

    /// Outside the source: still named, never a door.
    @Test func aFolderOutsideTheSourceIsNamedWithoutADoor() throws {
        let location = try #require(EditorHeaderLocation.location(
            documentPath: "/Volumes/Backup/Scratch/n.txt", paneFolder: "", sourceRoot: "/Users/me/Cloud",
            providerName: "iCloud", paneIsOpen: true, links: [:]))
        #expect(location.segments == [.init(name: "Scratch", target: nil)])
        #expect(location.help == "/Volumes/Backup/Scratch")
    }

    /// No document and no folder: nothing to name — the empty page's header says nothing about a
    /// location, as the + beside it is greyed.
    @Test func noDocumentAndNoFolderNoLocation() {
        #expect(EditorHeaderLocation.location(documentPath: nil, paneFolder: "", sourceRoot: "/r",
                                              providerName: "x", paneIsOpen: true, links: [:]) == nil)
    }

    /// **No document: the pane's folder, where a new file would be made — its own level named, not
    /// a door.** The levels above it keep their doors, the same targets a document's crumb has; the
    /// folder's own word would only send the pane where it already is. Mutations: returning `nil`
    /// with no document fails the first `#require`; keeping the last level's target fails the
    /// `segments` line; dropping every target fails it too.
    @Test func noDocumentNamesThePanesFolderWithoutADoorOntoItself() throws {
        for paneIsOpen in [true, false] {
            let location = try #require(EditorHeaderLocation.location(
                documentPath: nil, paneFolder: "/Users/me/Cloud/Documents/Finance",
                sourceRoot: "/Users/me/Cloud", providerName: "iCloud", paneIsOpen: paneIsOpen,
                links: [:]), "the empty page names no folder (pane open: \(paneIsOpen))")
            #expect(location.segments == [
                .init(name: "iCloud", target: ""),
                .init(name: "Documents", target: "Documents"),
                .init(name: "Finance", target: nil),
            ])
            #expect(location.help == "iCloud › Documents › Finance")
            #expect(location.style == (paneIsOpen ? .folderName : .crumb))
        }
        // And what the header draws from it: "in Finance" is words, not a door, with the pane open.
        let open = try #require(EditorHeaderLocation.location(
            documentPath: nil, paneFolder: "/Users/me/Cloud/Documents/Finance",
            sourceRoot: "/Users/me/Cloud", providerName: "iCloud", paneIsOpen: true, links: [:]))
        #expect(open.segments.last?.name == "Finance")
        #expect(open.segments.last?.target == nil, "the empty page's folder name is a door onto the folder the pane already shows")
        // An empty string for the document is no document, not a file named "".
        let blank = EditorHeaderLocation.location(
            documentPath: "", paneFolder: "/Users/me/Cloud/Documents/Finance",
            sourceRoot: "/Users/me/Cloud", providerName: "iCloud", paneIsOpen: false, links: [:])
        #expect(blank?.segments.last?.target == nil)
    }

    // MARK: What a press does

    private static let finance = EditorDocumentLocation(
        segments: [.init(name: "iCloud", target: ""), .init(name: "Documents", target: "Documents"),
                   .init(name: "Finance", target: "Documents/Finance")],
        style: .folderName, help: "iCloud › Documents › Finance")

    /// **The folder name: the pane goes to the folder, and the file is selected there** — through
    /// the pane's own selection write, which the test stands in for.
    @Test func theFolderNameShowsTheFileInThePane() {
        let manager = FileSyncManager()
        var selected: [Set<String>] = []
        let doors = EditorLocationDoors(syncManager: manager, drawsColumns: true,
                                        selectInPane: { selected.append($0) })
        doors.open(.showInPane, documentPath: "/c/Documents/Finance/Test.md", location: Self.finance)
        #expect(manager.combinedRelativePath(isLeft: true) == "Documents/Finance")
        #expect(selected == [["/c/Documents/Finance/Test.md"]])
    }

    /// **A crumb re-points the pane and selects nothing** — in Columns a browse move inside the
    /// pane's scope, in Tree a re-root, exactly as the pane's own crumb for that level would.
    @Test func aCrumbMovesThePaneAndSelectsNothing() {
        let columns = FileSyncManager()
        var selected: [Set<String>] = []
        EditorLocationDoors(syncManager: columns, drawsColumns: true,
                            selectInPane: { selected.append($0) })
            .open(.goTo("Documents"), documentPath: "/c/Documents/Finance/Test.md", location: Self.finance)
        #expect(columns.combinedRelativePath(isLeft: true) == "Documents")
        #expect(columns.leftRelativePath == "", "a crumb inside the scope re-rooted the Columns pane")

        let tree = FileSyncManager()
        EditorLocationDoors(syncManager: tree, drawsColumns: false,
                            selectInPane: { selected.append($0) })
            .open(.goTo("Documents"), documentPath: "/c/Documents/Finance/Test.md", location: Self.finance)
        #expect(tree.leftRelativePath == "Documents")
        #expect(selected.isEmpty, "a crumb selected something")
    }

    /// A location with nowhere to go selects nothing and moves nothing.
    @Test func aFolderOutsideTheSourceOpensNoDoor() {
        let manager = FileSyncManager()
        var selected: [Set<String>] = []
        let outside = EditorDocumentLocation(segments: [.init(name: "Scratch", target: nil)],
                                             style: .folderName, help: "~/Scratch")
        EditorLocationDoors(syncManager: manager, drawsColumns: true, selectInPane: { selected.append($0) })
            .open(.showInPane, documentPath: "/x/Scratch/n.txt", location: outside)
        #expect(selected.isEmpty)
        #expect(manager.combinedRelativePath(isLeft: true) == "")
    }

    // MARK: The real wiring

    /// **The app's closures, pinned by scan** — the review lesson from TE27–TE30: a test that
    /// injects its own closure cannot see the real one replaced by `{ _ in }`. Pinned: the header
    /// is handed the live location and the doors; the doors get the pane's OWN selection binding
    /// and the mode the pane is drawn in; the reading is keyed on the pane's collapse bit. And the
    /// doors' body never reaches the pane's visibility or the document — a crumb must not expand
    /// the collapsed pane, and no door may settle or reload the file.
    @Test func theHeaderIsWiredToTheRealDoors() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        #expect(editor.contains("location: editorDocumentLocation,"),
                "the header is not handed the document's location")
        #expect(editor.contains("editorLocationDoors.open(door, documentPath: editorDocument.path,"),
                "the header's doors are not wired to EditorLocationDoors")
        #expect(editor.contains("location: editorDocumentLocation)"),
                "the doors are not handed the live location at press time")
        #expect(editor.contains("selectInPane: { paneSelectionBinding(isLeft: true).wrappedValue = $0 }"),
                "the folder door does not select through the pane's own selection write")
        #expect(editor.contains("drawsColumns: resolvedViewMode(isLeft: true) == .columns,"),
                "the doors do not ask the mode the pane is drawn in")
        #expect(editor.contains("paneIsOpen: !panesHiddenForCurrentTab)"),
                "the reading is not keyed on the pane's collapse bit")
        // The empty page names the folder a new file goes in — the SAME `editorFolder` the ＋, ⌘N,
        // the rail and the naming row all read, not a second idea of "the folder".
        // Sliced to the location's own builder: `paneFolder: editorFolder,` also appears in the
        // owed-selection call further down, which would satisfy a scan of the whole file.
        let builder = try #require(editor.range(of: "var editorDocumentLocation: EditorDocumentLocation? {"))
        let builderEnd = try #require(editor.range(of: "var editorLocationDoors", range: builder.upperBound..<editor.endIndex))
        #expect(editor[builder.upperBound..<builderEnd.lowerBound].contains("paneFolder: editorFolder,"),
                "the empty page's location is not the folder ⌘N creates in")

        let doors = try OpenInEditorMenuTests.macApp("EditorLocationDoors.swift")
        let start = try #require(doors.range(of: "struct EditorLocationDoors {"))
        // Comments stripped: the body's own comments explain why `openInEditor` is not reached,
        // and a scan that matched them would report the explanation as the call.
        let body = String(doors[start.upperBound...])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop { $0 == " " }.hasPrefix("//") }
            .joined(separator: "\n")
        for forbidden in ["togglePanes", "panesHidden", "loadIntoEditor", "openInEditor",
                          "settleEditorDocument", "selectedWorkspace"] {
            #expect(!body.contains(forbidden), "EditorLocationDoors reaches \(forbidden)")
        }
        #expect(body.contains("syncManager.navigatePane(isLeft: true, toCombinedPath: target,"),
                "a crumb no longer takes the pane breadcrumb's own route")
    }
}
