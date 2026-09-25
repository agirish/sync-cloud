import Testing
import Foundation
import Sync
import FileExplorer
@testable import SyncCloud

/// **The pane's selection follows the open document** (TE47) — one rule, generalised from ⌘N's
/// owed selection (TE44), for every moment a document is opened, created, revealed or shown.
///
/// Four layers, each pinned: the rule (`owedPaneSelection`, pure); what retires a debt or a reveal
/// when the user moves; the one-click open not answering the app's own write (counted in log
/// lines, through the same functions the app runs); and the wiring of every entry point, by source
/// scan, since `ContentView` cannot be built in a test. The scroll itself is FileExplorer's
/// `PaneRowRevealTests`, measured in hosted panes.
///
/// **Local-only**, like every suite in this target: CI runs package tests alone.
@MainActor
@Suite struct EditorPaneFollowsDocumentTests {

    typealias Debt = ContentView.PaneSelectionDebt

    static let folder = "/Users/me/Documents/Finance"
    static let file = "/Users/me/Documents/Finance/Test.md"
    static let other = "/Users/me/Documents/Finance/Other.md"

    /// The one positive case's inputs; every case below changes one of them.
    private func decide(owed: Debt?? = nil, openDocument: String?? = nil, paneFolder: String? = nil,
                        paneIsCurrent: Bool = true, isListed: Bool = true,
                        selection: Set<String> = [], selectingOpens: Bool = true)
    -> ContentView.OwedPaneSelection {
        ContentView.owedPaneSelection(
            owed: owed ?? Debt(path: Self.file, document: Self.file),
            openDocument: openDocument ?? Self.file,
            paneFolder: paneFolder ?? Self.folder,
            paneIsCurrent: paneIsCurrent, isListed: isListed,
            selection: selection, selectingOpens: selectingOpens)
    }

    // MARK: The rule

    /// The control for every case below.
    @Test func theOpenDocumentIsSelectedOnceThePaneListsIt() {
        #expect(decide() == .select(Self.file))
    }

    /// Not listed yet — a re-read not published, a shallow first paint, a column still grafting —
    /// or listed only in a tree read for the folder the pane has just LEFT: the debt stands.
    @Test func notListedOrNotCurrentWaits() {
        #expect(decide(isListed: false) == .wait)
        #expect(decide(paneIsCurrent: false) == .wait)
    }

    @Test func nothingOwedIsNothing() {
        #expect(decide(owed: .some(nil)) == .nothing)
        #expect(decide(owed: .some(nil), isListed: false) == .nothing)
    }

    /// **Another document opened since: dropped**, listed or not — in Edit a selected text file
    /// OPENS, so paying it would drag the reader back.
    @Test func anotherOpenDocumentDropsTheDebt() {
        #expect(decide(openDocument: .some(Self.other)) == .drop)
        #expect(decide(openDocument: .some(nil)) == .drop)
        #expect(decide(openDocument: .some(Self.other), isListed: false) == .drop)
        // …and where a selection opens nothing too: the document CLOSED (TE46) while ⌘N's debt
        // waited behind a folded pane. Selecting the closed file would put it back under the
        // pointer with nothing open — this guard is the only one that sees it.
        #expect(decide(openDocument: .some(nil), selectingOpens: false) == .drop)
        #expect(decide(openDocument: .some(Self.other), selectingOpens: false) == .drop)
    }

    /// **The pane shows another folder: dropped** — the user navigated it, or the hand-off left it
    /// where it was (Compare's differences list). A sibling sharing the folder's opening is another
    /// folder; the same folder with a trailing slash is not.
    @Test func aPaneInAnotherFolderDropsTheDebt() {
        #expect(decide(paneFolder: "/Users/me/Documents") == .drop)
        #expect(decide(paneFolder: "/Users/me/Documents/Finance/IN") == .drop)
        #expect(decide(paneFolder: "/Users/me/Documents/Fin") == .drop)
        #expect(decide(paneFolder: Self.folder + "/") == .select(Self.file))
    }

    /// **A multi-selection is the user's**, and is never replaced; a single selection (or none) is.
    @Test func aMultiSelectionDropsTheDebtAndASingleOneIsReplaced() {
        #expect(decide(selection: [Self.other, "/Users/me/Documents/Finance/Third.md"]) == .drop)
        #expect(decide(selection: [Self.file, Self.other]) == .drop)
        #expect(decide(selection: [Self.other]) == .select(Self.file))
        #expect(decide(selection: [Self.file]) == .select(Self.file))
    }

