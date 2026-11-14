import Testing
import Foundation
import Sync
import FileExplorer
@testable import SyncCloud

/// The app half of the Edit header's location: what it says, built from the pane's own breadcrumb
/// model, and what a press on it does to the left pane, driven against a real `FileSyncManager`
/// the `DuplicateRevealCoordinatorTests` way.
@MainActor
@Suite struct EditorHeaderLocationTests {
    // MARK: What it says

    /// The pane breadcrumb's words: the source's display name first (never the root folder's last
    /// component), then the folders under the root, each with the combined path the pane's crumb
    /// for it navigates to.
    @Test func theLocationSpeaksThePaneBreadcrumbsVocabulary() throws {
        let location = try #require(EditorHeaderLocation.location(
            documentPath: "/Users/me/Cloud/Documents/Finance/Test.md",
            // A different folder in the pane: an open document is placed by its own folder.
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

    /// iCloud Drive's `Documents` is `~/Documents` on disk, linked into the container. A file the
    /// pane lists under `iCloud › Documents` must be placed there, through the hand-off's own root
    /// test, not refused as outside the source.
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

    /// A folder under another of the user's sources (a Dropbox copy opened from Compare) is placed
    /// there in words, led by that source's name, and no level is a door. Fails if the
    /// `otherSources` try is dropped.
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
        // How the folder-name reading draws it ("in Dropbox › Backup") is FileExplorer's to test,
        // in `aFolderInAnotherSourceSaysWhichSource`; `parts(rung:)` is internal to that module.

        // The most specific root wins when two nest: a folder source inside a cloud's folder.
        let nested = try #require(EditorHeaderLocation.location(
            documentPath: "/Users/me/Dropbox/Clients/Work/Q3/plan.md", paneFolder: "",
            sourceRoot: "/Users/me/Cloud", providerName: "iCloud", paneIsOpen: false,
            otherSources: others, links: [:]))
        #expect(nested.segments.map(\.name) == ["Work", "Q3"])
        #expect(nested.segments.allSatisfy { $0.target == nil }, "another source's level is a door")

        // At the other source's own top the folder is the source: one segment, its name.
        let top = try #require(EditorHeaderLocation.location(
            documentPath: "/Users/me/Dropbox/n.txt", paneFolder: "", sourceRoot: "/Users/me/Cloud",
            providerName: "iCloud", paneIsOpen: true, otherSources: others, links: [:]))
        #expect(top.segments == [.init(name: "Dropbox", target: nil)])
        #expect(top.otherSourceName == "Dropbox")

        // In no source at all: the folder's own name and its path.
        let nowhere = try #require(EditorHeaderLocation.location(
            documentPath: "/Volumes/Backup/Scratch/n.txt", paneFolder: "", sourceRoot: "/Users/me/Cloud",
            providerName: "iCloud", paneIsOpen: true, otherSources: others, links: [:]))
        #expect(nowhere.segments == [.init(name: "Scratch", target: nil)])
        #expect(nowhere.otherSourceName == nil)
    }

    /// The ＋ and the naming row call the folder what the breadcrumb does: "iCloud" at the top of
    /// iCloud Drive (not "com~apple~CloudDocs"), else its own name. Fails on the first line if
    /// `lastPathComponent` replaces the location's word.
    @Test func theNewFileFolderIsNamedAsTheBreadcrumbNamesIt() {
        let root = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(EditorHeaderLocation.folderName(paneFolder: root, sourceRoot: root,
                                                providerName: "iCloud", links: [:]) == "iCloud")
        #expect(EditorHeaderLocation.folderName(paneFolder: root + "/Finance", sourceRoot: root,
                                                providerName: "iCloud", links: [:]) == "Finance")
        #expect(EditorHeaderLocation.folderName(paneFolder: "", sourceRoot: root,
                                                providerName: "iCloud", links: [:]) == "")
    }

    /// No document and no folder: nothing to name. The empty page's header says nothing about a
    /// location, as the + beside it is greyed.
    @Test func noDocumentAndNoFolderNoLocation() {
        #expect(EditorHeaderLocation.location(documentPath: nil, paneFolder: "", sourceRoot: "/r",
                                              providerName: "x", paneIsOpen: true, links: [:]) == nil)
    }

    /// No document: the pane's folder (where a new file would go) is named but is not a door onto
    /// itself; the levels above keep their doors. Fails if it returns `nil`, keeps the last level's
    /// target, or drops every target.
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

    /// The folder name: the pane goes to the folder, and the file is selected there through the
    /// pane's own selection write, which the test stands in for.
    @Test func theFolderNameShowsTheFileInThePane() {
        let manager = FileSyncManager.scratch()
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

    /// A crumb re-points the pane and selects nothing: in Columns a browse move inside the pane's
    /// scope, in Tree a re-root, as the pane's own crumb for that level would.
    @Test func aCrumbMovesThePaneAndSelectsNothing() {
        let columns = FileSyncManager.scratch()
        var selected: [String] = []
        var logged: [String] = []
        EditorLocationDoors(syncManager: columns, drawsColumns: true,
                            log: { logged.append($0) }, selectInPane: { selected.append($0) })
            .open(.goTo("Documents"), documentPath: "/c/Documents/Finance/Test.md", location: Self.finance)
        #expect(columns.combinedRelativePath(isLeft: true) == "Documents")
        #expect(columns.leftRelativePath == "", "a crumb inside the scope re-rooted the Columns pane")

        let tree = FileSyncManager.scratch()
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

    /// One INFO line per press saying what happened: a browse, a re-root (naming what it resets),
    /// or nothing. The user runs at INFO and the moved pane may be folded away, so the log is the
    /// only trace. Fails if `describe` always answers "browsed".
    @Test func everyPressLeavesOneLineSayingWhatItDid() {
        let tree = FileSyncManager.scratch()
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

    // MARK: The rail's folder menu

    /// The rail's folder menu speaks the location's words: each level with its crumb's target, the
    /// folder's own named but not offered, plus the folder's own target for its subfolders. Run
    /// through iCloud Drive's linked `Documents`, so the folder is placed as the pane lists it.
    @Test func theRailsTrailIsTheLocationsLevelsPlusTheFoldersOwnTarget() throws {
        let trail = try #require(EditorHeaderLocation.folderTrail(
            paneFolder: "/home/Documents/Family/Anuraag", sourceRoot: "/c", providerName: "iCloud",
            subfolders: ["Receipts"], links: ["/c": ["Documents": "/home/Documents"]]))
        #expect(trail.levels == [
            .init(name: "iCloud", target: ""),
            .init(name: "Documents", target: "Documents"),
            .init(name: "Family", target: "Documents/Family"),
            .init(name: "Anuraag", target: nil),
        ])
        #expect(trail.currentTarget == "Documents/Family/Anuraag")
        #expect(trail.subfolders == ["Receipts"])
    }

    /// A survey of another folder offers no subfolders: the folder moved and its walk hasn't
    /// returned, so the old folder's names would be joined to the new folder's target.
    @Test func aSurveyOfAnotherFolderOffersNoSubfolders() {
        #expect(EditorHeaderLocation.subfolders(["Taxes"], surveyed: "/c/Family", folder: "/c/Family") == ["Taxes"])
        #expect(EditorHeaderLocation.subfolders(["Taxes"], surveyed: "/c", folder: "/c/Family") == [])
        #expect(EditorHeaderLocation.subfolders(["Taxes"], surveyed: nil, folder: "/c/Family") == [])
    }

    /// At the top of the source the folder's target is `""`, so its subfolders go by bare name.
    @Test func atTheTopOfTheSourceTheFoldersTargetIsEmpty() throws {
        let trail = try #require(EditorHeaderLocation.folderTrail(
            paneFolder: "/c", sourceRoot: "/c", providerName: "iCloud", subfolders: [], links: [:]))
        #expect(trail.levels == [.init(name: "iCloud", target: nil)])
        #expect(trail.currentTarget == "")
    }

    /// Outside the pane's source nothing is a door, neither a level nor a subfolder.
    @Test func outsideTheSourceTheTrailHasNoTargets() throws {
        let trail = try #require(EditorHeaderLocation.folderTrail(
            paneFolder: "/Volumes/Backup/Scratch", sourceRoot: "/Users/me/Cloud", providerName: "iCloud",
            subfolders: ["Inside"], links: [:]))
        #expect(trail.levels == [.init(name: "Scratch", target: nil)])
        #expect(trail.currentTarget == nil)
        #expect(EditorHeaderLocation.folderTrail(paneFolder: "", sourceRoot: "/c", providerName: nil,
                                                 subfolders: [], links: [:]) == nil)
    }

    /// A pick in the menu takes the header crumb's route (a browse move in Columns, a re-root in
    /// Tree), and its log line names where it came from.
    @Test func aPickInTheRailsMenuMovesThePaneByTheCrumbsRoute() {
        var logged: [String] = []
        let columns = FileSyncManager.scratch()
        EditorLocationDoors(syncManager: columns, drawsColumns: true,
                            log: { logged.append($0) }, selectInPane: { _ in })
            .goTo("Documents/Family", from: "Edit rail folder menu")
        #expect(columns.combinedRelativePath(isLeft: true) == "Documents/Family")
        let tree = FileSyncManager.scratch()
        EditorLocationDoors(syncManager: tree, drawsColumns: false,
                            log: { logged.append($0) }, selectInPane: { _ in })
            .goTo("Documents", from: "Edit rail folder menu")
        #expect(tree.leftRelativePath == "Documents")
        #expect(logged == [
            "Edit rail folder menu: left pane browsed to Documents/Family",
            "Edit rail folder menu: left pane re-rooted at Documents — Compare's left side is scoped there now, and this session's ignored paths were cleared",
        ])
    }

    /// A location with nowhere to go selects and moves nothing, and says so, as does the same door
    /// pressed with no document open (its closure is built during a render and can fire after a
    /// close).
    @Test func aFolderOutsideTheSourceOpensNoDoor() {
        let manager = FileSyncManager.scratch()
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
}

