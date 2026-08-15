import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// Browse's wiring inside `ContentView`, which nothing else in the suite can see.
///
/// `ContentView` is a SwiftUI view in the app target with no seam to instantiate, so the properties
/// below are checked at the source level, the same way `ToolbarPaletteBarCallSiteTests` and
/// `LensScanRootTests` check theirs.
///
/// **The reason it cannot be instantiated is its initializer, not its dependencies** — this said the
/// opposite until someone went and tried. Every argument `SyncCloudApp` passes it is constructible
/// from a test: `FileSyncManager.init(fileManager:)` takes an injectable filesystem and
/// `ReviewSessionStore.init()` takes nothing. What actually stops it is that `ContentView` declares
/// **private stored properties**, which makes its synthesized memberwise initializer `private` —
/// and `@testable` raises `internal` to visible, never `private`. (Deliberately not a count: one
/// added property would make a number here wrong, and the mechanism is what the reader needs.)
/// That is a wall, where "it needs a
/// live sync manager" merely sounds like one; the distinction matters because the second invites
/// someone to spend an afternoon building fixtures that could never have been enough.
///
/// The same fact answers "why is there no Browse render test". Browse is not a view type — it is a
/// `Workspace` case, a `ContentLayout` case, and `browseLayout`, a member of this unmountable
/// struct. What it *draws* is `PaneHeader`, `FileTreeView` and `PersonView`, and all three are
/// already render-tested inside their own packages, where the rendering harnesses and the
/// `machinePinned` gate live. A render test mounted here could only re-render one of those three
/// under a Browse-sounding name, which measures the component and not the wiring — the "adjacent to
/// the claim" shape this codebase keeps meeting. The wiring is what this file is for.
///
/// A source scan is only worth having with its guards, so: every reader fails loudly rather than
/// handing on a haystack that is missing or implausibly short, every assertion names a string whose
/// absence IS the regression, and `testTheScanCanActuallyFail` proves the reader is looking at real
/// text rather than passing on an empty string. Several checks also assert the OLD shape is gone,
/// because "the new call is present" stays true if someone leaves both in.
///
/// **What a check reads is chosen by what it is about.** A check about one file's contents names
/// that file (`macAppSources` would let another file answer for it); a check about a call site reads
/// `MacApp/` as a whole, because which file a member happens to sit in is not something these tests
/// were ever meant to pin — see `macAppSources`.
@Suite struct BrowseWorkspaceCallSiteTests {

