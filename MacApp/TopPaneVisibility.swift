import Events
import Foundation

/// State→presentation mapping and per-tab persistence for the file panes that sit alongside the
/// bottom workspace, kept out of the view builder so tests can pin the strings, the symbol, the
/// per-tab defaults, and the override encoding.
///
/// Two layout modes:
///   • **Compare** stacks *two* provider panes — the Left↔Right comparison surface — over the
///     Differences workspace. You navigate, select, and compare across both.
///   • **Single source** (Browse, and every lens workspace: Organize, Duplicates, Rename,
///     Automations, Storage) works one tree.
///
/// **Browse is single-source and gets no mode of its own, deliberately.** It has no lens to dock a
/// rail beside — it *is* the pane, full width — so a third case is tempting. It would also be a
/// trap: a dozen sites ask `layoutMode == .singleSource` to mean "there is only one tree here",
/// and a third case makes every one of them answer no for the workspace that is most purely one
/// tree. Those are the sites that empty the difference index, drop the comparison verbs from the
/// row menu, stop ⌥-click driving the hidden right pane, and let Escape clear a selection with no
/// action bar to clear it from — all of which Browse needs. What Browse does differently is
/// *layout*, and layout is `ContentView.ContentLayout`'s question: it answers `.browseFull` before
/// this type's pane-hiding is ever consulted. The rule to keep: this enum says how many trees,
/// `ContentLayout` says how they are arranged.
///
/// Either way the panes can be shown or hidden per workspace, and the choice persists — encoded
/// into one defaults string keyed by the workspace's raw value. Because the workspace bar is always
/// on screen — it rides the window toolbar — hiding the panes can never leave the window with no way
/// out, so every workspace's panes are freely hideable.
///
/// The persisted map stores *hidden* (not *visible*) per workspace, matching the format shipped
/// before, so a user's remembered show/hide survives.
enum TopPaneVisibility {

    /// How a workspace arranges its panes relative to the lens.
    enum Mode {
        /// Two provider panes stacked over the Differences workspace.
        case compare
        /// One collapsible provider rail docked beside the lens.
        case singleSource
    }

    /// The layout mode for a workspace.
    static func mode(for workspace: Workspace) -> Mode {
        workspace == .compare ? .compare : .singleSource
    }

    /// How many provider panes a workspace shows: both sides for a comparison, one for a lens.
    static func paneCount(for workspace: Workspace) -> Int {
        mode(for: workspace) == .compare ? 2 : 1
    }

    /// The default *hidden* state, before any user override: nothing starts hidden.
    ///
    /// This changes what `Tidy` defaulted to, deliberately. Tidy opened with its rail collapsed,
    /// but you could not *reach* a lens without going through the lens tabs, and choosing a lens
    /// there opened the rail — so the collapsed default described a state almost nobody saw. The
    /// flat bar drops you straight into a lens with no such side effect, and the point of the
    /// change is that the source browser is in the same place on every workspace. Starting it
    /// collapsed would contradict that on first use. A stored override still wins, and the
    /// upgrade carries Tidy's forward (see ``migratingOverrides(_:)``).
    ///
    /// **Editor is the one exception, and it starts hidden.** Its source pane is there for the
    /// session where you need to browse to a folder you have not kept or visited; the ordinary
    /// session opens a file from the rail and writes in it, and three columns standing between the
    /// window edge and the text would be three things to look past every time. A stored override
    /// still wins, so a user who expands it keeps it expanded.
    static func defaultPanesHidden(for workspace: Workspace) -> Bool {
        switch workspace {
        case .browse, .compare, .filing: return false
        case .editor: return true
        }
    }

    /// Resolves whether the panes are hidden for a workspace, honoring a stored override.
    static func panesHidden(for workspace: Workspace, override: Bool?) -> Bool {
        override ?? defaultPanesHidden(for: workspace)
    }

    // MARK: - The editor's file rail

    /// Whether the editor's file rail is drawn, from the two bits that decide it.
    ///
    /// `paneHidden` is the workspace's existing override (``panesHidden(for:override:)``);
    /// `railHidden` is the editor-only bit "Just the text" sets. The rail exists to be the ONE file
    /// list on screen: while the source pane is open it lists the pane's folder a second time, so
    /// the pane wins. While the pane is collapsed the rail bit decides. The bit is READ only in
    /// that state and never cleared by the pane opening, so "just the text" survives a trip into
    /// the pane and back.
    static func editorRailIsDrawn(paneHidden: Bool, railHidden: Bool) -> Bool {
        paneHidden && !railHidden
    }

