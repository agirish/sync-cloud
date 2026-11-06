import Foundation

/// Whether arriving at a tab costs a reload, or is a move inside what the pane already has.
///
/// One rule for two callers, which must not drift: the manager decides from it whether to drop the
/// trees and the comparison, the host whether to run the scan. Two copies could invalidate without
/// reloading, leaving a pane with no tree and no scan until the user pressed Refresh.
///
/// A pane's tree is a walk of one root at one focus, and the comparison is about one pair of
/// focused folders, so a switch that changes neither needs no reload: the column stack, the
/// selection, the history and the search field are inputs to neither, as when drilling columns.
public enum PaneTabArrival {
    public static func needsReload(arrivingAt tab: PaneTab, fromProvider: String, fromFocus: String) -> Bool {
        tab.providerId != fromProvider || tab.history.current != fromFocus
    }
}

/// Where a newly opened tab sits, cut the way the pane it was opened from is cut.
///
/// A pane's location is two values and only one draws columns (`PaneTab.browsePath`): the scope
/// contributes one column and the stack the rest. Handing the whole location over as the scope,
/// with an empty stack, would open a tab from four columns deep as one full-width column, and save
/// and restore it that way on every launch.
///
/// One rule for every opener:
///
/// - ⌘T / ＋ / double-click the strip open at the pane's own location, so the cut is the pane's
///   own and the new tab is laid out like the one it came from.
/// - Open in New Tab opens at a folder under that pane, so the scope holds and everything below it
///   becomes stack.
///
/// A target not under the pane's scope is all scope, no stack: there is nothing for a stack to be
/// relative to.
public enum PaneTabOpening {
    public static func location(of combined: String,
                                openedFromScope scope: String) -> (scope: String, stack: PaneBrowsePath) {
        let target = combined.split(separator: "/")
        let base = scope.split(separator: "/")
        guard base.count <= target.count, target.starts(with: base) else {
            return (combined, PaneBrowsePath())
        }
        // Through the same cut the stored strip is rebuilt with, so a tab opened at a location and
        // a tab restored to it can't disagree about where the two halves meet.
        return PaneTabsStore.split(relativePath: combined, stackDepth: target.count - base.count)
    }
}

