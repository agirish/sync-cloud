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
/// What a tab owns is the v4.x roadmap §1 table, and the reason each is here rather than shared:
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

    public init(id: UUID = UUID(),
                providerId: String,
                relativePath: String = "",
                browsePath: PaneBrowsePath = PaneBrowsePath(),
                history: PaneNavigationHistory? = nil,
                selection: Set<String> = [],
                searchQuery: String = "",
                searchIsExpanded: Bool = false) {
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
                                      searchIsExpanded: snapshot.searchIsExpanded)
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

    /// Closes one tab. Returns false — changing nothing — on the last tab, which is the signal for
    /// the caller to close the window instead.
    ///
    /// The neighbour to the RIGHT inherits selection, falling back to the left at the trailing end.
    /// That is Finder's rule and it is the one that lets you close several tabs in a row without
    /// the pointer chasing the strip.
    @discardableResult
    public mutating func close(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        let closing = tabs.remove(at: index)
        recentlyClosed.append(closing)
        if recentlyClosed.count > Self.reopenLimit { recentlyClosed.removeFirst() }
        if index < selectedIndex {
            selectedIndex -= 1
        } else if index == selectedIndex {
            selectedIndex = min(index, tabs.count - 1)
        }
        return true
    }

    @discardableResult
    public mutating func close(id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        return close(at: index)
    }

    /// ⌥-click on a ✕, and the context menu's Close Other Tabs. The kept tab becomes active
    /// whether or not it already was — the gesture is "leave me with this one".
    public mutating func closeOthers(keeping id: UUID) {
        guard let keep = index(of: id) else { return }
        let survivor = tabs[keep]
        let closed = tabs.enumerated().filter { $0.offset != keep }.map(\.element)
        recentlyClosed.append(contentsOf: closed)
        if recentlyClosed.count > Self.reopenLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.reopenLimit)
        }
        tabs = [survivor]
        selectedIndex = 0
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

    /// Duplicate: the same location under a new identity, opened at the end like any other tab.
    /// The selection and the search query are deliberately NOT carried over — a duplicate is a
    /// second view of a folder, not a second copy of what you were doing to it.
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