    /// The defaults key for the rail bit. Persisted like ``overridesKey``, for the same reason: a
    /// layout someone quit in is the layout they relaunch into.
    static let editorRailHiddenKey = "editorRailHidden"

    /// Defaults keys for ``EditorExpand``'s two record bits. Persisted like the rail bit: a window
    /// quit while expanded relaunches expanded, and leaving it then must still give back the same.
    static let editorExpandSidebarPutAwayKey = "editorExpandSidebarPutAway"
    static let editorExpandFoldedPaneKey = "editorExpandFoldedPane"

    // MARK: - Per-tab override persistence

    /// Decodes the persisted override map (workspace raw value → hidden). Malformed or empty input
    /// yields an empty map, so every workspace falls back to its default. Unknown keys (e.g. a
    /// retired tab's leftover entry) are harmless — lookups are by the current raw value.
    static func decodeOverrides(_ raw: String) -> [String: Bool] {
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return map
    }

    /// **The decoded map, memoised on the string it came from** — what every *read* goes through.
    ///
    /// ``decodeOverrides(_:)`` allocates a `JSONDecoder` and parses on each call, and it is on the
    /// hottest read in the window: `ContentView.panesHiddenForCurrentTab` is consulted by
    /// `contentLayout`, `folderSidebarIsShowing`, two shortcut gates, the source picker, two
    /// `.animation` modifiers and an `onChange` — several times per body pass, and the body
    /// re-evaluates on hover, on a drag frame and on every scan tick.
    ///
    /// **Keyed on the raw string, which is the whole of the input.** The map is a pure function of
    /// it, so a hit is not an approximation of the answer — it *is* the answer, and a write to the
    /// defaults key changes the string and misses. That is why this is a one-entry memo rather than
    /// a cache with an invalidation rule to keep in step with the writers: there is nothing to keep
    /// in step with. `decodeOverrides` stays as it was, uncached and pure, for the migration and
    /// for the tests that pin the encoding.
    ///
    /// Main-actor, because that is where every reader is and a shared `static var` needs an
    /// isolation; the write path (`togglePanesForCurrentTab`, `presentLensRail`) deliberately does
    /// not use it — it runs once per click and its result is stale by construction.
    @MainActor
    static func overrides(in raw: String) -> [String: Bool] {
        if let memo = overridesMemo, memo.raw == raw { return memo.map }
        let map = decodeOverrides(raw)
        overridesMemo = (raw, map)
        return map
    }

    @MainActor private static var overridesMemo: (raw: String, map: [String: Bool])?

    /// Encodes the override map back to a defaults string. Sorted keys keep the stored value
    /// stable (no churn when the contents are unchanged) and make the round-trip pinnable.
    static func encodeOverrides(_ map: [String: Bool]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(map),
              let string = String(data: data, encoding: .utf8) else {
            // "" decodes back to an empty map, so this branch silently resets every workspace's
            // override to its default. It cannot fire for a `[String: Bool]`, which is exactly
            // when a branch must announce itself if it ever does.
            Logger.shared.error("The pane-visibility overrides could not be encoded for saving — every workspace falls back to its default panes")
            return ""
        }
        return string
    }

    /// Returns a copy of `overrides` with `workspace` recorded as `hidden`.
    static func settingOverride(
        _ overrides: [String: Bool],
        workspace: Workspace,
        hidden: Bool
    ) -> [String: Bool] {
        var next = overrides
        next[workspace.rawValue] = hidden
        return next
    }

    /// The defaults key holding the encoded override map.
    static let overridesKey = "topPaneOverridesByTab"
    /// The raw value the single `Tidy` entry used, before the lenses became workspaces.
    static let legacyTidyKey = "Tidy"

    /// Fans the retired `Tidy` entry out across the workspaces that came out of it.
    ///
    /// One key used to cover all five lenses, so leaving it alone would silently discard a
    /// deliberate "keep the rail up in Tidy" the moment the lenses became peers. Each lens
    /// workspace inherits Tidy's stored value unless it already carries one of its own, and the
    /// spent key is dropped so this cannot re-run against a later, deliberate choice.
    static func migratingOverrides(_ overrides: [String: Bool]) -> [String: Bool] {
        guard let tidy = overrides[legacyTidyKey] else { return overrides }
        var next = overrides
        next.removeValue(forKey: legacyTidyKey)
        for workspace in Workspace.lensWorkspaces where next[workspace.rawValue] == nil {
            next[workspace.rawValue] = tidy
        }
        return next
    }