    /// **Reveal in Browse from a rail row can owe a file that is NOT the document.** Paid where a
    /// selection opens nothing; dropped where it would open that file in Edit.
    @Test func aDebtForAnotherFileIsPaidOnlyWhereSelectingOpensNothing() {
        let reveal = Debt(path: Self.other, document: Self.file)
        #expect(decide(owed: .some(reveal), selectingOpens: false) == .select(Self.other))
        #expect(decide(owed: .some(reveal), selectingOpens: true) == .drop)
    }

    // MARK: Never fight the user

    /// A selection change that picks something else retires the debt; one that empties the
    /// selection (navigation, a prune) does not — the debt's own guards decide that.
    @Test func aDifferentSelectionRetiresTheDebt() {
        let debt = Debt(path: Self.file, document: Self.file)
        #expect(ContentView.debtSurvives(debt, selection: []))
        #expect(ContentView.debtSurvives(debt, selection: [Self.file]))
        #expect(!ContentView.debtSurvives(debt, selection: [Self.other]))
        #expect(!ContentView.debtSurvives(debt, selection: [Self.file, Self.other]))
    }

    /// The reveal stands only while its row is the whole selection — so a later remount of the
    /// pane cannot scroll back to a file the user walked away from.
    @Test func anyOtherSelectionRetiresTheReveal() {
        let reveal = PaneRowReveal(path: Self.file, token: 1)
        #expect(ContentView.revealSurvives(reveal, selection: [Self.file]))
        #expect(!ContentView.revealSurvives(reveal, selection: []))
        #expect(!ContentView.revealSurvives(reveal, selection: [Self.other]))
        #expect(!ContentView.revealSurvives(reveal, selection: [Self.file, Self.other]))
    }

    // MARK: One open per open

    /// The app's own write is not a click: the one-click open answers every selection change
    /// except the one the app just made for the document.
    @Test func theOneClickOpenIgnoresTheAppsOwnWrite() {
        func opens(_ paid: String?) -> String? {
            ContentView.paneSelectionOpens(workspace: .editor, paneHidden: false, paths: [Self.file],
                                           isDirectory: false, paidSelection: paid)
        }
        #expect(opens(Self.file) == nil)
        #expect(opens(nil) == Self.file, "a real click must still open")
        #expect(opens(Self.other) == Self.file, "a marker for another row must not swallow this click")
    }

    /// **Counted in log lines, through the functions the app runs**: the hand-off opens the file
    /// (one "Editor opened"), the owed selection comes due under the rule, the write is marked as
    /// the app's own, and the selection change it causes reaches the one-click open — which must
    /// add nothing: no second line, no second settle.
    ///
    /// A readable file and a REFUSED one, because they are stopped by different guards: the
    /// readable one by `EditorHandOffRun.opens` (the document is already open), the refused one
    /// only by the paid marker — a refusal is let through that guard on purpose, so a second try
    /// can retry it.
    @Test(arguments: [false, true])
    func aProgrammaticSelectOpensNothingASecondTime(refused: Bool) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("te47-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(refused ? "binary.md" : "notes.md").path
        try (refused ? Data([0x61, 0x00, 0x62, 0x00]) : Data("# Notes\n".utf8))
            .write(to: URL(fileURLWithPath: path))

        let document = EditorDocument()
        var log: [String] = []
        var settles = 0
        func load(_ p: String) {
            log.append(ContentView.loadLogLine(path: p, result: EditorFileStore.load(path: p, into: document)))
        }
        // The hand-off.
        EditorHandOffRun.run(path, pane: .followsTheFile, syncManager: FileSyncManager(),
                             paneRoot: dir.path, openDocument: document.path,
                             isRefused: document.refusal != nil, paneFolder: { dir.path },
                             settle: { settles += 1; return true }, showEdit: {}, load: load,
                             log: { log.append($0) })
        // The debt comes due.
        let decision = ContentView.owedPaneSelection(
            owed: Debt(path: path, document: document.path), openDocument: document.path,
            paneFolder: dir.path, paneIsCurrent: true, isListed: true, selection: [],
            selectingOpens: true)
        #expect(decision == .select(path))
        let paid = path
        // The selection change reaches the pane's one-click open (`openSelectedPaneFileInEditor`
        // → `openInEditor`).
        if let open = ContentView.paneSelectionOpens(workspace: .editor, paneHidden: false,
                                                     paths: [path], isDirectory: false,
                                                     paidSelection: paid),
           EditorHandOffRun.opens(open, openDocument: document.path, isRefused: document.refusal != nil) {
            settles += 1
            load(open)
        }
        let loads = log.filter { $0.hasPrefix("Editor opened") || $0.hasPrefix("Editor could not open") }
        #expect(loads.count == 1, "\(loads.count) loads for one open: \(log)")
        #expect(settles == 1, "the buffer was settled \(settles) times for one open")
        #expect((document.refusal != nil) == refused, "the fixture did not produce the case it names")
    }

