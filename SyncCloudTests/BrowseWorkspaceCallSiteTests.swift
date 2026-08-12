import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// Browse's wiring inside `ContentView`, which nothing else in the suite can see.
///
/// `ContentView` is a SwiftUI view in the app target with no seam to instantiate — `paneColumn`,
/// `contentLayout` and `paneSelectionNodes` all need a live `FileSyncManager`, a settings object
/// and a render pass — so the properties below are checked at the source level, the same way
/// `ToolbarPaletteBarCallSiteTests` and `TidyScanRootTests` check theirs.
///
/// A source scan is only worth having with its guards, so: every check names the file it reads and
/// fails if that file is missing or implausibly short, every assertion names a string whose absence
/// IS the regression, and `testTheScanCanActuallyFail` proves the reader is looking at the right
/// text rather than passing on an empty string. Several checks also assert the OLD shape is gone,
/// because "the new call is present" stays true if someone leaves both in.
@Suite struct BrowseWorkspaceCallSiteTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)          // …/SyncCloudTests/<this>.swift
            .deletingLastPathComponent()                   // …/SyncCloudTests
            .deletingLastPathComponent()                   // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        #expect(text.count > 500, "\(name) is implausibly short")
        return text
    }

    /// The positive control. Every other test here asserts that some string is present; if the
    /// reader silently returned the wrong file they would all fail loudly — but the several that
    /// assert an ABSENCE would pass, which is the direction that goes unnoticed.
    @Test func testTheScanCanActuallyFail() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("func paneColumn(isLeft: Bool)"), "this file is not ContentView")
        #expect(!content.contains("a string that is definitely not in ContentView"))
    }

    // MARK: The layout

    /// Browse resolves its layout BEFORE the pane-hiding question is asked. The pane is the whole
    /// window there, so "panes hidden" would mean an empty window — and while no control in Browse
    /// can write that override today, a stray key in the stored map must not be able to blank the
    /// workspace either.
    @Test func testBrowseIsDecidedBeforePaneHidingIsConsulted() throws {
        let content = try Self.source("ContentView.swift")
        let layout = try #require(content.range(of: "var contentLayout: ContentLayout {"))
        let body = String(content[layout.upperBound...].prefix(1_200))
        let browse = try #require(body.range(of: "return .browseFull"),
                                  "contentLayout has no Browse arm — Browse falls through to the rail layout")
        let hidden = try #require(body.range(of: "panesHiddenForCurrentTab"),
                                  "contentLayout no longer reads the hidden override at all — this ordering check is vacuous")
        #expect(browse.lowerBound < hidden.lowerBound,
                "Browse is resolved after the pane-hiding branch, so a stored override can blank the window")
    }

    /// The full-width layout keeps the two things that make the column a pane rather than a list.
    ///
    /// Space → Quick Look used to be checked here too, as a `singleSource: true` handler written
    /// out in this function. It has moved inside `paneColumn`, onto the file list — a handler on the
    /// whole column also covered that pane's search field and ate the spaces typed into it. Browse
    /// still gets it, by getting the same column; `PaneQuickLookScopeTests` is where that now lives,
    /// including the `singleSource` resolution this used to pin.
    @Test func testTheBrowseLayoutKeepsTheRegionFrame() throws {
        let split = try Self.source("ContentView+SplitLayout.swift")
        let start = try #require(split.range(of: "func browseLayout(geo: GeometryProxy)"),
                                 "there is no Browse layout")
        let body = String(split[start.upperBound...].prefix(900))
        #expect(body.contains("paneColumn(isLeft: true)"))
        #expect(body.contains(".panesRegionFrame(surfaceStyle, level: glassLevel)"))
    }

    /// Nothing to collapse to: the header's collapse rung is nil in Browse, so `railSpine` — which
    /// is the only other way to reach `togglePanesForCurrentTab` — can never be drawn either.
    @Test func testTheCollapseRungIsNotOfferedInBrowse() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("onCollapse: layoutMode == .singleSource && selectedWorkspace != .browse"),
                "Browse offers a collapse rung — it would hide the only thing in the window")
    }

    // MARK: The view-mode key

    /// One member decides which of the three stored presentations is in play. Restated per call
    /// site — as it was before Browse existed — the site that got missed would show Browse in the
    /// rail's stack and write the user's choice into the rail's key.
    @Test func testEveryViewModeCallSiteGoesThroughTheOneResolver() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("let mode: PaneViewMode = resolvedViewMode(isLeft: isLeft)"))
        #expect(content.contains("viewMode: resolvedViewModeBinding(isLeft: isLeft)"))
        // The old two-way ternary must survive in exactly two places — the read resolver and the
        // write resolver — and nowhere else. Counted rather than banned outright, because the
        // resolvers are where it belongs; every OTHER copy is a surface that will not see Browse.
        //
        // This count is what caught the third surface: `shortcutPreviewColumn` spelled the same
        // ternary out for itself, so ⇧⌘P in Browse asked the rail's mode about a pane the user was
        // not looking at. It lives in a different file, hence the second scan below.
        let occurrences = content.components(separatedBy: "layoutMode == .singleSource ? railViewMode").count - 1
        #expect(occurrences == 2,
                "the rail-or-pane ternary appears \(occurrences) times in ContentView — it belongs in `resolvedViewMode` and `resolvedViewModeBinding` and nowhere else")
        #expect(content.contains("PaneViewMode.browseDefaultsKey"),
                "Browse has no key of its own — flipping it to Tree restacks the Organize rail")
    }

    /// The reader outside `ContentView.swift`: ⇧⌘P asks which presentation is on screen, and has
    /// to ask the same member everything else asks.
    @Test func testThePreviewChordAsksTheSameResolver() throws {
        let shortcuts = try Self.source("ShortcutCommands.swift")
        #expect(shortcuts.contains("resolvedViewModeBinding(isLeft: shortcutTargetIsLeft)"))
        #expect(!shortcuts.contains("railViewModeBinding"),
                "⇧⌘P reaches for the rail's mode directly again — in Browse it would offer the preview column according to a stack the user is not looking at")
    }

    // MARK: Delete acts on its own pane

    /// The pane bar's Delete is fed from THIS pane's selection, never the active pane's.
    ///
    /// `barSelectionNodes` is the tempting reuse — it is already resolved once per render right
    /// beside it — and it is wrong twice: it runs through `paneActionBarSideActive`, which opens
    /// `guard layoutMode == .compare`, so it is empty in Browse and on the Organize rail entirely,
    /// and empty for Compare's inactive side even when that side has a selection.
    @Test func testTheHeaderDeleteTakesThisPanesSelection() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("let ownNodes = paneSelectionNodes(isLeft: isLeft)"))
        // **Resolved at fire time, not captured.** The same closure runs from the ⋯ menu's Delete
        // entry, and a menu held open in menu-tracking mode is not re-armed by a republish — so a
        // captured array could name rows a background sync has since replaced. `ownNodes` is still
        // right for the COUNT, which is a question about the render the button is drawn in.
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

    /// …and the resolver behind it consults neither `activePane` nor the compare-only gate.
    @Test func testThePerPaneResolverIgnoresTheActivePane() throws {
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        let start = try #require(toolbar.range(of: "func paneSelectionNodes(isLeft: Bool) -> [FileNode] {"),
                                 "the per-pane resolver is gone")
        let body = String(toolbar[start.upperBound...].prefix(260))
        #expect(body.contains("syncManager.leftNodes(for: syncManager.selectedLeftPaths)"))
        #expect(body.contains("syncManager.rightNodes(for: syncManager.selectedRightPaths)"))
        #expect(!body.contains("activePane"),
                "the per-pane resolver reads the active pane — in Compare both panes' Delete buttons would act on the same selection")
        #expect(!body.contains("paneActionBarSideActive"),
                "the per-pane resolver went back through the compare-only gate — Delete is dead outside Compare")
        // The sibling it must not become: `barSelectionNodes` IS activePane-scoped, on purpose.
        let bar = try #require(toolbar.range(of: "func barSelectionNodes(isLeft: Bool) -> [FileNode] {"))
        #expect(String(toolbar[bar.upperBound...].prefix(120)).contains("paneActionBarSideActive"),
                "barSelectionNodes stopped being the active pane's — the floating action bar's target has changed")
    }

    /// The floating bar and ⌘⌫ stay Compare-only. Browse gets neither: the bar's transfer buttons
    /// take their titles from the OTHER pane, which does not exist there.
    @Test func testTheFloatingBarAndChordStayCompareOnly() throws {
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        let shortcuts = try Self.source("ShortcutCommands.swift")
        let gate = try #require(toolbar.range(of: "func paneActionBarSideActive(isLeft: Bool) -> Bool {"))
        #expect(String(toolbar[gate.upperBound...].prefix(140)).contains("guard layoutMode == .compare"),
                "the floating action bar's compare guard was widened — Browse would show transfer buttons naming a pane that does not exist")
        let chord = try #require(shortcuts.range(of: "var shortcutDeleteSelection: (() -> Void)? {"))
        #expect(String(shortcuts[chord.upperBound...].prefix(700)).contains("guard layoutMode == .compare"),
                "⌘⌫ escaped Compare — it acts on the active pane, which is ambiguous with no floating bar to show which")
    }

    // MARK: ⌘K

    @Test func testThePaletteCanReachBrowse() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("case .browse:"), "runPaletteRoute has no Browse arm")
        #expect(host.contains("workspaceSelection.wrappedValue = .browse"))
    }

    // MARK: The bar's rule

    @Test func testTheBarDrawsItsRuleFromTheNamedIndex() throws {
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        #expect(toolbar.contains("if index == Self.workspaceRuleIndex"),
                "the group rule is back to a bare literal — it can drift from the bar's order with nothing to catch it")
        #expect(!toolbar.contains("if index == 1 {"),
                "the old separator position is still in the file")
    }

    // MARK: A person gather has somewhere to land

    /// **Browse offers the gather, so Browse has to be able to show it.**
    ///
    /// `paneColumn` hands every pane header a `personOffer` and an `onAcceptPerson`, ungated by
    /// workspace — and Browse draws that same column. But the gather's card was written inline in
    /// `bottomPaneView`, which `browseLayout` never mounts: accepting the offer in Browse started
    /// the whole-source sweep and changed no pixel, with no ✕, no Esc target, and no way to reach
    /// the answer (switching workspace clears the scope). An accept doing nothing visible is the
    /// one failure the offer exists to prevent.
    ///
    /// Checked as "both layouts mount the same member", which is the property that made it
    /// impossible to fix one and leave the other telling the old lie.
    @Test func testBothLayoutsMountThePersonGather() throws {
        let content = try Self.source("ContentView.swift")
        let split = try Self.source("ContentView+SplitLayout.swift")
        #expect(content.contains("func personGatherSection(_ scope: PersonScope)"),
                "the gather's card is not a shared member — only one layout can mount it")
        #expect(content.contains("personGatherSection(scope)"),
                "bottomPaneView no longer mounts the gather")
        #expect(split.contains("personGatherSection(scope)"),
                "browseLayout does not mount the gather — an accept in Browse renders nowhere")
    }

    /// The gather takes a **resizable** slot in Browse, the same shape and remembered share it
    /// takes everywhere else — not a fixed strip, and not the whole window.
    @Test func testTheBrowseGatherSlotIsTheSharedResizableOne() throws {
        let split = try Self.source("ContentView+SplitLayout.swift")
        let start = try #require(split.range(of: "func browseLayout(geo: GeometryProxy)"),
                                 "browseLayout is gone — this scan would be vacuous")
        let body = String(split[start.upperBound...].prefix(1_600))
        #expect(body.contains("if let scope = personScope"),
                "browseLayout does not branch on a live gather")
        #expect(body.contains("verticalResizeDivider"),
                "the Browse gather slot cannot be resized, unlike every other workspace's")
        #expect(body.contains("bottomPaneFraction"),
                "the Browse gather slot does not use the shared remembered share")
    }
}