/// One tab in a pane's strip: a location that pane can hold, parked.
///
/// The active tab is not stored here. A pane has one live position (`leftProviderId` and the
/// manager's `leftRelativePath` / `leftBrowsePath` / `leftHistory` / `selectedLeftPaths`), and
/// switching tabs captures that live state into the outgoing tab and applies the incoming one over
/// it (`FileSyncManager+PaneTabs`). So the active tab's entry in `PaneTabList` is a snapshot from
/// when it was last parked: **never read its location while it is active**; use
/// `PaneTabList.active` only for its identity (id, provider mark, name). That keeps tabs cheap: no
/// workspace, lens, scan or view has to know what a tab is.
///
/// What a tab owns, and why each is here rather than shared:
///
/// - `providerId`: two tabs reading "Documents" from different clouds is what the chip's provider
///   mark is for.
/// - `relativePath`: the comparison scope, which in Browse is simply where you are.
/// - `browsePath`: the Columns stack inside that scope. Both, because they mean different things
///   (see `PaneBrowsePath`) and a tab restored with only one of them lands somewhere else.
/// - `history`: Back walking out of a tab into a folder another tab visited couldn't be explained
///   from what is on screen.
/// - `selection` and the search field: coming back to a tab and finding your selection cleared,
///   or another tab's query in the field, reads as a lost tab.
///
/// Deliberately not here: view mode, hidden files, the preview column, column width. Those are
/// reading preferences with their own app-wide (or per-surface) keys, and a tab that changed how
/// the pane draws would make the strip a settings control.
public struct PaneTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var providerId: String
    /// The pane's comparison scope: `FileSyncManager.leftRelativePath`'s value for this tab.
    public var relativePath: String
    /// Where inside that scope the Columns stack is standing.
    public var browsePath: PaneBrowsePath
    /// This tab's own back/forward stack.
    public var history: PaneNavigationHistory
    /// The rows selected in this tab.
    public var selection: Set<String>
    /// What is typed in this tab's search field, and whether the field is showing. Held as two
    /// plain values rather than as the app's `PaneSearchFieldState`: that type lives in `MacApp`
    /// (with the walk index and the reveal nonce, which are derived from a tree this tab is not
    /// showing), and `Sync` cannot see it. The host maps between them.
    public var searchQuery: String
    public var searchIsExpanded: Bool
    /// This tab's type filter, or `nil` for none. Parked and restored like the search, and like it
    /// never saved across launches: `PaneTabsStore.Entry` does not carry it.
    public var typeFilter: PaneTypeFilter?
    /// Whether this tab is pinned to the leading end of the strip.
    ///
    /// Pinning keeps a place reachable, nothing more: a pinned tab sits ahead of the unpinned ones,
    /// never folds into the overflow count, survives Close Other Tabs, and has no ✕ for a stray
    /// click. Unlike Safari's mark-only chip it keeps its name and wears a pin, since five
    /// identical cloud marks name nothing.
    public var isPinned: Bool

    public init(id: UUID = UUID(),
                providerId: String,
                relativePath: String = "",
                browsePath: PaneBrowsePath = PaneBrowsePath(),
                history: PaneNavigationHistory? = nil,
                selection: Set<String> = [],
                searchQuery: String = "",
                searchIsExpanded: Bool = false,
                typeFilter: PaneTypeFilter? = nil,
                isPinned: Bool = false) {
        self.typeFilter = typeFilter
        self.id = id
        self.providerId = providerId
        self.relativePath = relativePath
        self.browsePath = browsePath
        // A tab seeded at a folder needs a history that can walk back out of it, or Back is dead in
        // a restored tab and the pane has a location with no way home. `PaneNavigationHistory`
        // always holds the root entry, so pushing the path gives exactly [root, here].
        self.history = history ?? {
            var seeded = PaneNavigationHistory()
            if !relativePath.isEmpty { seeded.push(relativePath) }
            return seeded
        }()
        self.selection = selection
        self.searchQuery = searchQuery
        self.searchIsExpanded = searchIsExpanded
        self.isPinned = isPinned
    }

    /// Where this tab is, as one path under the provider root: focus scope and column stack
    /// joined, the location the header's path line renders.
    public var combinedRelativePath: String {
        PathBoundary.joinRelative(relativePath, browsePath.relativePath)
    }

    /// The chip's label: the leaf folder's own name, or the source's name at the root, where a
    /// chip reading "/" or "" couldn't be told from another (⌘T at the root opens a second one).
    public func displayName(providerName: String) -> String {
        let combined = combinedRelativePath
        guard !combined.isEmpty else { return providerName }
        return (combined as NSString).lastPathComponent
    }
}

/// One pane's tabs, and which of them is live.
///
/// Never empty: a pane always has a location, so "close the last tab" is not a state this type can
/// reach: `close(at:)` refuses it and the caller closes the window instead, as Finder does. Every
/// other member relies on that invariant, so `active` needs no optional.
public struct PaneTabList: Equatable, Sendable {
    public private(set) var tabs: [PaneTab]
    /// Index into `tabs`. Always in range, because every mutation re-derives it.
    public private(set) var selectedIndex: Int

    /// Tabs closed in this session, newest last: what Reopen Closed Tab pops. Capped, so a long
    /// session doesn't keep every folder visited alive for a menu item nobody reaches past the
    /// second entry.
    public private(set) var recentlyClosed: [PaneTab]
    static let reopenLimit = 10

    public init(tabs: [PaneTab], selectedIndex: Int = 0, recentlyClosed: [PaneTab] = []) {
        precondition(!tabs.isEmpty, "a pane always holds at least one tab")
        self.tabs = tabs
        self.selectedIndex = min(max(0, selectedIndex), tabs.count - 1)
        self.recentlyClosed = recentlyClosed
    }

    public init(single tab: PaneTab) {
        self.init(tabs: [tab])
    }

