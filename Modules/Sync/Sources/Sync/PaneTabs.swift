import Foundation

/// One tab in a pane's strip: a location that pane can hold, parked.
///
/// **The active tab is not stored here.** A pane has exactly one live position — `leftProviderId`
/// and the manager's `leftRelativePath` / `leftBrowsePath` / `leftHistory` / `selectedLeftPaths` —
/// and switching tabs *captures* that live state into the outgoing tab and *applies* the incoming
/// one over it (`FileSyncManager+PaneTabs`). So the entry in `PaneTabList` for the active tab is a
/// snapshot from the moment it was last parked, and reading it while it is active is a bug; every
/// consumer goes through `PaneTabList.active` only for its *identity* (id, provider mark, name).
///
/// That is what makes the whole feature cheap: no workspace, no lens, no scan and no view has to
/// learn what a tab is, because at any instant the app has exactly the same amount of pane state it
/// had before tabs existed. Only the strip and the four verbs that move between tabs know.
///
/// Whether arriving at a tab costs a reload, or is a move inside what the pane already has.
///
/// **One rule, two callers, and they must not drift**: the manager decides from it whether to drop
/// the trees and the comparison, and the host decides from it whether to run the scan. Two copies
/// would let a switch invalidate without reloading — a pane holding no tree and no scan until the
/// user pressed Refresh.
///
/// A pane's tree is a walk of one **root** at one **focus**, and the comparison is about one pair of
/// focused folders. So a switch that changes neither is not a cheaper reload, it is *no* reload:
/// nothing it touches — the column stack, the selection, the history, the search field — is an input
/// to either. That is the same reason drilling through columns has never rescanned, and a tab is a
/// location in exactly the sense a column stack is.
public enum PaneTabArrival {
    public static func needsReload(arrivingAt tab: PaneTab, fromProvider: String, fromFocus: String) -> Bool {
        tab.providerId != fromProvider || tab.history.current != fromFocus
    }
}

/// Where a **newly opened** tab sits, cut the way the pane it was opened from is cut.
///
/// **A pane's location is two values and only one of them draws columns** (`PaneTab.browsePath`):
/// the scope contributes exactly one column and the stack draws the rest. Every tab-opening verb
/// used to hand the whole location over as the *scope*, with an empty stack — so a tab opened from
/// a pane standing four columns deep came back as one full-width column, and there was nothing
/// wrong with it that persistence could fix. It saved a `stackDepth` of 0 faithfully, restored a
/// `stackDepth` of 0 faithfully, and every launch reproduced the flattening exactly.
///
/// That is what "the columns are collapsed again after a restart" was: not the restore, which had
/// already been fixed to carry the depth, but **⌘T flattening the stack at the moment the tab was
/// created**, forever after. `Health/Medical/Included Health/Expert Opinions` with depth 0, in his
/// own stored strip, written by `User opened a new tab at …` in the log.
///
/// One rule for every opener, because they are the same question asked twice:
///
/// - **⌘T / ＋ / double-click the strip** open at the pane's own location, so the cut is the pane's
///   own — the new tab is layout-identical to the one it came from, which is what "new tab *here*"
///   has to mean.
/// - **Open in New Tab / ⌘-double-click** open at a folder *under* that pane, so the scope holds
///   and everything below it becomes stack — the ancestor columns a column browser is for.
///
/// A target that is NOT under the pane's scope keeps the old answer (all scope, no stack): the
/// components would name folders under a path that does not contain them, so there is nothing left
/// for a stack to be relative to.
public enum PaneTabOpening {
    public static func location(of combined: String,
                                openedFromScope scope: String) -> (scope: String, stack: PaneBrowsePath) {
        let target = combined.split(separator: "/")
        let base = scope.split(separator: "/")
        guard base.count <= target.count, target.starts(with: base) else {
            return (combined, PaneBrowsePath())
        }
        // Through the SAME cut the stored strip is rebuilt with, so a tab opened at a location and
        // a tab restored to it cannot disagree about where the two halves meet.
        return PaneTabsStore.split(relativePath: combined, stackDepth: target.count - base.count)
    }
}

