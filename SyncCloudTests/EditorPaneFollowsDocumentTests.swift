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
    private func decide(owed: Debt?? = nil, openDocument: String?? = nil,
                        workspace: Workspace = .editor, paneFolder: String? = nil,
                        paneIsCurrent: Bool = true, isListed: Bool = true,
                        selection: Set<String> = [],
                        selectingOpens: Bool = true)
    -> ContentView.OwedPaneSelection {
        ContentView.owedPaneSelection(
            owed: owed ?? Debt(path: Self.file, document: Self.file, workspace: .editor),
            openDocument: openDocument ?? Self.file,
            workspace: workspace,
            paneFolder: paneFolder ?? Self.folder,
            paneIsCurrent: paneIsCurrent, isListed: isListed,
            selection: selection,
            selectingOpens: selectingOpens)
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
        #expect(decide(openDocument: .some(Self.other)) == .drop(.anotherDocument))
        #expect(decide(openDocument: .some(nil)) == .drop(.anotherDocument))
        #expect(decide(openDocument: .some(Self.other), isListed: false) == .drop(.anotherDocument))
        // …and where a selection opens nothing too: the document CLOSED (TE46) while ⌘N's debt
        // waited behind a folded pane. Selecting the closed file would put it back under the
        // pointer with nothing open — this guard is the only one that sees it.
        #expect(decide(openDocument: .some(nil), selectingOpens: false) == .drop(.anotherDocument))
        #expect(decide(openDocument: .some(Self.other), selectingOpens: false) == .drop(.anotherDocument))
    }

    /// **A debt belongs to the workspace it was owed in** (TE47 review). ⌘N's debt waits for the
    /// re-read to publish, and the user can be in Compare or Browse by then — where paying it would
    /// select over whatever they did there. Dropped, listed or not; paid in the workspace it names,
    /// whichever that is (Reveal in Browse owes in Browse).
    @Test func aDebtFromAnotherWorkspaceIsDropped() {
        #expect(decide(workspace: .compare) == .drop(.anotherWorkspace))
        #expect(decide(workspace: .browse) == .drop(.anotherWorkspace))
        #expect(decide(workspace: .compare, isListed: false) == .drop(.anotherWorkspace))
        let reveal = Debt(path: Self.file, document: Self.file, workspace: .browse)
        #expect(decide(owed: .some(reveal), workspace: .browse, selectingOpens: false) == .select(Self.file))
        #expect(decide(owed: .some(reveal), workspace: .editor) == .drop(.anotherWorkspace))
    }

    /// **The pane shows another folder: dropped** — the user navigated it, or the hand-off left it
    /// where it was (Compare's differences list). A sibling sharing the folder's opening is another
    /// folder; the same folder with a trailing slash is not.
    @Test func aPaneInAnotherFolderDropsTheDebt() {
        #expect(decide(paneFolder: "/Users/me/Documents") == .drop(.anotherFolder))
        #expect(decide(paneFolder: "/Users/me/Documents/Finance/IN") == .drop(.anotherFolder))
        #expect(decide(paneFolder: "/Users/me/Documents/Fin") == .drop(.anotherFolder))
        #expect(decide(paneFolder: Self.folder + "/") == .select(Self.file))
    }

    /// **A multi-selection in the LEFT pane is the user's**, and is never replaced; a single
    /// selection (or none) is. The RIGHT pane is not the rule's business at all — the payment
    /// clears it, one file or several, as a left-pane click does (his decision, 2026-09-26; see
    /// `theAppsWriteKeepsTheInvariantAndMarksFirst`) — so the rule is not even handed it.
    @Test func aMultiSelectionDropsTheDebtAndASingleOneIsReplaced() {
        #expect(decide(selection: [Self.other, "/Users/me/Documents/Finance/Third.md"]) == .drop(.multiSelection))
        #expect(decide(selection: [Self.file, Self.other]) == .drop(.multiSelection))
        #expect(decide(selection: [Self.other]) == .select(Self.file))
        #expect(decide(selection: [Self.file]) == .select(Self.file))
        #expect(ContentView.DropReason.multiSelection.sentence
                == "the left pane holds a selection of several items, which is the user's",
                "the drop line blames a pane the rule no longer reads")
    }

    /// **Reveal in Browse from a rail row can owe a file that is NOT the document.** Paid where a
    /// selection opens nothing; dropped where it would open that file in Edit.
    @Test func aDebtForAnotherFileIsPaidOnlyWhereSelectingOpensNothing() {
        let reveal = Debt(path: Self.other, document: Self.file, workspace: .editor)
        #expect(decide(owed: .some(reveal), selectingOpens: false) == .select(Self.other))
        #expect(decide(owed: .some(reveal), selectingOpens: true) == .drop(.wouldOpenAnotherFile))
    }

    // MARK: Never fight the user

    /// A selection change that picks something else retires the debt; one that empties the
    /// selection (navigation, a prune) does not — the debt's own guards decide that.
    @Test func aDifferentSelectionRetiresTheDebt() {
        let debt = Debt(path: Self.file, document: Self.file, workspace: .editor)
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

    /// **Answered once**: the pane's report retires the reveal it answered, and only that one — a
    /// newer request (a later open, the same file opened again) keeps standing.
    @Test func anAnsweredRevealIsRetiredAndANewerOneStands() {
        let answered = PaneRowReveal(path: Self.file, token: 1)
        #expect(ContentView.revealAfterAnswer(standing: answered, answered: answered) == nil)
        let newer = PaneRowReveal(path: Self.file, token: 2)
        #expect(ContentView.revealAfterAnswer(standing: newer, answered: answered) == newer)
        #expect(ContentView.revealAfterAnswer(standing: nil, answered: answered) == nil)
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
    /// (one "Editor opened"), the owed selection comes due under the rule, the app's write
    /// (`PaneLogic.payOwedSelection`, on a real manager) marks itself and selects, and the
    /// selection it LEFT reaches the one-click open with the marker IT set — which must add
    /// nothing: no second line, no second settle. Neither the path nor the marker is the test's
    /// own: both are read back from what the payment did.
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
        let undoStore = EditorUndoStore()
        var log: [String] = []
        var settles = 0
        func load(_ p: String) {
            // The real act `loadIntoEditor` performs, not a transcription of it.
            EditorDocumentLoad.run(path: p, document: document, undoStore: undoStore,
                                   log: { log.append($0) })
        }
        // The hand-off.
        EditorHandOffRun.run(path, pane: .followsTheFile, syncManager: FileSyncManager(),
                             paneRoot: dir.path, openDocument: document.path,
                             isRefused: document.refusal != nil, paneFolder: { dir.path },
                             settle: { settles += 1; return true }, endNaming: {}, showEdit: {}, load: load,
                             log: { log.append($0) })
        // The debt comes due.
        let decision = ContentView.owedPaneSelection(
            owed: Debt(path: path, document: document.path, workspace: .editor),
            openDocument: document.path, workspace: .editor,
            paneFolder: dir.path, paneIsCurrent: true, isListed: true, selection: [],
            selectingOpens: true)
        guard case .select(let owed) = decision else {
            Issue.record("the debt did not come due: \(decision)")
            return
        }
        // The app's write, as `settleOwedPaneSelection` makes it.
        let manager = FileSyncManager()
        var paid: String?
        PaneLogic.payOwedSelection(owed, state: manager, markPaid: { paid = $0 }, markRightCleared: {})
        // The selection change reaches the pane's one-click open (`openSelectedPaneFileInEditor`
        // → `openInEditor`), carrying the marker the write left.
        #expect(manager.selectedLeftPaths == [path], "the payment did not select the document")
        if let open = ContentView.paneSelectionOpens(workspace: .editor, paneHidden: false,
                                                     paths: manager.selectedLeftPaths,
                                                     isDirectory: false, paidSelection: paid),
           EditorHandOffRun.opens(open, openDocument: document.path, isRefused: document.refusal != nil) {
            settles += 1
            load(open)
        }
        let loads = log.filter { $0.hasPrefix("Editor opened") || $0.hasPrefix("Editor could not open") }
        #expect(loads.count == 1, "\(loads.count) loads for one open: \(log)")
        #expect(settles == 1, "the buffer was settled \(settles) times for one open")
        #expect((document.refusal != nil) == refused, "the fixture did not produce the case it names")
    }

    // MARK: The app's write is not a click

    /// A `PaneSelectionState` that records what each write saw — so the ORDER of the marker and
    /// the write is observable, not only their end state.
    private final class State: PaneSelectionState {
        var paid: String?
        var paidWhenLeftWasWritten: String??
        var selectedLeftPaths: Set<String> = [] {
            didSet { paidWhenLeftWasWritten = .some(paid) }
        }
        var selectedRightPaths: Set<String> = []
        var lastSelectionSurface: SelectionSurface?
    }

    /// **The payment writes the selection and nothing a click would add** (TE47 review). It went
    /// through `paneSelectionBinding`, which resolves a standing Compare-with pick, claims the
    /// selection surface, moves the keyboard's focus and logs a `[click]` — so opening a document
    /// in Edit with "Compare with…" armed in Browse opened the pair overlay on it. On a real
    /// manager: the left pane is selected, the surface and the focused pane are what they were, and
    /// nothing is re-scoped, re-read or re-histories. The Compare-with half is ContentView's and
    /// is held by `EditorNewFilePaneWiringTests` (the settle does not name the binding).
    @Test func theAppsWriteSelectsAndClaimsNothingElse() {
        let manager = FileSyncManager()
        manager.focusOn(relativePath: "Documents", isLeft: true)
        manager.ignoredPaths = ["Finance/old.md"]
        manager.lastSelectionSurface = .differences
        manager.noteFocusedPane(.right, because: "the test")
        var refreshes = 0
        let bag = manager.refreshSubject.sink { _ in refreshes += 1 }
        defer { bag.cancel() }
        let history = manager.leftHistory
        var paid: String?
        PaneLogic.payOwedSelection("/c/Documents/a.md", state: manager, markPaid: { paid = $0 }, markRightCleared: {})
        #expect(manager.selectedLeftPaths == ["/c/Documents/a.md"])
        #expect(paid == "/c/Documents/a.md", "the write was not marked as the app's own")
        #expect(manager.lastSelectionSurface == .differences, "the app's write claimed the selection surface")
        #expect(manager.focusedPaneSide == .right, "the app's write moved the keyboard's focus")
        #expect(manager.leftRelativePath == "Documents")
        #expect(manager.leftHistory == history)
        #expect(manager.ignoredPaths == ["Finance/old.md"])
        #expect(refreshes == 0)
    }

    /// **The other pane is cleared, whatever it holds** — one file or several — exactly as a
    /// click in the left pane clears it: the app never keeps selections in both panes (his
    /// decision, 2026-09-26; a set there used to drop the debt instead). Now, not a runloop turn
    /// later, since no click's `List` commit is in flight; and the clear is marked, so it keeps a
    /// Get Info target. And the left marker is set BEFORE the write, so the selection change can
    /// never reach the one-click open unmarked; a selection that already names the row is not
    /// rewritten, and not marked — a marker nobody consumes would swallow the user's next click on
    /// that row. Likewise an empty right pane is not "cleared", and its marker stays down.
    @Test func theAppsWriteKeepsTheInvariantAndMarksFirst() {
        for right: Set<String> in [["/c/x.md"], ["/c/x.md", "/c/y.md", "/c/z.md"]] {
            let state = State()
            state.selectedRightPaths = right
            var rightCleared = 0
            PaneLogic.payOwedSelection("/c/a.md", state: state, markPaid: { state.paid = $0 },
                                       markRightCleared: { rightCleared += 1 })
            #expect(state.selectedLeftPaths == ["/c/a.md"])
            #expect(state.selectedRightPaths.isEmpty, "both panes hold a selection (right held \(right.count))")
            #expect(rightCleared == 1, "the right pane's clear was not marked as the app's own")
            #expect(state.paidWhenLeftWasWritten == .some("/c/a.md"), "the selection was written before it was marked")
            #expect(state.lastSelectionSurface == nil)
        }

        let again = State()
        again.selectedLeftPaths = ["/c/a.md"]
        again.paidWhenLeftWasWritten = nil
        var rightCleared = 0
        PaneLogic.payOwedSelection("/c/a.md", state: again, markPaid: { again.paid = $0 },
                                   markRightCleared: { rightCleared += 1 })
        #expect(again.paid == nil, "an unchanged selection was marked — the marker would outlive its write")
        #expect(again.paidWhenLeftWasWritten == nil, "an unchanged selection was rewritten")
        #expect(rightCleared == 0, "an empty right pane was marked as cleared — the marker would swallow a real clear")
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

    /// **iCloud's linked Documents** (TE47 review): on the iCloud source, `Documents/Finance`
    /// composes through the container's link to the REAL `~/Documents/Finance` — in the pane's
    /// folder (`currentLeftPath` → `PaneLogic.fullPath` → `PathBoundary.join`) and in the folder
    /// the walk records (`focusURL` → the same `join`). The rule compares strings, so it holds
    /// only while both sides compose through `join`; the link-side spelling of the same folder is
    /// another string and would leave the debt waiting for ever. A synthetic table, so the case
    /// runs on a Mac without iCloud.
    @Test func theTreeIsCurrentForAFolderReachedThroughTheICloudLink() {
        let home = NSHomeDirectory()
        let container = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
        let links: PathBoundary.LinkedFolders = [container: ["Documents": "\(home)/Documents"]]
        let paneFolder = PathBoundary.join(root: container, relative: "Documents/Finance", links: links)
        #expect(paneFolder == "\(home)/Documents/Finance", "the link did not compose to the real folder")
        #expect(ContentView.treeIsCurrent(readAt: "\(home)/Documents/Finance", paneFolder: paneFolder))
        #expect(ContentView.treeIsCurrent(readAt: "\(home)/Documents/Finance", paneFolder: "~/Documents/Finance/"))
        #expect(!ContentView.treeIsCurrent(readAt: "\(container)/Documents/Finance", paneFolder: paneFolder),
                "the link-side spelling compared equal — the rule is no longer a string comparison, update this case")
        // The owed file sits in the real folder, and the rule's folder guard agrees.
        #expect(ContentView.owedPaneSelection(
            owed: Debt(path: "\(home)/Documents/Finance/Test.md", document: "\(home)/Documents/Finance/Test.md",
                       workspace: .editor),
            openDocument: "\(home)/Documents/Finance/Test.md", workspace: .editor,
            paneFolder: paneFolder, paneIsCurrent: true, isListed: true,
            selection: [], selectingOpens: true) == .select("\(home)/Documents/Finance/Test.md"))
    }
}