    /// One named file — for the checks that really are about that file: the positive control, and
    /// the two negatives whose string another file says for legitimate reasons.
    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)          // …/SyncCloudTests/<this>.swift
            .deletingLastPathComponent()                   // …/SyncCloudTests
            .deletingLastPathComponent()                   // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        // `#require`, not `#expect`: a file that exists but is TRUNCATED — a bad merge, a
        // half-written checkout — records one issue and then hands the short string on, after which
        // every `contains` here answers false and every `!contains` answers true. One quiet issue
        // in front of a page of green is the wrong signal; stop instead. The argument is
        // `OrganizeScopeCallSiteTests.source`'s, and this suite is where the pattern was copied
        // without it.
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// The same text with whole-line `//` comments removed — for counting, where prose describing a
    /// member by name would otherwise be counted as the member.
    /// The shared stripper — see ``sourceCodeOnly(_:)``. Four suites in this target carried a
    /// byte-identical copy of it; consolidating `body(of:in:)` and leaving the thing it depends on
    /// duplicated would have been half a fix.
    static func codeOnly(_ source: String) -> String { sourceCodeOnly(source) }

    /// One declaration's body, bounded by its **closing brace** rather than a character count.
    ///
    /// Two scans here took fixed windows (900 and 1,600 characters) of `browseLayout`. Both were
    /// silently wrong the moment that member grew: the 1,600 one already overran the body into the
    /// next doc comment, and the 900 one stopped covering its own assertions. A window that has to
    /// be re-tuned whenever the code it reads changes length is a spurious failure waiting to
    /// happen — the same argument `OrganizeScopeCallSiteTests.body(of:in:)` makes.
    ///
    /// Four more windows in this file were making the same mistake more quietly. Measured: the 260
    /// taken after `paneSelectionNodes` ran 108 characters past that member's 152-character body and
    /// into `paneActionBar`'s doc comment, so both of its `!contains` checks were being answered by
    /// *prose* — and they answered "absent" only on the accident that the sentence they landed in
    /// says "the active pane" with a space rather than `activePane`. The other three (120, 140 and
    /// 1,200) were the same window one edit away from the same thing. All four read a body now.
    ///
    /// The reading itself is ``declarationBody(of:in:)``, shared with the other two suites in this
    /// target that had grown their own copy.
    ///
    /// This copy grew the uniqueness guard `OrganizeScopeCallSiteTests` carries, and inherited its
    /// flaw with it: the count ran over comment-stripped source while `range(of:)` still searched
    /// the raw text, so a decoy in a doc comment above the real declaration passed the guard and
    /// was still the slice that came back. That matters more here, not less, now that the haystack
    /// can be the whole of `MacApp/`. The shared reader searches the stripped text too.
    static func body(of declaration: String, in source: String) throws -> String {
        try declarationBody(of: declaration, in: source)
    }

    /// The positive control. Every other test here asserts that some string is present; if the
    /// reader silently returned the wrong file they would all fail loudly — but the several that
    /// assert an ABSENCE would pass, which is the direction that goes unnoticed.
    ///
    /// **This one keeps naming a file, and that is its whole job**: proving the reader reads real
    /// text needs a text known to contain something and known not to contain something else. The
    /// checks below read `MacApp/` as a whole precisely because they are not about where a call
    /// lives; this one is about whether the reader works at all.
    @Test func testTheScanCanActuallyFail() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("func paneColumn(isLeft: Bool)"), "this file is not ContentView")
        #expect(!content.contains("a string that is definitely not in ContentView"))
    }

    /// The reader's own control: **a decoy in a comment must not become the answer.**
    ///
    /// This is the case the uniqueness guard was written for and did not cover, because the count
    /// ran over comment-stripped source while the search ran over the raw text. The fixture below
    /// is exactly that shape — a commented-out copy of the declaration above the real one — and
    /// under the old reader the first `#expect` got `decoy` and the second got nothing, with the
    /// guard green. Both halves read the stripped text now.
    ///
    /// The second fixture is the other direction, and the reason the count is not simply run over
    /// the raw source: a doc comment that *names* the member must not be counted as a second
    /// declaration. That version failed a correct implementation once already.
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
        // Plainly, not wrapped: the failure worth seeing here is the reader's own `#require`
        // firing, and it reports itself.
        #expect(try declarationBody(of: "func target() -> Int {", in: mentioned)
                    .contains("return real"))

        // And a genuine second declaration still stops the run rather than being read silently.
        // `withKnownIssue` rather than `#expect(throws:)` because the refusal is a `#require`,
        // which RECORDS an issue as well as throwing — caught by `#expect(throws:)`, that issue
        // still fails this test. This form asserts the refusal in both directions: it absorbs the
        // issue, and it fails if none is recorded.
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

    /// Browse resolves its layout BEFORE the pane-hiding question is asked. The pane is the whole
    /// window there, so "panes hidden" would mean an empty window — and while no control in Browse
    /// can write that override today, a stray key in the stored map must not be able to blank the
    /// workspace either.
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
    ///
    /// Space → Quick Look used to be checked here too, as a `singleSource: true` handler written
    /// out in this function. It has moved inside `paneColumn`, onto the file list — a handler on the
    /// whole column also covered that pane's search field and ate the spaces typed into it. Browse
    /// still gets it, by getting the same column; `PaneQuickLookScopeTests` is where that now lives,
    /// including the `singleSource` resolution this used to pin.
    @Test func testTheBrowseLayoutKeepsTheRegionFrame() throws {
        let body = try Self.body(of: "func browseLayout(geo: GeometryProxy)",
                                 in: try macAppSources())
        #expect(body.contains("paneColumn(isLeft: true)"))
        #expect(body.contains(".panesRegionFrame(surfaceStyle, level: glassLevel)"))
    }

    /// Nothing to collapse to: the header's collapse rung is nil in Browse, and `railSpine` — the
    /// only control that could otherwise reach `togglePanesForCurrentTab` — is drawn by
    /// `singleSourceLayout`, which Browse never takes.
    ///
    /// The gather's "Open" calls it too now, but only behind `contentLayout == .singleCollapsed`,
    /// a layout Browse resolves before the flag is read — so Browse still writes no override, and
    /// `contentLayout`'s assumption that it never does still holds.
    @Test func testTheCollapseRungIsNotOfferedInBrowse() throws {
        let content = try macAppSources()
        #expect(content.contains("onCollapse: layoutMode == .singleSource && selectedWorkspace != .browse"),
                "Browse offers a collapse rung — it would hide the only thing in the window")
    }

    // MARK: The view-mode key

    /// One member decides which of the three stored presentations is in play. Restated per call
    /// site — as it was before Browse existed — the site that got missed would show Browse in the
    /// rail's stack and write the user's choice into the rail's key.
    @Test func testEveryViewModeCallSiteGoesThroughTheOneResolver() throws {
        let content = try macAppSources()
        #expect(content.contains("let mode: PaneViewMode = resolvedViewMode(isLeft: isLeft)"))
        #expect(content.contains("viewMode: resolvedViewModeBinding(isLeft: isLeft)"))
        // The old two-way ternary must survive in exactly two places — the read resolver and the
        // write resolver — and nowhere else. Counted rather than banned outright, because the
        // resolvers are where it belongs; every OTHER copy is a surface that will not see Browse.
        //
        // This count is what caught the third surface: `shortcutPreviewColumn` spelled the same
        // ternary out for itself, so ⇧⌘P in Browse asked the rail's mode about a pane the user was
        // not looking at. It lived in a different file, which is exactly why the count is now taken
        // over the whole of `MacApp/` rather than over `ContentView.swift`: a fourth copy in a fifth
        // file is the same defect, and counting one file could not see it.
        let occurrences = Self.codeOnly(content)
            .components(separatedBy: "layoutMode == .singleSource ? railViewMode").count - 1
        #expect(occurrences == 2,
                "the rail-or-pane ternary appears \(occurrences) times in MacApp/ — it belongs in `resolvedViewMode` and `resolvedViewModeBinding` and nowhere else")
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

    // MARK: The preview key

    /// **Browse's preview is its own.** Turning the preview off to compare two providers used to turn
    /// it off in Browse as well: one key, `paneColumnShowsPreview`, read straight from `@AppStorage`
    /// by the pane, by the header's pill and by ⇧⌘P.
    ///
    /// Which of the two keys is in play is a question only this view can answer, so the split lives
    /// or dies on all three writers going through the one resolver. The three `@AppStorage`
    /// declarations are gone, and their absence is asserted: "the resolver exists" stays true if one
    /// of them is left behind, and the one left behind is the surface that keeps the old bug.
    ///
    /// The keys' own distinctness is `PaneViewModeTests.testBrowseStoresItsPreviewApartFromEverySurface`
    /// — this is about the wiring, which is what no other suite can see.
    @Test func testEveryPreviewWriterGoesThroughTheOneResolver() throws {
        let macApp = try macAppSources()
        let body = try Self.body(of: "var resolvedPreviewBinding: Binding<Bool> {", in: macApp)
        #expect(body.contains("selectedWorkspace == .browse"),
                "the preview resolver does not ask which workspace is on screen — Browse gets Compare's key")
        #expect(body.contains("$browsePreviewColumnEnabled"))
        #expect(body.contains("$previewColumnEnabled"))

        // The three writers, each on the resolved answer: the pane, the header's pill, and ⇧⌘P.
        #expect(macApp.contains("previewEnabled: resolvedPreviewBinding"),
                "a surface takes the preview binding some other way")
        let chord = try Self.body(of: "var shortcutPreviewColumn: Binding<Bool>? {", in: macApp)
        #expect(chord.contains("return resolvedPreviewBinding"),
                "⇧⌘P flips a key it picked for itself — in Browse it would turn Compare's preview off")

        // **Every surface that draws a pane takes it — counted against the surfaces themselves rather
        // than against a fixed number.** Both `previewEnabled:` parameters default to a `.constant`,
        // which a header or a pane accepts in silence: the pill still draws, the column menu's Toggle
        // still appears, and neither writes anything. A hardcoded `== 2` would have to be re-tuned by
        // whoever adds a third surface — the same person who would be re-tuning it *instead* of wiring
        // theirs up. Tied to the construction count, adding a surface without the binding is what fails.
        let content = try Self.source("ContentView.swift")
        let code = Self.codeOnly(content)
        let surfaces = (code.components(separatedBy: "PaneHeader(").count - 1)
            + (code.components(separatedBy: "FileTreeView(").count - 1)
        let wired = code.components(separatedBy: "previewEnabled: resolvedPreviewBinding").count - 1
        #expect(surfaces > 0, "no pane surface found in ContentView.swift — this count is vacuous")
        #expect(wired == surfaces,
                "ContentView.swift builds \(surfaces) pane surface(s) but hands the resolved preview binding to \(wired) of them — the one missing it takes the parameter's `.constant` default, so its pill and its column menu toggle nothing, silently")

        // No view in MacApp/ may hold an opinion of its own: an `@AppStorage` on the shared key
        // resolves nothing and answers for every surface, Browse included.
        #expect(!macApp.contains("@AppStorage(PaneViewMode.previewColumnDefaultsKey)"),
                "a MacApp view reads the shared preview key directly again")
        // Both properties are declared through the one function, which is what makes
        // `testBrowseStoresItsPreviewApartFromEverySurface` load-bearing rather than a fact about two
        // string literals: were those arms ever to return the same key, these two would silently
        // become one stored value again.
        #expect(content.contains("@AppStorage(PaneViewMode.previewColumnKey(isBrowse: false))"))
        #expect(content.contains("@AppStorage(PaneViewMode.previewColumnKey(isBrowse: true))"))

        // The same regression inside the packages needs no scan here, and deliberately gets none —
        // both views are caught on pixels, in their own packages, and both were verified by putting
        // the `@AppStorage` back and watching them fail:
        // `ColumnPreviewLayoutTests.testFlippingTheSettingRelaysAMountedPane` flips the pane's
        // binding under a mounted pane and reads the columns' widths back, and
        // `PaneHeaderPreviewPillTests` counts the pixels the pill moves between the two states.
        // (NOT `DashboardSnapshotTests.paneHeaderWideWithPreviewOff`, which measurably does not
        // catch it — see that suite.)
    }

    // MARK: Delete acts on its own pane

    /// The pane bar's Delete is fed from THIS pane's selection, never the active pane's.
    ///
    /// `barSelectionNodes` is the tempting reuse — it is already resolved once per render right
    /// beside it — and it is wrong twice: it runs through `paneActionBarSideActive`, which opens
    /// `guard layoutMode == .compare`, so it is empty in Browse and on the Organize rail entirely,
    /// and empty for Compare's inactive side even when that side has a selection.
    @Test func testTheHeaderDeleteTakesThisPanesSelection() throws {
        let content = try macAppSources()
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
    ///
    /// **Both bodies are brace-bounded, and the two `!contains` are why it matters.** The 260-character
    /// window this used to take ran 108 characters past the resolver's 152-character body and into
    /// `paneActionBar`'s doc comment ("docked at the bottom of the active pane"), so both negatives
    /// were being asked of prose — answering "absent" only because that sentence happens to spell it
    /// with a space. A body cannot drift like that: it ends where the member ends.
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
    /// take their titles from the OTHER pane, which does not exist there.
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
    ///
    /// **Two named files, deliberately, and this one is not over-constraint**: the claim is that
    /// *two distinct layouts* mount it, and over a concatenated `MacApp/` the two `contains` checks
    /// would collapse into the same check — one layout mounting it twice would pass.
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
        let body = try Self.body(of: "func browseLayout(geo: GeometryProxy)",
                                 in: try macAppSources())
        #expect(body.contains("if let scope = personScope"),
                "browseLayout does not branch on a live gather")
        // **The property the restructure is about**: ONE structure, so the file column keeps its
        // identity when a gather opens or clears. Both assertions above were true of the
        // two-branch version this replaced — the column appeared in each arm — so neither could
        // see the teardown. A single mount of the column, and no `else`, is what cannot.
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