/// What a tab owns is the v4.x roadmap companion §1 table, and the reason each is here rather than shared:
///
/// - `providerId` — two tabs reading "Documents" from different clouds is the case the provider
///   mark on the chip exists for.
/// - `relativePath` — the comparison *scope*, which in Browse is simply where you are.
/// - `browsePath` — the Columns stack inside that scope. Both, because they mean different things
///   (see `PaneBrowsePath`) and a tab restored with only one of them lands somewhere else.
/// - `history` — Back walking out of a tab into a folder another tab visited would be a bug you
///   could not explain from what is on screen.
/// - `selection` and the search field — parked with the tab because coming back to a tab and
///   finding your selection cleared, or someone else's query in the field, reads as a lost tab.
///
/// Deliberately *not* here: view mode, hidden files, the preview column, column width. Those are
/// reading preferences that already have their own app-wide (or per-surface) keys, and a tab that
/// changed how the pane draws would make the strip a settings control.
public struct PaneTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var providerId: String
    /// The pane's comparison scope — `FileSyncManager.leftRelativePath`'s value for this tab.
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
    /// Whether this tab is pinned to the leading end of the strip.
    ///
    /// Pinning is about **keeping a place reachable**, and that is all it is: a pinned tab sits
    /// ahead of the unpinned ones, never folds away behind the overflow count, survives Close Other
    /// Tabs, and drops its ✕ so a stray click cannot take it. It is deliberately NOT Safari's
    /// mark-only chip — five identical cloud marks name nothing (roadmap companion §1), so a pinned tab keeps
    /// its name and wears a pin instead.
    public var isPinned: Bool

    public init(id: UUID = UUID(),
                providerId: String,
                relativePath: String = "",
                browsePath: PaneBrowsePath = PaneBrowsePath(),
                history: PaneNavigationHistory? = nil,
                selection: Set<String> = [],
                searchQuery: String = "",
                searchIsExpanded: Bool = false,
                isPinned: Bool = false) {
        self.id = id
        self.providerId = providerId
        self.relativePath = relativePath
        self.browsePath = browsePath
        // A tab seeded at a folder needs a history that can walk back OUT of it, or Back is dead in
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

    /// Where this tab is, as one path under the provider root — focus scope and column stack
    /// joined, which is the single location the header's path line renders and the one thing a
    /// person would call "where this tab is".
    public var combinedRelativePath: String {
        let browse = browsePath.relativePath
        if relativePath.isEmpty { return browse }
        if browse.isEmpty { return relativePath }
        return relativePath + "/" + browse
    }

    /// The chip's label: the leaf folder's own name, falling back to the source's name at the root.
    ///
    /// The fallback is not cosmetic. At the root there is no folder to name, and a chip reading
    /// "/" or "" would be the one tab you cannot tell from another — which is exactly the state a
    /// second tab is opened from (⌘T opens the current folder, so two tabs with the same name is
    /// the *expected* first sight of the strip; two tabs with no name at all is not).
    public func displayName(providerName: String) -> String {
        let combined = combinedRelativePath
        guard !combined.isEmpty else { return providerName }
        return (combined as NSString).lastPathComponent
    }
}

/// One pane's tabs, and which of them is live.
///
/// Never empty: a pane always has a location, so "close the last tab" is not a state this type can
/// reach — `close(at:)` refuses it and the caller closes the window instead, as Finder does. That
/// refusal is the invariant every other member is written against, so `active` needs no optional.
public struct PaneTabList: Equatable, Sendable {
    public private(set) var tabs: [PaneTab]
    /// Index into `tabs`. Always in range, because every mutation re-derives it.
    public private(set) var selectedIndex: Int

    /// Tabs closed in this session, newest last — what Reopen Closed Tab pops.
    ///
    /// Capped, and the cap is the point: an uncapped stack holds every folder visited in a long
    /// session, which is a list of the user's paths kept alive for a menu item nobody reaches past
    /// the second entry.
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

