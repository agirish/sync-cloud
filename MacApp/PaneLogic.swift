import CoreGraphics
import Dashboard
import Design
import Events
import FileExplorer
import Foundation
import Sync

/// The two panes' selections, as the selection bindings need them. A protocol so
/// `PaneLogic.applySelectionWrite`, which orders a click's two halves, can be driven over a stub in
/// tests instead of a live `FileSyncManager`.
@MainActor
protocol PaneSelectionState: AnyObject {
    var selectedLeftPaths: Set<String> { get set }
    var selectedRightPaths: Set<String> { get set }
    /// Claimed by a non-empty pane write, so Space can tell a pane selection from a Differences one.
    var lastSelectionSurface: SelectionSurface? { get set }
}

extension FileSyncManager: PaneSelectionState {}

/// Orders the deferred half of the one-pane-selected invariant.
///
/// A pane click clears the *other* pane a runloop turn later (clearing it synchronously reloads
/// that pane's `List` mid-commit and drops the click). The queued clear writes a blind `[]`, so if
/// the user clicks the other pane before it drains, it wipes that fresh selection. Each commit
/// takes a token here; a deferral runs only while its token is still the newest.
///
/// A plain counter, not anything observable: this must not invalidate a view. `&+` so a long
/// session can't trap on overflow; only equality is asked of it, and a wrapped token can collide
/// with a live one no sooner than 2^63 clicks.
@MainActor
final class PaneSelectionSequencer {
    private var newest = 0

    /// Records a commit and returns its token.
    func commit() -> Int {
        newest &+= 1
        return newest
    }

    /// Whether `token` is still the newest commit, so the deferral queued with it still speaks for
    /// the pane the user is on.
    func isNewest(_ token: Int) -> Bool { token == newest }
}

/// The @AppStorage provider-id writes needed to repoint the Compare panes at target providers,
/// plus how many of ContentView's id `onChange` handlers those writes will fire.
///
/// Every programmatic pane retarget (pane swap, `compareCopies`, `restoreCompareState`) must
/// suppress the id onChanges its writes trigger, or the handlers clear the lens results and reset
/// navigation. The suppression is a hand-counted contract: one `pendingSwapProviderChanges` unit
/// per id that actually changes (SwiftUI's `onChange` never fires for an equal-value write), or
/// the counter strands and silently swallows the user's next real provider switches. This plan is
/// that count made pure: writers apply `assignments` and seed the counter with `suppressCount`.
struct ProviderPinPlan: Equatable {
    enum Side: Equatable {
        case left
        case right
    }

    /// One id write that really changes the stored value. An equal-value write is omitted: it
    /// neither fires an onChange nor needs suppressing.
    struct Assignment: Equatable {
        let side: Side
        let providerId: String
    }

    /// The id writes to perform, left before right, the order every call site writes in.
    let assignments: [Assignment]

    /// How many id onChanges the assignments will fire, one per real change. The writer adds this
    /// to `pendingSwapProviderChanges` before applying the assignments.
    var suppressCount: Int { assignments.count }

    /// Plans the retarget from the panes' current @AppStorage ids to the target ids, keeping
    /// only the writes that change something.
    static func make(
        currentLeft: String,
        currentRight: String,
        targetLeft: String,
        targetRight: String
    ) -> ProviderPinPlan {
        var assignments: [Assignment] = []
        if currentLeft != targetLeft {
            assignments.append(Assignment(side: .left, providerId: targetLeft))
        }
        if currentRight != targetRight {
            assignments.append(Assignment(side: .right, providerId: targetRight))
        }
        return ProviderPinPlan(assignments: assignments)
    }
}

/// Pure pane decision rules taken out of ContentView and its pane delegates so they are
/// unit-testable; the views delegate here and keep only state plumbing.
enum PaneLogic {

    /// Which pane owns the current selection.
    enum ActivePane {
        case left
        case right
    }

    /// The provider the action bar's Copy/Move buttons target: the pane opposite the selection.
    /// `nil` when nothing is selected, so the buttons fall back to a neutral label.
    static func copyTargetName(activePane: ActivePane?, paneNames: PaneProviderNames) -> String? {
        activePane.map { paneNames.other(isLeft: $0 == .left) }
    }

    /// What a pane's search run is for: which side's results it produces, and whether it annotates
    /// hits with the other pane's contents.
    ///
    /// Pulled out because it can be wrong invisibly. A left/right mix-up searches the right tree
    /// and stamps the answer with the other side; `PaneSearchResults.==` reads the side first, so
    /// the pane would compare its own results unequal forever and re-render every pass, or, the
    /// other way round, never notice a change.
    /// `PaneOutlineRepublishTests.testPaneRendersItsOwnTreeNotTheOtherPanes` guards the same class
    /// of bug one layer down.
    struct SearchPlan: Equatable {
        let side: PaneTree.Side
        /// Whether to walk the opposite pane's tree for "both sides" / "left only".
        let annotatesSides: Bool
    }

    /// - Parameters:
    ///   - isSingleSource: the single-source rail, which has no opposite pane at all.
    ///   - query: empty means no search is running, so nothing is annotated and the other tree must
    ///     not be walked; that walk is the only part of a search that touches a tree the user isn't
    ///     looking at.
    static func searchPlan(isLeft: Bool, isSingleSource: Bool, query: String) -> SearchPlan {
        SearchPlan(side: isLeft ? .left : .right,
                   annotatesSides: !query.isEmpty && !isSingleSource)
    }

    /// Whether a recomputation would only re-publish "no search": the results on hand answer no
    /// query, and neither does the field. Every tree publish re-keys the search task, and without
    /// this a pane with nothing typed would publish a fresh generation that compares unequal by
    /// that stamp alone, re-rendering the window and its panes with identical output. `query` is
    /// the field's raw text, normalized here the way `PaneSearchResults` stores it.
    static func searchStaysIdle(previous: PaneSearchResults, query: String) -> Bool {
        !previous.isActive && PaneTreeSearch.normalizedQuery(query).isEmpty
    }

    /// Whether landing `results` over `previous` is a new question, the one recomputation event
    /// that fires a reveal (the other trigger, ↩/⇧↩, bumps the nonce at its own call site).
    ///
    /// A republish answers false: same query, recomputed against a moved tree. Firing there would
    /// re-reveal the current hit after every background scan, over whatever the user had selected
    /// or navigated to since. Both sides compare the normalized query `PaneSearchResults` stores,
    /// so a whitespace-only edit isn't a new question either.
    static func searchAsksNewQuestion(previous: PaneSearchResults,
                                      results: PaneSearchResults) -> Bool {
        results.query != previous.query
    }