    public var active: PaneTab { tabs[selectedIndex] }
    public var count: Int { tabs.count }

    /// Whether the strip renders at all. One tab shows nothing, as in Finder, so someone who never
    /// opens a second tab never sees a strip.
    public var showsStrip: Bool { tabs.count > 1 }

    /// Whether this strip is indistinguishable from the one a fresh launch already seeds, so a
    /// restore would only replace an identical list with one whose ids nothing else knows about.
    ///
    /// "At the root" means the combined location, not the scope: a tab drilled straight down from
    /// the root has an empty scope and a full column stack, and testing `relativePath` alone would
    /// skip its restore and lose the stack. A pinned single tab at the root is not seed state: the
    /// pin is the user's decision, and skipping the restore would drop it silently.
    public var isSeedState: Bool {
        tabs.count == 1 && active.combinedRelativePath.isEmpty && !active.isPinned
    }

    public var canReopen: Bool { !recentlyClosed.isEmpty }

    public func index(of id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }

    // MARK: - Mutation

    /// Overwrites the active entry with the pane's live state, ahead of parking it.
    ///
    /// Keeps the active tab's id: a capture is the same tab with newer contents, and a new id would
    /// make the strip's `ForEach` rebuild the chip (losing its hover and, in `.chip`, closing the
    /// menu the user is clicking through).
    public mutating func captureActive(_ snapshot: PaneTab) {
        tabs[selectedIndex] = PaneTab(id: active.id,
                                      providerId: snapshot.providerId,
                                      relativePath: snapshot.relativePath,
                                      browsePath: snapshot.browsePath,
                                      history: snapshot.history,
                                      selection: snapshot.selection,
                                      searchQuery: snapshot.searchQuery,
                                      searchIsExpanded: snapshot.searchIsExpanded,
                                      // Kept, not taken from the snapshot: the live pane doesn't
                                      // know whether its tab is pinned, so reading it from there
                                      // would unpin a tab every time the user walked away from it.
                                      isPinned: active.isPinned)
    }

    /// The pane's live location written over the active entry: the list a save has to write.
    ///
    /// The active entry is a stale snapshot by construction (see `PaneTab`), so a strip saved
    /// straight off the list would store, for the tab on screen, where it was last parked rather
    /// than what it shows, and the active tab would lose its columns across a quit.
    ///
    /// Three values, not one joined path: `PaneTabsStore` records the scope/stack cut as a depth,
    /// and an entry with the combined path as its scope would save a depth of zero.
    ///
    /// The id and the pin are kept from the list: this is the same tab, and the live pane knows
    /// nothing about pinning.
    ///
    /// **The active tab's `history` is discarded**: `PaneTab.init` re-seeds it as `[root, here]`.
    /// Right for a save (`PaneTabsStore` stores no history, and `applyTab` relies on every
    /// constructed tab agreeing with its own path); pinned by
    /// `theSaveOverlayReSeedsTheActiveTabsHistoryRatherThanCarryingIt`. **Never use this to move a
    /// live tab inside the app**, where losing Back would be a bug.
    ///
    /// Nothing else moves: `selectedIndex`, `recentlyClosed` and the other tabs stay as they are.
    /// A rule here rather than at the call site, which is a `View` extension no test can create.
    public func replacingActive(providerId: String,
                                relativePath: String,
                                browsePath: PaneBrowsePath) -> PaneTabList {
        var copy = self
        let live = active
        copy.tabs[copy.selectedIndex] = PaneTab(
            id: live.id,
            providerId: providerId,
            relativePath: relativePath,
            browsePath: browsePath,
            // History re-seeded from the new path, as `PaneTab.init` does with none: `applyTab`
            // relies on every constructed tab agreeing with its own path, and the stored format
            // holds no history.
            selection: live.selection,
            searchQuery: live.searchQuery,
            searchIsExpanded: live.searchIsExpanded,
            isPinned: live.isPinned)
        return copy
    }