    /// Whether the strip renders at all. One tab shows nothing — Finder's behaviour, and what
    /// keeps an install that never opens a second tab pixel-identical to the one before tabs.
    public var showsStrip: Bool { tabs.count > 1 }

    /// Whether this strip is indistinguishable from the one a fresh launch already seeds, so a
    /// restore would replace an identical list with a new one whose ids nothing else knows about.
    ///
    /// **"At the root" means the COMBINED location, not the scope.** A pane's position is two
    /// values (see `PaneTab.browsePath`) and a tab drilled straight down from the root has an
    /// *empty scope* with a full column stack — so a test on `relativePath` alone reads that tab as
    /// "at the root" and throws the stack away. That is not hypothetical: it is precisely the
    /// one-tab-drilled-four-columns case the stack is persisted for, and testing the wrong half
    /// silently skipped its entire restore.
    ///
    /// A pinned single tab at the root is deliberately NOT this: the pin is a decision the user
    /// made, and skipping the restore would drop it with nothing said.
    public var isSeedState: Bool {
        tabs.count == 1 && active.combinedRelativePath.isEmpty && !active.isPinned
    }

    public var canReopen: Bool { !recentlyClosed.isEmpty }

    public func index(of id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }

    // MARK: - Mutation

    /// Overwrites the active entry with the pane's live state, ahead of parking it.
    ///
    /// Keeps the active tab's **id** — a capture is the same tab with newer contents, and replacing
    /// the id would make the strip's `ForEach` tear the chip down and rebuild it (losing its hover
    /// and, in `.chip`, closing the menu the user is clicking through).
    public mutating func captureActive(_ snapshot: PaneTab) {
        tabs[selectedIndex] = PaneTab(id: active.id,
                                      providerId: snapshot.providerId,
                                      relativePath: snapshot.relativePath,
                                      browsePath: snapshot.browsePath,
                                      history: snapshot.history,
                                      selection: snapshot.selection,
                                      searchQuery: snapshot.searchQuery,
                                      searchIsExpanded: snapshot.searchIsExpanded,
                                      // **Kept, not taken from the snapshot.** A capture carries
                                      // the live PANE's contents, and the pane has no idea whether
                                      // its tab is pinned — reading it from there would unpin a tab
                                      // every time the user walked away from it.
                                      isPinned: active.isPinned)
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

    /// Closes one tab **and records it for Reopen Closed Tab**. Returns false — changing nothing —
    /// on the last tab, which is the signal for the caller to close the window instead.
    ///
    /// Where the selection goes is `remove(at:)`'s, shared with `discard(at:)`; the recording is
    /// the whole of what this adds, and is exactly what separates the two.
    @discardableResult
    public mutating func close(at index: Int) -> Bool {
        guard let closing = remove(at: index) else { return false }
        recentlyClosed.append(closing)
        if recentlyClosed.count > Self.reopenLimit { recentlyClosed.removeFirst() }
        return true
    }

    /// Removes a tab **without putting it on the reopen stack** — a *discard*, not a close.
    ///
    /// The distinction is not bookkeeping. `recentlyClosed` is what File ▸ Reopen Closed Tab pops,
    /// and a tab is discarded precisely because it cannot be shown at all (its source is gone or
    /// switched off — `FileSyncManager.discardTab`). Recording one there made Reopen Closed Tab a
    /// **permanent no-op**: the press popped the dead tab, the host applied it, found the source
    /// still missing and discarded it again — which pushed it straight back. Measured at five
    /// presses in a row with the stack unchanged each time, and `canReopen` true throughout, so the
    /// menu item stayed enabled forever offering a tab that could never come back.
    ///
    /// It also drains correctly the other way: a tab the user closed BY HAND before its source went
    /// away is still on the stack, and one press now spends it — reopened, found dead, discarded
    /// with a line in the log saying why — instead of cycling.
    @discardableResult
    public mutating func discard(at index: Int) -> Bool { remove(at: index) != nil }

    /// The removal both of the above share: takes the tab out and re-derives `selectedIndex`.
    ///
    /// The neighbour to the RIGHT inherits selection, falling back to the left at the trailing end.
    /// That is Finder's rule and it is the one that lets you close several tabs in a row without
    /// the pointer chasing the strip. Refuses the last tab, which is the invariant every other
    /// member here is written against.
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
    /// whether or not it already was — the gesture is "leave me with this one".
    public mutating func closeOthers(keeping id: UUID) {
        guard index(of: id) != nil else { return }
        // **Pinned tabs survive.** "Close the others" means the pile you accumulated, not the two
        // places you deliberately kept — that is most of what pinning is for.
        //
        // Two filters over the same predicate rather than a rebuild: filtering preserves order, so
        // the pinned prefix and the survivor's place in it hold by construction. The first cut of
        // this appended the survivor and then moved it back when it turned out to be pinned, which
        // was three branches doing what `filter` does in one.
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
    ///
    /// **Not `count - 1`**: pins survive the gesture, so a strip of three whose other two are
    /// pinned has nothing to close. The host counts this for its log line and the strip gates its
    /// menu item on the same question — it was written twice, once per type, and two spellings of
    /// one rule is how the menu and the log come to disagree about the same click.
    public func closableOthers(keeping id: UUID) -> Int {
        tabs.filter { $0.id != id && !$0.isPinned }.count
    }

    /// Pins a tab, moving it to the end of the pinned run — the leading end of the strip.
    ///
    /// The pinned run is a PREFIX, always. Everything else about pinning (what folds away, what
    /// Close Other Tabs keeps, where a drag may drop) is stated in terms of that prefix, so the one
    /// thing this must never do is leave a pinned tab sitting among the unpinned ones.
    public mutating func pin(id: UUID) {
        guard let from = index(of: id), !tabs[from].isPinned else { return }
        let live = active.id
        var moving = tabs.remove(at: from)
        moving.isPinned = true
        tabs.insert(moving, at: tabs.prefix { $0.isPinned }.count)
        selectedIndex = index(of: live) ?? selectedIndex
    }

    /// Unpins a tab, dropping it to the head of the unpinned run — where a newly unpinned tab is
    /// closest to where it just was, rather than at the far end of a long strip.
    public mutating func unpin(id: UUID) {
        guard let from = index(of: id), tabs[from].isPinned else { return }
        let live = active.id
        var moving = tabs.remove(at: from)
        moving.isPinned = false
        tabs.insert(moving, at: tabs.prefix { $0.isPinned }.count)
        selectedIndex = index(of: live) ?? selectedIndex
    }

    /// Drag-to-reorder. Moves the tab at `from` so it lands at `to`, and **keeps the same tab
    /// live** — reordering is about where a chip sits, not about which one you are looking at.
    ///
    /// Indices out of range are ignored rather than clamped: a drop index is computed from a
    /// pointer position, and clamping a wild one would silently move a tab somewhere the user did
    /// not drop it.
    ///
    /// **A drag cannot cross the pin line.** Dropping an unpinned tab among the pinned ones would
    /// either pin it silently or break the prefix invariant every other rule here rests on; the
    /// drop is clamped to the tab's own run instead, which is what Chrome and Safari both do.
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
    /// The selection, the search query **and the back/forward history** are deliberately not
    /// carried over — a duplicate is a second view of a folder, not a second copy of what you were
    /// doing to it. The history is the one worth naming explicitly: it comes back seeded from the
    /// path by `PaneTab`'s initializer, so the new tab can walk *up* from where it opened but
    /// cannot walk *back* through somewhere it has never been.
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
        // once), and two chips sharing an id is a `ForEach` collision.
        // Reopened UNPINNED, whatever it was: `open` appends at the trailing end, and a pinned tab
        // landing there would break the prefix. Getting the place back is what this is for; getting
        // its pin back is one click.
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
