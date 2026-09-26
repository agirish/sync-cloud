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

    /// **A folder under another of the user's sources is placed there, in words** — the Dropbox
    /// copy opened from the differences list, which stays in the right pane while the left shows
    /// iCloud. It used to read "in Backup", which says nothing about which cloud. Now the source's
    /// name leads, in both readings, and no level is a door. Mutation: drop the `otherSources` try
    /// and it reads "in Backup" again.
    @Test func aFolderUnderAnotherSourceNamesThatSource() throws {
        let others: [(name: String, root: String)] = [
            (name: "Dropbox", root: "/Users/me/Dropbox"),
            (name: "Work", root: "/Users/me/Dropbox/Clients/Work"),
        ]
        let open = try #require(EditorHeaderLocation.location(
            documentPath: "/Users/me/Dropbox/Archive/Backup/n.txt", paneFolder: "/Users/me/Cloud",
            sourceRoot: "/Users/me/Cloud", providerName: "iCloud", paneIsOpen: true,
            otherSources: others, links: [:]))
        #expect(open.segments == [.init(name: "Dropbox", target: nil), .init(name: "Archive", target: nil),
                                  .init(name: "Backup", target: nil)])
        #expect(open.otherSourceName == "Dropbox")
        #expect(open.help == "Dropbox › Archive › Backup")
        // How the folder-name reading draws it ("in Dropbox › Backup") is FileExplorer's to test —
        // `aFolderInAnotherSourceSaysWhichSource`; `parts(rung:)` is internal to that module.

        // The most specific root wins when two nest: a folder source inside a cloud's folder.
        let nested = try #require(EditorHeaderLocation.location(
            documentPath: "/Users/me/Dropbox/Clients/Work/Q3/plan.md", paneFolder: "",
            sourceRoot: "/Users/me/Cloud", providerName: "iCloud", paneIsOpen: false,
            otherSources: others, links: [:]))
        #expect(nested.segments.map(\.name) == ["Work", "Q3"])
        #expect(nested.segments.allSatisfy { $0.target == nil }, "another source's level is a door")

        // At the other source's own top the folder IS the source: one segment, its name.
        let top = try #require(EditorHeaderLocation.location(
            documentPath: "/Users/me/Dropbox/n.txt", paneFolder: "", sourceRoot: "/Users/me/Cloud",
            providerName: "iCloud", paneIsOpen: true, otherSources: others, links: [:]))
        #expect(top.segments == [.init(name: "Dropbox", target: nil)])
        #expect(top.otherSourceName == "Dropbox")

        // In no source at all: as before, the folder's own name and its path.
        let nowhere = try #require(EditorHeaderLocation.location(
            documentPath: "/Volumes/Backup/Scratch/n.txt", paneFolder: "", sourceRoot: "/Users/me/Cloud",
            providerName: "iCloud", paneIsOpen: true, otherSources: others, links: [:]))
        #expect(nowhere.segments == [.init(name: "Scratch", target: nil)])
        #expect(nowhere.otherSourceName == nil)
    }

    /// **The ＋ and the naming row call the folder what the pane's breadcrumb does.** At the top of
    /// iCloud Drive the folder's last component is "com~apple~CloudDocs", which the tooltip used to
    /// print; the breadcrumb says "iCloud". Below the top it is the folder's own name; no folder,
    /// nothing. Mutation: `lastPathComponent` in place of the location's word fails the first line.
    @Test func theNewFileFolderIsNamedAsTheBreadcrumbNamesIt() {
        let root = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(EditorHeaderLocation.folderName(paneFolder: root, sourceRoot: root,
                                                providerName: "iCloud", links: [:]) == "iCloud")
        #expect(EditorHeaderLocation.folderName(paneFolder: root + "/Finance", sourceRoot: root,
                                                providerName: "iCloud", links: [:]) == "Finance")
        #expect(EditorHeaderLocation.folderName(paneFolder: "", sourceRoot: root,
                                                providerName: "iCloud", links: [:]) == "")
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
        var selected: [String] = []
        var logged: [String] = []
        let doors = EditorLocationDoors(syncManager: manager, drawsColumns: true,
                                        log: { logged.append($0) },
                                        selectInPane: { selected.append($0) })
        doors.open(.showInPane, documentPath: "/c/Documents/Finance/Test.md", location: Self.finance)
        #expect(manager.combinedRelativePath(isLeft: true) == "Documents/Finance")
        #expect(selected == ["/c/Documents/Finance/Test.md"])
        #expect(logged == ["Edit header folder name: left pane browsed to Documents/Finance, selecting /c/Documents/Finance/Test.md"])
    }

    /// **A crumb re-points the pane and selects nothing** — in Columns a browse move inside the
    /// pane's scope, in Tree a re-root, exactly as the pane's own crumb for that level would.
    @Test func aCrumbMovesThePaneAndSelectsNothing() {
        let columns = FileSyncManager()
        var selected: [String] = []
        var logged: [String] = []
        EditorLocationDoors(syncManager: columns, drawsColumns: true,
                            log: { logged.append($0) }, selectInPane: { selected.append($0) })
            .open(.goTo("Documents"), documentPath: "/c/Documents/Finance/Test.md", location: Self.finance)
        #expect(columns.combinedRelativePath(isLeft: true) == "Documents")
        #expect(columns.leftRelativePath == "", "a crumb inside the scope re-rooted the Columns pane")

        let tree = FileSyncManager()
        EditorLocationDoors(syncManager: tree, drawsColumns: false,
                            log: { logged.append($0) }, selectInPane: { selected.append($0) })
            .open(.goTo("Documents"), documentPath: "/c/Documents/Finance/Test.md", location: Self.finance)
        #expect(tree.leftRelativePath == "Documents")
        #expect(selected.isEmpty, "a crumb selected something")
        #expect(logged == [
            "Edit header crumb: left pane browsed to Documents",
            "Edit header crumb: left pane re-rooted at Documents — Compare's left side is scoped there now, and this session's ignored paths were cleared",
        ])
    }

    /// **One INFO line per press, whatever the press did** — the user runs at INFO, and under "Just
    /// the text" the pane that moved is folded away, so the log is the only trace a press leaves.
    /// The line says what happened, read off the manager: a browse, a re-root (which re-scopes
    /// Compare and clears the session's ignores — so it says so), or nothing, including the root
    /// crumb. Mutation: `describe` always answering "browsed" fails the re-root and no-op lines.
    @Test func everyPressLeavesOneLineSayingWhatItDid() {
        let tree = FileSyncManager()
        var logged: [String] = []
        let doors = EditorLocationDoors(syncManager: tree, drawsColumns: false,
                                        log: { logged.append($0) }, selectInPane: { _ in })
        doors.open(.goTo("Documents"), documentPath: nil, location: nil)
        doors.open(.goTo("Documents"), documentPath: nil, location: nil)
        doors.open(.goTo(""), documentPath: nil, location: nil)
        #expect(logged == [
            "Edit header crumb: left pane re-rooted at Documents — Compare's left side is scoped there now, and this session's ignored paths were cleared",
            "Edit header crumb: left pane already showed Documents — nothing moved",
            "Edit header crumb: left pane re-rooted at the source's top — Compare's left side is scoped there now, and this session's ignored paths were cleared",
        ])
    }

    /// A location with nowhere to go selects nothing and moves nothing — and says so, as does the
    /// same door pressed with no document open (its closure is built during a render and can fire
    /// after a close).
    @Test func aFolderOutsideTheSourceOpensNoDoor() {
        let manager = FileSyncManager()
        var selected: [String] = []
        var logged: [String] = []
        let outside = EditorDocumentLocation(segments: [.init(name: "Scratch", target: nil)],
                                             style: .folderName, help: "~/Scratch")
        let doors = EditorLocationDoors(syncManager: manager, drawsColumns: true,
                                        log: { logged.append($0) }, selectInPane: { selected.append($0) })
        doors.open(.showInPane, documentPath: "/x/Scratch/n.txt", location: outside)
        doors.open(.showInPane, documentPath: nil, location: Self.finance)
        #expect(selected.isEmpty)
        #expect(manager.combinedRelativePath(isLeft: true) == "")
        #expect(logged == [
            "Edit header folder name: /x/Scratch/n.txt is outside the pane's source — the pane was not moved",
            "Edit header folder name pressed with no document open — nothing to show",
        ])
    }

    // MARK: The real wiring

    /// **Edit's document column is told when the pane beside it draws its tab strip** — by the
    /// pane's own rule, and only while the pane is open — and moves with the strip's curve. The
    /// layout itself is measured in Dashboard's `EditHeaderMatchesPaneHeaderTests`; this pins that
    /// the app hands it the real answer. Mutations: `paneShowsTabStrip: false`, dropping the
    /// collapse term, or dropping the animation each fail.
    @Test func theDocumentColumnIsToldAboutThePanesTabStrip() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        #expect(try CallArguments(of: "EditorWorkspaceView(", in: sourceCodeOnly(editor))
                    .passes("paneShowsTabStrip", "editorPaneShowsTabStrip"),
                "the workspace is not told whether the pane draws its tab strip")
        let tabs = CodeText(try OpenInEditorMenuTests.macApp("ContentView+PaneTabs.swift"))
        #expect(tabs.contains("!panesHiddenForCurrentTab && paneShowsTabStrip(isLeft: true)"),
                "the strip's presence is not the LEFT pane's own rule, gated on the pane being open")
        #expect(CodeText(editor).contains(".designAnimation(.easeOut(duration: 0.18), value: editorPaneShowsTabStrip)"),
                "the document column does not move with the strip's own animation")
    }

    /// **The app's closures, pinned by scan** — the review lesson from TE27–TE30: a test that
    /// injects its own closure cannot see the real one replaced by `{ _ in }`. Pinned: the header
    /// is handed the live location and the doors; the doors select through the one owed-selection
    /// rule (TE47's `owePaneSelection`, which pays through the pane's own selection setter), log at
    /// INFO, and are told the mode the pane is drawn in; the location knows the user's other
    /// sources, and the ＋ the breadcrumb's word for its folder; the reading is keyed on the pane's
    /// collapse bit. And the
    /// doors' body never reaches the pane's visibility or the document — a crumb must not expand
    /// the collapsed pane, and no door may settle or reload the file.
    ///
    /// Each argument is read by its label on the call it belongs to (``CallArguments``) — where
    /// these were substrings of the whole file ending in `,` or `)`, so an argument that became
    /// the last in its call, or a call broken over one more line, went red with nothing wrong, and
    /// `log: { Logger.shared.info($0) },` was only the doors' because the other three `log:` in the
    /// file happened to end in `)`.
    @Test func theHeaderIsWiredToTheRealDoors() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        let code = sourceCodeOnly(editor)
        let workspace = try CallArguments(of: "EditorWorkspaceView(", in: code)
        #expect(workspace.passes("location", "editorDocumentLocation"),
                "the header is not handed the document's location")
        let open = try CallArguments(of: "editorLocationDoors.open(", in: code)
        #expect(open.unlabeled == ["door"] && open.passes("documentPath", "editorDocument.path"),
                "the header's doors are not wired to EditorLocationDoors")
        #expect(open.passes("location", "editorDocumentLocation"),
                "the doors are not handed the live location at press time")
        let doorsBuilt = try CallArguments(of: "EditorLocationDoors(", in: code)
        #expect(doorsBuilt.passes("selectInPane", "{ owePaneSelection($0) }"),
                "the folder door does not select through the one owed-selection rule (TE47)")
        let location = try CallArguments(
            of: "EditorHeaderLocation.location(",
            in: try declarationBody(of: "var editorDocumentLocation: EditorDocumentLocation? {", in: editor))
        #expect(location.passes("otherSources", "editorOtherSources"),
                "the location is not told about the user's other sources")
        #expect(CodeText(editor).contains("settings.enabledProviders.filter { $0.id != leftProviderId }"),
                "the other sources are not every enabled source but the left pane's")
        #expect(workspace.passes("folderDisplayName", "editorFolderDisplayName"),
                "the ＋ and the naming row are not handed the breadcrumb's word for the folder")
        #expect(doorsBuilt.passes("log", "{ Logger.shared.info($0) }"),
                "the doors' log does not reach the INFO log the user runs at")
        #expect(doorsBuilt.passes("drawsColumns", "resolvedViewMode(isLeft: true) == .columns"),
                "the doors do not ask the mode the pane is drawn in")
        #expect(location.passes("paneIsOpen", "!panesHiddenForCurrentTab"),
                "the reading is not keyed on the pane's collapse bit")
        // The empty page names the folder a new file goes in — the SAME `editorFolder` the ＋, ⌘N,
        // the rail and the naming row all read, not a second idea of "the folder". Read off the
        // location's own call: `paneFolder: editorFolder` is passed elsewhere in the file too.
        #expect(location.passes("paneFolder", "editorFolder"),
                "the empty page's location is not the folder ⌘N creates in")

        let doors = sourceCodeOnly(try OpenInEditorMenuTests.macApp("EditorLocationDoors.swift"))
        let start = try #require(doors.range(of: "struct EditorLocationDoors {"))
        // Comments stripped: the body's own comments explain why `openInEditor` is not reached,
        // and a scan that matched them would report the explanation as the call. Read to the end
        // of the file, as before, so an extension added below the struct is read too.
        let body = CodeText(String(doors[start.upperBound...]))
        for forbidden in ["togglePanes", "panesHidden", "loadIntoEditor", "openInEditor",
                          "settleEditorDocument", "selectedWorkspace"] {
            #expect(!body.contains(forbidden), "EditorLocationDoors reaches \(forbidden)")
        }
        let navigate = try CallArguments(of: "syncManager.navigatePane(", in: body.normalized)
        #expect(navigate.passes("isLeft", "true") && navigate.passes("toCombinedPath", "target"),
                "a crumb no longer takes the pane breadcrumb's own route")
    }
}