    /// Appends `tab` at the trailing end and makes it active.
    ///
    /// Trailing rather than next-to-the-current (Safari's rule): the ＋ sits at the trailing end, so
    /// a new tab appearing anywhere else moves the strip under the pointer that just asked for it.
    @discardableResult
    public mutating func open(_ tab: PaneTab) -> UUID {
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        return tab.id
    }

    /// Appends `tab` at the trailing end without making it active, like a ⌘-clicked link's
    /// background tab; the pane stays where it is. Files opened together from Finder use it: the
    /// first is on screen, and each of the others waits in a tab of its own.
    @discardableResult
    public mutating func openInBackground(_ tab: PaneTab) -> UUID {
        tabs.append(tab)
        return tab.id
    }

    /// Closes one tab and records it for Reopen Closed Tab. Returns false, changing nothing, on the
    /// last tab: the caller closes the window instead. Where the selection goes is `remove(at:)`'s,
    /// shared with `discard(at:)`; the recording is what separates the two.
    @discardableResult
    public mutating func close(at index: Int) -> Bool {
        guard let closing = remove(at: index) else { return false }
        recentlyClosed.append(closing)
        if recentlyClosed.count > Self.reopenLimit { recentlyClosed.removeFirst() }
        return true
    }

    /// Removes a tab without putting it on the reopen stack: a discard, not a close.
    ///
    /// A tab is discarded because it can't be shown at all (its source is gone or switched off,
    /// `FileSyncManager.discardTab`). On the reopen stack, Reopen Closed Tab would pop it, find the
    /// source still missing and discard it straight back: a menu item enabled forever that never
    /// works. A tab closed by hand before its source went away is still on the stack, and one press
    /// spends it (reopened, found dead, discarded with a log line) instead of cycling.
    @discardableResult
    public mutating func discard(at index: Int) -> Bool { remove(at: index) != nil }

    /// The removal both of the above share: takes the tab out and re-derives `selectedIndex`.
    ///
    /// The neighbour to the right inherits selection, or the left at the trailing end: Finder's
    /// rule, so closing several tabs in a row doesn't make the pointer chase the strip. Refuses the
    /// last tab, the invariant every other member relies on.
    private mutating func remove(at index: Int) -> PaneTab? {
        guard tabs.count > 1, tabs.indices.contains(index) else { return nil }
        let going = tabs.remove(at: index)
        if index < selectedIndex {
            selectedIndex -= 1
        } else if index == selectedIndex {
            selectedIndex = min(index, tabs.count - 1)
        }
        return going
    }

    @discardableResult
    public mutating func close(id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        return close(at: index)
    }

