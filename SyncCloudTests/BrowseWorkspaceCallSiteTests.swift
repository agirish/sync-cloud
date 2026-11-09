import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// Browse's wiring inside `ContentView`, checked at the source level as
/// `ToolbarPaletteBarCallSiteTests` and `LensScanRootTests` check theirs.
///
/// `ContentView` can't be instantiated because of its initializer, not its dependencies: its
/// private stored properties make the synthesized memberwise initializer `private`, which
/// `@testable` does not raise. Browse itself is not a view type but a `Workspace` case, a
/// `ContentLayout` case and `browseLayout`; what it draws (`PaneHeader`, `FileTreeView`,
/// `PersonView`) is render-tested in its own package, so this file checks only the wiring.
///
/// Every reader fails loudly on a missing or implausibly short file, and every assertion names a
/// string whose absence is the regression. Several checks also assert the old shape is gone, since "the new call is present" stays
/// true if both are left in. A check about one file's contents names that file; a check about a
/// call site reads all of `MacApp/` (`macAppSources`), since which file a member sits in isn't
/// pinned.
@Suite struct BrowseWorkspaceCallSiteTests {

    /// The same text with comments removed, for counting, where prose naming a member would
    /// otherwise count as the member. The shared stripper, ``sourceCodeOnly(_:)``.
    static func codeOnly(_ source: String) -> String { sourceCodeOnly(source) }

    /// One declaration's body, bounded by its closing brace rather than a character count. A fixed
    /// window drifts as the member changes length: it overruns into the next member's doc comment,
    /// so a `!contains` gets answered by prose, or stops short of the code it checks. The reading is
    /// the shared ``declarationBody(of:in:)``, which requires one declaration and searches the
    /// comment-stripped text, so a decoy in a comment can't become the answer.
    static func body(of declaration: String, in source: String) throws -> String {
        try declarationBody(of: declaration, in: source)
    }

    /// The reader's own control: a decoy in a comment must not become the answer. The first fixture
    /// puts a commented-out copy of the declaration above the real one; a reader that counted over
    /// stripped text but searched the raw text would return the decoy. The second is the other
    /// direction: a doc comment that names the member must not count as a second declaration.
    @Test func testTheReaderIgnoresDeclarationsThatAreOnlyComments() throws {
        let withDecoy = """
            struct S {
            //    func target() -> Int {
            //        return decoy
            //    }
                func target() -> Int {
                    return real
                }
            }
            """
        let body = try declarationBody(of: "func target() -> Int {", in: withDecoy)
        #expect(body.contains("return real"), "the reader took a commented-out declaration as the member")
        #expect(!body.contains("decoy"))

        let mentioned = """
            struct S {
                /// Companion to `func target() -> Int {`, which it must not be counted as.
                func target() -> Int {
                    return real
                }
            }
            """
        // Not wrapped: the failure worth seeing here is the reader's own `#require`, which reports
        // itself.
        #expect(try declarationBody(of: "func target() -> Int {", in: mentioned)
                    .contains("return real"))

