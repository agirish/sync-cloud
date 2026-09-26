import Testing
import Foundation
import Sync
@testable import SyncCloud

/// **Compare is owed one comparison, recorded in one place and paid in one place** (2026-09-26).
///
/// Compare's list of differences is the last scan's answer, and nothing in this app watches the
/// disk. Two review fixes each added a way to make it good, and they overlapped: one recorded every
/// file the editor wrote and ran a forced rescan (the whole cache dropped, both panes re-read) on
/// arriving in Compare; the other, for ⌘N and Export as PDF, re-read only the pane holding the file
/// and owed the comparison through the lens entry's flag, paid by a bare scan with no line. Now
/// there is one record (`ContentView.OwedComparison`), fed by every save and every create, and one
/// payment (`payOwedComparisonIfNeeded`) with one line saying why.
///
/// The rule is pure and tested as such; the wiring is read off the source, since `ContentView`
/// cannot be built in a test (see `BrowseWorkspaceCallSiteTests`). Every wiring check was proved
/// by removing the line it names and watching it go red.
@Suite struct OwedComparisonTests {

    typealias Owed = ContentView.OwedComparison

    private static func written(_ paths: Set<String>, skipped: String? = nil) -> Owed {
        Owed(skipped: skipped, unreadWrites: paths)
    }

    // MARK: The rule