    // MARK: Compare

    /// **Selecting the document in Compare's left pane re-scopes nothing.** After a differences-list
    /// open the pane is Compare's; the rule may select the file there when the pane shows its
    /// folder. The write a click makes, against a real manager: the comparison's scope, history,
    /// column stack and session ignores are untouched, and no refresh is sent.
    @Test func selectingInCompareLeftPaneReScopesNothing() {
        let manager = FileSyncManager()
        manager.focusOn(relativePath: "Documents", isLeft: true)
        manager.ignoredPaths = ["Finance/old.md"]
        manager.selectedRightPaths = ["/c/Documents/x.md"]
        var refreshes = 0
        let bag = manager.refreshSubject.sink { _ in refreshes += 1 }
        defer { bag.cancel() }
        let history = manager.leftHistory
        var queued: [() -> Void] = []
        PaneLogic.applySelectionWrite(["/c/Documents/a.md"], isLeft: true, state: manager,
                                      sequencer: PaneSelectionSequencer(), schedule: { queued.append($0) })
        queued.forEach { $0() }
        #expect(manager.selectedLeftPaths == ["/c/Documents/a.md"])
        #expect(manager.leftRelativePath == "Documents")
        #expect(manager.leftHistory == history)
        #expect(manager.ignoredPaths == ["Finance/old.md"])
        #expect(refreshes == 0)
        // The one thing it does move is the one a click moves: the other pane's selection.
        #expect(manager.selectedRightPaths.isEmpty)
    }

    /// **Is the tree the pane's?** No tree is not current (the rule waits rather than selecting
    /// against nothing); the tree of the folder the pane just LEFT is not current; the pane's own
    /// folder is, however its root was spelled. What `paneTreeFolder` answers is Sync's
    /// `PaneTreeFolderTests`.
    @Test func theTreeIsCurrentOnlyForThePanesOwnFolder() {
        let home = NSHomeDirectory()
        #expect(!ContentView.treeIsCurrent(readAt: nil, paneFolder: "\(home)/Docs"))
        #expect(!ContentView.treeIsCurrent(readAt: "\(home)/Docs", paneFolder: "\(home)/Docs/Finance"))
        #expect(!ContentView.treeIsCurrent(readAt: "\(home)/Docs/Finance", paneFolder: "\(home)/Docs"))
        #expect(ContentView.treeIsCurrent(readAt: "\(home)/Docs", paneFolder: "\(home)/Docs"))
        #expect(ContentView.treeIsCurrent(readAt: "\(home)/Docs", paneFolder: "~/Docs/"))
        #expect(FileSyncManager().paneTreeFolder(isLeft: true) == nil)
    }
}

/// **Every entry point owes through the one rule** — scanned, because `ContentView` cannot be
/// built in a test and a door wired to nothing would stay green in every suite above.
@Suite struct EditorPaneFollowsDocumentWiringTests {

    static func body(_ declaration: String) throws -> String {
        try EditorNewFilePaneWiringTests.body(of: declaration, in: "ContentView+Editor.swift")
    }

