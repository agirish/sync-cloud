import Events
import Foundation

/// How many file panes each workspace shows, and their per-workspace show/hide, kept out of the
/// view builder so tests can pin the defaults and the override encoding.
///
/// Two modes: Compare stacks two provider panes over the Differences workspace; single source
/// (Browse, Organize and Edit) works one tree. Browse gets no mode of its own on purpose: many
/// sites read `.singleSource` as "only one tree here" (emptying the difference index, dropping
/// the comparison verbs, Escape clearing a selection), and Browse needs all of them. This enum
/// says how many trees; `ContentView.ContentLayout` says how they are arranged.
///
/// Hidden or shown persists per workspace in one defaults string keyed by raw value. It stores
/// hidden, not visible, so a stored choice keeps its meaning. The workspace bar rides the toolbar,
/// so hiding the panes never leaves the window with no way out.
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

    /// The default hidden state, before any stored override: shown, so the source browser is in
    /// the same place on every workspace.
    ///
    /// Edit is the one exception and starts hidden: an ordinary session opens a file from the rail
    /// and writes, and the pane's columns would stand between the window edge and the text. A
    /// stored override still wins everywhere.
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

    /// Whether the editor's file rail is drawn, from the three bits that decide it.
    ///
    /// `paneHidden` is the workspace's override (``panesHidden(for:override:)``); `railHidden` is
    /// Expand's bit; `railFolded` is the list folded into the strip by hand. The rail is meant to
    /// be the one file list on screen, so while the source pane is open the pane wins. With the
    /// pane collapsed, either rail bit withholds it. This rule never clears them; opening the pane
    /// by hand clears Expand's (`EditorExpand.paneOpenedByHand`).
    ///
    /// Two bits because Expand reads its own (`EditorExpand.isOn`): a hand fold stored in that bit
    /// would light the header's Files button, and leaving Expand would unfold it.
    static func editorRailIsDrawn(paneHidden: Bool, railHidden: Bool, railFolded: Bool) -> Bool {
        paneHidden && !railHidden && !railFolded
    }

    /// The defaults key for the rail bit, persisted like ``overridesKey`` so a layout someone quit
    /// in is the layout they relaunch into.
    static let editorRailHiddenKey = "editorRailHidden"

    /// The defaults key for the list folded into the strip by hand. Its own key, not Expand's; see
    /// ``editorRailIsDrawn(paneHidden:railHidden:railFolded:)``.
    static let editorRailFoldedKey = "editorRailFolded"

    /// Folded until someone opens it: a new window shows the strip's Text Files and Outline
    /// buttons, not a full column, and the empty page carries a Show Text Files button so a first
    /// session still finds the files. Remembered once changed.
    static let editorRailFoldedDefault = true

    /// Defaults keys for ``EditorExpand``'s two record bits. Persisted like the rail bit: a window
    /// quit while expanded relaunches expanded, and leaving it then must still give back the same.
    static let editorExpandSidebarPutAwayKey = "editorExpandSidebarPutAway"
    static let editorExpandFoldedPaneKey = "editorExpandFoldedPane"

    // MARK: - Per-tab override persistence

    /// Decodes the persisted override map (workspace raw value → hidden). Malformed or empty input
    /// yields an empty map, so every workspace falls back to its default. Unknown keys, such as a
    /// retired tab's leftover entry, are harmless: lookups use the current raw value.
    static func decodeOverrides(_ raw: String) -> [String: Bool] {
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return map
    }

    /// The decoded map, memoised on the string it came from; every read goes through here.
    /// `ContentView.panesHiddenForCurrentTab` asks several times per body pass, and decoding
    /// allocates a `JSONDecoder` each time.
    ///
    /// A one-entry memo keyed on the raw string, which is the whole input, so a hit is exact and
    /// any write misses; there is no invalidation to keep in step. `decodeOverrides` stays uncached
    /// for the migration and the encoding tests.
    ///
    /// Main-actor because every reader is, and a shared `static var` needs an isolation. The write
    /// path (`togglePanesForCurrentTab`, `presentLensRail`) does not use it.
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
            // "" decodes back to an empty map, resetting every workspace's override. It cannot
            // fire for a `[String: Bool]`, so it logs loudly if it ever does.
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
}

/// What Expand put away, and so what leaving it gives back.
///
/// Expand leaves the text alone in the window: the Text Files list, the file pane and the sidebar
/// all go, and leaving gives back exactly what was showing when it began. Four bits, each persisted
/// where it already lived, and one method per act that moves them, so a test can walk every
/// combination without a window.
struct EditorExpand: Equatable {
    /// The Text Files list withheld — `editorRailHidden`. Cleared by the pane being opened by hand
    /// (``paneOpenedByHand()``), which ends Expand.
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
    /// Already on, the record is kept: a second entry (a launch from Finder into an expanded
    /// window) would otherwise record Expand's own work and forget what to give back. Only a
    /// sidebar shown by hand since is added to it.
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

    /// The pane opened from its spine, which ends Expand completely: the record is spent and the
    /// rail bit goes too. Otherwise folding the pane again would re-light Expand on its own. Folded
    /// again, the pane gives the ordinary layout, the Text Files list beside the text.
    mutating func paneOpenedByHand() {
        railHidden = false
        paneFolded = false
        paneFoldedByExpand = false
        sidebarPutAway = false
    }

    /// What changed between two states, for the log: "the Files list, the file pane and the
    /// sidebar", or the subset that moved. The sidebar counts only through Expand's hold, which is
    /// the only way Expand moves it. Never localised — it is a log line, read back by sessions.
    static func moved(from before: EditorExpand, to after: EditorExpand) -> String {
        var names: [String] = []
        if before.railHidden != after.railHidden { names.append("the Files list") }
        if before.paneFolded != after.paneFolded { names.append("the file pane") }
        if before.hidesSidebar != after.hidesSidebar { names.append("the sidebar") }
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// ⌃⌘S showed the sidebar while Expand had it put away, so Expand stops holding it off.
    /// Expand itself stays on.
    mutating func sidebarShownByHand() {
        sidebarPutAway = false
    }

    /// The strip's "Show the text files" rung: the list, with the pane left folded. Not
    /// ``leave()``, which would reopen a pane Expand folded, and with the pane open the list is not
    /// drawn (`TopPaneVisibility.editorRailIsDrawn`). Expand is over, so its hold on the sidebar
    /// goes too, and the record is spent so a later Expand starts from what is showing then.
    mutating func textFilesShown() {
        railHidden = false
        paneFoldedByExpand = false
        sidebarPutAway = false
    }
}