    /// A save under either compared folder re-reads the pane that holds it, and says which file.
    @Test func aWriteUnderEitherComparedFolderRereadsThePaneHoldingIt() {
        let left = "/c/Documents", right = "/d/Backup"
        #expect(Self.written(["/c/Documents/Tax/notes.md"]).payment(leftFolder: left, rightFolder: right, links: [:])
                == .reread(.leftOnly, because: "the editor wrote /c/Documents/Tax/notes.md since the last comparison"))
        #expect(Self.written(["/d/Backup/notes.md"]).payment(leftFolder: left, rightFolder: right, links: [:])
                == .reread(.rightOnly, because: "the editor wrote /d/Backup/notes.md since the last comparison"))
        #expect(Self.written(["/c/Documents/a.md", "/d/Backup/b.md"]).payment(leftFolder: left, rightFolder: right, links: [:])
                == .reread(.both, because: "the editor wrote /c/Documents/a.md since the last comparison"),
                "writes on both sides re-read only one pane")
    }

    /// Elsewhere — a sibling folder, a prefix that is not a folder boundary, nothing written, an
    /// unset pane — the comparison is not about it, and nothing is paid on arrival.
    @Test func aWriteElsewhereOwesNothingThere() {
        let left = "/c/Documents", right = "/d/Backup"
        #expect(Self.written(["/c/Other/notes.md"]).payment(leftFolder: left, rightFolder: right, links: [:]) == nil)
        #expect(Self.written(["/c/Documents2/notes.md"]).payment(leftFolder: left, rightFolder: right, links: [:]) == nil)
        #expect(Self.written([]).payment(leftFolder: left, rightFolder: right, links: [:]) == nil)
        #expect(Self.written(["/c/Documents/notes.md"]).payment(leftFolder: "", rightFolder: "", links: [:]) == nil,
                "an unset pane matched everything")
    }

    /// iCloud Drive's `Documents` is `~/Documents` on disk: a file the editor wrote there is under
    /// a comparison rooted at the container — the root test the re-read after ⌘N uses.
    @Test func aWriteInAFolderTheRootLinksInIsFound() {
        let links: PathBoundary.LinkedFolders = ["/c": ["Documents": "/home/Documents"]]
        #expect(Self.written(["/home/Documents/Tax/notes.md"]).payment(leftFolder: "/c", rightFolder: "/d", links: links)
                == .reread(.leftOnly, because: "the editor wrote /home/Documents/Tax/notes.md since the last comparison"))
    }

    /// Several writes name the first in path order, so the log line does not depend on set order;
    /// one outside both folders is neither named nor read.
    @Test func theFirstWriteInPathOrderIsNamed() {
        #expect(Self.written(["/c/b.md", "/c/a.md", "/x/0.md"]).payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .reread(.leftOnly, because: "the editor wrote /c/a.md since the last comparison"))
    }

    /// **A skipped comparison alone is only compared** — the lens entry's re-home, or ⌘N / Export
    /// as PDF outside Compare, whose pane was re-read at once: the trees are current, and a second
    /// walk would be the cost the targeted re-read exists to avoid. Its reason is the line.
    @Test func aSkippedComparisonAloneIsOnlyCompared() {
        let lens = Self.written([], skipped: Owed.skippedByARefresh)
        #expect(lens.payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .compare(because: "the pane moved outside Compare without a comparison"))
        let created = Self.written([], skipped: Owed.editorWrote("/c/New.md"))
        #expect(created.payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .compare(because: "the editor wrote /c/New.md since the last comparison"))
        let elsewhere = Self.written(["/x/a.md"], skipped: Owed.skippedByARefresh)
        #expect(elsewhere.payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .compare(because: Owed.skippedByARefresh), "a write elsewhere hid a skipped comparison")
        #expect(Owed().payment(leftFolder: "/c", rightFolder: "/d", links: [:]) == nil, "nothing owed paid something")
    }

    /// An unread write under a compared folder wins over a skipped comparison: its refresh
    /// compares, so it pays both — one refresh, one line.
    @Test func anUnreadWriteIsPaidWithTheSkippedComparison() {
        let both = Self.written(["/c/notes.md"], skipped: Owed.skippedByARefresh)
        #expect(both.payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .reread(.leftOnly, because: "the editor wrote /c/notes.md since the last comparison"))
    }

    /// **A write under neither compared folder is not recorded** — it cannot change the
    /// comparison, and recorded it made the next comparing refresh drop cached walks nothing in
    /// Compare shows. Under either folder (links included) it is recorded, as before; an unset
    /// pane holds nothing. Mutation: record every write and the elsewhere cases go red.
    @Test func onlyAWriteUnderAComparedFolderIsRecorded() {
        let left = "/c/Documents", right = "/d/Backup"
        var owed = Owed()
        let underLeft = owed.recordWrite("/c/Documents/Tax/notes.md", leftFolder: left, rightFolder: right, links: [:])
        let underRight = owed.recordWrite("/d/Backup/notes.md", leftFolder: left, rightFolder: right, links: [:])
        let elsewhere = owed.recordWrite("/c/Other/notes.md", leftFolder: left, rightFolder: right, links: [:])
        let sibling = owed.recordWrite("/c/Documents2/notes.md", leftFolder: left, rightFolder: right, links: [:])
        let unset = owed.recordWrite("/c/Documents/x.md", leftFolder: "", rightFolder: "", links: [:])
        #expect(underLeft && underRight, "a write under a compared folder was not recorded")
        #expect(!elsewhere, "a write outside both compared folders was recorded")
        #expect(!sibling, "a sibling sharing the folder's prefix was recorded")
        #expect(!unset, "an unset pane held the write")
        #expect(owed.unreadWrites == ["/c/Documents/Tax/notes.md", "/d/Backup/notes.md"],
                "the record holds \(owed.unreadWrites.sorted())")
        #expect(owed.skipped == nil, "recording a write touched the skipped comparison")
        let links: PathBoundary.LinkedFolders = ["/c": ["Documents": "/home/Documents"]]
        var linked = Owed()
        let throughTheLink = linked.recordWrite("/home/Documents/Tax/notes.md", leftFolder: "/c", rightFolder: "/d",
                                                links: links)
        #expect(throughTheLink && linked.unreadWrites == ["/home/Documents/Tax/notes.md"],
                "a write in the folder the root links in was not recorded")
    }

    // MARK: What feeds it

    /// Every rewrite the editor makes is recorded as an unread write: ⌘S and Save Anyway
    /// (`writeEditorDocument`), the background autosave (`writeEditorDocumentDidWrite`), and the
    /// flush on the way to another document (`settleEditorDocument`, only when it wrote) — each
    /// through `noteEditorWrote`, which records it only under a compared folder (dropping the
    /// cached walks of one elsewhere at once) and pays at once while Compare is on screen.
    @Test func everySaveIsRecordedAsAnUnreadWrite() throws {
        let save = try EditorNewFilePaneWiringTests.body(of: "private func writeEditorDocument(explicit: Bool) -> Bool {",
                                                         in: "ContentView+Editor.swift")
        let write = try #require(save.range(of: "try EditorFileStore.write(editorDocument)"))
        let note = try #require(save.range(of: "noteEditorWrote(path)"), "⌘S is not recorded")
        #expect(write.lowerBound < note.lowerBound, "recorded before the write succeeded")
        let background = try EditorNewFilePaneWiringTests.body(of: "private func writeEditorDocumentDidWrite() -> Bool {",
                                                               in: "ContentView+Editor.swift")
        #expect(background.contains("noteEditorWrote(editorDocument.path)"), "autosave is not recorded")
        let settle = try EditorNewFilePaneWiringTests.body(of: "func settleEditorDocument() -> Bool {",
                                                           in: "ContentView+Editor.swift")
        #expect(settle.contains("if case .wrote = flushed { noteEditorWrote(editorDocument.path) }"),
                "the flush on the way to another document is not recorded — or is recorded when it wrote nothing")
        let noted = try EditorNewFilePaneWiringTests.body(of: "func noteEditorWrote(_ path: String?) {",
                                                          in: "ContentView+Editor.swift")
        let record = try #require(
            noted.range(of: "guard owedComparison.recordWrite(path, leftFolder: currentLeftPath, rightFolder: currentRightPath) else {"),
            "a write is not recorded against the folders the panes are on — or not recorded at all")
        let drop = try #require(noted.range(of: "syncManager.prepareReread(afterWritingAt: path)\n            return"),
                                "a write outside the compared folders leaves its cached walks stale — a pane moved there later reads the pre-write walk")
        let pay = try #require(noted.range(of: "if selectedWorkspace == .compare { payOwedComparisonIfNeeded() }"),
                               "a write landing while Compare is on screen waits for the next visit")
        #expect(record.lowerBound < drop.lowerBound && drop.lowerBound < pay.lowerBound,
                "the unrecorded write's drop is not the guard's else — or a write elsewhere is paid")
        #expect(!noted.contains("unreadWrites.insert"), "a write is recorded without asking whether it is compared")
    }

    /// ⌘N and Export as PDF feed the same record (`rereadPanesAfterEditorWrite`, which both call —
    /// `EditorNewFilePaneWiringTests`): in Compare as a write, paid at once; elsewhere, after the
    /// re-read of the pane holding the file, as the skipped comparison — naming the file — so the
    /// payment compares without walking that pane a second time.
    @Test func createAndExportFeedTheSameRecord() throws {
        let body = try EditorNewFilePaneWiringTests.body(of: "func rereadPanesAfterEditorWrite(_ path: String) {",
                                                         in: "ContentView+Editor.swift")
        let compare = try #require(body.range(of: "if selectedWorkspace == .compare {"),
                                   "the re-read no longer tells Compare from the rest")
        let noted = try #require(body.range(of: "noteEditorWrote(path)"),
                                 "a file made in Compare is not compared at once")
        let reload = try #require(body.range(of: "refreshAction(reloading: scope, comparing: false)"),
                                  "outside Compare the pane is not re-read, or a comparison runs where nothing shows it")
        let owed = try #require(body.range(of: "owedComparison.skipped = OwedComparison.editorWrote(path)"),
                                "a file made outside Compare leaves it owing nothing — or owing an anonymous scan")
        #expect(compare.lowerBound < noted.lowerBound && noted.lowerBound < reload.lowerBound
                && reload.lowerBound < owed.lowerBound, "the two arms are not the Compare one and the rest")
        #expect(!body.contains("unreadWrites"), "a re-read file is owed a second walk")
    }

    /// A refresh that compares settles everything — reading the written files first, so its scan
    /// is not served the walk taken before the write — and one that does not takes the comparison
    /// on, keeping a more specific reason already there.
    @Test func aComparingRefreshReadsTheWritesAndSettlesTheRecord() throws {
        let refresh = try EditorNewFilePaneWiringTests.body(of: "func refreshAction(reloading: FileSyncManager.PaneReloadScope = .both,",
                                                            in: "ContentView.swift")
        let comparing = try #require(refresh.range(of: "if comparing {"))
        let read = try #require(
            refresh.range(of: "for path in owedComparison.unreadWrites { syncManager.prepareReread(afterWritingAt: path) }"),
            "a comparison settles the writes without reading them — it compares the pre-write walk")
        let clear = try #require(refresh.range(of: "owedComparison = OwedComparison()"),
                                 "a comparison leaves the record owed — a second scan for nothing")
        #expect(comparing.lowerBound < read.lowerBound && read.lowerBound < clear.lowerBound)
        #expect(refresh.contains("} else if owedComparison.skipped == nil {\n            owedComparison.skipped = OwedComparison.skippedByARefresh"),
                "a refresh that skips its comparison does not record the debt")
    }

    // MARK: Where it is paid

    /// **Arriving in Compare pays it, once, and nothing else there does** — the one call on the
    /// way in, and the only other caller the write that lands while Compare is on screen.
    @Test func arrivingInCompareIsTheOnePlaceItIsPaid() throws {
        let content = try EditorDivergenceWiringTests.source("ContentView.swift")
        let editor = try EditorDivergenceWiringTests.source("ContentView+Editor.swift")
        #expect(content.contains("if workspace == .compare { payOwedComparisonIfNeeded() }"),
                "nothing pays the debt on the way into Compare — the one workspace that displays a comparison")
        let calls = (content + editor).components(separatedBy: "payOwedComparisonIfNeeded()").count - 1
        #expect(calls == 3, "\(calls) mentions of the payment: its declaration, the arrival and a write in Compare are all there should be")
    }

    /// The payment reads the rule against the folders the panes are on, re-reads through the
    /// comparing refresh or compares alone, clears nothing until the providers resolve, and writes
    /// one line saying why.
    @Test func thePaymentAsksTheRuleAndSaysWhy() throws {
        let body = try EditorNewFilePaneWiringTests.body(of: "func payOwedComparisonIfNeeded() {", in: "ContentView.swift")
        for piece in ["owedComparison.payment(leftFolder: currentLeftPath,",
                      "rightFolder: currentRightPath) else { return }",
                      "guard refreshAction(reloading: scope) else { return }",
                      "await syncManager.scanDirectories(left: leftProvider, leftPath: currentLeftPath,",
                      "Logger.shared.info(\"Compare rescans: \\(payment.because)\")"] {
            #expect(body.contains(piece), "the payment no longer has \(piece)")
        }
        let resolve = try #require(body.range(of: "let rightProvider = settings.enabledProviders"))
        let clear = try #require(body.range(of: "owedComparison = OwedComparison()"))
        #expect(resolve.lowerBound < clear.lowerBound,
                "the debt is dropped before the providers resolve — lost during bootstrap")
        for gone in ["prepareForcedRescan()", "refreshAction()"] {
            #expect(!body.contains(gone), "the payment is a whole-cache, two-pane rescan again: \(gone)")
        }
    }
}