    /// The door itself: the debt carries the document it was recorded against, and is tried now.
    @Test func oweRecordsTheDocumentAndTriesAtOnce() throws {
        let body = try Self.body("func owePaneSelection(_ path: String) {")
        let record = try #require(
            body.range(of: "editorPaneSelectionOwed = PaneSelectionDebt(path: path, document: editorDocument.path)"),
            "the debt no longer records the open document")
        let settle = try #require(body.range(of: "settleOwedPaneSelection()"),
                                  "the debt is not tried at once — a rail click would wait for a publish that never comes")
        #expect(record.lowerBound < settle.lowerBound)
        // One writer of a debt: every door goes through this function.
        let editor = try EditorDivergenceWiringTests.source("ContentView+Editor.swift")
        #expect(editor.components(separatedBy: "PaneSelectionDebt(path:").count == 2,
                "a second place builds a debt — a second path around the rule")
    }

    /// Each door: the rail's click, every hand-off, ⌘N, Reveal in Browse, the header's location.
    @Test func everyEntryPointOwesTheSelection() throws {
        let workspace = try Self.body("func editorWorkspace(showsRail: Bool) -> some View {")
        #expect(workspace.contains("onOpen: { entry in openInEditor(path: entry.path, selectsInPane: true) },"),
                "a rail click no longer selects the file in the pane")

        let open = try Self.body("func openInEditor(path: String, selectsInPane: Bool = false) {")
        let load = try #require(open.range(of: "loadIntoEditor(path: path)"))
        let owes = open.ranges(of: "if selectsInPane { owePaneSelection(path) }")
        #expect(owes.count == 2, "openInEditor owes on \(owes.count) of its two exits (opened, already open)")
        #expect(owes.last.map { $0.lowerBound > load.lowerBound } ?? false,
                "the selection is owed before the file is the document — the rule would drop it")

        let handOff = try Self.body("func handOffToEditor(_ path: String, pane: EditorHandOffRun.Pane = .followsTheFile) {")
        #expect(handOff.contains("if outcome != .cancelled { owePaneSelection(path) }"),
                "a hand-off no longer selects the file — or selects it after a Cancel")

        let reveal = try Self.body("func revealInBrowse(_ path: String) {")
        let browse = try #require(reveal.range(of: "selectedWorkspace = .browse"))
        let owe = try #require(reveal.range(of: "owePaneSelection(path)"),
                               "Reveal in Browse no longer lands with the file selected")
        #expect(browse.lowerBound < owe.lowerBound,
                "owed before the switch — the rule would read Edit's pane, where a selection opens")

        let created = try Self.body("func showCreatedFileInPane(_ path: String) {")
        #expect(created.contains("owePaneSelection(path)"), "⌘N no longer owes through the rule")

        let doors = try Self.body("var editorLocationDoors: EditorLocationDoors {")
        #expect(doors.contains("selectInPane: { owePaneSelection($0) })"),
                "the header's location selects around the rule")
    }

    /// **The pane's own click does NOT owe** — the row is already selected under the pointer, and a
    /// reveal would scroll it to the middle under the user's hand.
    @Test func thePanesOwnClickDoesNotOwe() throws {
        let body = try Self.body("func openSelectedPaneFileInEditor(_ paths: Set<String>) {")
        #expect(body.contains("openInEditor(path: path)"), "the pane click no longer opens")
        #expect(!body.contains("selectsInPane") && !body.contains("owePaneSelection"),
                "the pane's own click owes a selection — every click would scroll its row to the middle")
        // …and it passes the marker, once.
        #expect(body.contains("paidSelection: paid)"), "the one-click open is not told what the app wrote")
        #expect(body.contains("editorPaneSelectionPaid = nil"), "the marker is not consumed — it would swallow a later click")
    }

    /// The payment: the rule's inputs are the live ones, the write is marked before it is made,
    /// it goes through the click's setter, and a reveal follows.
    @Test func theSettleAsksTheRuleAndMarksAndRevealsItsWrite() throws {
        let body = try Self.body("func settleOwedPaneSelection() {")
        for input in ["openDocument: editorDocument.path, paneFolder: editorFolder,",
                      "paneIsCurrent: paneTreeIsCurrent,",
                      "isListed: !syncManager.leftNodes(for: [owed.path]).isEmpty,",
                      "selection: syncManager.selectedLeftPaths,",
                      "selectingOpens: selectedWorkspace == .editor && !panesHiddenForCurrentTab)"] {
            #expect(body.contains(input), "the rule is no longer handed \(input)")
        }
        let mark = try #require(body.range(of: "editorPaneSelectionPaid = path"),
                                "the app's write is not marked — the one-click open would answer it")
        let write = try #require(body.range(of: "paneSelectionBinding(isLeft: true).wrappedValue = [path]"),
                                 "the selection is not written through the click's setter")
        #expect(mark.lowerBound < write.lowerBound, "marked after the write — the change can land first")
        #expect(body.contains("paneRowReveal = PaneRowReveal(path: path, token: paneRowRevealToken)"),
                "the selected row is not revealed")
        let current = try Self.body("var paneTreeIsCurrent: Bool {")
        #expect(current.contains("Self.treeIsCurrent(readAt: syncManager.paneTreeFolder(isLeft: true), paneFolder: currentLeftPath)"),
                "the tree is compared with something other than the pane's folder")
    }

    /// The triggers, and the reveal reaching the left pane only.
    @Test func theTriggersAndTheRevealAreWired() throws {
        let content = try EditorDivergenceWiringTests.source("ContentView.swift")
        #expect(content.contains(".onChange(of: syncManager.leftPaneTree) { _, _ in settleOwedPaneSelection() }"),
                "nothing pays a debt when the pane's tree publishes")
        let start = try #require(content.range(of: ".onChange(of: syncManager.selectedLeftPaths) { _, paths in"))
        let handler = content[start.upperBound...].prefix(400)
        #expect(handler.contains("openSelectedPaneFileInEditor(paths)"))
        #expect(handler.contains("retirePaneSelectionDebts(after: paths)"),
                "a user's selection no longer retires the debt and the reveal — the app would fight them")
        #expect(content.contains("rowReveal: pane.isLeft ? paneRowReveal : nil,"),
                "the left pane is not handed the reveal")
    }
}
