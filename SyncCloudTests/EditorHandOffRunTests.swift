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
        #expect(scene.steps == ["settle", "showEdit", "load \(Self.file)"])
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
            "Editor hand-off: \(Self.file) opened without moving the left pane — it stays on /c/Documents",
        ])
        let ordinary = Scene()
        ordinary.handOff(Self.file, pane: .followsTheFile)
        #expect(ordinary.log.isEmpty, "the ordinary hand-off's line is the load's own, written by loadIntoEditor")
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
            #expect(scene.steps == ["showEdit"])
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
        var owed: [Set<String>] = []
        EditorLocationDoors(syncManager: columns.manager, drawsColumns: true, selectInPane: { owed.append($0) })
            .open(.showInPane, documentPath: Self.file, location: location)
        #expect(columns.manager.leftRelativePath == "Documents")
        #expect(columns.manager.combinedRelativePath(isLeft: true) == "Documents/Finance/Tax")
        #expect(columns.manager.ignoredPaths == ["Finance/old.md"])
        #expect(columns.refreshes.isEmpty)
        #expect(owed == [[Self.file]])

        let tree = Scene()
        EditorLocationDoors(syncManager: tree.manager, drawsColumns: false, selectInPane: { _ in })
            .open(.showInPane, documentPath: Self.file, location: location)
        #expect(tree.manager.leftRelativePath == "Documents/Finance/Tax")
        #expect(tree.manager.ignoredPaths.isEmpty)
        #expect(tree.refreshes == [.leftOnly])
    }

    // MARK: The real wiring

    /// `handOffToEditor` runs this act with the window's own pieces, and the default is the
    /// ordinary variant — so every door but the differences list keeps re-rooting.
    @Test func theAppRunsTheSharedActWithItsOwnPieces() throws {
        let body = try EditorNewFilePaneWiringTests.body(
            of: "func handOffToEditor(_ path: String, pane: EditorHandOffRun.Pane = .followsTheFile) {",
            in: "ContentView+Editor.swift")
        for piece in ["EditorHandOffRun.run(", "path, pane: pane,", "syncManager: syncManager,",
                      "openDocument: editorDocument.path, isRefused: editorDocument.refusal != nil,",
                      "paneFolder: { editorFolder },", "settle: { settleEditorDocument() },",
                      "showEdit: { if selectedWorkspace != .editor { selectedWorkspace = .editor } },",
                      "load: { loadIntoEditor(path: $0) },", "log: { Logger.shared.info($0) })"] {
            #expect(body.contains(piece), "handOffToEditor no longer hands the act \(piece)")
        }
        #expect(!body.contains("focusOn(") && !body.contains("focusPaneOnFolder("),
                "handOffToEditor moves the pane itself — the variant's decision is bypassed")
    }

    /// The differences list is the ONE `.staysPut` door; every other hand-off takes the default.
    @Test func onlyTheDifferencesListLeavesThePane() throws {
        var count = 0
        for file in ["ContentView.swift", "ContentView+Editor.swift", "ContentView+PaneTabs.swift"] {
            let source = try OpenInEditorMenuTests.macApp(file)
            count += source.components(separatedBy: "pane: .staysPut").count - 1
        }
        #expect(count == 1, "\(count) callers leave the pane where it is — expected exactly the differences list")
    }
}
