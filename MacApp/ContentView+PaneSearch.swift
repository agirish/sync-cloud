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
    /// The search itself is cheap — in-memory string matching over nodes already in RAM, a few
    /// milliseconds for a large tree — and the debounce is not there to protect it. It protects what
    /// happens AFTERWARDS: a new result set re-renders both panes and, through the walk's reset,
    /// reveals a hit. Doing that per keystroke means opening a folder for every prefix of the word
    /// being typed, which is the tree detonating slowly instead of all at once.
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
    func recomputeSearch(isLeft: Bool) {
        let pane = paneContext(isLeft: isLeft)
        let query = (isLeft ? leftPaneSearch : rightPaneSearch).query
        let otherPaths: Set<String>? = {
            guard !query.isEmpty, layoutMode != .singleSource else { return nil }
            return PaneTreeSearch.relativePaths(in: pane.otherTree)
        }()
        if isLeft {
            leftSearchGeneration += 1
            leftSearchResults = PaneSearchResults(
                side: .left, generation: leftSearchGeneration, query: query,
                tree: pane.tree, otherPaths: otherPaths)
        } else {
            rightSearchGeneration += 1
            rightSearchResults = PaneSearchResults(
                side: .right, generation: rightSearchGeneration, query: query,
                tree: pane.tree, otherPaths: otherPaths)
        }
    }

    /// Walks to the next (`reverse: false`) or previous hit — ↩ and ⇧↩.
    func advancePaneSearch(isLeft: Bool, reverse: Bool) {
        let results = paneSearchResults(isLeft: isLeft)
        let state = paneSearchState(isLeft: isLeft)
        state.wrappedValue.hitIndex = PaneSearchWalk.advance(
            state.wrappedValue.hitIndex, count: results.hits.count, reverse: reverse)
    }

    /// What ⌘F opens. The rule itself is `PaneLogic.searchTargetIsLeft`, where it can be tested —
    /// this only supplies the two live facts.
    var paneSearchTargetIsLeft: Bool {
        PaneLogic.searchTargetIsLeft(isSingleSource: layoutMode == .singleSource,
                                     activePane: activePane)
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
            .keyboardShortcut("f", modifiers: .command)
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
