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
        for workspace in Workspace.lensWorkspaces {
            #expect(TopPaneVisibility.mode(for: workspace) == .singleSource)
        }
    }

    /// **Browse is single-source, and deliberately gets no mode of its own.**
    ///
    /// It is not in `lensWorkspaces`, so the loop above never reaches it — which is exactly how a
    /// third case could be added here and every existing assertion stay green. A dozen sites ask
    /// `layoutMode == .singleSource` to mean "there is only one tree", and a `.browse` case makes
    /// all of them answer no for the workspace that is most purely one tree: the difference index
    /// would stop being emptied, the row menu would offer Copy to the other provider, ⌥-click
    /// would drive the hidden right pane, and Escape would stop clearing the selection. What
    /// Browse does differently is layout, and layout is `ContentLayout`'s question.
    @Test func testBrowseIsSingleSourceLikeTheLenses() {
        #expect(TopPaneVisibility.mode(for: .browse) == .singleSource)
        #expect(TopPaneVisibility.paneCount(for: .browse) == 1)
        #expect(!Workspace.lensWorkspaces.contains(.browse), "Browse has no lens — this loop cannot cover it")
    }

    @Test func testPaneCountPerWorkspace() {
        #expect(TopPaneVisibility.paneCount(for: .compare) == 2)
        for workspace in Workspace.lensWorkspaces {
            #expect(TopPaneVisibility.paneCount(for: workspace) == 1)
        }
    }

    // MARK: Defaults

    /// **Every workspace that shows files starts with its pane up — and Editor, which shows a
    /// document, does not.**
    ///
    /// The rule the flat bar is built on — the source browser is in the same place on every
    /// workspace — is only true on first use if the rail actually starts up. That changed what
    /// `Tidy` defaulted to (its rail started collapsed), deliberately: you could not reach a lens
    /// without the lens tabs, and picking one there opened the rail, so the collapsed default
    /// described a state almost nobody saw.
    ///
    /// Editor is the one exception, and it is the opposite case: its pane exists for the session
    /// where you must browse to a folder you have not kept or visited, while the ordinary session
    /// opens a file from the rail and writes in it. Three columns between the window edge and the
    /// text would be three things to look past every time. Listed by name rather than derived, so
    /// that a workspace changing its mind about this is a decision somebody writes down.
    @Test func onlyTheEditorStartsWithItsPaneCollapsed() {
        let startCollapsed: Set<Workspace> = [.editor]
        for workspace in Workspace.allCases {
            let expected = startCollapsed.contains(workspace)
            #expect(TopPaneVisibility.defaultPanesHidden(for: workspace) == expected,
                    "\(workspace.title) starts \(expected ? "expanded" : "collapsed") — the opposite of the rule this test states")
            #expect(TopPaneVisibility.panesHidden(for: workspace, override: nil) == expected)
        }
        // The control: if this ever became "all of them" or "none of them", the loop above would
        // still pass while saying nothing.
        #expect(!startCollapsed.isEmpty && startCollapsed.count < Workspace.allCases.count)
    }

    // MARK: The editor's file rail

    /// The quiet state: pane collapsed, nothing asked of the rail — it is the file list.
    @Test func theRailIsDrawnInTheQuietState() {
        #expect(TopPaneVisibility.editorRailIsDrawn(paneHidden: true, railHidden: false))
    }

    /// An open pane IS the file list, so the rail steps aside rather than listing the folder twice.
    @Test func theRailYieldsToAnOpenPane() {
        #expect(!TopPaneVisibility.editorRailIsDrawn(paneHidden: false, railHidden: false))
    }

    /// "Just the text": the pane is collapsed and the rail bit is set, so neither list is drawn.
    @Test func justTheTextHidesTheRail() {
        #expect(!TopPaneVisibility.editorRailIsDrawn(paneHidden: true, railHidden: true))
    }

    /// With the pane open the bit is not consulted at all — both values of it answer the same —
    /// which is what lets the bit survive a trip into the pane and back without being cleared.
    /// The rule takes the bit by value and has nowhere to write, so "ignored" is the whole claim.
    @Test func anOpenPaneIgnoresTheRailBitRatherThanClearingIt() {
        let withBitClear = TopPaneVisibility.editorRailIsDrawn(paneHidden: false, railHidden: false)
        let withBitSet = TopPaneVisibility.editorRailIsDrawn(paneHidden: false, railHidden: true)
        #expect(withBitClear == withBitSet, "an open pane answers differently depending on the rail bit")
        #expect(!withBitSet)
    }

    // MARK: The sidebar beside Edit's folded pane, and Expand

    /// **Only Edit's sidebar outlives a collapsed pane.** Listed by name: in a lens a click would
    /// re-root a pane nobody can see, so a workspace joining this set is a decision to write down.
    @Test func onlyEditsSidebarOutlivesACollapsedPane() {
        for workspace in Workspace.allCases {
            #expect(workspace.folderSidebarOutlivesPaneCollapse == (workspace == .editor),
                    "\(workspace.title) answers \(workspace.folderSidebarOutlivesPaneCollapse)")
        }
    }

    /// Every starting state, as the person sees it: list hidden or not, pane folded or not,
    /// sidebar showing or not. The record bits start clear — what a state reached by hand has.
    static let startingStates: [(rail: Bool, pane: Bool, sidebar: Bool)] =
        [false, true].flatMap { r in [false, true].flatMap { p in [false, true].map { (r, p, $0) } } }

    /// **Leaving gives back exactly what was showing** (asked 2026-10-04) — from every one of the
    /// eight states Expand can be entered from (one of which is already on, see below). The
    /// sidebar is read as drawn: the preference, less Expand's hold. Mutation: drop the pane
    /// restore from `leave` and every state with the pane open fails.
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
        // The rail comes back whatever it was — leaving Expand is the request for the list.
        #expect(!expand.railHidden)
        #expect(!expand.sidebarPutAway && !expand.paneFoldedByExpand, "a spent record was kept")
    }

    /// **A second entry keeps the record** — a launch from Finder into a window already expanded.
    /// Reading the state afresh would see Expand's own work (pane folded, sidebar held) and leave
    /// owing nothing. Mutation: drop the `isOn` branch and the pane stays folded on leaving.
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

    /// **Opening the pane from its spine ends Expand and spends the record.** The sidebar comes
    /// back with the pane, and a later fold from the spine — which re-lights Expand, the rail bit
    /// having survived — does not leave Expand owing a pane or a sidebar.
    @Test func openingThePaneByHandSpendsTheRecord() {
        var expand = EditorExpand(railHidden: false, paneFolded: false,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        expand.enter(sidebarShowing: true)
        expand.paneOpenedByHand()
        #expect(!expand.isOn && !expand.hidesSidebar)
        #expect(expand.railHidden, "the rail bit was cleared — editorRailIsDrawn requires it to survive")
        expand.paneFolded = true            // the spine's fold
        #expect(expand.isOn && !expand.hidesSidebar)
        expand.leave()
        #expect(expand.paneFolded, "leaving reopened a pane the person folded themselves")
    }

    /// The log names what moved, and only that.
    @Test func theLogNamesWhatMoved() {
        let quiet = EditorExpand(railHidden: false, paneFolded: true, sidebarPutAway: false, paneFoldedByExpand: false)
        var all = EditorExpand(railHidden: false, paneFolded: false, sidebarPutAway: false, paneFoldedByExpand: false)
        let open = all
        all.enter(sidebarShowing: true)
        #expect(EditorExpand.moved(from: open, to: all) == "the Text Files list, the file pane and the sidebar")
        var listOnly = quiet
        listOnly.enter(sidebarShowing: false)
        #expect(EditorExpand.moved(from: quiet, to: listOnly) == "the Text Files list")
        #expect(EditorExpand.moved(from: quiet, to: quiet) == "nothing")
    }

    /// **The collapsed Edit row fits beside the sidebar at any width the clamp allows.** The
    /// sidebar takes its width from `lensSidebarWidth`, which reserves a rail and a lens panel;
    /// Edit's collapsed row is the spine's card and the rail-and-document workspace, and must not
    /// need more, or the document column is squeezed under its floor at the window minimum.
    @Test func theCollapsedEditRowFitsTheLensClamp() {
        let spineSlot = PaneLogic.railSpineWidth + LiquidGlass.cardGutter
        let reserved = PaneLogic.minRailWidth + PaneLogic.minLensWorkspaceWidth
        #expect(spineSlot + EditorLayoutMetrics.minWorkspaceWidth <= reserved,
                "Edit's collapsed row needs \(spineSlot + EditorLayoutMetrics.minWorkspaceWidth)pt; the clamp leaves \(reserved)")
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
        let map: [String: Bool] = ["Storage": true, "Differences": false]
        #expect(TopPaneVisibility.encodeOverrides(map) == TopPaneVisibility.encodeOverrides(map))
    }

    @Test func testUnknownKeysAreIgnoredNotFatal() {
        // A retired entry stays in the map but is never looked up, so it can't affect any
        // current workspace. Both examples here are real retirements: "Storage Lens" was a tab,
        // and "Duplicates" was a workspace until it folded into Organize as a rail item.
        let raw = TopPaneVisibility.encodeOverrides(["Storage Lens": true, "Duplicates": false])
        let decoded = TopPaneVisibility.decodeOverrides(raw)
        #expect(decoded["Storage Lens"] == true)
        #expect(decoded["Duplicates"] == false)
        // The live workspaces are unaffected by either.
        #expect(!TopPaneVisibility.panesHidden(for: .filing, override: decoded[Workspace.filing.rawValue]))
    }

    /// **The memo answers about the string it was handed, not about the last one.**
    ///
    /// `overrides(in:)` exists because `panesHiddenForCurrentTab` is read from around three dozen
    /// sites — `contentLayout`, `folderSidebarIsShowing`, both shortcut gates, `showSourcePicker`,
    /// two `.animation` modifiers and an `onChange` — several per body pass, each allocating a
    /// `JSONDecoder` and parsing. It is a one-entry memo, which makes exactly one thing able to go
    /// wrong: serving a previous string's answer for the current one. That would show up as the
    /// panes not collapsing when a workspace's override is written, or a stale collapse persisting
    /// — a stuck layout, with the stored value correct.
    ///
    /// Interleaved A → B → A rather than A → B, because a memo that overwrites unconditionally and
    /// one that keys correctly both pass a single change; only coming BACK to a value distinguishes
    /// them from a memo that never re-reads.
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

    // MARK: Migrating the single `Tidy` entry

    @Test func testTidysOverrideFansOutToEveryLensWorkspace() {
        // One key covered every lens. Leaving it alone would silently discard a deliberate
        // "keep the rail up in Tidy" the moment the lenses became peers with their own keys.
        // Fewer keys than there once were — duplicates and automations are rail items inside
        // Organize now and share its entry — but the fan-out still has to reach each survivor.
        let migrated = TopPaneVisibility.migratingOverrides(["Tidy": true])
        for workspace in Workspace.lensWorkspaces {
            #expect(migrated[workspace.rawValue] == true, "\(workspace.rawValue) lost Tidy's choice")
        }
        // And the spent key is gone, so this cannot re-run against a later, deliberate choice.
        #expect(migrated[TopPaneVisibility.legacyTidyKey] == nil)
        // Compare had its own entry and is not a lens — it must not inherit Tidy's.
        #expect(migrated[Workspace.compare.rawValue] == nil)
    }

    @Test func testAWorkspaceThatAlreadyDecidedKeepsItsOwnAnswer() {
        // A second migration pass (or a hand-edited map) must not overwrite a real choice with
        // the legacy one.
        let migrated = TopPaneVisibility.migratingOverrides(["Tidy": true, "Storage": false])
        #expect(migrated["Storage"] == false)
        #expect(migrated["Filing"] == true)
    }

    @Test func testAMapWithNoTidyEntryIsLeftExactlyAlone() {
        let already = [Workspace.compare.rawValue: true, Workspace.filing.rawValue: false]
        #expect(TopPaneVisibility.migratingOverrides(already) == already)
        // And the raw-string form reports "nothing to do" rather than rewriting the same value,
        // which would churn @AppStorage on every launch.
        #expect(TopPaneVisibility.migratingOverridesRaw(TopPaneVisibility.encodeOverrides(already)) == nil)
        #expect(TopPaneVisibility.migratingOverridesRaw("") == nil)
    }

    @Test func testTheRawMigrationRoundTripsThroughTheStoredString() throws {
        let raw = TopPaneVisibility.encodeOverrides(["Tidy": true, "Differences": false])
        let migrated = try #require(TopPaneVisibility.migratingOverridesRaw(raw))
        let decoded = TopPaneVisibility.decodeOverrides(migrated)
        #expect(decoded["Tidy"] == nil)
        #expect(decoded["Differences"] == false)
        // **Organize is the only lens workspace left**, so Tidy's value fans out to it alone. This
        // asserted `decoded["Storage"] == true` while Storage was a workspace with a pane of its
        // own; since the fold its panes are Organize's panes, and the single key above governs it.
        #expect(decoded["Filing"] == true)
        // Neither Rename nor Storage is a workspace, so the fan-out must not mint a key for either
        // — an override for a place that cannot be selected is a row of dead state that would
        // outlive every reader. Storage is the newer half of that rule and the easier to miss,
        // because it WAS a workspace and its key was legitimately written until the fold.
        #expect(decoded[Workspace.retiredRenameRawValue] == nil)
        #expect(decoded["Storage"] == nil)
    }
}
