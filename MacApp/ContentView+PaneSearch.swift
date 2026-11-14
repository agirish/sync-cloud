import SwiftUI
import AppKit
import Dashboard
import Design
import FileExplorer
import Sync

/// One pane's search field: the query, whether it is showing, and where ↩ has walked to.
///
/// Not the results. The query is the user's and survives a republish; the results are derived,
/// large, and rebuilt whenever either tree moves. Keeping them apart lets the field re-render on a
/// keystroke while the recomputation waits out the debounce.
struct PaneSearchFieldState: Equatable {
    var query: String = ""
    var isExpanded: Bool = false
    /// Which hit ↩/⇧↩ have walked to. Not clamped here: the results it indexes are rebuilt under it
    /// on every keystroke, so `PaneSearchWalk.advance` and `PaneSearchResults.hit(at:)` clamp it.
    var hitIndex: Int = 0
    /// Bumped exactly when the user asks to be taken somewhere (a debounced new query, or ↩/⇧↩),
    /// and the pane's reveal fires on this and nothing else.
    ///
    /// **Never** key the reveal on the results' generation: that moves on every republish of
    /// either tree (a scan, a copy, a hidden-files toggle), and with a query parked in the field
    /// each one would snap the selection back, re-centre the viewport, re-open the Columns stack and
    /// re-expand collapsed folders, undoing whatever the user did since the walk. A republish
    /// recomputes results, annotations and the walk's index, and moves the user nowhere.
    var revealNonce: Int = 0
}

/// What a pane's debounced recomputation is keyed on: which pane, what was typed, and which publish
/// of each tree it runs against.
///
/// A named type because `.task(id:)` restarts exactly when this compares unequal, so this `==`
/// defines when the search re-runs. Without `treeVersion` a republish would leave the results naming
/// paths that no longer exist, and the walk would reveal nothing and select a ghost.
struct PaneSearchRecomputeKey: Equatable {
    let isLeft: Bool
    let query: String
    let treeVersion: Int
    /// The opposite pane's publish counter. The side annotation ("both sides" / "left only") is read
    /// from that tree, so without this a rescan or copy over there would leave every annotation
    /// wrong, such as "left only" on a file just copied across.
    let otherTreeVersion: Int
}

/// Searching inside a pane's tree, the host's half: owning the field's state, recomputing results
/// off a debounce, and answering ⌘F.
///
/// The `@State` is declared in `ContentView.swift` (an extension cannot add stored properties);
/// everything that reads or writes it is here.
extension ContentView {

    /// How long the query rests before the tree is searched.
    ///
    /// It protects two things. After a result set lands both panes re-render and the walk reveals a
    /// hit, so searching per keystroke would open a folder for every prefix of the word being typed.
    /// And the search itself is not cheap: about 77–142 ms in Release on a 40,000-node tree, which
    /// is why `recomputeSearch` runs off the main actor. A debounce makes the cost rarer; it never
    /// makes paying it on the main thread acceptable.
    static let searchDebounce: Duration = .milliseconds(150)

    /// This pane's field state, as a binding the header can write.
    func paneSearchState(isLeft: Bool) -> Binding<PaneSearchFieldState> {
        isLeft ? $leftPaneSearch : $rightPaneSearch
    }

    /// This pane's results. The rail reads the LEFT pane's, because it is the left pane.
    func paneSearchResults(isLeft: Bool) -> PaneSearchResults {
        isLeft ? leftSearchResults : rightSearchResults
    }