/// The real wiring, read from `MacApp/`. A suite of its own so it isn't `@MainActor`: the scans
/// touch no AppKit or SwiftUI, and on the main thread they would hold up every main-actor test in
/// the process (see `EditorHandOffRunWiringTests`).
@Suite struct EditorHeaderLocationWiringTests {
    /// Edit's document column is told when the open pane draws its tab strip, and moves with the
    /// strip's curve (`EditHeaderMatchesPaneHeaderTests` measures the layout). The animation is
    /// keyed on the strip alone: `sourcePaneShowsTabStrip` also flips on a fold, which must snap.
    @Test func theDocumentColumnIsToldAboutThePanesTabStrip() throws {
        let editor = try macAppFile("ContentView+Editor.swift")
        #expect(try CallArguments(of: "EditorWorkspaceView(", in: sourceCodeOnly(editor))
                    .passes("paneShowsTabStrip", "sourcePaneShowsTabStrip"),
                "the workspace is not told whether the pane draws its tab strip")
        let tabs = CodeText(try macAppFile("ContentView+PaneTabs.swift"))
        #expect(tabs.contains("!panesHiddenForCurrentTab && paneShowsTabStrip(isLeft: true)"),
                "the strip's presence is not the LEFT pane's own rule, gated on the pane being open")
        #expect(CodeText(editor).contains(".designAnimation(.easeOut(duration: 0.18), value: sourcePaneStripIgnoringFold)"),
                "the document column does not move with the strip's own animation")
    }

    /// An Organize lens is handed Edit's same predicate, so its header leaves the strip's slot
    /// empty too, and moves with the strip's curve (`LensHeaderMatchesPaneHeaderTests` measures it).
    @Test func theLensIsToldAboutThePanesTabStrip() throws {
        let content = sourceCodeOnly(try macAppFile("ContentView.swift"))
        #expect(try CallArguments(of: "LensWorkspaceView(", in: content)
                    .passes("paneShowsTabStrip", "sourcePaneShowsTabStrip"),
                "the lens is not told whether the pane draws its tab strip")
        let split = CodeText(try macAppFile("ContentView+SplitLayout.swift"))
        #expect(split.contains(".designAnimation(.easeOut(duration: 0.18), value: sourcePaneStripIgnoringFold)"),
                "the lens column does not move with the strip's own animation")
    }

    /// The app's closures, pinned by scan (read by label with ``CallArguments``), since a test that
    /// injects its own can't see the real one replaced by `{ _ in }`. The doors select through
    /// `owePaneSelection` and log at INFO, and never reach the pane's visibility or the document: a
    /// crumb must not expand a collapsed pane, and no door may settle or reload the file.
    @Test func theHeaderIsWiredToTheRealDoors() throws {
        let editor = try macAppFile("ContentView+Editor.swift")
        let code = sourceCodeOnly(editor)
        let workspace = try CallArguments(of: "EditorWorkspaceView(", in: code)
        #expect(workspace.passes("location", "editorDocumentLocation"),
                "the header is not handed the document's location")
        let open = try CallArguments(of: "editorLocationDoors.open(", in: code)
        #expect(open.unlabeled == ["door"] && open.passes("documentPath", "editorOpenPath"),
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
        // The empty page names the folder ⌘N creates in. Read off the location's own call, since
        // `paneFolder: editorFolder` is passed elsewhere in the file too.
        #expect(location.passes("paneFolder", "editorFolder"),
                "the empty page's location is not the folder ⌘N creates in")

        let doors = sourceCodeOnly(try macAppFile("EditorLocationDoors.swift"))
        let start = try #require(doors.range(of: "struct EditorLocationDoors {"))
        // Comments stripped, since they name `openInEditor` to explain it isn't called. Read to
        // the end of the file, so an extension below the struct is read too.
        let body = CodeText(String(doors[start.upperBound...]))
        for forbidden in ["togglePanes", "panesHidden", "loadIntoEditor", "openInEditor",
                          "settleEditorDocument", "selectedWorkspace"] {
            #expect(!body.contains(forbidden), "EditorLocationDoors reaches \(forbidden)")
        }
        let navigate = try CallArguments(of: "syncManager.navigatePane(", in: body.normalized)
        #expect(navigate.passes("isLeft", "true") && navigate.passes("toCombinedPath", "target"),
                "a crumb no longer takes the pane breadcrumb's own route")
    }

    /// The rail's folder menu is handed the live trail, built from `editorFolder` and the survey's
    /// folders, and a pick goes through the doors' `goTo`. Fails with `onGoToFolder: nil`, or a
    /// trail built from another folder.
    @Test func theRailsFolderMenuIsWiredToTheRealPane() throws {
        let editor = try macAppFile("ContentView+Editor.swift")
        let code = sourceCodeOnly(editor)
        let workspace = try CallArguments(of: "EditorWorkspaceView(", in: code)
        #expect(workspace.passes("folderTrail", "editorFolderTrail"),
                "the rail is not handed the folder's trail")
        #expect(workspace.passes("onGoToFolder",
                                 "{ target in editorLocationDoors.goTo(target, from: \"Edit rail folder menu\") }"),
                "a pick in the rail's folder menu does not move the pane by the crumbs' route")
        let trail = try CallArguments(
            of: "EditorHeaderLocation.folderTrail(",
            in: try declarationBody(of: "var editorFolderTrail: EditorFolderTrail? {", in: editor))
        #expect(trail.passes("paneFolder", "editorFolder"),
                "the menu is not about the folder the rail lists")
        #expect(trail.passes("subfolders", """
            EditorHeaderLocation.subfolders(editorRailSurvey.folders, surveyed: editorRailSurveyFolder, folder: editorFolder)
            """), "the menu's subfolders are not the rail survey's, or are offered for a folder it did not read")
        let refresh = try declarationBody(of: "func refreshEditorRail() async {", in: editor)
        #expect(sourceCodeOnly(refresh).contains("if editorRailSurveyFolder != folder { editorRailSurveyFolder = folder }"),
                "the survey's folder is never recorded, so the menu would offer no subfolders at all")
        #expect(trail.passes("otherSources", "editorOtherSources"),
                "the menu does not know the user's other sources, as the header's location does")
    }
}
