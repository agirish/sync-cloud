import Testing
import Foundation
import Sync
@testable import SyncCloud

/// **A file made with ⌘N appears in the pane, selected** — TE44's wiring.
///
/// Since TE36 the open source pane IS Edit's file list and the rail is withheld beside it, so a
/// ⌘N that refreshed only the rail created the file on disk, opened it, and left the column it was
/// created in listing the folder as it had been. The fix has two halves: the pane is re-read (the
/// path every file operation takes), and the new file is selected once the re-read lists it. The
/// selection's rule was ⌘N's own and is now the one every door shares (TE47) — its cases, ⌘N's
/// among them, are `EditorPaneFollowsDocumentTests`.
///
/// **Local-only**, like every suite in this target: CI runs package tests alone.
///
/// The real call sites: `ContentView` cannot be constructed in a
/// test (its memberwise initializer is private — see `BrowseWorkspaceCallSiteTests`), so the
/// wiring is pinned at the source level, the house technique for exactly this. Every check below
/// was proved by deleting the line it names and watching it go red.
@Suite struct EditorNewFilePaneWiringTests {

    static func body(of declaration: String, in file: String,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let code = try EditorDivergenceWiringTests.source(file)
        let start = try #require(code.range(of: declaration),
                                 "\(declaration) is gone — this scan is aimed at nothing",
                                 sourceLocation: sourceLocation)
        let rest = String(code[start.upperBound...])
        let end = rest.range(of: #"\n {4}(///|(private )?(static )?(func|var|enum) )"#,
                             options: .regularExpression)
        return end.map { String(rest[..<$0.lowerBound]) } ?? rest
    }

    /// **⌘N re-reads and selects in the pane, not only the rail** — the regression itself. The
    /// rail refresh stays: collapsed, the rail is the list.
    @Test func creatingAFileShowsItInThePaneAsWellAsTheRail() throws {
        let body = try Self.body(of: "func createTextFile(named name: String) -> Bool {",
                                 in: "ContentView+Editor.swift")
        let load = try #require(body.range(of: "loadIntoEditor(path: path)"),
                                "createTextFile no longer opens the file — this slice is not the member it claims to be")
        let pane = try #require(body.range(of: "showCreatedFileInPane(path)"),
                                "⌘N no longer shows the new file in the pane — with the pane open it is Edit's only list")
        #expect(body.contains("await refreshEditorRail()"),
                "⌘N no longer refreshes the rail — the collapsed arm's list")
        // Opened first, so the document already names the file when the selection lands and the
        // pane's one-click open finds it open.
        #expect(load.lowerBound < pane.lowerBound,
                "the pane is asked to select the file before it is the open document")
    }

    /// **The re-read is targeted** (TE47 review): the walks listing the file's folder are dropped
    /// and the epoch bumped (`prepareReread`), then only the pane(s) whose folder holds the file
    /// are reloaded, compared only in Compare — where it was a file operation's whole-cache drop
    /// and a `.both` refresh with a full comparison scan, on every ⌘N and export.
    @Test func theReReadIsTargetedAtThePaneThatShowsTheFile() throws {
        let show = try Self.body(of: "func showCreatedFileInPane(_ path: String) {",
                                 in: "ContentView+Editor.swift")
        #expect(show.contains("owePaneSelection(path)"),
                "the selection is no longer owed — nothing will select the file")
        #expect(show.contains("rereadPanesAfterEditorWrite(path)"),
                "⌘N no longer re-reads the pane — the new file is not listed")
        let body = try Self.body(of: "func rereadPanesAfterEditorWrite(_ path: String) {",
                                 in: "ContentView+Editor.swift")
        let prepare = try #require(body.range(of: "syncManager.prepareReread(afterWritingAt: path)"),
                                   "the cache is not dropped — the re-read is served the pre-create walk")
        // Outside Compare the reload without its comparison; in Compare the write is paid at once,
        // which re-reads the same pane(s) and compares (`OwedComparisonTests`).
        let reload = try #require(body.range(of: "refreshAction(reloading: scope, comparing: false)"),
                                  "the pane is never re-read, or a comparison runs outside Compare")
        #expect(prepare.lowerBound < reload.lowerBound,
                "the refresh is sent before the cache is dropped — it can serve the pre-create tree")
        #expect(body.contains("Self.panesHolding(path, leftFolder: currentLeftPath,"),
                "the reload is not scoped to the pane that shows the file")
        for gone in ["prepareForcedRescan()", "refreshSubject.send(.both)"] {
            #expect(!body.contains(gone), "the re-read is a whole-cache, two-pane one again: \(gone)")
        }
    }

    /// Which panes are re-read: each whose folder holds the file, deep — and neither for a file
    /// saved outside both (an export to Downloads). The iCloud container's pane holds a file in
    /// `~/Documents` through its link (synthetic table).
    @Test func onlyThePanesThatHoldTheFileAreReRead() {
        func scope(_ path: String, left: String = "/a/Finance", right: String = "/b",
                   links: PathBoundary.LinkedFolders = [:]) -> FileSyncManager.PaneReloadScope? {
            ContentView.panesHolding(path, leftFolder: left, rightFolder: right, links: links)
        }
        #expect(scope("/a/Finance/Test.md") == .leftOnly)
        #expect(scope("/a/Finance/IN/Test.md") == .leftOnly, "a file below the pane's folder is listed by its deep walk")
        #expect(scope("/b/x/Test.pdf") == .rightOnly)
        #expect(scope("/a/Finance/Test.md", right: "/a") == .both)
        #expect(scope("/Users/me/Downloads/Test.pdf") == nil, "an export saved outside both panes re-read them")
        #expect(scope("/a/Fin/Test.md") == nil, "a sibling sharing the folder's opening is another folder")
        let links: PathBoundary.LinkedFolders = ["/c": ["Documents": "/h/Documents"]]
        #expect(scope("/h/Documents/Finance/Test.md", left: "/c", links: links) == .leftOnly)
    }

    /// **Export as PDF adds a file to the folder too**, and refreshed only the rail for the same
    /// reason ⌘N did — so with the pane open the exported PDF was not listed either.
    @Test func exportingAPDFReReadsThePaneToo() throws {
        let body = try Self.body(of: "func exportEditorDocumentAsPDF() {", in: "EditorPrinting.swift")
        let write = try #require(body.range(of: "try EditorFileStore.write(data, toPath: url.path)"),
                                 "the export no longer writes — this slice is not the member it claims to be")
        let reread = try #require(body.range(of: "rereadPanesAfterEditorWrite(url.path)"),
                                  "the export no longer re-reads the pane — the PDF is not listed beside the document")
        #expect(write.lowerBound < reread.lowerBound, "the pane is re-read before the PDF exists")
    }

    /// The debt is paid on the tree publish, under the rule — and NOT through the setter a click
    /// uses, whose Compare-with pick, focus move and surface claim are a click's (TE47 review).
    @Test func theOwedSelectionIsPaidOnPublishAsTheAppsOwnWrite() throws {
        let content = try EditorDivergenceWiringTests.source("ContentView.swift")
        #expect(content.contains(".onChange(of: syncManager.leftPaneTree) { _, _ in settleOwedPaneSelection() }"),
                "nothing pays the owed selection when the pane's tree publishes")
        let body = try Self.body(of: "func settleOwedPaneSelection() {", in: "ContentView+Editor.swift")
        #expect(body.contains("Self.owedPaneSelection("),
                "the settle no longer asks the tested rule")
        #expect(body.contains("PaneLogic.payOwedSelection(path, state: syncManager,"),
                "the selection is not written as the app's own write")
        #expect(!body.contains("paneSelectionBinding"),
                "the app's write goes through the click's setter — it would resolve a Compare-with pick")
        #expect(body.contains("openDocument: editorDocument.path"),
                "the rule is not told which document is open — it could drag the reader back")
    }

    /// **Exactly one "Editor opened" per create.** Selecting a text file in Edit's open pane opens
    /// it through `openInEditor`; that is a no-op here only because its first guard returns for
    /// the path already open. Pinned so that guard cannot be loosened without this going red.
    @Test func selectingTheOpenDocumentDoesNotOpenItAgain() throws {
        let body = try Self.body(of: "func openInEditor(path: String, selectsInPane: Bool = false) {",
                                 in: "ContentView+Editor.swift")
        let guardLine = try #require(
            body.range(of: "guard EditorHandOffRun.opens(path, openDocument: editorDocument.path,"),
            "openInEditor no longer returns early for the open document — a ⌘N would open the file twice")
        let load = try #require(body.range(of: "loadIntoEditor(path: path)"))
        #expect(guardLine.lowerBound < load.lowerBound)
        // …and the guard it asks is the one that returns for the open document.
        #expect(!EditorHandOffRun.opens("/r/a.md", openDocument: "/r/a.md", isRefused: false),
                "the shared guard lets the open document through — a programmatic select would reopen it")
    }
}
