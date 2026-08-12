import SwiftUI
import AppKit
import Dashboard
import Design
import FileExplorer
import Sync

/// One pane's search field: the query, whether it is showing, and where ↩ has walked to.
///
/// Deliberately not the results. The query is what the user owns and it survives a republish; the
/// results are derived, are rebuilt whenever either moves, and are large. Keeping them apart is what
/// lets the field re-render on a keystroke while the recomputation waits out the debounce.
struct PaneSearchFieldState: Equatable {
    var query: String = ""
    var isExpanded: Bool = false
    /// Which hit ↩/⇧↩ have walked to. Not clamped here — the results it indexes are rebuilt
    /// underneath it on every keystroke, so the clamping belongs where the count is known
    /// (`PaneSearchWalk.advance`, `PaneSearchResults.hit(at:)`), and both do it.
    var hitIndex: Int = 0
    /// Bumped exactly when the user asks to be TAKEN somewhere — a (debounced) new query, or
    /// ↩/⇧↩ — and the pane's reveal fires on this and nothing else.
    ///
    /// This replaces a token built from the results' generation, and the difference is the whole
    /// point: the generation moves on every recomputation, and a recomputation runs on every
    /// republish of EITHER tree (a scan, a copy, a hidden-files toggle — "constantly", per the
    /// pane's own docs). With a query parked in the field, every one of those re-fired the reveal:
    /// selection snapped back to the current hit, the viewport re-centred on it, Columns re-opened
    /// the stack the user had navigated out of, and manually collapsed folders re-opened — undoing
    /// whatever the user had done since the walk. Two earlier fixes each closed one trigger of
    /// this clobber (the index reset, the pane's reappearance) and left the republish one open.
    /// A republish now recomputes results, annotations and the walk's standing index — and moves
    /// the user nowhere.
    var revealNonce: Int = 0
}

/// What a pane's debounced recomputation is keyed on: which pane, what was typed, and which publish
/// of the tree it will run against.
///
/// A named type rather than a tuple because `.task(id:)` restarts exactly when this compares unequal,
/// so this `==` is the definition of "when does the search re-run" — and one of its three fields is
/// easy to leave out. `treeVersion` is that one: without it a republish leaves the results naming
/// paths that no longer exist, and the walk then reveals nothing and selects a ghost.
struct PaneSearchRecomputeKey: Equatable {
    let isLeft: Bool
    let query: String
    let treeVersion: Int
    /// The OPPOSITE pane's publish counter. The side annotation ("both sides" / "left only") is read
    /// out of that tree, so a rescan or a copy over there makes every annotation on screen a claim
    /// about a tree that no longer exists — "left only" on a file that was just copied across is
    /// precisely the answer the user searched to get, reported wrong.
    let otherTreeVersion: Int
}

/// Searching inside a pane's tree: the host's half — owning the field's state, recomputing the
/// results off a debounce, and answering ⌘F.
///
/// Split out of `ContentView.swift` for size, like the toolbar. The `@State` itself has to be
/// declared over there (an extension cannot add stored properties); everything that reads or writes
/// it is here.
extension ContentView {