    /// Runs the override migration against a stored string, returning the new string, or `nil`
    /// when nothing needed to change.
    static func migratingOverridesRaw(_ raw: String) -> String? {
        let decoded = decodeOverrides(raw)
        let migrated = migratingOverrides(decoded)
        guard migrated != decoded else { return nil }
        return encodeOverrides(migrated)
    }
}

/// **What Expand put away, and so what leaving it gives back** (TE48, revised 2026-10-04).
///
/// Expand leaves the text alone in the window: the Text Files list, the file pane and the sidebar
/// all go. Leaving it gives back exactly what was showing when it began — asked 2026-10-04, when
/// the sidebar stopped riding on the pane in Edit (`Workspace.folderSidebarOutlivesPaneCollapse`).
/// Before that, leaving brought back the list only and the pane stayed folded.
///
/// Four bits, each persisted where it already lived, and one method per act that moves them, so a
/// test can walk every combination without a window.
struct EditorExpand: Equatable {
    /// The Text Files list withheld — `editorRailHidden`. Survives the pane being opened by hand,
    /// by design (see `TopPaneVisibility.editorRailIsDrawn`).
    var railHidden: Bool
    /// Edit's file pane folded to its spine — Edit's entry in the pane overrides.
    var paneFolded: Bool
    /// Expand put the sidebar away, so leaving shows it again. The sidebar's own preference is
    /// shared by every workspace and is NOT written: hiding it here must not hide it in Compare.
    var sidebarPutAway: Bool
    /// Expand folded the pane, so leaving reopens it. False when the pane was folded already.
    var paneFoldedByExpand: Bool

    /// The bit AND the pane folded — see `ContentView.editorIsExpanded`, which asks the same of
    /// the workspace on screen.
    var isOn: Bool { railHidden && paneFolded }

    /// Whether Expand is holding the sidebar off, whatever its preference says.
    var hidesSidebar: Bool { sidebarPutAway && isOn }

    /// Turns Expand on, recording what it puts away. `sidebarShowing` is Edit's column as drawn.
    ///
    /// **Already on, the record is kept**: a second entry (a launch from Finder into an expanded
    /// window) would otherwise read "the pane was folded, the sidebar was hidden" off Expand's own
    /// work and forget what to give back. Only a sidebar shown by hand since is added to it.
    mutating func enter(sidebarShowing: Bool) {
        if isOn {
            if sidebarShowing { sidebarPutAway = true }
        } else {
            paneFoldedByExpand = !paneFolded
            sidebarPutAway = sidebarShowing
        }
        railHidden = true
        paneFolded = true
    }

    /// Turns Expand off, giving back each piece it took.
    mutating func leave() {
        railHidden = false
        if paneFoldedByExpand { paneFolded = false }
        paneFoldedByExpand = false
        sidebarPutAway = false
    }

    /// The pane opened from its spine. That ends Expand, so the record is spent: the sidebar comes
    /// back with the pane, as it always did, and a later fold from the spine does not leave Expand
    /// owing a pane it never folded. The rail bit stays, as `editorRailIsDrawn` requires.
    mutating func paneOpenedByHand() {
        paneFolded = false
        paneFoldedByExpand = false
        sidebarPutAway = false
    }

    /// What changed between two states, for the log: "the Text Files list, the file pane and the
    /// sidebar", or the subset that moved. The sidebar counts only through Expand's hold, which is
    /// the only way Expand moves it. Never localised — it is a log line, read back by sessions.
    static func moved(from before: EditorExpand, to after: EditorExpand) -> String {
        var names: [String] = []
        if before.railHidden != after.railHidden { names.append("the Text Files list") }
        if before.paneFolded != after.paneFolded { names.append("the file pane") }
        if before.hidesSidebar != after.hidesSidebar { names.append("the sidebar") }
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// ⌃⌘S showed the sidebar while Expand had it put away — the person asked for it back, so
    /// Expand stops holding it off. Expand itself stays on.
    mutating func sidebarShownByHand() {
        sidebarPutAway = false
    }
}