    /// Which pane the user is working in: the single answer for every surface that has to pick one.
    /// The pane-scoped chords (⌘F, ⌘[, ⌘], ⇧⌘N), the file-action bar, the lens scans and the folder
    /// sidebar all route through here, so "the focused pane" can't mean two panes to two features
    /// (the accent border saying one pane while Copy names the other).
    ///
    /// `focusedSide` is the answer whenever there is one. It is set by ⌃⇥ and by clicking in a pane
    /// (`ContentView.paneSelectionBinding`), so it survives letting go of a selection.
    ///
    /// The selection is the fallback, with a floor. `activePane` decides where the action bar draws
    /// and which pane's selection wash is strong, so before anything takes focus these chords land
    /// where every other pane-scoped affordance points. It is `nil` when nothing is selected, as on
    /// a cold window, and the left pane is the floor there, matching a left-to-right comparison's
    /// reading order. `focusedSide` lets a user who never clicked a row still aim ⌘F at the right
    /// pane.
    ///
    /// On the single-source rail the rail is the left pane (see `ContentView.paneContext`) and the
    /// only one on screen, so a right answer would open a field on a pane nobody can see; that
    /// includes a stale `focusedSide` left over from Compare, which is why the rail's guard comes
    /// first.
    static func focusedPaneIsLeft(isSingleSource: Bool,
                                  focusedSide: PaneTree.Side?,
                                  activePane: ActivePane?) -> Bool {
        guard !isSingleSource else { return true }
        if let focusedSide { return focusedSide == .left }
        return activePane != .right
    }

    /// What Compare's not-scanned card says, given the persisted summary and where the panes point.
    ///
    /// The decision to consult the summary at all lives here so a test can hold it: `ComparePrompt`
    /// owns the wording and `LastScanSummary` owns "is this the same comparison". The failure is
    /// silent: a count for the wrong pair of folders reads as current, which is worse than the cold
    /// "Nothing scanned yet".
    static func notScannedMessage(summary: LastScanSummary?,
                                  leftProviderID: String, leftPath: String,
                                  rightProviderID: String, rightPath: String,
                                  now: Date) -> String {
        guard let summary,
              summary.describes(leftProviderID: leftProviderID, leftPath: leftPath,
                                rightProviderID: rightProviderID, rightPath: rightPath)
        else { return ComparePrompt.neverScanned }
        return ComparePrompt.lastScan(differenceCount: summary.differenceCount,
                                      date: summary.date, now: now)
    }

    /// The focused side after one pane-selection write: the mouse's half of the fact ⌃⇥ sets.
    ///
    /// The case that matters changes nothing: an empty write is a deselect, not leaving the pane.
    /// Moving focus there would send the next ⌘F back to the left-hand floor the moment you pressed
    /// Escape. Kept out of the `Binding`'s setter so a test can reach it.
    static func focusedSideAfterSelectionWrite(_ newSelection: Set<String>,
                                               isLeft: Bool,
                                               current: PaneTree.Side?) -> PaneTree.Side? {
        guard !newSelection.isEmpty else { return current }
        return isLeft ? .left : .right
    }

    /// Where ⌃⇥ moves focus from the pane the chords act on now.
    ///
    /// Resolved from the effective target, not the stored `focusedSide`, so the first press always
    /// flips what is in effect. Flipping the stored value would make the first press a no-op for
    /// anyone whose focus is still implicit: `nil` has no opposite, and an arbitrary pick lands on
    /// the pane the fallback already chose half the time.
    static func focusSwitchTarget(isSingleSource: Bool,
                                  focusedSide: PaneTree.Side?,
                                  activePane: ActivePane?) -> PaneTree.Side {
        focusedPaneIsLeft(isSingleSource: isSingleSource,
                          focusedSide: focusedSide,
                          activePane: activePane) ? .right : .left
    }

