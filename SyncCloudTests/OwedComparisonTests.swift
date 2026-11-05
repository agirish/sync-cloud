import Testing
import Foundation
import Sync
@testable import SyncCloud

/// Compare is owed one comparison, recorded in one place and paid in one place. Compare's list of
/// differences is the last scan's answer, and nothing in the app watches the disk, so every save
/// and create feeds one record (`ContentView.OwedComparison`) and one payment
/// (`payOwedComparisonIfNeeded`) settles it, with one line saying why.
///
/// The rule is pure and tested as such; the wiring is read off the source, since `ContentView`
/// can't be built in a test (see `BrowseWorkspaceCallSiteTests`). Each wiring check fails when the
/// line it names is removed. Members are sliced by `EditorNewFilePaneWiringTests.body`:
/// brace-matched, comment-stripped and whitespace-insensitive, so a check spanning two lines is
/// about the code, not its indentation.
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

    /// Elsewhere (a sibling folder, a prefix that isn't a folder boundary, nothing written, an
    /// unset pane) the comparison isn't about it, and nothing is paid on arrival.
    @Test func aWriteElsewhereOwesNothingThere() {
        let left = "/c/Documents", right = "/d/Backup"
        #expect(Self.written(["/c/Other/notes.md"]).payment(leftFolder: left, rightFolder: right, links: [:]) == nil)
        #expect(Self.written(["/c/Documents2/notes.md"]).payment(leftFolder: left, rightFolder: right, links: [:]) == nil)
        #expect(Self.written([]).payment(leftFolder: left, rightFolder: right, links: [:]) == nil)
        #expect(Self.written(["/c/Documents/notes.md"]).payment(leftFolder: "", rightFolder: "", links: [:]) == nil,
                "an unset pane matched everything")
    }

    /// iCloud Drive's `Documents` is `~/Documents` on disk: a file the editor wrote there is under
    /// a comparison rooted at the container, by the same root test the re-read after ⌘N uses.
    @Test func aWriteInAFolderTheRootLinksInIsFound() {
        let links: PathBoundary.LinkedFolders = ["/c": ["Documents": "/home/Documents"]]
        #expect(Self.written(["/home/Documents/Tax/notes.md"]).payment(leftFolder: "/c", rightFolder: "/d", links: links)
                == .reread(.leftOnly, because: "the editor wrote /home/Documents/Tax/notes.md since the last comparison"))
    }

    /// And a folder symlink a pane's walk followed: a document opened below the link is saved where
    /// it leads, under no prefix of the pane's folder. The walk's record finds it; without the
    /// record, the same write is owed nothing.
    @Test func aWriteWhereAPanesWalkFollowedAFolderLinkIsFound() {
        let write = Self.written(["/t/sub/notes.md"])
        #expect(write.payment(leftFolder: "/c", rightFolder: "/d", rightLinkTargets: ["/t"], links: [:])
                == .reread(.rightOnly, because: "the editor wrote /t/sub/notes.md since the last comparison"))
        #expect(write.payment(leftFolder: "/c", rightFolder: "/d", links: [:]) == nil,
                "a write outside both folders was paid with no walk's record to place it")
    }

    /// Several writes name the first in path order, so the log line does not depend on set order;
    /// one outside both folders is neither named nor read.
    @Test func theFirstWriteInPathOrderIsNamed() {
        #expect(Self.written(["/c/b.md", "/c/a.md", "/x/0.md"]).payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .reread(.leftOnly, because: "the editor wrote /c/a.md since the last comparison"))
    }

    /// A skipped comparison alone is only compared (the lens entry's re-home, or ⌘N / Export as PDF
    /// outside Compare, whose pane was re-read at once): the trees are current, and a second walk
    /// is the cost the targeted re-read avoids. Its reason is the line.
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

    /// A refresh that compares walks every pane holding an unread write, whatever it was asked to
    /// walk: settling drops that pane's cached walk, so a pane left out would show the file as it
    /// was. A source or tab switch asks for the moved pane alone, and the write is usually under
    /// the other. A write the panes have moved off holds no pane.
    @Test func aComparingRefreshWalksEveryPaneHoldingAnUnreadWrite() {
        let left = "/c/Documents", right = "/d/Backup"
        func reason(_ owed: Owed, _ requested: FileSyncManager.PaneReloadScope) -> String? {
            owed.reasonToWalkBoth(insteadOf: requested, leftFolder: left, rightFolder: right, links: [:])
        }
        let underRight = Self.written(["/d/Backup/notes.md"])
        #expect(reason(underRight, .leftOnly) == "the editor wrote /d/Backup/notes.md since the last comparison",
                "a switch of the left pane left the right pane, which holds the write, unread")
        #expect(reason(underRight, .rightOnly) == nil)
        #expect(reason(underRight, .both) == nil)
        let underLeft = Self.written(["/c/Documents/notes.md"])
        #expect(reason(underLeft, .rightOnly) != nil, "the left pane, which holds the write, was left unread")
        #expect(reason(underLeft, .leftOnly) == nil)
        let underBoth = Self.written(["/c/Documents/a.md", "/d/Backup/b.md"])
        #expect(reason(underBoth, .leftOnly) != nil && reason(underBoth, .rightOnly) != nil)
        #expect(reason(Self.written(["/x/moved-off.md"]), .leftOnly) == nil, "a write under neither folder widened the walk")
        #expect(reason(Self.written([], skipped: Owed.skippedByARefresh), .leftOnly) == nil,
                "a skipped comparison alone widened the walk — its trees are current")
    }

    /// An unread write under a compared folder wins over a skipped comparison: its refresh
    /// compares, so it pays both, in one refresh and one line.
    @Test func anUnreadWriteIsPaidWithTheSkippedComparison() {
        let both = Self.written(["/c/notes.md"], skipped: Owed.skippedByARefresh)
        #expect(both.payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .reread(.leftOnly, because: "the editor wrote /c/notes.md since the last comparison"))
    }

    /// A write under neither compared folder is not recorded: it can't change the comparison, and
    /// recording it would make the next comparing refresh drop cached walks Compare doesn't show.
    /// Under either folder (links included) it is recorded; an unset pane holds nothing. Recording
    /// every write must fail the elsewhere cases.
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
        var followed = Owed()
        let whereTheWalkFollowed = followed.recordWrite("/t/sub/notes.md", leftFolder: "/c", rightFolder: "/d",
                                                        leftLinkTargets: ["/t"], links: [:])
        #expect(whereTheWalkFollowed && followed.unreadWrites == ["/t/sub/notes.md"],
                "a write where the left pane's walk followed a folder link was not recorded")
    }

    // MARK: What feeds it

    /// Every rewrite the editor makes is recorded as an unread write: ⌘S and Save Anyway
    /// (`writeEditorDocument`), autosave (`writeEditorDocumentDidWrite`), and the flush on the way
    /// to another document (`settleEditorDocument`, only when it wrote). Each goes through
    /// `noteEditorWrote`, which records only under a compared folder (dropping cached walks of one
    /// elsewhere at once) and pays at once while Compare is on screen.
    @Test func everySaveIsRecordedAsAnUnreadWrite() throws {
        let save = try EditorNewFilePaneWiringTests.body(of: "private func writeEditorDocument(explicit: Bool, consentedTo: EditorFileStore.Stamp? = nil) -> Bool {",
                                                         in: "ContentView+Editor.swift")
        let write = try #require(save.range(of: "try EditorFileStore.write(editorDocument, consentedTo: consentedTo)"))
        let note = try #require(save.range(of: "noteEditorWrote(path)"), "⌘S is not recorded")
        #expect(write.lowerBound < note.lowerBound, "recorded before the write succeeded")
        let background = try EditorNewFilePaneWiringTests.body(of: "private func writeEditorDocumentDidWrite() -> Bool {",
                                                               in: "ContentView+Editor.swift")
        #expect(background.contains("noteEditorWrote(editorDocument.path)"), "autosave is not recorded")
        let settle = try EditorNewFilePaneWiringTests.body(of: "func settleEditorDocument(asksAboutPDFWork: Bool = true, asksAboutTheOnlyCopy: Bool = true, thenRetry retry: (@MainActor () -> Void)? = nil) -> Bool {",
                                                           in: "ContentView+Editor.swift")
        #expect(settle.contains("if case .wrote = flushed { noteEditorWrote(editorDocument.path) }"),
                "the flush on the way to another document is not recorded — or is recorded when it wrote nothing")
        let noted = try EditorNewFilePaneWiringTests.body(of: "func noteEditorWrote(_ path: String?) {",
                                                          in: "ContentView+Editor.swift")
        let record = try #require(noted.range(of: "guard owedComparison.recordWrite("),
                                  "a write is not recorded at all")
        let recorded = try CallArguments(of: "owedComparison.recordWrite(", in: noted.normalized)
        #expect(recorded.unlabeled == ["path"] && recorded.passes("leftFolder", "currentLeftPath")
                && recorded.passes("rightFolder", "currentRightPath"),
                "a write is not recorded against the folders the panes are on")
        #expect(recorded.passes("leftLinkTargets", "syncManager.leftTreeLinkTargets")
                && recorded.passes("rightLinkTargets", "syncManager.rightTreeLinkTargets"),
                "a write is recorded without the panes' walks' folder links — one saved where a link leads is owed nothing")
        let drop = try #require(noted.range(of: "syncManager.prepareReread(afterWritingAt: path)\n            return"),
                                "a write outside the compared folders leaves its cached walks stale — a pane moved there later reads the pre-write walk")
        let pay = try #require(noted.range(of: "if selectedWorkspace == .compare { payOwedComparisonIfNeeded() }"),
                               "a write landing while Compare is on screen waits for the next visit")
        #expect(record.lowerBound < drop.lowerBound && drop.lowerBound < pay.lowerBound,
                "the unrecorded write's drop is not the guard's else — or a write elsewhere is paid")
        #expect(!noted.contains("unreadWrites.insert"), "a write is recorded without asking whether it is compared")
    }

    /// ⌘N and Export as PDF feed the same record through `rereadPanesAfterEditorWrite`
    /// (`EditorNewFilePaneWiringTests`): in Compare as a write, paid at once; elsewhere, after
    /// re-reading the pane holding the file, as a skipped comparison naming the file, so the
    /// payment compares without walking that pane again.
    @Test func createAndExportFeedTheSameRecord() throws {
        let body = try EditorNewFilePaneWiringTests.body(of: "func rereadPanesAfterEditorWrite(_ path: String, writer: String = \"Edit wrote\", comparesInCompare: Bool = true) {",
                                                         in: "ContentView+Editor.swift")
        let compare = try #require(body.range(of: "if selectedWorkspace == .compare, comparesInCompare {"),
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

    /// A refresh that compares settles everything, reading the written files first so its scan
    /// isn't served the pre-write walk. One that doesn't compare takes the debt on, keeping a more
    /// specific reason already there.
    @Test func aComparingRefreshReadsTheWritesAndSettlesTheRecord() throws {
        let refresh = try EditorNewFilePaneWiringTests.body(of: "func refreshAction(reloading: FileSyncManager.PaneReloadScope = .both,",
                                                            in: "ContentView.swift")
        let comparing = try #require(refresh.range(of: "if comparing {"))
        // The widening asks the record, so it must come before the record is cleared, and its
        // answer must be what the refresh walks.
        let widen = try #require(
            refresh.range(of: "if let because = owedComparison.reasonToWalkBoth(insteadOf: reloading,"),
            "a comparison settles writes under a pane it does not walk — that pane keeps the pre-write tree")
        #expect(refresh.contains("leftFolder: currentLeftPath, rightFolder: currentRightPath,"),
                "the widening asks about folders other than the ones the panes are on")
        #expect(refresh.contains("reloading = .both"), "the widening is asked and not acted on")
        let read = try #require(
            refresh.range(of: "for path in owedComparison.unreadWrites { syncManager.prepareReread(afterWritingAt: path) }"),
            "a comparison settles the writes without reading them — it compares the pre-write walk")
        let clear = try #require(refresh.range(of: "owedComparison = OwedComparison()"),
                                 "a comparison leaves the record owed — a second scan for nothing")
        #expect(comparing.lowerBound < widen.lowerBound && widen.lowerBound < read.lowerBound
                && read.lowerBound < clear.lowerBound)
        #expect(refresh.contains("reloading: reloading, comparing: comparing"),
                "the refresh walks something other than the widened scope")
        #expect(refresh.contains("} else if owedComparison.skipped == nil {\n            owedComparison.skipped = OwedComparison.skippedByARefresh"),
                "a refresh that skips its comparison does not record the debt")
    }

    /// The tab-switch refresh compares too, so it goes through the comparing refresh above. It walks
    /// only the moved pane, so its scan reads the other pane's kept walk; unsettled, a file the
    /// editor wrote there would be compared as it was before the write. ⌘K's and the sidebar's
    /// cross-source opens reload through it too. Checked as delegation, since a second copy of the
    /// refresh would be free to skip the settle.
    @Test func theTabSwitchRefreshIsTheComparingRefresh() throws {
        let body = try EditorNewFilePaneWiringTests.body(of: "func refreshForTabSwitch(movedPane isLeft: Bool) {",
                                                         in: "ContentView+PaneTabs.swift")
        // Whole call, closing parenthesis included: a `comparing: false` would not match it.
        #expect(body.contains("refreshAction(reloading: .movedPane(isLeft: isLeft))"),
                "the tab-switch refresh no longer goes through refreshAction's comparing refresh — nothing settles what Compare owes before its scan reads the kept walk")
        #expect(!body.contains("refreshTreesAndScan("),
                "the tab-switch refresh starts a refresh of its own beside refreshAction's — a second spelling, free to skip the settle")
    }

    // MARK: Where it is paid

    /// Arriving in Compare pays it, once: the one call on the way in, plus the write that lands
    /// while Compare is on screen, and no other caller.
    @Test func arrivingInCompareIsTheOnePlaceItIsPaid() throws {
        let content = try EditorDivergenceWiringTests.source("ContentView.swift")
        let editor = try EditorDivergenceWiringTests.source("ContentView+Editor.swift")
        #expect(CodeText(content).contains("if workspace == .compare { payOwedComparisonIfNeeded() }"),
                "nothing pays the debt on the way into Compare — the one workspace that displays a comparison")
        // Counted in code: a comment naming the payment is not a caller.
        let calls = CodeText(content + "\n" + editor).count(of: "payOwedComparisonIfNeeded()")
        #expect(calls == 3, "\(calls) mentions of the payment: its declaration, the arrival and a write in Compare are all there should be")
    }

    /// The payment reads the rule against the folders the panes are on, re-reads through the
    /// comparing refresh or compares alone, clears nothing until the providers resolve, and writes
    /// one line saying why.
    @Test func thePaymentAsksTheRuleAndSaysWhy() throws {
        let body = try EditorNewFilePaneWiringTests.body(of: "func payOwedComparisonIfNeeded() {", in: "ContentView.swift")
        let asked = try CallArguments(of: "owedComparison.payment(", in: body.normalized)
        #expect(asked.passes("leftFolder", "currentLeftPath") && asked.passes("rightFolder", "currentRightPath")
                && asked.passes("leftLinkTargets", "syncManager.leftTreeLinkTargets")
                && asked.passes("rightLinkTargets", "syncManager.rightTreeLinkTargets"),
                "the payment does not ask the rule about the folders the panes are on and the links their walks followed")
        for piece in ["guard let payment = owedComparison.payment(",
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