    /// How long the query rests before the tree is searched.
    ///
    /// It protects two things. The obvious one is what happens AFTER a result set lands: both panes
    /// re-render and the walk's reset reveals a hit, so searching per keystroke would open a folder
    /// for every prefix of the word being typed — the tree detonating slowly instead of all at once.
    ///
    /// The other is the search itself, which is **not** the "few milliseconds" this comment used to
    /// claim. Measured in Release on a 40,000-node tree, the size `PaneTree` documents for a real
    /// pane: 262 ms with the original matcher, 77–142 ms after `PaneTreeSearch.match` was rewritten.
    /// That is why `recomputeSearch` runs off the main actor — a debounce shortens how often you pay
    /// a cost, and never makes paying it on the main thread acceptable.
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
    /// Called from the debounce below and on every republish, because a result set names paths in a
    /// tree that has since been rebuilt — a scan, a delete or a filter change leaves hits pointing at
    /// rows that are no longer there, and the walk would then reveal nothing and select a ghost.
    ///
    /// The side annotation is the opposite pane's already-walked tree and nothing else: one pass over
    /// nodes in RAM, no disk access, no new scan. On the single-source rail there is no opposite pane
    /// — `nil`, so no annotation is produced rather than a wrong one.
    func recomputeSearch(isLeft: Bool) async {
        let pane = paneContext(isLeft: isLeft)
        let query = (isLeft ? leftPaneSearch : rightPaneSearch).query
        let plan = PaneLogic.searchPlan(isLeft: isLeft, isSingleSource: layoutMode == .singleSource,
                                        query: query)
        let generation = (isLeft ? leftSearchGeneration : rightSearchGeneration) + 1
        // Everything below the hop reads only `Sendable` values captured here — the two trees are
        // `PaneTree`, which is a stamped snapshot, so the background pass cannot observe a
        // republish half-applied.
        let tree = pane.tree
        let otherTree = pane.otherTree
        let annotatesSides = plan.annotatesSides

        let results = await Task.detached(priority: .userInitiated) {
            PaneSearchResults(
                side: plan.side, generation: generation, query: query, tree: tree,
                otherPaths: annotatesSides ? PaneTreeSearch.relativePaths(in: otherTree) : nil)
        }.value

        // **`Task.detached` does not inherit cancellation, and awaiting its `.value` does not
        // throw.** So when `.task(id:)` cancels this — which every keystroke does — the detached
        // pass runs to completion anyway and resumes here carrying a result for a query nobody is
        // asking about any more. Assigning it would publish a stale answer over a newer one, which
        // is exactly the race `FileRowView.resolveBadge` documents one layer down.
        //
        // Both guards, because they catch different things: cancellation covers a superseded key
        // (a keystroke, a republish), and the live query re-read covers the field having been
        // cleared or closed while this was out.
        guard !Task.isCancelled,
              (isLeft ? leftPaneSearch : rightPaneSearch).query == query else { return }

        // The walk moves with the results, and only with them. Setting it at the CALL SITE — which
        // is what this used to do — moved the user's position even when the results that prompted
        // it were dropped just above for being stale. `walkIndex(after:standingAt:)` also keeps them
        // on the file they were reading across a republish, rather than restarting the walk every
        // time a background scan lands.
        let state = paneSearchState(isLeft: isLeft)
        let previous = isLeft ? leftSearchResults : rightSearchResults
        let landed = results.walkIndex(after: previous, standingAt: state.wrappedValue.hitIndex)
        if isLeft {
            leftSearchGeneration = generation
            leftSearchResults = results
        } else {
            rightSearchGeneration = generation
            rightSearchResults = results
        }
        state.wrappedValue.hitIndex = landed
        // The reveal fires only for a NEW QUESTION — the query moved — never for a republish of
        // the same one. The rule lives in `PaneLogic` where a test can hold it; see
        // `PaneSearchFieldState.revealNonce` for what firing on every recomputation used to do.
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
        // A walk is the other thing that reveals (a bump with no hits is a guarded no-op in the
        // pane) — and with the same index re-landed by a wrap over one hit, the nonce is the only
        // part of the signal that moves, so it bumps unconditionally.
        state.wrappedValue.revealNonce &+= 1
    }

