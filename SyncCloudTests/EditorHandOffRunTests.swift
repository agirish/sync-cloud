import Testing
import Foundation
import Combine
import Sync
import FileExplorer
@testable import SyncCloud

/// **Compare's differences list opens a file in Edit without moving the left pane** (TE31's fixup),
/// and what the hand-off does with the pane in each of its two variants — driven against a real
/// `FileSyncManager`, the `EditorHeaderLocationTests` way.
///
/// The reason the list needs its own variant is a measurement, pinned by the control below: the
/// ordinary hand-off re-roots the left pane on the file's folder (`focusOn`), and in Compare that
/// pane is half of the comparison the list is showing. `focusOn` clears the session's "Ignore in
/// comparison" entries, resets the column stack, pushes a history entry and sends a refresh — which
/// `ContentView` turns into a reload and a new comparison scan. The list the user acted from would
/// be replaced under them.
@MainActor
@Suite struct EditorHandOffRunTests {

    static let root = "/c"
    /// A comparison scoped to `Documents`, with one row set aside for the session and one refresh
    /// counter — the state a Compare user is in when they right-click a difference.
    @MainActor final class Scene {
        let manager = FileSyncManager()
        var refreshes: [FileSyncManager.PaneReloadScope] = []
        var bag: AnyCancellable?
        var log: [String] = []
        var steps: [String] = []

        init() {
            manager.focusOn(relativePath: "Documents", isLeft: true)
            manager.ignoredPaths = ["Finance/old.md"]
            bag = manager.refreshSubject.sink { [unowned self] in self.refreshes.append($0) }
        }

        var paneFolder: String { "\(EditorHandOffRunTests.root)/\(manager.leftRelativePath)" }

        @discardableResult
        func handOff(_ path: String, pane: EditorHandOffRun.Pane, openDocument: String? = nil,
                     isRefused: Bool = false, settles: Bool = true) -> EditorHandOffRun.Outcome {
            EditorHandOffRun.run(
                path, pane: pane, syncManager: manager, paneRoot: EditorHandOffRunTests.root,
                openDocument: openDocument, isRefused: isRefused,
                paneFolder: { self.paneFolder },
                settle: { self.steps.append("settle"); return settles },
                endNaming: { self.steps.append("endNaming") },
                showEdit: { self.steps.append("showEdit") },
                load: { self.steps.append("load \($0)") },
                log: { self.log.append($0) })
        }
    }

    static let file = "/c/Documents/Finance/Tax/notes.md"

    // MARK: What each variant does to the pane