    /// Recomputes one pane's results against the tree it is showing now.
    ///
    /// Called from the debounce and on every republish, because a scan, a delete or a filter change
    /// leaves hits pointing at rows that are gone, and the walk would select a ghost.
    ///
    /// The side annotation reads the opposite pane's already-walked tree: one pass over nodes in RAM,
    /// no disk access. On the single-source rail there is no opposite pane, so no annotation at all
    /// rather than a wrong one.
    func recomputeSearch(isLeft: Bool) async {
        let query = (isLeft ? leftPaneSearch : rightPaneSearch).query
        // Nothing asked and nothing showing: a republish would only stamp a new generation.
        guard !PaneLogic.searchStaysIdle(previous: paneSearchResults(isLeft: isLeft), query: query)
        else { return }
        let pane = paneContext(isLeft: isLeft)
        let plan = PaneLogic.searchPlan(isLeft: isLeft, isSingleSource: layoutMode == .singleSource,
                                        query: query)
        let generation = paneSearchResults(isLeft: isLeft).generation + 1
        // Everything below the hop reads only `Sendable` values captured here. The trees are
        // stamped `PaneTree` snapshots, so the background pass cannot see a half-applied republish.
        let tree = pane.tree
        // The other pane's tree before its type filter: a file that filter hides is still on that
        // side, and the shown tree would mark it "only on left".
        let otherNodes = syncManager.searchSideAnnotationNodes(forPaneIsLeft: isLeft)
        let otherSide = pane.otherTree.side
        let annotatesSides = plan.annotatesSides

        let results = await Task.detached(priority: .userInitiated) {
            PaneSearchResults(
                side: plan.side, generation: generation, query: query, tree: tree,
                otherPaths: annotatesSides
                    ? PaneTreeSearch.relativePaths(in: PaneTree(side: otherSide, version: 0, nodes: otherNodes))
                    : nil)
        }.value

        // **`Task.detached` does not inherit cancellation, and awaiting its `.value` does not
        // throw.** When `.task(id:)` cancels this (every keystroke does), the detached pass still
        // finishes and resumes here with a result for a stale query. Publishing it would overwrite a
        // newer answer, the race `FileRowView.resolveBadge` documents one layer down.
        //
        // Both guards: cancellation covers a superseded key (a keystroke, a republish), and the
        // query re-read covers the field being cleared or closed meanwhile.
        guard !Task.isCancelled,
              (isLeft ? leftPaneSearch : rightPaneSearch).query == query else { return }

        // The walk moves with the results and only with them, so stale results dropped above never
        // move the user. `walkIndex(after:standingAt:)` keeps them on the file they were reading
        // across a republish, rather than restarting the walk whenever a background scan lands.
        let state = paneSearchState(isLeft: isLeft)
        let previous = isLeft ? leftSearchResults : rightSearchResults
        let landed = results.walkIndex(after: previous, standingAt: state.wrappedValue.hitIndex)
        if isLeft {
            leftSearchResults = results
        } else {
            rightSearchResults = results
        }
        state.wrappedValue.hitIndex = landed
        // The reveal fires only for a new question (the query moved), never for a republish of the
        // same one. The rule is in `PaneLogic` where a test can hold it; see
        // `PaneSearchFieldState.revealNonce` for why.
        if PaneLogic.searchAsksNewQuestion(previous: previous, results: results) {
            state.wrappedValue.revealNonce &+= 1
        }
    }

    /// Walks to the next (`reverse: false`) or previous hit — ↩ and ⇧↩.
    func advancePaneSearch(isLeft: Bool, reverse: Bool) {
        let results = paneSearchResults(isLeft: isLeft)
        let state = paneSearchState(isLeft: isLeft)
        state.wrappedValue.hitIndex = PaneSearchWalk.advance(
            state.wrappedValue.hitIndex, count: results.hits.count, reverse: reverse)
        // A walk is the other thing that reveals (with no hits the pane ignores the bump). A wrap
        // over one hit re-lands the same index, so the nonce bumps unconditionally.
        state.wrappedValue.revealNonce &+= 1
    }