    /// Space → Quick Look for one pane, hung off that pane's FILE LIST rather than its column.
    ///
    /// **The subtree is the whole fix.** This handler used to sit on the pane column — on
    /// `panesSplit` in Compare, on `paneColumn(isLeft: true)` in the rail and in Browse — back when
    /// a pane column was a header of buttons over a list, and a column-wide scope was the same thing
    /// as a list-wide one. Its own comment said as much: onKeyPress "only fires while key focus is
    /// inside this subtree (the pane Lists) … so text fields elsewhere get Space normally."
    ///
    /// Pane search put a text field INSIDE that subtree, and "elsewhere" stopped covering it. Every
    /// Space typed into a pane's search field was therefore intercepted here: the space never
    /// reached the query, and the Quick Look panel opened over the app on whatever the pane happened
    /// to have selected — the hit the walk had just revealed, which is why it read as "a random
    /// match", or a row from before the search, which is why it sometimes was not a match at all.
    /// The panel then takes key focus, so the next keystroke went nowhere: typing simply stopped.
    /// (`.quickLookPreview` clears its binding only on manual dismissal, so the panel also sat there
    /// naming a stale file through every later query.)
    ///
    /// Scoping to the list restores the original intent rather than adding a special case: the pane
    /// header — search field, breadcrumb, every button on it — is now genuinely "elsewhere", and
    /// Space in the list previews exactly as it always did.
    ///
    /// `singleSource` follows the layout for the same reason it always did: on a one-pane workspace
    /// the hidden Compare pane's leftover right-hand selection must not hijack the preview.
    ///
    /// Takes no side, deliberately, though both of Compare's lists install it: the target is
    /// `CurrentSelection`'s answer across both panes, which is what the single column-wide handler
    /// resolved before. Whichever list holds focus fires, and both get the same answer — so moving
    /// one handler to two changes where Space is heard and nothing about what it previews.
    func paneQuickLook() -> KeyPress.Result {
        guard let targetPath = CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: layoutMode == .singleSource
        ) else { return .ignored }
        toggleQuickLook(URL(fileURLWithPath: targetPath))
        return .handled
    }

    /// What ⌘F opens — and, through `shortcutTargetIsLeft`, what ⌘[, ⌘], ⇧⌘N and ⇧⌘P act on. The
    /// rule itself is `PaneLogic.searchTargetIsLeft`, where it can be tested; this only supplies
    /// the three live facts.
    var paneSearchTargetIsLeft: Bool {
        PaneLogic.searchTargetIsLeft(isSingleSource: layoutMode == .singleSource,
                                     focusedSide: syncManager.focusedPaneSide,
                                     activePane: activePane)
    }

    /// ⌃⇥ — move the pane-scoped chords to the other comparison pane.
    ///
    /// `nil` on the single-source workspaces, which show one pane: an enabled item that moved focus
    /// to something not on screen would be worse than a disabled one, and the menu item names the
    /// destination pane, which there is no second of.
    var switchPaneFocusAction: PaneFocusSwitch? {
        guard layoutMode == .compare else { return nil }
        let target = PaneLogic.focusSwitchTarget(isSingleSource: false,
                                                 focusedSide: syncManager.focusedPaneSide,
                                                 activePane: activePane)
        let name = target == .left ? paneNames.left : paneNames.right
        // Deliberately a bare state write, with no side effect on either pane. Closing the vacated
        // pane's search field was tried as a way to make the chord produce something visible, and
        // it is not worth it: the field holds a query the user typed, `isExpanded` is the only
        // thing hiding it, and discarding a search to animate a focus move trades real state for
        // decoration. What this does not yet have is a resting indicator of which pane is focused
        // — see the note in `ROADMAP.md`.
        return PaneFocusSwitch(targetName: name) { syncManager.focusedPaneSide = target }
    }

    /// Opens the focused pane's search field, or — if it is already open — puts the caret back in it
    /// by closing and reopening.
    ///
    /// The reopen is what makes a second ⌘F useful rather than inert. The field claims focus on
    /// appear (see `ExpandingSearchField`), so a field that is already showing but has lost the caret
    /// to the file table — which is exactly where focus goes the moment you walk to a hit — has no
    /// other way to get it back from the keyboard.
    func beginPaneSearch() {
        let isLeft = paneSearchTargetIsLeft
        let state = paneSearchState(isLeft: isLeft)
        if state.wrappedValue.isExpanded {
            state.wrappedValue.isExpanded = false
        }
        // Next turn, so the field is genuinely re-inserted rather than being told to appear inside
        // the same transaction that removed it — a `FocusState` write landing in the transaction
        // that inserts the field is silently dropped, which is the whole reason the field's own
        // focus claim is a Task hop.
        DispatchQueue.main.async {
            withAnimation(ExpandingSearch.animation) {
                state.wrappedValue.isExpanded = true
            }
        }
    }
}

/// The Edit ▸ Find item. A `View` rather than a `Button` inline in the `.commands` builder, because
/// `@FocusedValue` is a dynamic property and only a view can hold one — the same reason
/// `HelpBook`'s Activity Log item is its own view.
///
/// **⌘F has to be a menu item.** It cannot be `.onKeyPress`: that is strictly focus-scoped, and a
/// pane search is invoked precisely when focus is sitting in a file table, which is where the key
/// would never arrive. A menu item is also the only form that documents itself — the shortcut shows
/// up in the menu bar, which is where someone looks for it.
struct FindInPaneCommand: View {
    /// Set by whichever scene is focused; `nil` when no window is up, which is when the item should
    /// be disabled rather than silently doing nothing.
    @FocusedValue(\.beginPaneSearch) private var begin

    var body: some View {
        Button("Find in Pane…") { begin?() }
            .keyboardShortcut(AppChord.findInPane.key, modifiers: AppChord.findInPane.modifiers)
            .disabled(begin == nil)
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
