import Testing
import Foundation
import Sync
@testable import SyncCloud

/// A file made with ⌘N appears in the pane, selected.
///
/// The open source pane is Edit's file list and the rail is withheld beside it, so refreshing only
/// the rail would leave the pane listing the folder without the new file. So the pane is re-read
/// (the path every file operation takes) and the new file selected once the re-read lists it, by
/// the rule every door shares; its cases, ⌘N's among them, are `EditorPaneFollowsDocumentTests`.
///
/// Local-only, like every suite in this target: CI runs package tests alone.
///
/// `ContentView` can't be constructed in a test (its memberwise initializer is private; see
/// `BrowseWorkspaceCallSiteTests`), so the wiring is pinned at the source level. Each check goes
/// red if the line it names is deleted.
@Suite struct EditorNewFilePaneWiringTests {

    /// ⌘N re-reads and selects in the pane, not only the rail. The rail refresh stays: collapsed,
    /// the rail is the list.
    @Test func creatingAFileShowsItInThePaneAsWellAsTheRail() throws {
        let body = try memberBody("func createTextFile(named name: String) -> Bool {",
                                  inFile: "ContentView+Editor.swift")
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

    /// The re-read is targeted: the walks listing the file's folder are dropped and the epoch
    /// bumped (`prepareReread`), then only the panes whose folder holds the file are reloaded,
    /// compared only in Compare, not a whole-cache drop and a `.both` refresh with a full
    /// comparison scan on every ⌘N and export.
    @Test func theReReadIsTargetedAtThePaneThatShowsTheFile() throws {
        let show = try memberBody("func showCreatedFileInPane(_ path: String) {", inFile: "ContentView+Editor.swift")
        #expect(show.contains("rereadPanesAfterEditorWrite(path)"),
                "⌘N no longer re-reads the pane — the new file is not listed")
        let body = try memberBody("func rereadPanesAfterEditorWrite(_ path: String, writer: String = \"Edit wrote\", comparesInCompare: Bool = true) {",
                                  inFile: "ContentView+Editor.swift")
        let prepare = try #require(body.range(of: "syncManager.prepareReread(afterWritingAt: path)"),
                                   "the cache is not dropped — the re-read is served the pre-create walk")
        // Outside Compare the reload without its comparison; in Compare the write is paid at once,
        // which re-reads the same pane(s) and compares (`OwedComparisonTests`).
        let reload = try #require(body.range(of: "refreshAction(reloading: scope, comparing: false)"),
                                  "the pane is never re-read, or a comparison runs outside Compare")
        #expect(prepare.lowerBound < reload.lowerBound,
                "the refresh is sent before the cache is dropped — it can serve the pre-create tree")
        let holding = try CallArguments(of: "Self.panesHolding(", in: body.normalized)
        #expect(holding.unlabeled == ["path"] && holding.passes("leftFolder", "currentLeftPath")
                && holding.passes("rightFolder", "currentRightPath"),
                "the reload is not scoped to the pane that shows the file")
        #expect(holding.passes("leftLinkTargets", "syncManager.leftTreeLinkTargets")
                && holding.passes("rightLinkTargets", "syncManager.rightTreeLinkTargets"),
                "the rule is not told where the panes' walks followed a folder link — a file there re-reads neither")
        for gone in ["prepareForcedRescan()", "refreshSubject.send(.both)"] {
            #expect(!body.contains(gone), "the re-read is a whole-cache, two-pane one again: \(gone)")
        }
    }

    /// Which panes are re-read: each whose folder holds the file, deep, and neither for a file
    /// saved outside both (an export to Downloads). The iCloud container's pane holds a file in
    /// `~/Documents` through its link, and so does a pane above the container (synthetic tables).
    /// A pane whose walk followed a folder link holds a file where the link leads, by its walk's
    /// own record, since no prefix of the pane's folder names it.
    @Test func onlyThePanesThatHoldTheFileAreReRead() {
        func scope(_ path: String, left: String = "/a/Finance", right: String = "/b",
                   leftTargets: Set<String> = [], rightTargets: Set<String> = [],
                   links: PathBoundary.LinkedFolders = [:]) -> FileSyncManager.PaneReloadScope? {
            ContentView.panesHolding(path, leftFolder: left, rightFolder: right,
                                     leftLinkTargets: leftTargets, rightLinkTargets: rightTargets, links: links)
        }
        #expect(scope("/a/Finance/Test.md") == .leftOnly)
        #expect(scope("/a/Finance/IN/Test.md") == .leftOnly, "a file below the pane's folder is listed by its deep walk")
        #expect(scope("/b/x/Test.pdf") == .rightOnly)
        #expect(scope("/a/Finance/Test.md", right: "/a") == .both)
        #expect(scope("/Users/me/Downloads/Test.pdf") == nil, "an export saved outside both panes re-read them")
        #expect(scope("/a/Fin/Test.md") == nil, "a sibling sharing the folder's opening is another folder")
        let links: PathBoundary.LinkedFolders = ["/c": ["Documents": "/h/Documents"]]
        #expect(scope("/h/Documents/Finance/Test.md", left: "/c", links: links) == .leftOnly)
        // A pane above the container lists the linked folder too: its walk meets the link below it.
        let below: PathBoundary.LinkedFolders = ["/lib/Mobile/c": ["Documents": "/h/Documents"]]
        #expect(scope("/h/Documents/Finance/Test.md", left: "/lib", links: below) == .leftOnly,
                "a pane whose walk reaches the folder through a link below its root was not re-read")
        #expect(scope("/t/sub/Test.md", leftTargets: ["/t"]) == .leftOnly,
                "a pane whose walk followed a folder link to the file's folder was not re-read")
        #expect(scope("/t/sub/Test.md", rightTargets: ["/t"]) == .rightOnly)
        #expect(scope("/t/sub/Test.md") == nil, "with no walk's record, a file outside both panes re-read one")
    }

    /// The record the rule reads is the one the walk wrote. A real pane on `R` holding `link → T`,
    /// with `T` outside it: a file written where the link leads, spelled as the pane's rows name it,
    /// is in that pane, and in neither without the walk's record of its links.
    @MainActor
    @Test func aPaneWhoseWalkFollowedAFolderLinkHoldsAFileWhereItLeads() async throws {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("synccloud-panes-holding-link-\(UUID().uuidString)")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: raw) }
        let base = URL(fileURLWithPath: try raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? raw.path)
        let r = base.appendingPathComponent("R"), t = base.appendingPathComponent("T")
        let other = base.appendingPathComponent("other")
        try fm.createDirectory(at: t.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: r, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: t.appendingPathComponent("sub/x.txt"))
        try fm.createSymbolicLink(at: r.appendingPathComponent("link"), withDestinationURL: t)

        let m = FileSyncManager.scratch()
        await m.refreshTreesAndScan(
            left: CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: r.path, type: .localFolder),
            right: CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: other.path, type: .localFolder),
            comparing: false)
        let row = try #require(m.leftNodes(for: [t.appendingPathComponent("sub/x.txt").path]).first,
                               "premise: the pane does not list the file below the link under its resolved spelling")
        let written = ((row.id as NSString).deletingLastPathComponent as NSString).appendingPathComponent("new.md")
        // Written before the rule is asked, as every caller asks after the write. The order
        // matters: the resolver takes `/private` off a temp path only when the path exists, so for
        // a file not there yet the spelling never meets the record.
        try Data().write(to: URL(fileURLWithPath: written))
        try #require(ContentView.panesHolding(written, leftFolder: r.path, rightFolder: other.path, links: [:]) == nil,
                     "premise: the pane's folder alone holds the file — nothing below is measured")
        #expect(ContentView.panesHolding(written, leftFolder: r.path, rightFolder: other.path,
                                         leftLinkTargets: m.leftTreeLinkTargets,
                                         rightLinkTargets: m.rightTreeLinkTargets, links: [:]) == .leftOnly,
                "the pane that lists the folder through its link was not found to hold the file")
    }

    /// Export as PDF adds a file to the folder too, so it re-reads the pane like ⌘N, or with the
    /// pane open the exported PDF wouldn't be listed.
    @Test func exportingAPDFReReadsThePaneToo() throws {
        let body = try memberBody("func exportEditorDocumentAsPDF() {", inFile: "EditorPrinting.swift")
        let write = try #require(body.range(of: "try EditorFileStore.write(data, toPath: url.path)"),
                                 "the export no longer writes — this slice is not the member it claims to be")
        let reread = try #require(body.range(of: "rereadPanesAfterEditorWrite(url.path)"),
                                  "the export no longer re-reads the pane — the PDF is not listed beside the document")
        #expect(write.lowerBound < reread.lowerBound, "the pane is re-read before the PDF exists")
    }

    /// Exactly one "Editor opened" per create. Selecting a text file in Edit's open pane opens it
    /// through `openInEditor`, a no-op here only because its first guard returns for the path
    /// already open. Pinned so that guard can't be loosened without this going red.
    @Test func selectingTheOpenDocumentDoesNotOpenItAgain() throws {
        let body = try memberBody("func openInEditor(path: String, selectsInPane: Bool = false) {",
                                  inFile: "ContentView+Editor.swift")
        let guardLine = try #require(
            body.range(of: "guard EditorHandOffRun.opens("),
            "openInEditor no longer returns early for the open document — a ⌘N would open the file twice")
        let opens = try CallArguments(of: "EditorHandOffRun.opens(", in: body.normalized)
        #expect(opens.unlabeled == ["path"] && opens.passes("openDocument", "editorOpenPath"),
                "the guard no longer asks about the path against the open document")
        let load = try #require(body.range(of: "loadIntoEditor(path: path)"))
        #expect(guardLine.lowerBound < load.lowerBound)
    }
}