    /// ⌥-click on a ✕, and the context menu's Close Other Tabs. The kept tab becomes active
    /// whether or not it already was: the gesture is "leave me with this one".
    public mutating func closeOthers(keeping id: UUID) {
        guard index(of: id) != nil else { return }
        // Pinned tabs survive: "close the others" means the pile you accumulated, not the places
        // you deliberately kept. Two filters over one predicate preserve order, so the pinned
        // prefix and the survivor's place in it hold by construction.
        let closed = tabs.filter { !$0.isPinned && $0.id != id }
        recentlyClosed.append(contentsOf: closed)
        if recentlyClosed.count > Self.reopenLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.reopenLimit)
        }
        tabs = tabs.filter { $0.isPinned || $0.id == id }
        selectedIndex = index(of: id) ?? 0
    }

    public mutating func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
    }

    public mutating func select(id: UUID) {
        if let index = index(of: id) { selectedIndex = index }
    }

    /// ⇧⌘] / ⌃⇥. Wraps, because a cycle that stops at the end is a cycle you have to look at the
    /// strip to use.
    public mutating func selectNext() {
        guard tabs.count > 1 else { return }
        selectedIndex = (selectedIndex + 1) % tabs.count
    }

    public mutating func selectPrevious() {
        guard tabs.count > 1 else { return }
        selectedIndex = (selectedIndex + tabs.count - 1) % tabs.count
    }

    /// The tabs pinned to the leading end, in strip order.
    public var pinned: [PaneTab] { tabs.filter(\.isPinned) }
    public var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// How many tabs "Close Other Tabs" would actually close, keeping `id` and every pinned tab.
    /// Not `count - 1`, since pins survive. The host's log line and the strip's menu item both ask
    /// this, so the menu and the log can't disagree about one click.
    public func closableOthers(keeping id: UUID) -> Int {
        tabs.filter { $0.id != id && !$0.isPinned }.count
    }

    /// Pins a tab, moving it to the end of the pinned run at the leading end of the strip.
    ///
    /// The pinned run is always a prefix. Everything else about pinning (what folds away, what
    /// Close Other Tabs keeps, where a drag may drop) is stated in terms of it, so this must never
    /// leave a pinned tab among the unpinned ones.
    public mutating func pin(id: UUID) {
        guard let from = index(of: id), !tabs[from].isPinned else { return }
        let live = active.id
        var moving = tabs.remove(at: from)
        moving.isPinned = true
        tabs.insert(moving, at: tabs.prefix { $0.isPinned }.count)
        selectedIndex = index(of: live) ?? selectedIndex
    }

    /// Unpins a tab, dropping it to the head of the unpinned run: closest to where it just was,
    /// rather than at the far end of a long strip.
    public mutating func unpin(id: UUID) {
        guard let from = index(of: id), tabs[from].isPinned else { return }
        let live = active.id
        var moving = tabs.remove(at: from)
        moving.isPinned = false
        tabs.insert(moving, at: tabs.prefix { $0.isPinned }.count)
        selectedIndex = index(of: live) ?? selectedIndex
    }

    /// Drag-to-reorder. Moves the tab at `from` so it lands at `to`, and keeps the same tab live:
    /// reordering is about where a chip sits, not which one you are looking at.
    ///
    /// Indices out of range are ignored rather than clamped: a drop index comes from a pointer
    /// position, and clamping a wild one would move a tab somewhere the user didn't drop it.
    ///
    /// A drag can't cross the pin line: dropping an unpinned tab among the pinned ones would pin it
    /// silently or break the prefix invariant, so the drop is clamped to the tab's own run, as in
    /// Chrome and Safari.
    public mutating func move(from: Int, to: Int) {
        guard from != to, tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let pinnedRun = tabs.prefix { $0.isPinned }.count
        let to = tabs[from].isPinned ? min(to, max(0, pinnedRun - 1)) : max(to, pinnedRun)
        guard from != to, tabs.indices.contains(to) else { return }
        let live = active.id
        let moving = tabs.remove(at: from)
        tabs.insert(moving, at: to)
        selectedIndex = index(of: live) ?? min(to, tabs.count - 1)
    }

    /// Duplicate: the same location under a new identity, opened at the end like any other tab.
    ///
    /// The selection, the search query and the back/forward history are not carried over: a
    /// duplicate is a second view of a folder, not a copy of what you were doing. Its history is
    /// seeded from the path by `PaneTab.init`, so it can walk up from where it opened but not back
    /// through places it never was.
    public mutating func duplicate(id: UUID) {
        guard let index = index(of: id) else { return }
        let source = tabs[index]
        open(PaneTab(providerId: source.providerId,
                     relativePath: source.relativePath,
                     browsePath: source.browsePath))
    }

    /// Reopen Closed Tab, newest first. Returns the reopened tab so the caller can apply it.
    @discardableResult
    public mutating func reopenLastClosed() -> PaneTab? {
        guard let tab = recentlyClosed.popLast() else { return nil }
        // A new id: the closed one may still be on the stack (Close Other Tabs pushes several at
        // once), and two chips sharing an id collide in `ForEach`. Reopened unpinned: `open`
        // appends at the trailing end, where a pinned tab would break the prefix; the pin is one
        // click back.
        let reopened = PaneTab(providerId: tab.providerId,
                               relativePath: tab.relativePath,
                               browsePath: tab.browsePath,
                               history: tab.history,
                               selection: tab.selection,
                               searchQuery: tab.searchQuery,
                               searchIsExpanded: tab.searchIsExpanded)
        open(reopened)
        return reopened
    }
}