    /// SF Symbols for the action bar's Copy/Move buttons, from the shared `TransferGlyph`
    /// vocabulary so the toolbar, the Differences header and the right-click menus can't drift.
    /// Copy is the plain duplicate glyph in every state, its direction carried in the "Copy to
    /// <pane>" label, since SF Symbols has no left-pointing copy glyph. Move stays directional: a
    /// box-with-arrow toward the target pane (opposite the selection), right-pointing when nothing
    /// is selected.
    static func actionBarSymbols(activePane: ActivePane?) -> (copy: String, move: String) {
        switch activePane {
        case .left: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: true))
        case .right: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: false))
        case nil: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: true))
        }
    }

    /// What the action bar's Compare button would do for this selection, or `nil` where it is not
    /// offered at all.
    ///
    /// One value rather than a Bool beside a handler that re-derives it: the button's presence and
    /// its action are two readings of one question, so the action can't be offered for a selection
    /// it doesn't know how to act on.
    ///
    /// Two files and one folder are mutually exclusive by construction, so one word labels both.
    /// This surface never calls itself "Compare files", so the sidebar's Compare keeps one meaning;
    /// the bar's button reaches whichever comparison the selection describes.
    enum CompareOffer: Equatable {
        /// One folder: the two-folder scan.
        case folderScan(FileNode)
        /// Two files in one pane, opening the pair viewer. Reachable with a plain ⌘-click: a pane's
        /// selection is a `Set`, so this needs no new state and leaves the one-pane-selected
        /// invariant alone.
        case filePair(FileNode, FileNode)
        /// One file: arm it, and the next file clicked in either pane completes the pair.
        ///
        /// This is the case that makes the button reachable: the Columns view most people use can't
        /// select two files together, and one file is what every click produces. It also reaches
        /// what two-file selection never can, a counterpart in the other pane. The
        /// one-pane-selected invariant clears the opposite side on every non-empty write, so "one
        /// here and one there" isn't a state that exists; the armed path lives outside both sets
        /// for that reason.
        case armPick(FileNode)

        /// What the action bar's button says. Arming says so: "Compare" over a single file promises
        /// a comparison this click can't deliver, and the ellipsis is the app's word for "this asks
        /// for something next", as the row menu's "Compare with…" already uses for the same
        /// gesture.
        var buttonTitle: String {
            if case .armPick = self { return "Compare with…" }
            return "Compare"
        }

        /// The two files, where this offer is a pair; `nil` for a folder scan.
        ///
        /// What ⇧⌘C reads, as a value rather than a `guard case` at its call site: the item must
        /// stay disabled for a folder, and a `guard let` written where `guard case .filePair` was
        /// meant would run the pair viewer on a folder. As a value, that is testable without a
        /// window.
        var filePair: (FileNode, FileNode)? {
            if case .filePair(let a, let b) = self { return (a, b) }
            return nil
        }
    }

    /// ``CompareOffer`` for a pane selection. A file pair keeps the selection's order, the order
    /// the rows were resolved in; the viewer labels its columns from the pair, so a stable order is
    /// all this owes.
    static func compareOffer(for selection: [FileNode]) -> CompareOffer? {
        if selection.count == 1, selection[0].isDirectory { return .folderScan(selection[0]) }
        if selection.count == 1 { return .armPick(selection[0]) }
        if selection.count == 2, !selection[0].isDirectory, !selection[1].isDirectory {
            return .filePair(selection[0], selection[1])
        }
        return nil
    }

    /// Reconciles a pane-selection write with the one-pane-selected invariant: a non-empty
    /// selection in one pane clears the other in the same update, so no consumer sees both
    /// selected. An empty write (a deselect, or SwiftUI re-writing an unchanged empty set) leaves
    /// the other pane alone, which keeps right-click menus working: right-click never sets a
    /// selection, and "Copy N items from other pane" needs the other pane's to survive. Only the
    /// FileTreeView selection bindings route through this; pruning and navigation resets write the
    /// manager's properties directly.
    static func reconciledSelections(
        settingSelection newSelection: Set<String>,
        isLeft: Bool,
        currentLeft: Set<String>,
        currentRight: Set<String>
    ) -> (left: Set<String>, right: Set<String>) {
        if isLeft {
            return (left: newSelection, right: newSelection.isEmpty ? currentRight : [])
        } else {
            return (left: newSelection.isEmpty ? currentLeft : [], right: newSelection)
        }
    }

    /// Applies one pane-selection write, enforcing the one-pane-selected invariant across the two
    /// halves of a click.
    ///
    /// The clicked pane commits synchronously: its `List` is waiting on that write, and clearing
    /// the sibling here instead reloads that List mid-commit and drops the click. The other pane's
    /// clear goes to the next runloop turn.
    ///
    /// That deferral is safe only while it is still the newest click. The queued block writes a
    /// blind `[]` to the other pane, so a left click then a right click before it drains would wipe
    /// the right click's fresh selection: the row un-highlights and the click reads as ignored. Two
    /// clicks don't reliably land in separate turns once a click also rebuilds a Columns stack and
    /// mirrors it onto the linked pane.
    ///
    /// So every commit takes a token and a deferral stands down unless its token is still the
    /// newest. That loses nothing: the newer click queued its own deferral, which clears the
    /// correct pane.
    ///
    /// `schedule` is injected so the ordering, not just the arithmetic, can be tested.
    @MainActor
    static func applySelectionWrite(
        _ newSelection: Set<String>,
        isLeft: Bool,
        state: PaneSelectionState,
        sequencer: PaneSelectionSequencer,
        schedule: (@escaping () -> Void) -> Void
    ) {
        let reconciled = reconciledSelections(
            settingSelection: newSelection,
            isLeft: isLeft,
            currentLeft: state.selectedLeftPaths,
            currentRight: state.selectedRightPaths
        )
        // Commit the clicked pane now: the List is waiting on this write.
        if isLeft {
            if state.selectedLeftPaths != reconciled.left { state.selectedLeftPaths = reconciled.left }
        } else {
            if state.selectedRightPaths != reconciled.right { state.selectedRightPaths = reconciled.right }
        }
        // A deselect (empty write) enforces nothing, so the other pane is left alone (this keeps
        // the right-click "Copy from other pane" menu working). It takes no token either: it queues
        // no deferral, and bumping the counter would cancel a live deferral without replacing it.
        guard !newSelection.isEmpty else { return }
        // The user just picked something in a pane, so the panes are what "the current file" means
        // until they pick elsewhere. Guarded so a run of pane clicks publishes once, not per click:
        // this is observed state, and the panes re-render off it.
        if state.lastSelectionSurface != .pane { state.lastSelectionSurface = .pane }
        let token = sequencer.commit()
        // This timing spans the button hold, not just work: `NSTableView` commits the selection on
        // mouse-down inside its tracking loop, so the gap to the deferred block includes however
        // long the button stayed down. For the cost of a click, trust `PaneColumnsView`'s
        // `[render]` line, which starts after mouse-up. This one measures press-to-settled, what
        // the hand feels, and is labelled so nobody optimises against it.
        let committed = CFAbsoluteTimeGetCurrent()
        schedule {
            let heldAndSettledMs = (CFAbsoluteTimeGetCurrent() - committed) * 1000
            let side = isLeft ? "left" : "right"
            guard sequencer.isNewest(token) else {
                Logger.shared.debug(
                    "[click] \(side) selection superseded before its cross-pane clear ran "
                    + "(press→settled \(Self.ms(heldAndSettledMs)), includes button hold)")
                return
            }
            if isLeft {
                if state.selectedRightPaths != reconciled.right { state.selectedRightPaths = reconciled.right }
            } else {
                if state.selectedLeftPaths != reconciled.left { state.selectedLeftPaths = reconciled.left }
            }
            Logger.shared.debug(
                "[click] \(side) pane selected \(newSelection.count) item(s), "
                + "press→settled \(Self.ms(heldAndSettledMs)) (includes button hold)")
        }
    }

    /// The app's own selection of one row in the left pane, not a click (the owed selection
    /// `ContentView.settleOwedPaneSelection` pays).
    ///
    /// It must not go through the pane's selection binding, which gives it everything a click gets:
    /// it would resolve a standing Compare-with pick on any single-path write (the pick survives a
    /// workspace switch, so opening a document in Edit would open the pair overlay on it), claim
    /// `lastSelectionSurface` for the panes, move keyboard focus to the left pane, and log a
    /// `[click]` the log reader would attribute to the user.
    ///
    /// So this writes the selection and nothing else. The left pane is written synchronously (no
    /// click started this, so no `List` commit is in flight), marked first as the app's own
    /// (`markPaid`) so the pane's one-click open in Edit doesn't answer it.
    ///
    /// The one-pane-selected invariant still holds: the right pane's selection is cleared, whatever
    /// it holds, as a click in the left pane would. The app never keeps selections in both panes;
    /// only a set in the left pane is protected, and the owed-selection rule drops the debt for
    /// that before this is called (`ContentView.owedPaneSelection`). The clear is marked too
    /// (`markRightCleared`) so it doesn't retire a Get Info target the way a right-pane click does.
    /// The selection sequencer is left alone: a click's deferred clear queued behind this is newer
    /// intent, and wins.
    ///
    /// `companions` are selected with `path` in the one write: a PDF batch's other copies in its
    /// folder, which its Reveal in Browse owes; empty for every other caller. The marker still
    /// names `path`: several rows open nothing (`paneSelectionOpens`), and the change consumes it.
    @MainActor
    static func payOwedSelection(_ path: String, with companions: [String] = [], state: PaneSelectionState,
                                 markPaid: (String) -> Void, markRightCleared: () -> Void) {
        let rows = Set(companions).union([path])
        if state.selectedLeftPaths != rows {
            markPaid(path)
            state.selectedLeftPaths = rows
        }
        if !state.selectedRightPaths.isEmpty {
            markRightCleared()
            state.selectedRightPaths = []
        }
    }

    /// One decimal place, so a log line reads `412.4ms` rather than `412.35917663574219ms`.
    static func ms(_ value: Double) -> String { String(format: "%.1fms", value) }

    /// Lets go of the selection in both panes, for a plain click on a pane's empty space.
    ///
    /// Not routed through `applySelectionWrite`, which treats an empty write as enforcing nothing
    /// and leaves the other pane alone so right-click menus keep the other pane's selection. A
    /// click on empty space means "I'm done with that", and under the one-pane-selected invariant
    /// the selection it dismisses usually lives in the pane the user didn't just click, so clearing
    /// only the clicked side would look dead.
    ///
    /// Synchronous, and safely so: this runs from a click recognizer on mouse-up, outside the
    /// mouse-down tracking loop an `NSTableView` commits its selection from, so it is no mid-commit
    /// sibling write, and it queues nothing that could go stale.
    @MainActor
    static func clearBothSelections(state: PaneSelectionState) {
        if !state.selectedLeftPaths.isEmpty { state.selectedLeftPaths = [] }
        if !state.selectedRightPaths.isEmpty { state.selectedRightPaths = [] }
    }

    // MARK: - The column stack's two chords (roadmap RD5)

    /// The stack ⌘↓ should apply, or `nil` when the chord must be disabled.
    ///
    /// ⌘↓ moves the column stack, never the comparison scope (`PaneBrowsePath`'s doc draws the
    /// line), so this returns a `PaneBrowsePath` and nothing else: no branch here can re-root a
    /// pane or start a scan.
    ///
    /// Three conditions, each a refusal rather than a guess:
    ///
    /// - Columns must be on screen. A tree draws no columns to open one into, so the item greys out
    ///   rather than quietly meaning something else.
    /// - Exactly one row, a directory. ⌘↓ on a file isn't "open the file" (that is Space and Quick
    ///   Look), and a multi-selection names no single destination.
    /// - The row must live in the deepest open column. `drill(into:atDepth:)` discards every column
    ///   past `atDepth`, so drilling a row in an earlier column would close the columns to its
    ///   right. A click there does that rightly, since it says where it landed; a chord doesn't,
    ///   and silently closing three columns isn't what ⌘↓ asks for.
    ///
    /// "Lives in" asks the column's rows, not the folder id's parent: the two part wherever the
    /// walk spells a row where a link leads (`TreeShape`), below a folder symlink's child and
    /// everywhere under a root reached through one (`/var/…` lists `/private/var/…`).
    static func openSelectedFolderStack(drawsColumns: Bool,
                                        stack: PaneBrowsePath,
                                        selection: [FileNode],
                                        treeRoot: String,
                                        index: PaneChildrenIndex) -> PaneBrowsePath? {
        guard drawsColumns else { return nil }
        guard selection.count == 1, let folder = selection.first, folder.isDirectory else { return nil }
        guard index.children(atPath: stack.currentDirectory(treeRoot: treeRoot))?
                .contains(where: { $0.id == folder.id }) == true else { return nil }
        var next = stack
        next.drill(into: folder.name, atDepth: stack.depth)
        return next
    }

    /// The stack ⌘↑ should apply, or `nil` when the chord must be disabled.
    ///
    /// This is what makes ⌘↑ differ from ⌘[. `⌘[` pops this same stack, then falls through to the
    /// pane's focus history once it is empty (`FileSyncManager.canGoBack(isLeft:drawsColumns:)`),
    /// which steps the comparison scope back and costs a reload. ⌘↑ returns `nil` at the root
    /// column instead, so the item disables and the scope never moves, as Finder separates Back
    /// from Enclosing Folder.
    ///
    /// "Simplifying" this into `canGoBack` puts a rescan behind a chord that promises not to move
    /// the scope; `theEnclosingFolderChordStopsAtTheRootColumn` catches that.
    ///
    /// `popLast()` pushes onto the forward stack, as `‹` does: the same move on the same axis, so
    /// `›` can walk back into a column either one closed.
    static func enclosingFolderStack(drawsColumns: Bool,
                                     stack: PaneBrowsePath) -> PaneBrowsePath? {
        guard drawsColumns, !stack.isEmpty else { return nil }
        var next = stack
        next.popLast()
        return next
    }

    /// The column stack a background click leaves behind, or nil when it changes nothing.
    ///
    /// Finder's rule: clicking a column's empty space closes the columns to its right but opens
    /// none, the same truncation a click on a file in that column performs, so both go through
    /// `PaneBrowsePath.truncate(toDepth:)`.
    ///
    /// `depth` is nil where there is no column to truncate to: Tree mode, the single-source rail,
    /// and the dead space past the last column. Closing the stack from a click past it would be a
    /// navigation the user didn't ask for.
    static func backgroundDeselectPath(from browsePath: PaneBrowsePath, depth: Int?) -> PaneBrowsePath? {
        guard let depth else { return nil }
        var path = browsePath
        path.truncate(toDepth: depth)
        return path == browsePath ? nil : path
    }

    /// Which pane the Info inspector describes: the pane the user is working in, or the other one
    /// when only that one holds a selection. With nothing selected anywhere, still the user's pane:
    /// the inspector then shows its folder, captioned "Right pane" or "Left pane". Outside Compare
    /// there is only the left pane.
    static func inspectorFollowsLeft(isCompare: Bool, focusedIsLeft: Bool,
                                     leftHasSelection: Bool, rightHasSelection: Bool) -> Bool {
        guard isCompare else { return true }
        if focusedIsLeft { return leftHasSelection || !rightHasSelection }
        return !rightHasSelection && leftHasSelection
    }

    /// The left pane wins when both have selections. The selection bindings enforce exclusivity via
    /// `reconciledSelections`, clearing the other pane one runloop tick after a pick lands, so both
    /// can be non-empty for at most a frame; this tiebreak keeps that frame pointing at a real
    /// pane.
    static func activePane(leftSelection: Set<String>, rightSelection: Set<String>) -> ActivePane? {
        if !leftSelection.isEmpty { return .left }
        if !rightSelection.isEmpty { return .right }
        return nil
    }

    // The primary selection rule is `CurrentSelection.primaryPanePath` in `Sync`, where the
    // Differences table and the Info inspector, which can't see `MacApp`, reach it too.

    /// Whether Escape, pressed over a pane, should clear that pane's selection (and swallow the
    /// key) rather than let it bubble to a dialog.
    ///
    /// On the single-source rail it asks the pane's own selection: the action bar is Compare-only
    /// (`paneActionBarSideActive`), so `hasActionBarSelection` is always false there, and the rail
    /// shows no ✕ and its lists offer no other deselect, so a picked folder could never be
    /// unpicked.
    ///
    /// Compare keeps the action-bar gate: a selected path that no longer resolves to a node keeps
    /// the bar hidden, and Escape stays `.ignored` in that state.
    static func escapeClearsSelection(
        isSingleSource: Bool,
        hasActionBarSelection: Bool,
        paneHasSelection: Bool
    ) -> Bool {
        isSingleSource ? paneHasSelection : hasActionBarSelection
    }

    /// What esc does in a pane, in precedence order.
    enum EscapeAction: Equatable {
        /// A comparison pick is armed; see ``ComparePick``.
        case cancelComparePick
        case clearSelection
        /// Not ours: the key bubbles, so dialogs and the rest still see it.
        case ignore
    }

    /// The pick wins, and the selection is still there for a second press.
    ///
    /// A mode indicator that names esc has to mean it, and while a pick is armed the mode is what
    /// esc is most likely aimed at: the reader may be several folders from the armed row. Nothing
    /// is lost: one more press clears the selection, while no number of presses restores a pick.
    ///
    /// A rule rather than two `if`s at the call site, because the precedence is the whole content
    /// and a call site can't be asked what it would have done.
    static func escapeAction(
        hasComparePick: Bool,
        isSingleSource: Bool,
        hasActionBarSelection: Bool,
        paneHasSelection: Bool
    ) -> EscapeAction {
        if hasComparePick { return .cancelComparePick }
        return escapeClearsSelection(isSingleSource: isSingleSource,
                                     hasActionBarSelection: hasActionBarSelection,
                                     paneHasSelection: paneHasSelection)
            ? .clearSelection : .ignore
    }

    /// Which pane a lens scan or inspect should target. The single-source rail is always the left
    /// pane, so outside Compare the answer is always left, even when a selection lingers in the
    /// hidden right pane from an earlier Compare session; otherwise the lens scans (Find
    /// Duplicates, Organize, Rename, Storage) would read the wrong provider while the rail shows
    /// the left one.
    ///
    /// In Compare this follows the focused pane, not the selection: `activePane` is nil when
    /// nothing is selected, which would send every scan on a cold window to the left pane. The
    /// accent border draws from the same rule, so the pane wearing it is the pane the scan reads.
    static func lensTargetsRightPane(isCompare: Bool,
                                     focusedSide: PaneTree.Side?,
                                     activePane: ActivePane?) -> Bool {
        guard isCompare else { return false }
        return !focusedPaneIsLeft(isSingleSource: false, focusedSide: focusedSide,
                                  activePane: activePane)
    }

    /// A folder expressed relative to a pane's root, or `nil` when it is not inside that root.
    ///
    /// Component-wise, never a string prefix, which is why this is a named function and not a
    /// `hasPrefix` at the call site: `/Users/me/Documents` begins with `/Users/me/Doc`, so a prefix
    /// test would put a folder under a root that merely shares an opening with it.
    ///
    /// The root itself answers `""`, the pane's resting position, which `focusOn` takes for "the
    /// top".
    ///
    /// Both paths must be absolute. `split(separator:)` drops the leading empty component, so a
    /// relative `"Users/me/Docs"` against `/Users/me` would yield `"Docs"`, inside a root it has no
    /// relationship to.
    ///
    /// Compared case-insensitively, because the volumes this app runs on are: APFS is
    /// case-insensitive by default, and so is every iCloud and Dropbox folder on it, so
    /// `/Users/me/documents` and `/Users/me/Documents` are one folder.
    ///
    /// A folder the root links in from outside answers through the link's name: `~/Documents/x`
    /// under the iCloud Drive container is `Documents/x` (`PathBoundary.LinkedFolders`), tried
    /// after the component walk fails, with the same case rule below the link.
    static func relativePath(of folder: String, under root: String,
                             links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> String? {
        guard folder.hasPrefix("/"), root.hasPrefix("/") else { return nil }
        let folderParts = (folder as NSString).standardizingPath.split(separator: "/").map(String.init)
        let rootParts = (root as NSString).standardizingPath.split(separator: "/").map(String.init)
        guard folderParts.count >= rootParts.count,
              zip(folderParts, rootParts).allSatisfy({ $0.compare($1, options: .caseInsensitive) == .orderedSame })
        else {
            for (name, target) in PathBoundary.linkedFolders(atRoot: root, in: links) {
                if let below = relativePath(of: folder, under: target, links: [:]) {
                    return PathBoundary.joinRelative(name, below)
                }
            }
            return nil
        }
        // The folder's own spelling is returned, not the root's: this path goes back to the
        // filesystem, and correcting capitalisation isn't this function's business.
        return folderParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    /// How wide the folder sidebar may be in a lens workspace, which isn't always the width the
    /// user stored.
    ///
    /// Browse gives the sidebar the window minus one pane, so its stored width always fits. A lens
    /// row is sidebar + rail + workspace panel, and the rail and panel have hard minimums of 220
    /// and 340, so at the 760pt window floor the sidebar gets 200pt: the 180 default fits and the
    /// 280 maximum overruns by 80. The clamp is computed from the row's real width, not the floor,
    /// so a floor that moves needs no change here.
    ///
    /// The sidebar gives way because its job survives being narrower: a rail under 220 can't show a
    /// file name, and a lens panel under 340 reflows into nonsense (`LensHeaderCardOverrunTests`
    /// measures that). A clamp, never a collapse, like the resize divider: it stops at its own
    /// `minWidth`, and 150 fits at the window floor with room to spare.
    ///
    /// - Parameters:
    ///   - stored: the user's remembered width, already clamped to the sidebar's own bounds.
    ///   - totalWidth: the whole row the three share.
    ///   - gutter: the gap between the sidebar card and the rail.
    static func lensSidebarWidth(stored: CGFloat, totalWidth: CGFloat,
                                 minSidebar: CGFloat, gutter: CGFloat) -> CGFloat {
        sidebarWidthSharingRow(stored: stored, totalWidth: totalWidth,
                               roomForOthers: minRailWidth + minLensWorkspaceWidth,
                               minSidebar: minSidebar, gutter: gutter)
    }

    /// The same clamp for Compare, whose row holds two panes rather than a rail and a lens panel.
    ///
    /// It needs 500 against the lens workspaces' 560, so Compare has more slack at the window floor
    /// (260pt against 200). Its own entry point, not a shared constant, because one "room for
    /// others" number would have to be the larger and would clamp Compare needlessly.
    static func compareSidebarWidth(stored: CGFloat, totalWidth: CGFloat,
                                    minSidebar: CGFloat, gutter: CGFloat) -> CGFloat {
        sidebarWidthSharingRow(stored: stored, totalWidth: totalWidth,
                               roomForOthers: minComparePaneWidth * 2,
                               minSidebar: minSidebar, gutter: gutter)
    }

    /// One pane's hard minimum in Compare: `panesSplit`'s own `minPane`, named here so the clamp
    /// and the split can't disagree about it.
    static let minComparePaneWidth: CGFloat = 250

    /// The shared core: give the row's other occupants their minimums first and the sidebar what is
    /// left, never below its own floor.
    static func sidebarWidthSharingRow(stored: CGFloat, totalWidth: CGFloat, roomForOthers: CGFloat,
                                       minSidebar: CGFloat, gutter: CGFloat) -> CGFloat {
        // `sidebarOverhead`, not `gutter`: the seam strip is part of what a shown sidebar costs the
        // row, and reserving a point less than it takes makes the clamp disagree with the layout.
        max(minSidebar, min(stored, totalWidth - roomForOthers - sidebarOverhead(gutter: gutter)))
    }

    /// The three widths a lens workspace's row divides into, computed once so they can't disagree.
    ///
    /// A value, because done inline the arithmetic can go wrong where no test sees it: subtracting
    /// the sidebar into a shadowed `totalWidth` that then reaches the row's `.frame(width:)` frames
    /// the row narrower than its contents, SwiftUI centres the overflow, and the sidebar renders
    /// outside the window (the failure the comment beside `bottomPaneView` describes for the lens
    /// card).
    ///
    /// The invariant is arithmetic, not pixels: `sidebarSlot + rail + workspace` must equal the
    /// row, which `theWidthsAlwaysSumToTheRow` asserts over the whole range.
    struct LensRow: Equatable {
        /// What the sidebar occupies in total: its own width, the card gutter and the 1pt seam
        /// strip that carries its drag handle, because all three are in the row. Without the seam,
        /// a lens or Compare row's parts sum to `totalWidth + 1` and SwiftUI centres the
        /// difference: invisible by eye, so it needs the arithmetic. Browse doesn't show it because
        /// the stack beside its sidebar is flexible.
        let sidebarSlot: CGFloat
        /// The width handed to the sidebar column itself.
        let sidebarWidth: CGFloat
        let railWidth: CGFloat
        let workspaceWidth: CGFloat
        /// The room the rail and the workspace divide, what `railFraction` is a fraction of, so it
        /// means the same thing whether or not a sidebar is up.
        let splitWidth: CGFloat

        /// Where the rail's drag handle sits, measured from the row's leading edge, not the rail's.
        /// The overlay carrying it is aligned to the row, so a sidebar in front of the rail moves
        /// the handle.
        var railHandleOffset: CGFloat { sidebarSlot + railWidth - 6 }
    }

    /// The clear strip between the sidebar and what follows it, which carries the drag handle.
    /// One point wide and real: see `LensRow.sidebarSlot`.
    static let sidebarSeamWidth: CGFloat = 1

    /// Everything a shown sidebar costs a row beyond the column itself.
    static func sidebarOverhead(gutter: CGFloat) -> CGFloat { gutter + sidebarSeamWidth }

    static func lensRow(totalWidth: CGFloat, sidebarWidth: CGFloat, showsSidebar: Bool,
                        gutter: CGFloat, fraction: Double) -> LensRow {
        let slot = showsSidebar ? sidebarWidth + sidebarOverhead(gutter: gutter) : 0
        let split = totalWidth - slot
        let rail = split * CGFloat(fraction)
        return LensRow(sidebarSlot: slot,
                       sidebarWidth: showsSidebar ? sidebarWidth : 0,
                       railWidth: rail,
                       workspaceWidth: split - rail,
                       splitWidth: split)
    }

    /// The rail's hard minimum in a lens workspace; below this it can't show a file name. Named
    /// rather than a literal in `singleSourceLayout` because `lensSidebarWidth` reasons about the
    /// same number, and two copies of a layout minimum let a clamp disagree with what it clamps
    /// against.
    static let minRailWidth: CGFloat = 220
    /// The collapsed pane's spine; its card adds `cardGutter` beyond this. Named so Edit's
    /// collapsed row, sidebar included, can be checked against the clamp `lensSidebarWidth` gives
    /// it (`theCollapsedEditRowFitsTheLensClamp`).
    static let railSpineWidth: CGFloat = 34
    /// The lens panel's hard minimum, for the same reason.
    static let minLensWorkspaceWidth: CGFloat = 340

    /// Whether a ⌘K "organize <folder>" aimed at the right pane can only be honoured by swapping
    /// the panes first.
    ///
    /// Organize is single-source and shows the left pane (`lensTargetsRightPane` is false outside
    /// Compare), and the scope is re-resolved on read against whatever provider is showing. A
    /// folder from the right pane's tree would land as a path not under the root it is measured
    /// against: `OrganizeScope.init?` answers nil, the chip disappears and every lens falls back to
    /// the global view, the request silently dropped. Swapping puts the named provider on the left.
    ///
    /// Decided with `OrganizeScope` itself, not a string prefix, so this and the resolver can't
    /// disagree: it carries the tilde expansion, the component boundary (`/a/b` is not a base of
    /// `/a/bc`) and the rule that the provider root normalizes to the global view.
    ///
    /// False (no swap, nothing to ask) in every other case, three of them worth naming:
    /// - No scope. "Organize" with no folder has nothing to keep, and both panes answer it.
    /// - Both panes on one provider. The roots are the same, so the scope already resolves under
    ///   the left one; a swap would move the panes for nothing.
    /// - The scope is under neither root: a stale or foreign path. Swapping can't fix that; it
    ///   degrades to the global view as `OrganizeScope` documents.
    static func organizeAimNeedsPaneSwap(scope: String?,
                                         aimedAtRight: Bool,
                                         leftRoot: String,
                                         rightRoot: String) -> Bool {
        guard aimedAtRight, let scope else { return false }
        // Under the aimed pane's root, or there is nothing a swap would rescue.
        guard OrganizeScope(path: scope, providerRoot: rightRoot) != nil else { return false }
        // …and not under the pane Organize will show, which is the failure.
        return OrganizeScope(path: scope, providerRoot: leftRoot) == nil
    }

    /// Builds a pane's full path from its provider root and in-pane relative path. An empty or
    /// absolute "relative" path yields just the root, so a stale or cross-provider relative path
    /// can never escape the pane's root.
    ///
    /// The rule is `PathBoundary.join`, shared with `CloudProvider.landingPath`. Kept as a named
    /// seam because the pane call sites read as "the pane's full path", not as a path join.
    static func fullPath(root: String, relativePath: String) -> String {
        PathBoundary.join(root: root, relative: relativePath)
    }

    /// A source of its own, walked into from inside another one: the provider a pane should re-root
    /// at when a column drill lands exactly on that provider's root, or nil when the folder just
    /// entered is nobody's root, as in almost every drill.
    ///
    /// Browsing `~` into `Dropbox` and opening the Dropbox source show the same folder, but only
    /// one says so: the first reads `Home folder ▸ Dropbox ▸ Backup` and carries Home folder's
    /// root, scan and breadcrumb ceiling; the second reads `Dropbox ▸ Backup`. This rule collapses
    /// the two.
    ///
    /// Exactly the root, never merely inside it. `owningSource` answers containment, the wrong
    /// question here: every folder in a Dropbox tree is inside Dropbox, so containment would
    /// re-root on the first drill and claim every drill after. A pane re-roots only on the source's
    /// own doorstep.
    ///
    /// Cloud accounts only, never a folder source, so the rule builds no one-way doors. A re-root
    /// resets the pane's Back stack (`retargetPane`), and with `/` and `~` both added as folder
    /// sources, `/Users` → `/Users/abhishek` would strand the user in Home folder with `/Users`
    /// unreachable. A cloud root is a place people navigate to; a folder source is often one they
    /// pass through.
    ///
    /// Never the source the pane is already on, or the first drill inside a source would reset the
    /// pane onto its own root.
    ///
    /// `providers` should be the enabled list: no refresh walks a disabled source, so re-rooting
    /// onto one lands in the state `PaneTabProviderSwitch` handles.
    ///
    /// `resolve` expands and follows links, so a source stored as `~/Dropbox` and a path built from
    /// an expanded root compare equal.
    ///
    /// **The empty-root check must read the raw string, before `resolve`.** `URL(fileURLWithPath:
    /// "")` resolves to the process's current directory, `/` for an app launched from Finder, so a
    /// source with no root would resolve to a real folder and `isSameFolder` would match a pane
    /// standing on it. A guard after the resolve can't fire, and a fixture resolving `""` to `""`
    /// hides that.
    ///
    /// An empty `absolutePath` needs no guard of its own: it also resolves to the current
    /// directory, and the only source that could then match is one with no root, which the guard
    /// refuses.
    static func sourceRootedAt(_ absolutePath: String,
                               currentProviderId: String,
                               among providers: [CloudProvider],
                               resolve: (String) -> String) -> CloudProvider? {
        let target = resolve(absolutePath)
        return providers.first { provider in
            guard !provider.isLocalFolder, provider.id != currentProviderId,
                  !provider.rootPath.isEmpty else { return false }
            return SidebarSourceModel.isSameFolder(resolve(provider.rootPath), target)
        }
    }

    /// The folder a lens scan targets: the focus root, walked down to where the pane is browsing.
    /// Column clicks move `PaneBrowsePath`, not the comparison focus (browsing must not rescan the
    /// comparison), so reading the focus root alone would leave every lens scan and the "Scan
    /// '<folder>'" offer stuck at the root whatever is selected.
    ///
    /// At rest (no columns open) the focus root is returned unchanged, trailing slashes and all:
    /// the join below normalizes them, and normalizing a root nothing was joined onto would change
    /// paths for panes that never browsed.
    static func lensScanRoot(focusRootExpanded root: String, browsePath: PaneBrowsePath) -> String {
        guard !root.isEmpty, !browsePath.isEmpty else { return root }
        return browsePath.currentDirectory(treeRoot: root)
    }

    /// The base path a pane's "Ignore in comparison" targets are measured against: that pane's own
    /// provider root (tilde-expanded) joined with its own in-pane relative path. An empty relative
    /// path means the pane is at its root.
    ///
    /// Pulled out of `PaneActionDelegate.handleIgnore` because the tested `relativeIgnoreTargets`
    /// is only as good as its base: one side's root with the other side's focus, or a missed tilde
    /// expansion, yields paths that miss the base and are stored verbatim as absolute paths in the
    /// durable per-pair ignore store, hiding the wrong files from every future comparison.
    ///
    /// `PathBoundary.join`, not lexical composition: a focus on a folder the root only links to
    /// would compose a base no node id matches. The iCloud source focused on `Documents` would give
    /// `<iCloud Drive>/Documents` while every node under it is spelled `~/Documents/…`, so every
    /// ignore would land as a pane-specific absolute path the other side can't see.
    /// `FileSyncManager.focusURL` uses the same join for the same reason.
    static func ignoreBasePath(
        isLeft: Bool,
        leftRoot: String,
        rightRoot: String,
        leftRelativePath: String,
        rightRelativePath: String,
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders
    ) -> String {
        PathBoundary.join(root: isLeft ? leftRoot : rightRoot,
                          relative: isLeft ? leftRelativePath : rightRelativePath,
                          links: links)
    }

    /// Reduces absolute node paths to ignore targets relative to the pane's focal path, so an
    /// ignore set applies to both panes whatever their provider roots. Paths outside `basePath`
    /// pass through unchanged. Stripping happens only at a path-component boundary ("/root/ab" is
    /// not a base of "/root/abc/x"), so a sibling root sharing a string prefix can't alias into
    /// relative targets.
    static func relativeIgnoreTargets(nodeIds: [String], basePath: String) -> [String] {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return nodeIds.map { id in
            if id == base { return "" }
            guard id.hasPrefix(base + "/") else { return id }
            return String(id.dropFirst(base.count + 1))
        }
    }

    /// The provider ids the two panes show after a left↔right swap: each id moves to the other
    /// side. Pure so ContentView's swap and its test agree on the mapping without a running view.
    /// This is only the @AppStorage half; the manager's focused relative paths, selections and
    /// navigation histories are swapped in lockstep by `FileSyncManager.swapPanes()`.
    static func swappedProviderIds(
        leftProviderId: String,
        rightProviderId: String
    ) -> (leftProviderId: String, rightProviderId: String) {
        (leftProviderId: rightProviderId, rightProviderId: leftProviderId)
    }

    // The "Ignore in comparison" toggle lives in
    // `FileSyncManager.toggleIgnored(focusRelativePaths:)`, which also reconciles the durable
    // ignore store; Sync's PersistentIgnoresTests pin it.

    // MARK: - Window bootstrap

    /// One step of ContentView's `onAppear` bootstrap. The app is single-window, but `onAppear`
    /// runs again mid-session (a close and Dock reopen, an open from Finder, a launch with a file
    /// all re-present the window), so each step is classified once-per-session or per-window.
    /// `bootstrapSteps(isFirstAppearance:)` is the single source of that classification (pinned by
    /// tests), and the view runs whatever list it returns so the two can't drift.
    ///
    /// A re-appearance is the same view, not a rebuilt one: a close and Dock reopen keeps the
    /// view's `@State`, its NSWindow and its content view (checked on macOS 27). A rebuilt view is
    /// still provided for, defensively: SwiftUI promises nothing, and the Dock-reopen hook's
    /// fall-through (no stored main window) would build a new one.
    enum BootstrapStep: Equatable {
        /// Session: seed `showHiddenFiles` from the General default. Re-running on a window reopen
        /// would discard a mid-session toggle.
        case resetShowHiddenFilesFromDefault
        /// Session: the launch-time overlay diagnostics (`openSettingsOnLaunch`,
        /// `openCommandPaletteOnLaunch`) are launch hooks; a window reopen must not re-open an
        /// overlay the user has since dismissed. The palette is keyboard-only and a script can't
        /// open it (`System Events` keystrokes need assistive access), so a launch hook is the only
        /// way to get it on screen without a human.
        case honorLaunchOverlayDiagnostics
        /// Window: `FileActionHandler` lives in view `@State`, so a view appearing for the first
        /// time, or a rebuilt one, starts with nil and needs its own. A re-appearance just replaces
        /// it.
        case createActionHandler
        /// Window: each window brings a fresh `UndoManager`; the shared sync manager must register
        /// undos with the one on screen.
        case rewireUndoManager
        /// Session: seeds the manager from Settings once; the `onChange(of:)` observer keeps it
        /// current afterwards (both objects outlive the window).
        case syncProviderQuirkSettings
        /// Session: provider discovery, the distinct-pair pane selection and the initial scan.
        /// Re-running would silently flip a deliberately-same right pane to another provider and
        /// redo discovery and a rescan over live state. Clears the view's provider-bootstrap guard
        /// when the discovery task finishes.
        case discoverProvidersAndApplyInitialSelection
        /// Window, re-appearance only: sets `isBootstrappingProviders` from whether the launch has
        /// finished. For the same view this changes nothing; it is for a rebuilt view, whose
        /// `@State` would start true and, never cleared, refuse provider switches and pane swaps
        /// for the rest of the session. **Never lowered early:** a re-appearance can come while the
        /// launch's discovery is still running (SwiftUI re-presents the window for a file opened
        /// from Finder), so the guard is lowered only when `LaunchBootstrap` says the launch has
        /// finished.
        case endProviderBootstrapGuard
    }

    /// The bootstrap steps to run for an appearance of ContentView, in execution order.
    static func bootstrapSteps(isFirstAppearance: Bool) -> [BootstrapStep] {
        if isFirstAppearance {
            return [
                .resetShowHiddenFilesFromDefault,
                .honorLaunchOverlayDiagnostics,
                .createActionHandler,
                .rewireUndoManager,
                .syncProviderQuirkSettings,
                .discoverProvidersAndApplyInitialSelection,
            ]
        }
        return [
            .createActionHandler,
            .rewireUndoManager,
            .endProviderBootstrapGuard,
        ]
    }

    // MARK: - Resize split layout

    /// Math for the two invisible resize dividers (the pane split and the panes↔bottom split), pure
    /// and out of the `GeometryReader` builders so the clamp guards that stop a too-small window
    /// inverting the split are exercised by tests, not only against live geometry.

    /// The horizontal split's minimum fraction: the smallest share that keeps the left pane at
    /// `minPane` points. Capped at 0.5 so a window narrower than 2×minPane degrades to an even
    /// split instead of pushing the minimum past `1 - minFraction` and inverting the clamp bounds;
    /// 0 for a zero-width window so the arithmetic stays finite.
    static func horizontalMinFraction(totalWidth: CGFloat, minPane: CGFloat) -> Double {
        totalWidth > 0 ? min(0.5, Double(minPane / totalWidth)) : 0
    }

    /// The bottom (Differences/Details) pane's area: the content height less the 1pt divider,
    /// floored at 0 so a collapsed window never yields a negative height.
    static func verticalPanesHeight(totalHeight: CGFloat, dividerHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - dividerHeight)
    }

    /// The vertical split's minimum fraction: the bottom pane's smallest share, so it never drops
    /// below `minBottom` points. Capped at 0.85 (as the horizontal rule caps) and 0 for a
    /// zero-height area.
    static func verticalMinFraction(panesHeight: CGFloat, minBottom: CGFloat) -> Double {
        panesHeight > 0 ? min(0.85, Double(minBottom / panesHeight)) : 0
    }

    /// The vertical split's maximum fraction, so the top panes never drop below `minTop` points.
    /// The `max(minFraction, …)` floor matters: in a window too short for both minimums, `1 -
    /// minTop/panesHeight` can fall below `minFraction` and invert the clamp bounds; keeping the
    /// upper bound at or above the lower lets the bottom pane's minimum win and the clamp stay
    /// sane.
    static func verticalMaxFraction(panesHeight: CGFloat, minTop: CGFloat, minFraction: Double) -> Double {
        panesHeight > 0 ? max(minFraction, 1 - Double(minTop / panesHeight)) : 1
    }

    /// Clamps a desired split fraction into `[lower, upper]`, shared so the laid-out fraction and
    /// the live drag clamp identically. With inverted bounds (`upper < lower`, an over-constrained
    /// window) the outer `min` wins and the result pins to `upper`.
    static func clampedFraction(_ desired: Double, lower: Double, upper: Double) -> Double {
        min(max(desired, lower), upper)
    }

    /// The split fraction implied by the cursor's x within the pane row during a horizontal divider
    /// drag. The caller guards `totalWidth > 0`.
    static func horizontalDragFraction(locationX: CGFloat, totalWidth: CGFloat) -> Double {
        Double(locationX / totalWidth)
    }

    /// The bottom-pane fraction implied by the cursor's y during a vertical divider drag: its
    /// distance from the bottom of the pane area, since the bottom pane grows as the cursor moves
    /// up. The caller guards `panesHeight > 0`.
    static func verticalDragFraction(locationY: CGFloat, panesHeight: CGFloat) -> Double {
        Double((panesHeight - locationY) / panesHeight)
    }

    /// The Info inspector's minimum width, matching `DetailsSidebar`'s own `minWidth: 200`, below
    /// which the metadata rows stop reflowing cleanly.
    static let inspectorMinWidth: Double = 200
    /// The inspector's maximum width, so a drag can't let it swallow the window and starve the
    /// panes. A fixed cap keeps the math geometry-free; the flexible panes absorb what is left.
    static let inspectorMaxWidth: Double = 600

    /// The inspector width during a resize drag. The handle is on the panel's leading edge, so
    /// dragging left (negative `translation`) widens it. `base` is the width at drag start,
    /// constant for the gesture since storage is written only on release; `translation` is
    /// cumulative. Clamped to `[inspectorMinWidth, inspectorMaxWidth]` so the same guard runs in
    /// tests.
    static func inspectorDragWidth(base: Double, translation: CGFloat) -> Double {
        min(max(base - Double(translation), inspectorMinWidth), inspectorMaxWidth)
    }

    /// Whether one copy of a duplicate review is still where, and what, the scan saw.
    ///
    /// Asked of both ends, as the engine does (`copyDriftedInPlace` runs for the keeper and every
    /// removal candidate). The removal candidate is the dangerous half: a Compare review stays
    /// open, and meanwhile a provider re-download or an edit can replace the right copy; trashing
    /// it then destroys the only instance of its new content under a button that says the left copy
    /// is kept.
    ///
    /// Modification date as well as size, as the engine checks: size alone waves through every
    /// equal-length rewrite (2025 to 2026, a `sed -i` over fixed-width text). Dates are compared
    /// only when both are known, so a scan that recorded none doesn't refuse every review.
    ///
    /// `statSucceeded: false` (the attributes read threw) refuses for a file, like the engine's
    /// failed-attributes guard; a nil `currentSize` after a successful stat (never on a real file
    /// system) falls back to the existence check rather than over-refusing, also like the engine.
    ///
    /// A directory is answered by `folderContentsMatchScan` alone, never by stat facts (a folder's
    /// stat size isn't its recursive content size). The Compare review is the folder-only flow, and
    /// the engine re-walks every folder it trashes against the scan's ``FolderContentSnapshot``, so
    /// this consults the same `FileSyncManager.folderContentsMatchScan` routine and the review
    /// can't be the weaker gate. The verdict arrives precomputed (the coordinator re-walks off the
    /// main actor, like its stats) to keep this pure; nil (no re-walk, or no baseline) refuses, the
    /// safe direction on both ends.
    static func duplicateCopyMatchesScan(
        exists: Bool,
        isDirectory: Bool,
        statSucceeded: Bool,
        currentSize: Int?,
        scannedSize: Int,
        currentDate: Date? = nil,
        scannedDate: Date? = nil,
        folderContentsMatchScan: Bool? = nil
    ) -> Bool {
        guard exists else { return false }
        guard !isDirectory else { return folderContentsMatchScan ?? false }
        guard statSucceeded else { return false }
        if let currentSize, currentSize != scannedSize { return false }
        if let scannedDate, let currentDate, scannedDate != currentDate { return false }
        return true
    }
}