/// **Every entry point owes through the one rule** — scanned, because `ContentView` cannot be
/// built in a test and a door wired to nothing would stay green in every suite above.
///
/// **Read as code, not as layout** (2026-09-26): each argument is checked by its LABEL on the call
/// it belongs to (``CallArguments``), and every other snippet whitespace-insensitively
/// (``CodeText``) — so breaking a call over more lines, or an argument becoming the last and
/// losing its `,` to a `)`, cannot turn a check red with nothing wrong. Every check here was
/// re-run against its mutation after the change.
@Suite struct EditorPaneFollowsDocumentWiringTests {

    static func body(_ declaration: String,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> CodeText {
        try EditorNewFilePaneWiringTests.body(of: declaration, in: "ContentView+Editor.swift",
                                              sourceLocation: sourceLocation)
    }

    /// The call of `callee` inside `body`, read by label.
    static func call(_ callee: String, in body: CodeText,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> CallArguments {
        try CallArguments(of: callee, in: body.normalized, sourceLocation: sourceLocation)
    }

    /// The door itself: the debt carries the document it was recorded against, and is tried now.
    @Test func oweRecordsTheDocumentAndTriesAtOnce() throws {
        let body = try Self.body("func owePaneSelection(_ path: String) {")
        let record = try #require(body.range(of: "editorPaneSelectionOwed = PaneSelectionDebt("),
                                  "the open-document debt is no longer what is recorded")
        let debt = try Self.call("PaneSelectionDebt(", in: body)
        #expect(debt.passes("path", "path") && debt.passes("document", "editorDocument.path"),
                "the debt no longer records the open document")
        #expect(debt.passes("workspace", "selectedWorkspace"),
                "the debt no longer records the workspace it was owed in — it would pay in another")
        let settle = try #require(body.range(of: "settleOwedPaneSelection()"),
                                  "the debt is not tried at once — a rail click would wait for a publish that never comes")
        #expect(record.lowerBound < settle.lowerBound)
        // One writer of a debt: every door goes through this function. Counted as CALLS in code —
        // a construction spread over lines is still one, a comment naming it is none.
        let editor = sourceCodeOnly(try EditorDivergenceWiringTests.source("ContentView+Editor.swift"))
        #expect(argumentLists(of: "PaneSelectionDebt(", in: editor).count == 1,
                "a second place builds a debt — a second path around the rule")
    }

    /// Each door: the rail's click, every hand-off, ⌘N, Reveal in Browse, the header's location.
    @Test func everyEntryPointOwesTheSelection() throws {
        let workspace = try Self.body("func editorWorkspace(showsRail: Bool) -> some View {")
        #expect(try Self.call("EditorWorkspaceView(", in: workspace)
                    .passes("onOpen", "{ entry in openInEditor(path: entry.path, selectsInPane: true) }"),
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

        let reveal = try Self.body("func revealInBrowse(_ path: String, from door: EditorRevealInBrowse.Door) {")
        // The order — switch, then owe — is `EditorRevealInBrowse.reveal`'s, and is measured by
        // `EditorHandOffRunTests.revealInBrowseFromEditLandsWithTheFileSelected`.
        let act = try Self.call("EditorRevealInBrowse.reveal(", in: reveal)
        #expect(act.passes("showBrowse", "{ selectedWorkspace = .browse }"))
        #expect(act.passes("owe", "{ owePaneSelection($0) }"),
                "Reveal in Browse no longer lands with the file selected")

        let created = try Self.body("func showCreatedFileInPane(_ path: String) {")
        #expect(created.contains("owePaneSelection(path)"), "⌘N no longer owes through the rule")

        let doors = try Self.body("var editorLocationDoors: EditorLocationDoors {")
        #expect(try Self.call("EditorLocationDoors(", in: doors).passes("selectInPane", "{ owePaneSelection($0) }"),
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
        #expect(try Self.call("Self.paneSelectionOpens(", in: body).passes("paidSelection", "paid"),
                "the one-click open is not told what the app wrote")
        #expect(body.contains("editorPaneSelectionPaid = nil"), "the marker is not consumed — it would swallow a later click")
    }

    /// The payment: the rule's inputs are the live ones, the write is the app's own (marked, and
    /// NOT the click's setter — see `theAppsWriteSelectsAndClaimsNothingElse`), a reveal follows,
    /// and both outcomes say so at the level the user runs at.
    @Test func theSettleAsksTheRuleAndMarksAndRevealsItsWrite() throws {
        let body = try Self.body("func settleOwedPaneSelection() {")
        let rule = try Self.call("Self.owedPaneSelection(", in: body)
        for (label, value) in [("owed", "owed"),
                               ("openDocument", "editorDocument.path"), ("workspace", "selectedWorkspace"),
                               ("paneFolder", "editorFolder"),
                               ("paneIsCurrent", "paneTreeIsCurrent"),
                               ("isListed", "!syncManager.leftNodes(for: [owed.path]).isEmpty"),
                               ("selection", "syncManager.selectedLeftPaths"),
                               ("selectingOpens", "selectedWorkspace == .editor && !panesHiddenForCurrentTab")] {
            #expect(rule.passes(label, value),
                    "the rule is no longer handed \(label): \(value) — it is handed \(rule.value(label) ?? "nothing")")
        }
        let pay = try Self.call("PaneLogic.payOwedSelection(", in: body)
        #expect(pay.passes("markPaid", "{ editorPaneSelectionPaid = $0 }"),
                "the app's write is not marked — the one-click open would answer it")
        #expect(pay.passes("markRightCleared", "{ editorPaneRightClearPaid = true }"),
                "the app's clear of the right pane is not marked — it would retire a Get Info target")
        #expect(!body.contains("selectedRightPaths"),
                "the right pane's selection is read again — it may not block or drop the debt (2026-09-26)")
        #expect(body.contains("PaneLogic.payOwedSelection(path, state: syncManager,"),
                "the selection is not written as the app's own write")
        #expect(!body.contains("paneSelectionBinding"),
                "the app's write goes through the click's setter — a Compare-with pick would resolve on it")
        #expect(body.contains("paneRowReveal = PaneRowReveal(path: path, token: paneRowRevealToken)"),
                "the selected row is not revealed")
        #expect(body.contains("Logger.shared.info(\"[pane-follow] Selected \\(path) in the left pane\")"),
                "a selection on the user's behalf is not logged at info")
        #expect(body.contains("Logger.shared.info(\"[pane-follow] Not selecting \\(owed.path) in the left pane: \\(reason.sentence)\")"),
                "a dropped debt is not logged at info, with its reason")
        let current = try Self.body("var paneTreeIsCurrent: Bool {")
        #expect(current.contains("Self.treeIsCurrent(readAt: syncManager.paneTreeFolder(isLeft: true), paneFolder: currentLeftPath)"),
                "the tree is compared with something other than the pane's folder")
    }

    /// The triggers, and the reveal reaching the left pane only.
    @Test func theTriggersAndTheRevealAreWired() throws {
        let content = try EditorDivergenceWiringTests.source("ContentView.swift")
        // A workspace switch asks too, so a debt owed elsewhere drops at once, with its line. Each
        // handler is its closure's own braces — `declarationBody` matches them — where it was a
        // 4,000- and a 400-character window, and an end found by exact indentation.
        let switchHandler = CodeText(try declarationBody(of: ".onChange(of: selectedWorkspace) { _, workspace in",
                                                         in: content))
        #expect(switchHandler.contains("settleOwedPaneSelection()"),
                "a workspace switch does not settle the owed selection — a debt from Edit would wait to pay in Compare")
        #expect(CodeText(content).contains(".onChange(of: syncManager.leftPaneTree) { _, _ in settleOwedPaneSelection() }"),
                "nothing pays a debt when the pane's tree publishes")
        let handler = CodeText(try declarationBody(of: ".onChange(of: syncManager.selectedLeftPaths) { _, paths in",
                                                   in: content))
        #expect(handler.contains("openSelectedPaneFileInEditor(paths)"))
        #expect(handler.contains("retirePaneSelectionDebts(after: paths)"),
                "a user's selection no longer retires the debt and the reveal — the app would fight them")
        let pane = try CallArguments(of: "FileTreeView(", in: sourceCodeOnly(content))
        #expect(pane.passes("rowReveal", "pane.isLeft ? paneRowReveal : nil"),
                "the left pane is not handed the reveal")
        #expect(pane.passes("onRowRevealed", "pane.isLeft ? { retireAnsweredRowReveal($0) } : nil"),
                "the pane's answer does not retire the reveal — every appearance would scroll back to it")
        let retire = try Self.body("func retireAnsweredRowReveal(_ answered: PaneRowReveal) {")
        #expect(retire.contains("paneRowReveal = Self.revealAfterAnswer(standing: paneRowReveal, answered: answered)"),
                "the answer is not applied through the tested rule")
    }
}
