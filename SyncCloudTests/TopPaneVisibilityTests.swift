import Testing
import AppKit
import Design
import FileExplorer
@testable import SyncCloud

@Suite struct TopPaneVisibilityTests {

    // MARK: Mode & pane count

    @Test func testModePerWorkspace() {
        // Compare compares two locations; every lens scans one.
        #expect(TopPaneVisibility.mode(for: .compare) == .compare)
        for workspace in Workspace.allCases where workspace.lens != nil {
            #expect(TopPaneVisibility.mode(for: workspace) == .singleSource)
        }
    }

    /// Browse is single-source, with no mode of its own: a dozen sites read `.singleSource` as
    /// "there is only one tree", and a `.browse` mode would have them offer Copy to the hidden pane,
    /// drive it with ⌥-click and stop clearing the selection on Escape.
    @Test func testBrowseIsSingleSourceLikeTheLenses() {
        #expect(TopPaneVisibility.mode(for: .browse) == .singleSource)
        #expect(Workspace.browse.lens == nil, "Browse has no lens — this loop cannot cover it")
    }

    // MARK: Defaults

    /// Every workspace that shows files starts with its pane up; Editor, which shows a document and
    /// opens files from its rail, does not. Listed by name rather than derived, so changing this is
    /// a decision somebody writes down.
    @Test func onlyTheEditorStartsWithItsPaneCollapsed() {
        let startCollapsed: Set<Workspace> = [.editor]
        for workspace in Workspace.allCases {
            let expected = startCollapsed.contains(workspace)
            #expect(TopPaneVisibility.defaultPanesHidden(for: workspace) == expected,
                    "\(workspace.title) starts \(expected ? "expanded" : "collapsed") — the opposite of the rule this test states")
            #expect(TopPaneVisibility.panesHidden(for: workspace, override: nil) == expected)
        }
        // The control: if this became "all of them" or "none of them", the loop above would still
        // pass while saying nothing.
        #expect(!startCollapsed.isEmpty && startCollapsed.count < Workspace.allCases.count)
    }

    // MARK: The editor's file rail

    /// Folded by hand withholds the list as Expand does, through its own bit, so a hand fold does
    /// not read as Expand and light Files in the header. Every combination: drawn only with the
    /// pane folded and both rail bits clear. Dropping `!railFolded` from the rule must fail the
    /// folded rows.
    @Test func eitherRailBitWithholdsTheListAndOnlyAFoldedPaneDrawsIt() {
        for pane in [false, true] {
            for hidden in [false, true] {
                for folded in [false, true] {
                    #expect(TopPaneVisibility.editorRailIsDrawn(paneHidden: pane, railHidden: hidden, railFolded: folded)
                                == (pane && !hidden && !folded),
                            "pane hidden=\(pane), Expand's bit=\(hidden), folded=\(folded)")
                }
            }
        }
    }

    /// A new window opens with the list folded, so the quiet layout is sidebar · strip · text.
    /// Pinned because the default is the decision.
    @Test func theListStartsFolded() {
        #expect(TopPaneVisibility.editorRailFoldedDefault)
        #expect(TopPaneVisibility.editorRailFoldedKey != TopPaneVisibility.editorRailHiddenKey,
                "the hand fold shares Expand's key — folding the list would light Expand")
    }

    // MARK: The sidebar beside Edit's folded pane, and Expand

    /// Only Edit's sidebar outlives a collapsed pane. Listed by name: in a lens a click would
    /// re-root a pane nobody can see, so a workspace joining this set is a decision to write down.
    @Test func onlyEditsSidebarOutlivesACollapsedPane() {
        for workspace in Workspace.allCases {
            #expect(workspace.folderSidebarOutlivesPaneCollapse == (workspace == .editor),
                    "\(workspace.title) answers \(workspace.folderSidebarOutlivesPaneCollapse)")
        }
    }

    /// Every starting state, as the person sees it: list hidden or not, pane folded or not,
    /// sidebar showing or not. The record bits start clear, as in a state reached by hand.
    static let startingStates: [(rail: Bool, pane: Bool, sidebar: Bool)] =
        [false, true].flatMap { r in [false, true].flatMap { p in [false, true].map { (r, p, $0) } } }

    /// Leaving gives back exactly what was showing, from every state Expand can be entered from
    /// (list hidden with pane folded is already on; see below). The sidebar is read as drawn: the
    /// preference, less Expand's hold. Dropping the pane restore from `leave` must fail every state
    /// with the pane open.
    @Test(arguments: startingStates.filter { !($0.rail && $0.pane) })
    func leavingExpandGivesBackExactlyWhatWasShowing(start: (rail: Bool, pane: Bool, sidebar: Bool)) {
        let before = EditorExpand(railHidden: start.rail, paneFolded: start.pane,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        var expand = before
        expand.enter(sidebarShowing: start.sidebar)
        #expect(expand.isOn)
        #expect(start.sidebar ? expand.hidesSidebar : true, "the sidebar was left on screen")
        expand.leave()
        #expect(!expand.isOn)
        #expect(expand.paneFolded == start.pane, "the pane came back \(expand.paneFolded ? "folded" : "open")")
        #expect(!expand.hidesSidebar, "Expand still holds the sidebar off after leaving")
        // The rail comes back whatever it was: leaving Expand is the request for the list.
        #expect(!expand.railHidden)
        #expect(!expand.sidebarPutAway && !expand.paneFoldedByExpand, "a spent record was kept")
    }

    /// A second entry, such as a launch from Finder into a window already expanded, keeps the
    /// record. Reading the state afresh would see Expand's own work (pane folded, sidebar held) and
    /// owe nothing. Dropping the `isOn` branch must leave the pane folded on leaving.
    @Test func enteringAgainKeepsWhatTheFirstEntryOwes() {
        var expand = EditorExpand(railHidden: false, paneFolded: false,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        expand.enter(sidebarShowing: true)
        expand.enter(sidebarShowing: false)
        expand.leave()
        #expect(!expand.paneFolded, "the pane Expand folded was not given back")
    }

    /// ⌃⌘S while expanded shows the sidebar and leaves Expand on; a second entry then puts it away
    /// again and still gives it back.
    @Test func showingTheSidebarByHandLiftsOnlyTheHold() {
        var expand = EditorExpand(railHidden: false, paneFolded: true,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        expand.enter(sidebarShowing: true)
        #expect(expand.hidesSidebar)
        expand.sidebarShownByHand()
        #expect(!expand.hidesSidebar && expand.isOn)
        expand.enter(sidebarShowing: true)
        #expect(expand.hidesSidebar, "a sidebar shown by hand survived a second entry")
    }

    /// Opening the pane from its spine ends Expand completely and spends the record. The sidebar
    /// comes back with the pane and the rail bit goes too, so a later fold from the pane's header
    /// gives the ordinary folded layout (the Text Files list beside the text) rather than
    /// re-lighting Expand. Keeping the rail bit in `paneOpenedByHand` must fail this.
    @Test(arguments: [false, true])
    func openingThePaneByHandSpendsTheRecord(paneWasFolded: Bool) {
        var expand = EditorExpand(railHidden: false, paneFolded: paneWasFolded,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        expand.enter(sidebarShowing: true)
        expand.paneOpenedByHand()
        #expect(!expand.isOn && !expand.hidesSidebar)
        #expect(!expand.railHidden, "the rail bit survived the pane being opened by hand")
        #expect(!expand.sidebarPutAway && !expand.paneFoldedByExpand, "a spent record was kept")
        expand.paneFolded = true            // the pane header's fold, which writes only the pane
        #expect(!expand.isOn, "folding the pane again re-lit Expand")
        #expect(TopPaneVisibility.editorRailIsDrawn(paneHidden: expand.paneFolded, railHidden: expand.railHidden, railFolded: false),
                "folding the pane again did not bring the Text Files list")
        // And Expand from there starts afresh, and leaving it keeps the pane the person folded.
        expand.enter(sidebarShowing: true)
        expand.leave()
        #expect(expand.paneFolded, "leaving reopened a pane the person folded themselves")
    }

    /// The strip's "Show the text files" rung shows the text files, from either layout Expand can
    /// begin in: the list is drawn, the pane stays folded, Expand is over and its record spent. An
    /// open pane draws no list, so making `textFilesShown` reopen the pane Expand folded, as
    /// `leave()` does, must fail the open-pane start.
    @Test(arguments: [false, true])
    func theStripsTextFilesRungShowsTheListAndLeavesThePaneFolded(paneWasFolded: Bool) {
        var expand = EditorExpand(railHidden: false, paneFolded: paneWasFolded,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        expand.enter(sidebarShowing: true)
        expand.textFilesShown()
        #expect(TopPaneVisibility.editorRailIsDrawn(paneHidden: expand.paneFolded, railHidden: expand.railHidden, railFolded: false),
                "the rung did not bring the Text Files list back (pane \(expand.paneFolded ? "folded" : "open"))")
        #expect(expand.paneFolded, "the rung opened the file pane")
        #expect(!expand.isOn && !expand.hidesSidebar, "Expand is still on, or still holds the sidebar")
        #expect(!expand.sidebarPutAway && !expand.paneFoldedByExpand, "a spent record was kept")
    }

    /// The log names what moved, and only that.
    @Test func theLogNamesWhatMoved() {
        let quiet = EditorExpand(railHidden: false, paneFolded: true, sidebarPutAway: false, paneFoldedByExpand: false)
        var all = EditorExpand(railHidden: false, paneFolded: false, sidebarPutAway: false, paneFoldedByExpand: false)
        let open = all
        all.enter(sidebarShowing: true)
        #expect(EditorExpand.moved(from: open, to: all) == "the Files list, the file pane and the sidebar")
        var listOnly = quiet
        listOnly.enter(sidebarShowing: false)
        #expect(EditorExpand.moved(from: quiet, to: listOnly) == "the Files list")
        #expect(EditorExpand.moved(from: quiet, to: quiet) == "nothing")
    }

    /// The collapsed Edit row fits beside the sidebar at any width the clamp allows. The sidebar's
    /// width comes from `lensSidebarWidth`, which reserves a rail and a lens panel; Edit's
    /// collapsed row (the spine's card and the rail-and-document workspace) must not need more, or
    /// the document column is squeezed under its floor at the window minimum.
    @Test func theCollapsedEditRowFitsTheLensClamp() {
        let spineSlot = PaneLogic.railSpineWidth + LiquidGlass.cardGutter
        // The rail and its card, then the document's floor with its own card.
        let workspace = EditorLayoutMetrics.railWidth + LiquidGlass.cardGutter
            + EditorLayoutMetrics.minDocumentOnlyWidth
        let reserved = PaneLogic.minRailWidth + PaneLogic.minLensWorkspaceWidth
        #expect(spineSlot + workspace <= reserved,
                "Edit's collapsed row needs \(spineSlot + workspace)pt; the clamp leaves \(reserved)")
    }

    @Test func testOverrideWinsOnEveryWorkspace() {
        for workspace in Workspace.allCases {
            #expect(TopPaneVisibility.panesHidden(for: workspace, override: true))
            #expect(!TopPaneVisibility.panesHidden(for: workspace, override: false))
        }
    }

    // MARK: Override encoding (persistence format stores `hidden`, keyed by workspace raw value)

    @Test func testOverrideEncodeDecodeRoundTrips() {
        let map: [String: Bool] = [
            Workspace.filing.rawValue: false,
            Workspace.compare.rawValue: true,
        ]
        let decoded = TopPaneVisibility.decodeOverrides(TopPaneVisibility.encodeOverrides(map))
        #expect(decoded == map)
    }

    @Test func testEncodingIsStableAcrossCalls() {
        // Sorted keys keep the persisted string identical for identical contents, so an
        // unchanged map doesn't churn @AppStorage.
        // Six keys, so an unsorted encoding matching this by chance is 1 in 720.
        let map: [String: Bool] = ["Storage": true, "Differences": false, "Browse": true,
                                   "Edit": false, "Activity": true, "Filing": false]
        #expect(TopPaneVisibility.encodeOverrides(map)
                == #"{"Activity":true,"Browse":true,"Differences":false,"Edit":false,"Filing":false,"Storage":true}"#)
    }

    @Test func testUnknownKeysAreIgnoredNotFatal() {
        // A retired entry stays in the map but is never looked up, so it can't affect any
        // current workspace. Both examples are real retired keys.
        let raw = TopPaneVisibility.encodeOverrides(["Storage Lens": true, "Duplicates": false])
        let decoded = TopPaneVisibility.decodeOverrides(raw)
        #expect(decoded["Storage Lens"] == true)
        #expect(decoded["Duplicates"] == false)
        // The live workspaces are unaffected by either.
        #expect(!TopPaneVisibility.panesHidden(for: .filing, override: decoded[Workspace.filing.rawValue]))
    }

    /// The one-entry memo answers about the string it was handed, not the last one; serving a
    /// previous answer shows as a stuck layout with the stored value correct. A → B → A, since only
    /// coming back to a value catches a memo that never re-reads.
    @MainActor
    @Test func theOverridesMemoFollowsTheStringItIsGiven() {
        let hidden = TopPaneVisibility.encodeOverrides([Workspace.filing.rawValue: true])
        let shown = TopPaneVisibility.encodeOverrides([Workspace.filing.rawValue: false])
        #expect(hidden != shown, "the two fixtures encode identically — this scan compares nothing")

        #expect(TopPaneVisibility.overrides(in: hidden)[Workspace.filing.rawValue] == true)
        #expect(TopPaneVisibility.overrides(in: shown)[Workspace.filing.rawValue] == false,
                "the memo served the previous string's map — a written override would never take effect")
        #expect(TopPaneVisibility.overrides(in: hidden)[Workspace.filing.rawValue] == true,
                "the memo served the previous string's map on the way back")
        #expect(TopPaneVisibility.overrides(in: "") == [:],
                "an emptied key still reads as the last decoded map")
    }

    /// And it agrees with the uncached decode on every input the decoder has a special answer for,
    /// so the memo cannot become a second, kinder parser.
    @MainActor
    @Test(arguments: ["", "not json", "{\"Duplicates\":123}", "{\"Filing\":true}"])
    func theMemoAgreesWithTheUncachedDecode(raw: String) {
        #expect(TopPaneVisibility.overrides(in: raw) == TopPaneVisibility.decodeOverrides(raw))
    }

    @Test func testMalformedAndEmptyOverridesDecodeToEmptyMap() {
        #expect(TopPaneVisibility.decodeOverrides("") == [:])
        #expect(TopPaneVisibility.decodeOverrides("not json") == [:])
        #expect(TopPaneVisibility.decodeOverrides("{\"Duplicates\":123}") == [:])
    }

    @Test func testSettingOverrideAddsAndReplaces() {
        var overrides: [String: Bool] = [:]
        overrides = TopPaneVisibility.settingOverride(overrides, workspace: .filing, hidden: false)
        #expect(overrides[Workspace.filing.rawValue] == false)
        overrides = TopPaneVisibility.settingOverride(overrides, workspace: .filing, hidden: true)
        #expect(overrides[Workspace.filing.rawValue] == true)
        #expect(overrides.count == 1)
    }
}