        // A genuine second declaration still stops the run. `withKnownIssue`, not
        // `#expect(throws:)`: the refusal is a `#require`, which records an issue as well as
        // throwing, and that issue would still fail the test. This form also fails if none is
        // recorded.
        let twice = """
            struct S {
                func target() -> Int {
                    return first
                }
                func target() -> Int {
                    return second
                }
            }
            """
        withKnownIssue("two real declarations were not refused — range(of:) would read the first") {
            _ = try declarationBody(of: "func target() -> Int {", in: twice)
        }
    }

    // MARK: The layout

    /// Browse resolves its layout before the pane-hiding question is asked. The pane is the whole
    /// window there, so "panes hidden" would mean an empty window; no Browse control writes that
    /// override, but a stray key in the stored map must not blank the workspace either.
    @Test func testBrowseIsDecidedBeforePaneHidingIsConsulted() throws {
        let body = try Self.body(of: "var contentLayout: ContentLayout {",
                                 in: try macAppSources())
        let browse = try #require(body.range(of: "return .browseFull"),
                                  "contentLayout has no Browse arm — Browse falls through to the rail layout")
        let hidden = try #require(body.range(of: "panesHiddenForCurrentTab"),
                                  "contentLayout no longer reads the hidden override at all — this ordering check is vacuous")
        #expect(browse.lowerBound < hidden.lowerBound,
                "Browse is resolved after the pane-hiding branch, so a stored override can blank the window")
    }

    /// The full-width layout keeps the two things that make the column a pane rather than a list.
    /// Space → Quick Look lives on the file list inside `paneColumn`, so Browse gets it with the
    /// column; `PaneQuickLookScopeTests` covers it.
    @Test func testTheBrowseLayoutKeepsTheRegionFrame() throws {
        let body = try Self.body(of: "func browseLayout(geo: GeometryProxy)",
                                 in: try macAppSources())
        #expect(body.contains("paneColumn(isLeft: true)"))
        #expect(body.contains(".panesRegionFrame(surfaceStyle, level: glassLevel)"))
    }

    /// Nothing to collapse to: the header's collapse rung is nil in Browse, and `railSpine` (the
    /// other control that reaches `togglePanesForCurrentTab`) is drawn by `singleSourceLayout`,
    /// which Browse never takes. The gather's "Open" calls it only behind
    /// `contentLayout == .singleCollapsed`, so Browse still writes no override.
    ///
    /// The rung is asked of `ContentLayout.hasCollapsibleRail`, a `switch` with no `default:`, so a
    /// new full-window workspace is a compile error rather than silently inheriting a rung it has
    /// no spine for. Pinned at both ends: the call site asks the layout; Browse's arm says no.
    @Test func testTheCollapseRungIsNotOfferedInBrowse() throws {
        let content = try macAppSources()
        #expect(content.contains("onCollapse: contentLayout.hasCollapsibleRail"),
                "the collapse rung is no longer resolved from the layout — a full-window workspace can inherit one")
        let rung = try declarationBody(of: "var hasCollapsibleRail: Bool {", in: content)
        #expect(rung.contains(".browseFull"),
                "Browse is no longer named in the collapse rung's answer — it would hide the only thing in the window")
        #expect(!rung.contains("default:"),
                "a default arm would silently give the next workspace a collapse rung")
    }

    // MARK: The view-mode key

    /// One member decides which of the three stored presentations is in play. Restated per call
    /// site, a missed site would show Browse in the rail's stack and write the user's choice into
    /// the rail's key.
    @Test func testEveryViewModeCallSiteGoesThroughTheOneResolver() throws {
        let content = try macAppSources()
        #expect(content.contains("let mode: PaneViewMode = resolvedViewMode(isLeft: isLeft)"))
        #expect(content.contains("viewMode: resolvedViewModeBinding(isLeft: isLeft)"))
        // The two-way ternary belongs in exactly two places, the read and write resolvers; any
        // other copy is a surface that won't see Browse. Counted over all of `MacApp/`, since a copy
        // in another file is the same defect. The read resolver is `viewMode(in:isLeft:)`, which
        // answers for any workspace and to which `resolvedViewMode` must delegate, so the count
        // matches the ternary's tail, which both spellings share.
        let occurrences = Self.codeOnly(content)
            .components(separatedBy: ".singleSource ? railViewMode").count - 1
        #expect(occurrences == 2,
                "the rail-or-pane ternary appears \(occurrences) times in MacApp/ — it belongs in `viewMode(in:isLeft:)` and `resolvedViewModeBinding` and nowhere else")
        #expect(content.contains("TopPaneVisibility.mode(for: workspace) == .singleSource ? railViewMode"),
                "the read resolver no longer holds the ternary")
        #expect(content.contains("viewMode(in: selectedWorkspace, isLeft: isLeft)"),
                "resolvedViewMode answers on its own again — two read resolvers")
        #expect(content.contains("PaneViewMode.browseDefaultsKey"),
                "Browse has no key of its own — flipping it to Tree restacks the Organize rail")
    }

    // MARK: The preview

    /// The preview is Info's alone, drawn at the height last dragged to. Info is one more column, drawn
    /// over the room the list keeps for it, or a drawer; never a view inside the list's columns,
    /// which would resize them and make the pane non-`Equatable`.
    /// View ▸ File Preview is gone; this pins what is left for the app to get wrong.
    @Test func testThePreviewIsThePanesInfoAlone() throws {
        let macApp = Self.codeOnly(try macAppSources())
        let content = Self.codeOnly(try macAppFile("ContentView+PaneInfo.swift"))
        #expect(content.contains("AnyView(InspectorFilePreview("),
                "Info no longer draws the preview")
        #expect(content.contains("previewFraction: $inspectorPreviewFraction"),
                "Info no longer draws the preview at the remembered height")
        // The retired menu item by its title, the only spelling that can come back: the type and
        // keys it read are gone from the modules, so a check on their names could never fail.
        #expect(!macApp.contains("\"File Preview\""), "View ▸ File Preview is back")
        #expect(content.contains("paneWatches: true"),
                "Info's preview no longer says the pane is on screen to watch a download")
        #expect(content.contains("downloads: inspectorDownloads"),
                "Info's downloads are not the window's, so they die with the preview")
    }

    // MARK: Sort By ticks the panes' order

    /// The pane is told the order it is sorted in. Its background menus tick it; the parameter
    /// defaults to Name, so a host that stopped passing it would silently tick Name for every order.
    @Test func testThePaneIsToldTheSortOrder() throws {
        let content = try macAppFile("ContentView.swift")
        #expect(content.contains("sortOption: syncManager.sortOption,"),
                "the pane's background menus are not told the current sort order")
    }

    // MARK: Delete acts on its own pane

    /// The pane bar's Delete is fed from this pane's selection, never the active pane's.
    /// `barSelectionNodes`, resolved right beside it, is the tempting reuse and is wrong: it runs
    /// through `paneActionBarSideActive`'s `guard layoutMode == .compare`, so it is empty in Browse,
    /// on the Organize rail, and for Compare's inactive side even when that side has a selection.
    @Test func testTheHeaderDeleteTakesThisPanesSelection() throws {
        let content = try macAppSources()
        #expect(content.contains("let ownNodes = paneSelectionNodes(isLeft: isLeft)"))
        // Resolved at fire time, not captured. The same closure runs from the ⋯ menu's Delete, and
        // a menu held open in tracking mode is not re-armed by a republish, so a captured array
        // could name rows a background sync has since replaced. `ownNodes` is still right for the
        // count, which belongs to the render the button is drawn in.
        #expect(content.contains("actionHandler?.confirmDelete(paneSelectionNodes(isLeft: isLeft),"),
                "the header's Delete captures a snapshot instead of resolving its nodes when clicked")
        #expect(content.contains("alwaysConfirm: true)"))
        #expect(!content.contains("confirmDelete(ownNodes"),
                "the captured-snapshot form is back")
        #expect(content.contains("selectionCount: ownNodes.count"))
        // The two must not be confused: `barNodes` still exists and still feeds the floating bar.
        #expect(content.contains("let barNodes = barSelectionNodes(isLeft: isLeft)"),
                "barSelectionNodes is gone — this test can no longer tell the two resolvers apart")
    }

    /// …and the resolver behind it consults neither `activePane` nor the compare-only gate. Both
    /// bodies are brace-bounded, so the two `!contains` are asked of the member and not of the
    /// prose after it.
    @Test func testThePerPaneResolverIgnoresTheActivePane() throws {
        let macApp = try macAppSources()
        let body = try Self.body(of: "func paneSelectionNodes(isLeft: Bool) -> [FileNode] {", in: macApp)
        #expect(body.contains("syncManager.leftNodes(for: syncManager.selectedLeftPaths)"))
        #expect(body.contains("syncManager.rightNodes(for: syncManager.selectedRightPaths)"))
        #expect(!body.contains("activePane"),
                "the per-pane resolver reads the active pane — in Compare both panes' Delete buttons would act on the same selection")
        #expect(!body.contains("paneActionBarSideActive"),
                "the per-pane resolver went back through the compare-only gate — Delete is dead outside Compare")
        // The sibling it must not become: `barSelectionNodes` IS activePane-scoped, on purpose.
        let bar = try Self.body(of: "func barSelectionNodes(isLeft: Bool) -> [FileNode] {", in: macApp)
        #expect(bar.contains("paneActionBarSideActive"),
                "barSelectionNodes stopped being the active pane's — the floating action bar's target has changed")
    }

    /// The floating bar and ⌘⌫ stay Compare-only. Browse gets neither: the bar's transfer buttons
    /// take their titles from the other pane, which does not exist there.
    @Test func testTheFloatingBarAndChordStayCompareOnly() throws {
        let macApp = try macAppSources()
        let gate = try Self.body(of: "func paneActionBarSideActive(isLeft: Bool) -> Bool {", in: macApp)
        #expect(gate.contains("guard layoutMode == .compare"),
                "the floating action bar's compare guard was widened — Browse would show transfer buttons naming a pane that does not exist")
        let chord = try Self.body(of: "var shortcutDeleteSelection: (() -> Void)? {", in: macApp)
        #expect(chord.contains("guard layoutMode == .compare"),
                "⌘⌫ escaped Compare — it acts on the active pane, which is ambiguous with no floating bar to show which")
    }

    // MARK: ⌘K

    @Test func testThePaletteCanReachBrowse() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        #expect(host.contains("case .browse:"), "runPaletteRoute has no Browse arm")
        #expect(host.contains("workspaceSelection.wrappedValue = .browse"))
    }

    // MARK: The bar has no rule

    /// The workspace bar draws no group rule. `WorkspaceBarMetrics` charges nothing for separators,
    /// so a divider added to tidy up the bar would be 13pt the arithmetic can't see, and
    /// under-measuring folds the whole toolbar behind macOS's overflow chevron.
    @Test func testTheBarDrawsNoGroupRule() throws {
        let toolbar = try macAppFile("ContentView+Toolbar.swift")
        #expect(!toolbar.contains("workspaceRuleIndex"),
                "the group rule's index is back — the bar's width arithmetic no longer counts separators")
        #expect(!(try declarationBody(of: "var workspaceBar: some View {", in: toolbar)).contains("Divider()"),
                "the workspace bar draws a Divider again — the metrics charge nothing for it")
    }

    // MARK: A person gather has somewhere to land

    /// Browse offers the gather, so Browse has to be able to show it. `paneColumn` hands every pane
    /// header a `personOffer` and an `onAcceptPerson` in every workspace, so a card mounted only in
    /// `bottomPaneView` would leave an accept in Browse sweeping the source with nothing on screen,
    /// no ✕ and no Esc target. Checked as both layouts mounting one shared member, in two named
    /// files: over all of `MacApp/`, one layout mounting it twice would pass.
    @Test func testBothLayoutsMountThePersonGather() throws {
        let content = try macAppFile("ContentView.swift")
        let split = try macAppFile("ContentView+SplitLayout.swift")
        #expect(content.contains("func personGatherSection(_ scope: PersonScope)"),
                "the gather's card is not a shared member — only one layout can mount it")
        #expect(content.contains("personGatherSection(scope)"),
                "bottomPaneView no longer mounts the gather")
        #expect(split.contains("personGatherSection(scope)"),
                "browseLayout does not mount the gather — an accept in Browse renders nowhere")
    }

    /// The gather takes a resizable slot in Browse, the same shape and remembered share it takes
    /// everywhere else: not a fixed strip, and not the whole window.
    @Test func testTheBrowseGatherSlotIsTheSharedResizableOne() throws {
        let body = try Self.body(of: "func browseLayout(geo: GeometryProxy)",
                                 in: try macAppSources())
        #expect(body.contains("if let scope = personScope"),
                "browseLayout does not branch on a live gather")
        // One structure, so the file column keeps its identity when a gather opens or clears. The
        // checks above hold for a two-branch layout with the column in each arm too; one mount of
        // the column, and no `else`, is what rules it out.
        let mounts = body.components(separatedBy: "paneColumn(isLeft: true)").count - 1
        #expect(mounts == 1,
                "the column is mounted \(mounts)× in browseLayout; two positions is two identities")
        #expect(!body.contains("} else {"),
                "browseLayout branches structurally again, so the pane column has two identities")
        #expect(body.contains("verticalResizeDivider"),
                "the Browse gather slot cannot be resized, unlike every other workspace's")
        #expect(body.contains("bottomPaneFraction"),
                "the Browse gather slot does not use the shared remembered share")
    }
}