    /// Space → Quick Look for one pane, hung off that pane's file list rather than its column.
    ///
    /// **Keep it on the list.** The pane header holds the search field, and `.onKeyPress` on the
    /// whole column would catch every Space typed into it: the space would never reach the query,
    /// and Quick Look would open on whatever the pane has selected and take key focus, so typing
    /// stops. Scoped to the list, the header is outside the handler and Space in the list previews
    /// as before.
    ///
    /// `singleSource` follows the layout: on a one-pane workspace the hidden Compare pane's leftover
    /// right-hand selection must not hijack the preview.
    ///
    /// `followsPane: true` marks the preview as the panes': it re-targets as the selection moves and
    /// closes when it is cleared (`CurrentSelection.previewFollow`). A Differences row or a lens card
    /// opens the same panel without that claim, since a pane click says nothing about their preview.
    ///
    /// Takes no side, though both of Compare's lists install it: the target is `CurrentSelection`'s
    /// answer across both panes, so whichever list holds focus, Space previews the same thing.
    func paneQuickLook() -> KeyPress.Result {
        // See `paneChordsSuspended`: a pending pick owns the keyboard, and the overlay that draws
        // it does not take key from the AppKit table underneath.
        guard !paneChordsSuspended else { return .ignored }
        guard let targetPath = CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: layoutMode == .singleSource
        ) else { return .ignored }
        toggleQuickLook(URL(fileURLWithPath: targetPath), followsPane: true)
        return .handled
    }

    /// ↩ renames the selected row: Finder's chord, and the one people try first in any file list.
    ///
    /// **A pane key handler, never a menu key equivalent.** A menu equivalent outranks the field
    /// editor and every default button, so a bare ↩ there would take the key from the destination
    /// picker, the ⌘K field, a rename field and every sheet. Finder registers no key for Rename
    /// either. `.onKeyPress` is focus-scoped, so this fires only while the file list holds focus.
    ///
    /// The action is the menu item's own closure, so File ▸ Rename and ↩ cannot drift apart:
    /// `shortcutPaneRowVerbs.rename` is `nil` unless exactly one row is selected, and `.ignored`
    /// then lets ↩ fall through to whatever else would have had it.
    func paneRename() -> KeyPress.Result {
        // **Ask the suspension rule here too.** The menu item is silenced by the publication's
        // `suspended:` flag, but this reads `shortcutPaneRowVerbs` directly. Focus scoping is not
        // enough (see `paneChordsSuspended`): over a pending destination pick, ↩ would rename a row
        // and eat the keystroke the picker's default button is waiting for.
        guard !paneChordsSuspended else { return .ignored }
        guard let rename = shortcutPaneRowVerbs.rename else { return .ignored }
        rename()
        return .handled
    }

    /// What ⌘F opens and, through `shortcutTargetIsLeft`, what ⌘[, ⌘] and ⇧⌘N act on. The rule is
    /// `PaneLogic.focusedPaneIsLeft`, where it can be tested; this supplies the three live facts.
    var paneSearchTargetIsLeft: Bool {
        PaneLogic.focusedPaneIsLeft(isSingleSource: layoutMode == .singleSource,
                                     focusedSide: syncManager.focusedPaneSide,
                                     activePane: activePane)
    }

    /// ⌃⇥: move the pane-scoped chords to the other comparison pane.
    ///
    /// `nil` on the single-source workspaces: an enabled item that moved focus to something not on
    /// screen would be worse than a disabled one, and the item names a second pane that isn't there.
    var switchPaneFocusAction: PaneFocusSwitch? {
        // ⌃⇥ cycles tabs in Browse, which has one pane but may have a strip of tabs. Compare keeps
        // it as a pane switch; the menu item's title says which.
        if layoutMode != .compare, selectedWorkspace == .browse {
            guard syncManager.paneTabs(isLeft: true).count > 1 else { return nil }
            return .nextTab { cycleTab(forward: true, isLeft: true) }
        }
        guard layoutMode == .compare else { return nil }
        let target = PaneLogic.focusSwitchTarget(isSingleSource: false,
                                                 focusedSide: syncManager.focusedPaneSide,
                                                 activePane: activePane)
        let name = target == .left ? paneNames.left : paneNames.right
        // A bare state write, with no side effect on either pane. Closing the vacated pane's search
        // field to make the move visible would discard a query the user typed, for decoration. The
        // focused pane's accent border (`ActivePaneMark`) already shows the move.
        return PaneFocusSwitch(targetName: name) {
            syncManager.noteFocusedPane(target, because: "⌃⇥ (View ▸ Focus Other Pane)")
        }
    }

    /// Opens the focused pane's search field or, if it is already open, closes and reopens it to put
    /// the caret back.
    ///
    /// The reopen makes a second ⌘F useful. The field claims focus on appear (`ExpandingSearchField`),
    /// so once the caret has gone to the file table, as it does when you walk to a hit, the keyboard
    /// has no other way to get it back.
    func beginPaneSearch() {
        let isLeft = paneSearchTargetIsLeft
        let state = paneSearchState(isLeft: isLeft)
        if state.wrappedValue.isExpanded {
            state.wrappedValue.isExpanded = false
        }
        // Next turn, so the field is really re-inserted: a `FocusState` write landing in the
        // transaction that inserts the field is silently dropped, which is also why the field's own
        // focus claim is a Task hop.
        let reduceMotion = self.reduceMotion
        DispatchQueue.main.async {
            withDesignAnimation(ExpandingSearch.animation, reduceMotion: reduceMotion) {
                state.wrappedValue.isExpanded = true
            }
        }
    }
}

