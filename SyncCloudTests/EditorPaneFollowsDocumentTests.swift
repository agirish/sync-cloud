import Testing
import Foundation
import Sync
import FileExplorer
@testable import SyncCloud

/// The pane's selection follows the open document, by one rule for every open, create, reveal or
/// show. Four layers: the rule (`owedPaneSelection`, pure); what retires a debt or reveal when the
/// user moves; the one-click open not answering the app's own write (counted in log lines); and
/// the wiring of every entry point, by source scan, since `ContentView` can't be built in a test.
/// The scroll itself is FileExplorer's `PaneRowRevealTests`.
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
                        companionsListed: Set<String> = [],
                        selection: Set<String> = [],
                        selectingOpens: Bool = true)
    -> ContentView.OwedPaneSelection {
        ContentView.owedPaneSelection(
            owed: owed ?? Debt(path: Self.file, document: Self.file, workspace: .editor),
            openDocument: openDocument ?? Self.file,
            workspace: workspace,
            paneFolder: paneFolder ?? Self.folder,
            paneIsCurrent: paneIsCurrent, isListed: isListed,
            companionsListed: companionsListed,
            selection: selection,
            selectingOpens: selectingOpens)
    }

    // MARK: The rule

    /// The control for every case below.
    @Test func theOpenDocumentIsSelectedOnceThePaneListsIt() {
        #expect(decide() == .select(Self.file))
    }

    /// Not listed yet (a re-read not published, a shallow first paint, a column still grafting), or
    /// listed only in a tree read for the folder the pane has just left: the debt stands.
    @Test func notListedOrNotCurrentWaits() {
        #expect(decide(isListed: false) == .wait)
        #expect(decide(paneIsCurrent: false) == .wait)
    }

    @Test func nothingOwedIsNothing() {
        #expect(decide(owed: .some(nil)) == .nothing)
        #expect(decide(owed: .some(nil), isListed: false) == .nothing)
    }

    /// Another document opened since: dropped, listed or not. In Edit a selected text file opens,
    /// so paying the debt would drag the reader back.
    @Test func anotherOpenDocumentDropsTheDebt() {
        #expect(decide(openDocument: .some(Self.other)) == .drop(.anotherDocument))
        #expect(decide(openDocument: .some(nil)) == .drop(.anotherDocument))
        #expect(decide(openDocument: .some(Self.other), isListed: false) == .drop(.anotherDocument))
        // Also where a selection opens nothing: the document closed while ⌘N's debt waited behind a
        // folded pane. Only this guard sees it; paying would select a file with nothing open.
        #expect(decide(openDocument: .some(nil), selectingOpens: false) == .drop(.anotherDocument))
        #expect(decide(openDocument: .some(Self.other), selectingOpens: false) == .drop(.anotherDocument))
    }

    /// A debt belongs to the workspace it was owed in: by the time ⌘N's re-read publishes the user
    /// may be in Compare or Browse, where paying would select over their work. Dropped, listed or
    /// not; paid in the workspace it names (Reveal in Browse owes in Browse).
    @Test func aDebtFromAnotherWorkspaceIsDropped() {
        #expect(decide(workspace: .compare) == .drop(.anotherWorkspace))
        #expect(decide(workspace: .browse) == .drop(.anotherWorkspace))
        #expect(decide(workspace: .compare, isListed: false) == .drop(.anotherWorkspace))
        let reveal = Debt(path: Self.file, document: Self.file, workspace: .browse)
        #expect(decide(owed: .some(reveal), workspace: .browse, selectingOpens: false) == .select(Self.file))
        #expect(decide(owed: .some(reveal), workspace: .editor) == .drop(.anotherWorkspace))
    }

    /// The pane shows another folder (the user navigated, or the hand-off left it in place): dropped.
    /// A sibling sharing the name prefix is another folder; a trailing slash is not.
    @Test func aPaneInAnotherFolderDropsTheDebt() {
        #expect(decide(paneFolder: "/Users/me/Documents") == .drop(.anotherFolder))
        #expect(decide(paneFolder: "/Users/me/Documents/Finance/IN") == .drop(.anotherFolder))
        #expect(decide(paneFolder: "/Users/me/Documents/Fin") == .drop(.anotherFolder))
        #expect(decide(paneFolder: Self.folder + "/") == .select(Self.file))
    }

    /// A left-pane multi-selection is the user's and never replaced; a single one (or none) is. The
    /// right pane isn't the rule's business: the payment clears it, as a left-pane click does.
    @Test func aMultiSelectionDropsTheDebtAndASingleOneIsReplaced() {
        #expect(decide(selection: [Self.other, "/Users/me/Documents/Finance/Third.md"]) == .drop(.multiSelection))
        #expect(decide(selection: [Self.file, Self.other]) == .drop(.multiSelection))
        #expect(decide(selection: [Self.other]) == .select(Self.file))
        #expect(decide(selection: [Self.file]) == .select(Self.file))
        #expect(ContentView.DropReason.multiSelection.sentence
                == "the left pane holds a selection of several items, which is the user's",
                "the drop line blames a pane the rule no longer reads")
    }

    /// Reveal in Browse from a rail row can owe a file that is not the document. Paid where a
    /// selection opens nothing; dropped where it would open that file in Edit.
    @Test func aDebtForAnotherFileIsPaidOnlyWhereSelectingOpensNothing() {
        let reveal = Debt(path: Self.other, document: Self.file, workspace: .editor)
        #expect(decide(owed: .some(reveal), selectingOpens: false) == .select(Self.other))
        #expect(decide(owed: .some(reveal), selectingOpens: true) == .drop(.wouldOpenAnotherFile))
    }

    // MARK: A PDF batch's copies

    /// A batch over three PDFs in Finance, run from Browse's left pane with the three selected:
    /// the copies it wrote beside them, and the debt its banner's Reveal in Browse owes.
    static let sources: [String] = ["a", "b", "c"].map { "\(folder)/\($0).pdf" }
    static let copies: [String] = ["a", "b", "c"].map { "\(folder)/\($0) (rotated).pdf" }
    static let batch = Debt(path: copies[0], document: file, workspace: .browse,
                            companions: Array(copies.dropFirst()), replaces: Set(sources))

    /// Every copy is selected and the first is the row the pane goes to, paid only in Browse and only
    /// once the first copy is listed. A companion the pane doesn't list is left out rather than
    /// holding the rest up.
    @Test func aBatchsRevealSelectsEveryListedCopy() {
        let listed = Set(Self.copies.dropFirst())
        #expect(decide(owed: .some(Self.batch), workspace: .browse, companionsListed: listed,
                       selectingOpens: false)
                == .select(Self.copies[0], with: Array(Self.copies.dropFirst())))
        #expect(decide(owed: .some(Self.batch), workspace: .browse, companionsListed: [Self.copies[2]],
                       selectingOpens: false)
                == .select(Self.copies[0], with: [Self.copies[2]]))
        #expect(decide(owed: .some(Self.batch), workspace: .browse, isListed: false, companionsListed: listed,
                       selectingOpens: false) == .wait,
                "the batch's debt paid before the first copy — the row the pane goes to — was listed")
        // Every other guard is the one-row rule's: the pane in another folder drops it too.
        #expect(decide(owed: .some(Self.batch), workspace: .browse, paneFolder: "/Users/me/Documents",
                       companionsListed: listed, selectingOpens: false) == .drop(.anotherFolder))
    }

    /// Only the set the batch ran on is replaced; otherwise the sources' multi-selection would drop
    /// the debt and Reveal would select nothing. A set the user made since is still theirs.
    @Test func aBatchsRevealReplacesOnlyTheSetItWasRunOn() {
        let listed = Set(Self.copies.dropFirst())
        func decide(_ selection: Set<String>, owed: Debt = Self.batch) -> ContentView.OwedPaneSelection {
            self.decide(owed: .some(owed), workspace: .browse, companionsListed: listed,
                        selection: selection, selectingOpens: false)
        }
        let all = ContentView.OwedPaneSelection.select(Self.copies[0], with: Array(Self.copies.dropFirst()))
        #expect(decide(Set(Self.sources)) == all, "the batch's own sources blocked its Reveal")
        #expect(decide(Set(Self.sources.prefix(2))) == all)
        #expect(decide(Set(Self.copies)) == all, "the copies, already selected, blocked their own Reveal")
        #expect(decide(Set(Self.sources + [Self.other])) == .drop(.multiSelection),
                "a set reaching past the batch's files was replaced — it is the user's")
        #expect(decide([Self.other, "/Users/me/Documents/Finance/Third.md"]) == .drop(.multiSelection))
        // The control: the same debt with nothing to replace is the one-row rule, and drops.
        var bare = Self.batch
        bare.replaces = []
        #expect(decide(Set(Self.sources), owed: bare) == .drop(.multiSelection))
    }

    /// The companions: copies in the first copy's folder only, in batch order, once each. A batch
    /// over two folders writes copies in both, and the pane shows one.
    @Test func theCompanionsAreTheCopiesInTheFirstCopysFolder() {
        let elsewhere = "/Users/me/Documents/Tax/d (rotated).pdf"
        let nested = "\(Self.folder)/IN/e (rotated).pdf"
        #expect(EditorRevealInBrowse.companions(of: [Self.copies[0], elsewhere, Self.copies[2], nested, Self.copies[1]])
                == [Self.copies[2], Self.copies[1]])
        #expect(EditorRevealInBrowse.companions(of: [Self.copies[0], Self.copies[0], Self.copies[1], Self.copies[1]])
                == [Self.copies[1]], "a path was owed twice, or the first owed as its own companion")
        #expect(EditorRevealInBrowse.companions(of: [Self.copies[0]]).isEmpty)
        #expect(EditorRevealInBrowse.companions(of: []).isEmpty)
    }

    /// A debt with no companions is the one-row debt, and a reveal built without a selection
    /// speaks for its row alone.
    @Test func aSingleRowDebtAndRevealAreTheOneRowRule() {
        let debt = Debt(path: Self.file, document: Self.file, workspace: .editor)
        #expect(debt.rows == [Self.file] && debt.companions.isEmpty && debt.replaces.isEmpty)
        #expect(PaneRowReveal(path: Self.file, token: 1).selection == [Self.file])
        #expect(decide() == .select(Self.file, with: []))
    }

    /// The batch's debt survives only the copies themselves (and an emptied selection); its reveal
    /// stands only while the copies are the whole selection, not the first alone.
    @Test func theCopiesRetireTheirDebtAndRevealAsOneSelection() {
        #expect(ContentView.debtSurvives(Self.batch, selection: []))
        #expect(ContentView.debtSurvives(Self.batch, selection: Set(Self.copies)))
        #expect(!ContentView.debtSurvives(Self.batch, selection: [Self.copies[0]]))
        #expect(!ContentView.debtSurvives(Self.batch, selection: [Self.other]))
        let reveal = PaneRowReveal(path: Self.copies[0], token: 1, selection: Set(Self.copies))
        #expect(ContentView.revealSurvives(reveal, selection: Set(Self.copies)))
        #expect(!ContentView.revealSurvives(reveal, selection: [Self.copies[0]]))
        #expect(!ContentView.revealSurvives(reveal, selection: Set(Self.copies + [Self.other])))
        #expect(!ContentView.revealSurvives(reveal, selection: []))
    }

    // MARK: Never fight the user

    /// A selection change that picks something else retires the debt; one that empties the
    /// selection (navigation, a prune) doesn't, since the debt's own guards decide that.
    @Test func aDifferentSelectionRetiresTheDebt() {
        let debt = Debt(path: Self.file, document: Self.file, workspace: .editor)
        #expect(ContentView.debtSurvives(debt, selection: []))
        #expect(ContentView.debtSurvives(debt, selection: [Self.file]))
        #expect(!ContentView.debtSurvives(debt, selection: [Self.other]))
        #expect(!ContentView.debtSurvives(debt, selection: [Self.file, Self.other]))
    }

    /// The reveal stands only while its row is the whole selection, so a later remount of the pane
    /// can't scroll back to a file the user walked away from.
    @Test func anyOtherSelectionRetiresTheReveal() {
        let reveal = PaneRowReveal(path: Self.file, token: 1)
        #expect(ContentView.revealSurvives(reveal, selection: [Self.file]))
        #expect(!ContentView.revealSurvives(reveal, selection: []))
        #expect(!ContentView.revealSurvives(reveal, selection: [Self.other]))
        #expect(!ContentView.revealSurvives(reveal, selection: [Self.file, Self.other]))
    }

    /// The pane's report retires the reveal it answered, and only that one: a newer request (a later
    /// open, the same file opened again) keeps standing.
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

    /// One open per open, through the functions the app runs: the hand-off opens the file, the debt
    /// comes due, `PaneLogic.payOwedSelection` marks and selects, and that selection reaches the
    /// one-click open with its marker, adding no second load or settle. Run for a readable file
    /// (stopped by `EditorHandOffRun.opens`) and a refused one, stopped only by the marker.
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
                                   log: { log.append($0.text) })
        }
        EditorHandOffRun.run(path, pane: .followsTheFile, syncManager: FileSyncManager.scratch(),
                             paneRoot: dir.path, openDocument: document.path,
                             isRefused: document.refusal != nil, paneFolder: { dir.path },
                             settle: { settles += 1; return true }, endNaming: {}, showEdit: {}, load: load,
                             log: { log.append($0) })
        let decision = ContentView.owedPaneSelection(
            owed: Debt(path: path, document: document.path, workspace: .editor),
            openDocument: document.path, workspace: .editor,
            paneFolder: dir.path, paneIsCurrent: true, isListed: true, selection: [],
            selectingOpens: true)
        guard case .select(let owed, _) = decision else {
            Issue.record("the debt did not come due: \(decision)")
            return
        }
        // The app's write, as `settleOwedPaneSelection` makes it.
        let manager = FileSyncManager.scratch()
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

    /// A `PaneSelectionState` that records what each write saw, so the order of the marker and the
    /// write is observable, not only their end state.
    private final class State: PaneSelectionState {
        var paid: String?
        var paidWhenLeftWasWritten: String??
        var selectedLeftPaths: Set<String> = [] {
            didSet { paidWhenLeftWasWritten = .some(paid) }
        }
        var selectedRightPaths: Set<String> = []
        var lastSelectionSurface: SelectionSurface?
    }

    /// The payment writes the selection and nothing a click would add. The click's setter,
    /// `paneSelectionBinding`, resolves a Compare-with pick, claims the selection surface, moves focus
    /// and logs a `[click]`, which would open the pair overlay on a document. The Compare-with half is
    /// held by `EditorNewFilePaneWiringTests`.
    @Test func theAppsWriteSelectsAndClaimsNothingElse() {
        let manager = FileSyncManager.scratch()
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

    /// The other pane is cleared now (no click's `List` commit is in flight) and marked, as a
    /// left-pane click clears it. The left marker is set before the write, so the change never reaches
    /// the one-click open unmarked. A row already selected is neither rewritten nor marked, since an
    /// unconsumed marker would swallow the user's next click; an empty right pane isn't marked either.
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

        // A batch's copies, in the one write: every row selected, the marker on the first.
        let batch = State()
        batch.selectedLeftPaths = ["/c/a.pdf", "/c/b.pdf"]
        batch.selectedRightPaths = ["/c/x.md"]
        var batchCleared = 0
        PaneLogic.payOwedSelection("/c/a (rotated).pdf", with: ["/c/b (rotated).pdf"], state: batch,
                                   markPaid: { batch.paid = $0 }, markRightCleared: { batchCleared += 1 })
        #expect(batch.selectedLeftPaths == ["/c/a (rotated).pdf", "/c/b (rotated).pdf"],
                "the payment selected \(batch.selectedLeftPaths), not the batch's copies")
        #expect(batch.paidWhenLeftWasWritten == .some("/c/a (rotated).pdf"))
        #expect(batch.selectedRightPaths.isEmpty && batchCleared == 1)

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

    /// The tree is current only for the pane's own folder, however its root is spelled: no tree, or
    /// the tree of the folder just left, makes the rule wait. `paneTreeFolder` is Sync's
    /// `PaneTreeFolderTests`.
    @Test func theTreeIsCurrentOnlyForThePanesOwnFolder() {
        let home = NSHomeDirectory()
        #expect(!ContentView.treeIsCurrent(readAt: nil, paneFolder: "\(home)/Docs"))
        #expect(!ContentView.treeIsCurrent(readAt: "\(home)/Docs", paneFolder: "\(home)/Docs/Finance"))
        #expect(!ContentView.treeIsCurrent(readAt: "\(home)/Docs/Finance", paneFolder: "\(home)/Docs"))
        #expect(ContentView.treeIsCurrent(readAt: "\(home)/Docs", paneFolder: "\(home)/Docs"))
        #expect(ContentView.treeIsCurrent(readAt: "\(home)/Docs", paneFolder: "~/Docs/"))
        #expect(FileSyncManager.scratch().paneTreeFolder(isLeft: true) == nil)
    }

    /// On the iCloud source, `Documents/Finance` composes through the container's link to the real
    /// `~/Documents/Finance`, in both the pane's folder and the walk's, via `PathBoundary.join`. The
    /// rule compares strings, so a link-side spelling on either side would leave the debt waiting
    /// for ever. A synthetic link table, so it runs without iCloud.
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