    /// **The fix.** `.staysPut` opens the file and leaves the comparison exactly as it was: same
    /// scope, same history, same column stack, the session's ignores intact, and no refresh sent —
    /// so no reload and no new scan.
    @Test func theDifferencesListsHandOffLeavesTheComparisonAlone() {
        let scene = Scene()
        let history = scene.manager.leftHistory
        let stack = scene.manager.leftBrowsePath
        let outcome = scene.handOff(Self.file, pane: .staysPut)
        #expect(outcome == .opened)
        #expect(scene.steps == ["settle", "endNaming", "showEdit", "load \(Self.file)"])
        #expect(scene.manager.leftRelativePath == "Documents", "the comparison was re-scoped")
        #expect(scene.manager.leftHistory == history, "the pane's history moved")
        #expect(scene.manager.leftBrowsePath == stack, "the pane's column stack moved")
        #expect(scene.manager.ignoredPaths == ["Finance/old.md"],
                "the session's Ignore in comparison entries were cleared")
        #expect(scene.refreshes.isEmpty, "a refresh was sent — the comparison would be re-scanned")
    }

    /// **The control, and the reason for the variant**: the ordinary hand-off, from the same state,
    /// re-scopes the comparison and throws the session's ignores away. If this ever stops being
    /// true, the variant is no longer needed — and the test above would pass for nothing.
    @Test func theOrdinaryHandOffReScopesTheComparison() {
        let scene = Scene()
        #expect(scene.handOff(Self.file, pane: .followsTheFile) == .opened)
        #expect(scene.manager.leftRelativePath == "Documents/Finance/Tax")
        #expect(scene.manager.ignoredPaths.isEmpty)
        #expect(scene.refreshes == [.leftOnly])
    }

    /// Each hand-off says how it ended; the no-re-root case has its own line naming the decision.
    @Test func theNoReRootCaseSaysSo() {
        let scene = Scene()
        scene.handOff(Self.file, pane: .staysPut)
        #expect(scene.log == [
            "Editor hand-off to \(Self.file) leaves the left pane on /c/Documents — Compare's list of differences does not move it",
        ])
        let ordinary = Scene()
        ordinary.handOff(Self.file, pane: .followsTheFile)
        #expect(ordinary.log.isEmpty, "the ordinary hand-off's line is the load's own, written by loadIntoEditor")
    }

    /// **A refused file is never logged as opened.** The `.staysPut` line is written before the
    /// load, so it may only name the decision; the load's own line — the real one, through
    /// `EditorFileStore.load` and `loadLogLine` — says the file could not be opened, and nothing
    /// above it may say it was. It read "<path> opened without moving the left pane" until
    /// 2026-09-25, a false "opened" over the refusal.
    @Test func aRefusedFileFromTheDifferencesListIsNeverLoggedAsOpened() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("binary.md").path
        try Data([0x61, 0x00, 0x62, 0x00]).write(to: URL(fileURLWithPath: path))
        let document = EditorDocument()
        var log: [String] = []
        EditorHandOffRun.run(
            path, pane: .staysPut, syncManager: FileSyncManager(), paneRoot: dir.path,
            openDocument: nil, isRefused: false, paneFolder: { dir.path }, settle: { true },
            endNaming: {}, showEdit: {},
            load: { log.append(ContentView.loadLogLine(path: $0, result: EditorFileStore.load(path: $0, into: document))) },
            log: { log.append($0) })
        #expect(log.count == 2, "a .staysPut hand-off writes its decision and the load's line: \(log)")
        #expect(log.last?.hasPrefix("Editor could not open \(path)") == true, "the fixture was not refused: \(log)")
        #expect(!log.contains { $0.contains("opened") }, "a refused file was logged as opened: \(log)")
    }

    // MARK: ⌘N's naming row

    /// **A hand-off lands on a document, never on ⌘N's naming row.** ⌘N, then leaving Edit and
    /// choosing a file elsewhere, used to land with the row still open over the handed-off
    /// document and its field taking the keyboard — only the rail's click put it away. Put away
    /// after the settle (never on Cancel, which must change nothing) and on the already-open exit.
    @Test func aHandOffPutsTheNamingRowAwayUnlessCancelled() {
        for pane in [EditorHandOffRun.Pane.staysPut, .followsTheFile] {
            let opened = Scene()
            opened.handOff(Self.file, pane: pane)
            #expect(Array(opened.steps.prefix(2)) == ["settle", "endNaming"], "\(pane): \(opened.steps)")
            let already = Scene()
            already.handOff(Self.file, pane: pane, openDocument: Self.file)
            #expect(already.steps == ["endNaming", "showEdit"], "\(pane): \(already.steps)")
            let cancelled = Scene()
            cancelled.handOff(Self.file, pane: pane, openDocument: "/c/Documents/draft.md", settles: false)
            #expect(!cancelled.steps.contains("endNaming"), "\(pane): the naming row went on Cancel")
        }
    }

    // MARK: Which folder "already there" asks about

    /// **The guard asks the folder EDIT will show, not the folder on screen.** Browse drawing
    /// Columns at Documents › Finance, Edit drawing Tree: the pane's stack is shared and parked
    /// while Tree is drawn, so the same pane shows `Documents/Finance` in Browse and `Documents` in
    /// Edit. A hand-off of a file in Finance from Browse read Browse's folder, took "already
    /// there", skipped the re-root — and Edit's Tree showed Documents, with the file's owed
    /// selection dropped for naming a folder the pane was not showing (2026-09-25).
    @Test func theHandOffAsksTheFolderEditWillShow() {
        let scene = Scene()
        scene.manager.navigatePane(isLeft: true, toCombinedPath: "Documents/Finance", drawsColumns: true)
        #expect(scene.manager.leftRelativePath == "Documents", "the premise: a browse move, not a re-root")
        let tree = "/c/\(scene.manager.leftRelativePath)"
        let browse = ContentView.paneFolder(treeRoot: tree, browsePath: scene.manager.leftBrowsePath,
                                            drawsColumns: true)
        let edit = ContentView.paneFolder(treeRoot: tree, browsePath: scene.manager.leftBrowsePath,
                                          drawsColumns: false)
        #expect(browse == "/c/Documents/Finance")
        #expect(edit == "/c/Documents")
        let file = "/c/Documents/Finance/budget.md"
        EditorHandOffRun.run(
            file, pane: .followsTheFile, syncManager: scene.manager, paneRoot: Self.root,
            openDocument: nil, isRefused: false, paneFolder: { edit }, settle: { true },
            endNaming: {}, showEdit: {}, load: { _ in }, log: { _ in })
        #expect(scene.manager.leftRelativePath == "Documents/Finance",
                "Edit's Tree was left on Documents — the rail and the pane list the wrong folder")
    }

    /// The app hands the act Edit's folder, through the one member that reads each workspace's
    /// view mode — `resolvedViewMode` is that member for the workspace on screen.
    @Test func theAppAsksForEditsFolder() throws {
        let editor = try OpenInEditorMenuTests.macApp("ContentView+Editor.swift")
        #expect(CodeText(editor).contains("var editorFolder: String { leftPaneFolder(in: selectedWorkspace) }"))
        let folder = try declarationBody(of: "func leftPaneFolder(in workspace: Workspace) -> String {", in: editor)
        #expect(try CallArguments(of: "Self.paneFolder(", in: folder)
                    .passes("drawsColumns", "viewMode(in: workspace, isLeft: true) == .columns"),
                "the folder is not read in the mode of the workspace it was asked about")
        let content = CodeText(try OpenInEditorMenuTests.macApp("ContentView.swift"))
        #expect(content.contains("viewMode(in: selectedWorkspace, isLeft: isLeft)"),
                "resolvedViewMode no longer delegates — two answers to one question")
    }

    // MARK: Shared with the ordinary hand-off

    /// **Settle first, and Cancel means nothing happens** — no workspace switch, no load, and in
    /// the ordinary variant no pane move either. One line says it was cancelled.
    @Test func cancellingTheSettleDoesNothingInEitherVariant() {
        for pane in [EditorHandOffRun.Pane.staysPut, .followsTheFile] {
            let scene = Scene()
            #expect(scene.handOff(Self.file, pane: pane, openDocument: "/c/Documents/draft.md",
                                  settles: false) == .cancelled)
            #expect(scene.steps == ["settle"], "\(pane): something ran after a cancelled settle")
            #expect(scene.manager.leftRelativePath == "Documents", "\(pane): the pane moved on Cancel")
            #expect(scene.refreshes.isEmpty, "\(pane): a refresh was sent on Cancel")
            #expect(scene.log == ["Editor hand-off to \(Self.file) cancelled — the open document was kept"])
        }
    }

    /// The already-open guard is shared too: Edit is shown, nothing is settled or loaded.
    @Test func anAlreadyOpenFileIsShownNotReloaded() {
        for pane in [EditorHandOffRun.Pane.staysPut, .followsTheFile] {
            let scene = Scene()
            #expect(scene.handOff(Self.file, pane: pane, openDocument: Self.file) == .alreadyOpen)
            #expect(scene.steps == ["endNaming", "showEdit"])
            #expect(scene.log == ["Editor hand-off: \(Self.file) is already open — showing Edit"])
            #expect(scene.manager.leftRelativePath == "Documents")
        }
        // A refused document is tried again — the second click that retries a refusal.
        let scene = Scene()
        #expect(scene.handOff(Self.file, pane: .staysPut, openDocument: Self.file, isRefused: true) == .opened)
    }

    // MARK: The header's location, from Compare

    /// **What TE43's "in <folder>" does to the comparison after a differences-list open.** The file
    /// is below the comparison's scope, so in Columns the door is a browse move inside the scope —
    /// no re-scope, no scan, the ignores kept. In Tree it is a re-root (Tree has no column stack to
    /// move), which re-scopes the comparison and clears the ignores, exactly as the pane's own
    /// breadcrumb does for that folder in Tree. Measured, and reported rather than changed: it is
    /// the breadcrumb's route, and a Tree pane cannot show a folder any other way.
    @Test func theHeaderLocationFromCompareMovesColumnsButReRootsATree() {
        let location = EditorDocumentLocation(
            segments: [.init(name: "Cloud", target: ""), .init(name: "Documents", target: "Documents"),
                       .init(name: "Finance", target: "Documents/Finance"),
                       .init(name: "Tax", target: "Documents/Finance/Tax")],
            style: .folderName, help: "")
        let columns = Scene()
        var owed: [String] = []
        EditorLocationDoors(syncManager: columns.manager, drawsColumns: true, log: { _ in }, selectInPane: { owed.append($0) })
            .open(.showInPane, documentPath: Self.file, location: location)
        #expect(columns.manager.leftRelativePath == "Documents")
        #expect(columns.manager.combinedRelativePath(isLeft: true) == "Documents/Finance/Tax")
        #expect(columns.manager.ignoredPaths == ["Finance/old.md"])
        #expect(columns.refreshes.isEmpty)
        #expect(owed == [Self.file])

        let tree = Scene()
        EditorLocationDoors(syncManager: tree.manager, drawsColumns: false, log: { _ in }, selectInPane: { _ in })
            .open(.showInPane, documentPath: Self.file, location: location)
        #expect(tree.manager.leftRelativePath == "Documents/Finance/Tax")
        #expect(tree.manager.ignoredPaths.isEmpty)
        #expect(tree.refreshes == [.leftOnly])
    }

    // MARK: The real wiring

    /// `handOffToEditor` runs this act with the window's own pieces, and the default is the
    /// ordinary variant — so every door but the differences list keeps re-rooting.
    ///
    /// Every argument is read by its label on the `EditorHandOffRun.run(` call itself, so the
    /// check is about what is passed and not how the call is laid out — and `paneRoot:` is pinned
    /// too, which the snippet list this replaced left out: the root is what the act re-roots the
    /// pane under and what it decides "inside the source" against, so the left source's EXPANDED
    /// root is the only right answer (`~` is not a folder the pane can walk).
    @Test func theAppRunsTheSharedActWithItsOwnPieces() throws {
        let body = try EditorNewFilePaneWiringTests.body(
            of: "func handOffToEditor(_ path: String, pane: EditorHandOffRun.Pane = .followsTheFile) {",
            in: "ContentView+Editor.swift")
        let run = try CallArguments(of: "EditorHandOffRun.run(", in: body.normalized)
        #expect(run.unlabeled == ["path"], "the act is handed \(run.unlabeled), not the path it was asked to open")
        for (label, value) in [("pane", "pane"), ("syncManager", "syncManager"),
                               ("paneRoot", "(settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath"),
                               ("openDocument", "editorDocument.path"),
                               ("isRefused", "editorDocument.refusal != nil"),
                               ("paneFolder", "{ leftPaneFolder(in: .editor) }"),
                               ("settle", "{ settleEditorDocument() }"),
                               ("endNaming", "{ editorIsNaming = false }"),
                               ("showEdit", "{ if selectedWorkspace != .editor { selectedWorkspace = .editor } }"),
                               ("load", "{ loadIntoEditor(path: $0) }"),
                               ("log", "{ Logger.shared.info($0) }")] {
            #expect(run.passes(label, value),
                    "handOffToEditor no longer hands the act \(label): \(value) — it hands \(run.value(label) ?? "nothing")")
        }
        #expect(!body.contains("focusOn(") && !body.contains("focusPane("),
                "handOffToEditor moves the pane itself — the variant's decision is bypassed")
    }

    /// The differences list is the ONE `.staysPut` door; every other hand-off takes the default.
    ///
    /// Over the whole of `MacApp/` (``macAppSources()``), comments stripped and whitespace
    /// normalised — it read three named files, so a `.staysPut` door added in a fourth passed in
    /// silence, which is the one event this test exists for. Either spelling of the case counts.
    @Test func onlyTheDifferencesListLeavesThePane() throws {
        let app = CodeText(try macAppSources())
        let count = app.count(of: "pane: .staysPut") + app.count(of: "pane: EditorHandOffRun.Pane.staysPut")
        #expect(count == 1, "\(count) callers leave the pane where it is — expected exactly the differences list")
        let differences = try CallArguments(of: "DifferencesView(", in: sourceCodeOnly(try macAppSources()))
        #expect(differences.passes("onOpenInEditor", "{ handOffToEditor($0, pane: .staysPut) }"),
                "the one `.staysPut` door is not the differences list's")
    }

    // MARK: Reveal in Browse (header and rail rows)

    /// **Already there: nothing moves.** Columns drilled to Documents › Finance › Tax, revealing a
    /// file in Tax: it re-rooted at Tax until 2026-09-25 — the stack reset, a history entry, the
    /// session's ignores cleared and a refresh sent, to arrive where the pane already was.
    @Test func revealingAFileInTheFolderBrowseShowsMovesNothing() {
        let scene = Scene()
        scene.manager.navigatePane(isLeft: true, toCombinedPath: "Documents/Finance/Tax", drawsColumns: true)
        let history = scene.manager.leftHistory, stack = scene.manager.leftBrowsePath
        EditorRevealInBrowse.movePane(to: Self.file, from: .railRow, syncManager: scene.manager,
                                      sourceRoot: Self.root, drawsColumns: true, links: [:],
                                      log: { scene.log.append($0) })
        #expect(scene.manager.leftRelativePath == "Documents")
        #expect(scene.manager.leftHistory == history)
        #expect(scene.manager.leftBrowsePath == stack)
        #expect(scene.manager.ignoredPaths == ["Finance/old.md"])
        #expect(scene.refreshes.isEmpty)
        #expect(scene.log == ["Reveal in Browse from a rail row's menu: \(Self.file) — Browse already shows its folder"])
    }

    /// **Edit in Tree, Browse in Columns with its stack parked deeper.** Revealing a file in the
    /// scope Edit's Tree shows: `focusOn` of that scope was a no-op, so Browse opened on the parked
    /// folder, the file not in it and its selection dropped. Browse's own route is a browse move
    /// back to the scope — no re-scope, no scan.
    @Test func aParkedStackDeeperThanTheFileIsBroughtBack() {
        let scene = Scene()
        scene.manager.navigatePane(isLeft: true, toCombinedPath: "Documents/Finance", drawsColumns: true)
        let file = "/c/Documents/letter.md"
        EditorRevealInBrowse.movePane(to: file, from: .header, syncManager: scene.manager,
                                      sourceRoot: Self.root, drawsColumns: true, links: [:],
                                      log: { scene.log.append($0) })
        #expect(scene.manager.paneLocation(isLeft: true, drawsColumns: true) == "Documents",
                "Browse still shows the parked folder")
        #expect(scene.manager.leftRelativePath == "Documents")
        #expect(scene.manager.ignoredPaths == ["Finance/old.md"])
        #expect(scene.refreshes.isEmpty)
        #expect(scene.log == ["Reveal in Browse from the header's file name: \(file) — Browse moves to /c/Documents"])
    }

    /// The breadcrumb's route in every other case: inside the scope a browse move, above it — or
    /// anywhere in Tree — a re-root; outside the source nothing, and a line saying so.
    @Test func revealTakesTheBreadcrumbsRouteForBrowsesMode() {
        let columns = Scene()
        EditorRevealInBrowse.movePane(to: Self.file, from: .header, syncManager: columns.manager,
                                      sourceRoot: Self.root, drawsColumns: true, links: [:], log: { _ in })
        #expect(columns.manager.leftRelativePath == "Documents")
        #expect(columns.manager.combinedRelativePath(isLeft: true) == "Documents/Finance/Tax")
        #expect(columns.refreshes.isEmpty)

        let tree = Scene()
        EditorRevealInBrowse.movePane(to: Self.file, from: .header, syncManager: tree.manager,
                                      sourceRoot: Self.root, drawsColumns: false, links: [:], log: { _ in })
        #expect(tree.manager.leftRelativePath == "Documents/Finance/Tax")
        #expect(tree.refreshes == [.leftOnly])

        let above = Scene()
        EditorRevealInBrowse.movePane(to: "/c/Other/a.md", from: .header, syncManager: above.manager,
                                      sourceRoot: Self.root, drawsColumns: true, links: [:], log: { _ in })
        #expect(above.manager.leftRelativePath == "Other")

        let outside = Scene()
        EditorRevealInBrowse.movePane(to: "/elsewhere/a.md", from: .railRow, syncManager: outside.manager,
                                      sourceRoot: Self.root, drawsColumns: true, links: [:],
                                      log: { outside.log.append($0) })
        #expect(outside.manager.leftRelativePath == "Documents")
        #expect(outside.refreshes.isEmpty)
        #expect(outside.log == ["Reveal in Browse from a rail row's menu: /elsewhere/a.md is outside the left source — Browse stays where it is"])
    }

    /// The app runs the shared act (`EditorRevealInBrowse.reveal`, whose order is
    /// `revealInBrowseFromEditLandsWithTheFileSelected`) in BROWSE's mode, with the real switch
    /// and the real debt — and each door passes its own name.
    @Test func theAppRevealsThroughBrowsesModeAndNamesTheDoor() throws {
        let body = try EditorNewFilePaneWiringTests.body(
            of: "func revealInBrowse(_ path: String, from door: EditorRevealInBrowse.Door) {",
            in: "ContentView+Editor.swift")
        #expect(body.contains("EditorRevealInBrowse.reveal("), "the app no longer runs the tested act")
        let reveal = try CallArguments(of: "EditorRevealInBrowse.reveal(", in: body.normalized)
        #expect(reveal.passes("drawsColumns", "viewMode(in: .browse, isLeft: true) == .columns"),
                "Reveal in Browse asks some other workspace's view mode")
        #expect(reveal.unlabeled == ["path"] && reveal.passes("from", "door"))
        #expect(reveal.passes("showBrowse", "{ selectedWorkspace = .browse }"), "the act does not switch to Browse")
        #expect(reveal.passes("owe", "{ owePaneSelection($0) }"), "the act owes nothing — Browse lands with no selection")
        #expect(!body.contains("focusOn(") && !body.contains("focusPane("), "Reveal re-roots again")
        #expect(try EditorRailRowMenuWiringTests.workspaceConstruction()
                    .passes("onRevealInBrowse", "{ path in revealInBrowse(path, from: .header) }"))
        #expect(try EditorRailRowMenuWiringTests.railRowActions()
                    .passes("revealInBrowse", "{ path in revealInBrowse(path, from: .railRow) }"))
    }

    /// **Reveal in Browse from Edit ends with the file selected in Browse** — the notes' promise,
    /// driven through the functions the app runs, on a real manager over a real folder: the act
    /// (`EditorRevealInBrowse.reveal`), the debt as `owePaneSelection` records it (the workspace on
    /// screen at that moment), the rule `settleOwedPaneSelection` asks with the pane's own
    /// answers, and the app's write. Columns (a browse move, listed at once) and Tree (a re-root,
    /// listed once the walk the refresh asks for lands). The file is a rail row that is NOT the
    /// open document, the case only Browse can pay; and the right pane holds a set, which the
    /// payment clears (2026-09-26). With the switch after the debt, it is Edit's and is dropped.
    @MainActor @Test(arguments: [true, false])
    func revealInBrowseFromEditLandsWithTheFileSelected(browseDrawsColumns: Bool) async throws {
        // The REAL path (`realpath`, which keeps `/private`): a walk names its nodes by it, and the
        // temporary directory is reached through the `/var` link.
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("reveal-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: "\(made)/Documents/Finance/Tax", withIntermediateDirectories: true)
        let root = try #require(realpath(made, nil).map { String(cString: $0) })
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tax = "\(root)/Documents/Finance/Tax"
        let file = "\(tax)/notes.md", open = "\(root)/Documents/letter.md"
        for path in [file, open] { try Data("x\n".utf8).write(to: URL(fileURLWithPath: path)) }

        // Edit, with its pane (Tree) on Documents and a document open there; a set in the right
        // pane. `loadTree` takes the SOURCE's root and walks the pane's folder under it, as the
        // app's refresh does.
        let manager = FileSyncManager()
        manager.focusOn(relativePath: "Documents", isLeft: true)
        var paneFolder: String { PaneLogic.fullPath(root: root, relativePath: manager.leftRelativePath) }
        await manager.loadTree(path: root, isLeft: true)
        manager.selectedRightPaths = ["/d/a.md", "/d/b.md"]
        var workspace = Workspace.editor
        var debt: ContentView.PaneSelectionDebt?

        EditorRevealInBrowse.reveal(file, from: .railRow, syncManager: manager, sourceRoot: root,
                                    drawsColumns: browseDrawsColumns, links: [:],
                                    showBrowse: { workspace = .browse },
                                    owe: { debt = .init(path: $0, document: open, workspace: workspace) },
                                    log: { _ in })
        #expect(workspace == .browse)
        #expect(debt?.workspace == .browse, "the selection was owed before the switch — it is Edit's, and Browse drops it")
        // Tree re-roots; the app's refresh walks the new folder, and the tree publish pays the debt.
        if !browseDrawsColumns { await manager.loadTree(path: root, isLeft: true) }

        let decision = ContentView.owedPaneSelection(
            owed: debt, openDocument: open, workspace: workspace,
            paneFolder: ContentView.paneFolder(treeRoot: paneFolder, browsePath: manager.leftBrowsePath,
                                               drawsColumns: browseDrawsColumns),
            paneIsCurrent: ContentView.treeIsCurrent(readAt: manager.paneTreeFolder(isLeft: true),
                                                     paneFolder: paneFolder),
            isListed: !manager.leftNodes(for: [file]).isEmpty,
            selection: manager.selectedLeftPaths,
            selectingOpens: workspace == .editor)
        #expect(decision == .select(file), "Browse did not select the revealed file: \(decision)")
        guard case .select(let path) = decision else { return }
        PaneLogic.payOwedSelection(path, state: manager, markPaid: { _ in }, markRightCleared: {})
        #expect(manager.selectedLeftPaths == [file])
        #expect(manager.selectedRightPaths.isEmpty, "the app left selections in both panes")
    }
}