/// The Edit ▸ Find item. A `View` rather than an inline `Button`, because `@FocusedValue` is a
/// dynamic property only a view can hold, as with `HelpBook`'s Activity Log item.
///
/// **⌘F has to be a menu item.** `.onKeyPress` is focus-scoped, and a pane search starts while
/// focus sits in a file table, where the key would never arrive. A menu item also shows its chord
/// in the menu bar, where people look for it.
///
/// It routes ⌘F to what the user is looking at: the open document when the caret is in Edit's
/// document, the focused pane everywhere else. The route is resolved at key press from
/// `NSApp.keyWindow`'s first responder, so no focus tracking in SwiftUI state is needed; the cost is
/// a title that can't name the destination, so it says "Find…", true of both.
///
/// **Route on `EditorDocumentSurface`, not `TextEditingChord`.** The latter asks whether the
/// responder `is NSTextView`, which every field editor is, so a pane's own search box would open
/// the document's find bar.
///
/// A PDF open in Edit comes first (`FindMenuRoute.find`): its reader has its own find card, and
/// nothing in it is a text view this walk could find.
struct FindInPaneCommand: View {
    /// Set by whichever scene is focused; `nil` when no window is up, so the item is disabled rather
    /// than silently doing nothing.
    @FocusedValue(\.beginPaneSearch) private var begin
    @FocusedValue(\.pdfFind) private var pdfFind

    var body: some View {
        Button("Find…") {
            // The document first: when the caret is in it, the pane search is not what was meant.
            FindMenuRoute.find(pdf: pdfFind,
                               showDocumentFind: { EditorDocumentSurface.showFindBar(in: NSApp.keyWindow) },
                               beginPaneSearch: begin)
        }
        .keyboardShortcut(AppChord.findInPane.key, modifiers: AppChord.findInPane.modifiers)
        .disabled(!FindMenuRoute.findIsEnabled(pdf: pdfFind, beginPaneSearch: begin))
    }
}

private struct BeginPaneSearchKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// Opens the focused pane's search field. Published by `ContentView` and read by the Find menu
    /// item, which lives in the App scope and can otherwise see none of the window's state.
    var beginPaneSearch: (() -> Void)? {
        get { self[BeginPaneSearchKey.self] }
        set { self[BeginPaneSearchKey.self] = newValue }
    }
}