/// Every entry point owes through the one rule, scanned because `ContentView` can't be built and a
/// door wired to nothing would stay green above. Arguments are checked by label
/// (``CallArguments``), other snippets whitespace-insensitively (``CodeText``).
@Suite struct EditorPaneFollowsDocumentWiringTests {
    /// The door itself: the debt carries the document it was recorded against, and is tried now.
    @Test func oweRecordsTheDocumentAndTriesAtOnce() throws {
        let body = try memberBody("func owePaneSelection(_ path: String, with companions: [String] = [], replacing replaces: Set<String> = []) {", inFile: "ContentView+Editor.swift")
        let record = try #require(body.range(of: "editorPaneSelectionOwed = PaneSelectionDebt("),
                                  "the open-document debt is no longer what is recorded")
        let debt = try call("PaneSelectionDebt(", in: body)
        // The open file, text or PDF (`EditorOpenRoute.openPath`): a PDF is the open document too.
        #expect(debt.passes("path", "path") && debt.passes("document", "editorOpenPath"),
                "the debt no longer records the open document")
        #expect(debt.passes("workspace", "selectedWorkspace"),
                "the debt no longer records the workspace it was owed in — it would pay in another")
        #expect(debt.passes("companions", "companions") && debt.passes("replaces", "replaces"),
                "the debt drops a PDF batch's copies or the set it was run on — its Reveal selects one copy, or none")
        let settle = try #require(body.range(of: "settleOwedPaneSelection()"),
                                  "the debt is not tried at once — a rail click would wait for a publish that never comes")
        #expect(record.lowerBound < settle.lowerBound)
        // One writer of a debt: every door goes through this function. Counted as code calls, so a
        // multi-line construction is one and a comment naming it is none.
        let editor = sourceCodeOnly(try macAppFile("ContentView+Editor.swift"))
        #expect(argumentLists(of: "PaneSelectionDebt(", in: editor).count == 1,
                "a second place builds a debt — a second path around the rule")
    }

    /// Each door: the rail's click, every hand-off, ⌘N, Reveal in Browse, the header's location.
    @Test func everyEntryPointOwesTheSelection() throws {
        let workspace = try memberBody("func editorWorkspace(showsRail: Bool, railWidth: CGFloat = EditorLayoutMetrics.railWidth) -> some View {", inFile: "ContentView+Editor.swift")
        #expect(try call("EditorWorkspaceView(", in: workspace)
                    .passes("onOpen", "{ entry in openInEditor(path: entry.path, selectsInPane: true) }"),
                "a rail click no longer selects the file in the pane")

        let open = try memberBody("func openInEditor(path: String, selectsInPane: Bool = false) {", inFile: "ContentView+Editor.swift")
        let load = try #require(open.range(of: "loadIntoEditor(path: path)"))
        let owes = open.ranges(of: "if selectsInPane { owePaneSelection(path) }")
        #expect(owes.count == 2, "openInEditor owes on \(owes.count) of its two exits (opened, already open)")
        #expect(owes.last.map { $0.lowerBound > load.lowerBound } ?? false,
                "the selection is owed before the file is the document — the rule would drop it")

        let handOff = try memberBody("func handOffToEditor(_ path: String, pane: EditorHandOffRun.Pane? = nil) -> EditorHandOffRun.Outcome {", inFile: "ContentView+Editor.swift")
        #expect(handOff.contains("if outcome != .cancelled { owePaneSelection(path) }"),
                "a hand-off no longer selects the file — or selects it after a Cancel")

        // Reveal in Browse's owe is `EditorHandOffRunWiringTests`'.
        let created = try memberBody("func showCreatedFileInPane(_ path: String) {", inFile: "ContentView+Editor.swift")
        #expect(created.contains("owePaneSelection(path)"), "⌘N no longer owes through the rule")

        let doors = try memberBody("var editorLocationDoors: EditorLocationDoors {", inFile: "ContentView+Editor.swift")
        #expect(try call("EditorLocationDoors(", in: doors).passes("selectInPane", "{ owePaneSelection($0) }"),
                "the header's location selects around the rule")
    }

    /// The pane's own click doesn't owe: the row is already selected under the pointer, and a reveal
    /// would scroll it to the middle under the user's hand.
    @Test func thePanesOwnClickDoesNotOwe() throws {
        let body = try memberBody("func openSelectedPaneFileInEditor(_ paths: Set<String>) {", inFile: "ContentView+Editor.swift")
        #expect(body.contains("openInEditor(path: path)"), "the pane click no longer opens")
        #expect(!body.contains("selectsInPane") && !body.contains("owePaneSelection"),
                "the pane's own click owes a selection — every click would scroll its row to the middle")
        // …and it passes the marker, once.
        #expect(try call("Self.paneSelectionOpens(", in: body).passes("paidSelection", "paid"),
                "the one-click open is not told what the app wrote")
        #expect(body.contains("editorPaneSelectionPaid = nil"), "the marker is not consumed — it would swallow a later click")
    }

    /// The payment: the rule gets the live inputs, the write is the app's own (marked, not the
    /// click's setter), a reveal follows, and both outcomes are logged at info.
    @Test func theSettleAsksTheRuleAndMarksAndRevealsItsWrite() throws {
        let body = try memberBody("func settleOwedPaneSelection() {", inFile: "ContentView+Editor.swift")
        let rule = try call("Self.owedPaneSelection(", in: body)
        for (label, value) in [("owed", "owed"),
                               ("openDocument", "editorOpenPath"), ("workspace", "selectedWorkspace"),
                               ("paneFolder", "editorFolder"),
                               ("paneIsCurrent", "paneTreeIsCurrent"),
                               ("isListed", "!syncManager.leftNodes(for: [owed.path]).isEmpty"),
                               ("companionsListed", "Set(syncManager.leftNodes(for: Set(owed.companions)).map(\\.id))"),
                               ("selection", "syncManager.selectedLeftPaths"),
                               ("selectingOpens", "selectedWorkspace == .editor && !panesHiddenForCurrentTab")] {
            #expect(rule.passes(label, value),
                    "the rule is no longer handed \(label): \(value) — it is handed \(rule.value(label) ?? "nothing")")
        }
        let pay = try call("PaneLogic.payOwedSelection(", in: body)
        #expect(pay.passes("markPaid", "{ editorPaneSelectionPaid = $0 }"),
                "the app's write is not marked — the one-click open would answer it")
        #expect(pay.passes("markRightCleared", "{ editorPaneRightClearPaid = true }"),
                "the app's clear of the right pane is not marked — it would retire a Get Info target")
        #expect(!body.contains("selectedRightPaths"),
                "the right pane's selection is read again — it may not block or drop the debt (2026-09-26)")
        #expect(body.contains("PaneLogic.payOwedSelection(path, with: companions, state: syncManager,"),
                "the selection is not written as the app's own write")
        #expect(!body.contains("paneSelectionBinding"),
                "the app's write goes through the click's setter — a Compare-with pick would resolve on it")
        #expect(body.contains("paneRowReveal = PaneRowReveal(path: path, token: paneRowRevealToken, selection: Set(companions).union([path]))"),
                "the selected rows are not revealed — or the reveal speaks for another selection than the one written")
        #expect(body.contains("Logger.shared.info(\"[pane-follow] Selected \\(path) in the left pane\""),
                "a selection on the user's behalf is not logged at info")
        #expect(body.contains("Logger.shared.info(\"[pane-follow] Not selecting \\(owed.path) in the left pane: \\(reason.sentence)\")"),
                "a dropped debt is not logged at info, with its reason")
        let current = try memberBody("var paneTreeIsCurrent: Bool {", inFile: "ContentView+Editor.swift")
        #expect(current.contains("Self.treeIsCurrent(readAt: syncManager.paneTreeFolder(isLeft: true), paneFolder: currentLeftPath)"),
                "the tree is compared with something other than the pane's folder")
    }

    /// The triggers, and the reveal reaching the left pane only.
    @Test func theTriggersAndTheRevealAreWired() throws {
        let content = try macAppFile("ContentView.swift")
        // A workspace switch asks too, so a debt owed elsewhere drops at once, with its line. Each
        // handler is read as its closure's own braces, which `declarationBody` matches.
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
        let retire = try memberBody("func retireAnsweredRowReveal(_ answered: PaneRowReveal) {", inFile: "ContentView+Editor.swift")
        #expect(retire.contains("paneRowReveal = Self.revealAfterAnswer(standing: paneRowReveal, answered: answered)"),
                "the answer is not applied through the tested rule")
    }
}
