import Foundation

/// State→presentation mapping and per-tab persistence for the file panes that sit alongside the
/// bottom workspace, kept out of the view builder so tests can pin the strings, the symbol, the
/// per-tab defaults, and the override encoding.
///
/// Two layout modes:
///   • **Compare** (Differences, Details) stacks *two* provider panes — the Left↔Right comparison
///     surface — over the workspace. You navigate, select, and compare across both.
///   • **Single source** (Tidy, with its Duplicates / Filing / Names / Automations / Storage lenses)
///     scans one folder, so it docks a *single* collapsible provider rail beside the workspace.
///
/// Either way the panes can be shown or hidden per tab, and the choice persists — encoded into one
/// defaults string keyed by the tab's raw value. The single-source tab defaults to the rail
/// collapsed (workspace fills the window); the compare tabs default to the panes shown. Because the
/// persistent tab strip is always on screen, hiding the panes can never leave the window empty, so —
/// unlike the previous model — every tab's panes are freely hideable.
///
/// The persisted map stores *hidden* (not *visible*) per tab, matching the format shipped before the
/// two-mode rework, so a user's remembered show/hide survives the upgrade unchanged.
enum TopPaneVisibility {

    static let symbol = "rectangle.topthird.inset.filled"

    /// How a tab arranges its panes relative to the workspace.
    enum Mode {
        /// Two provider panes stacked over the workspace (Differences, Details).
        case compare
        /// One collapsible provider rail docked beside the workspace (Tidy).
        case singleSource
    }

    /// The layout mode for a tab.
    static func mode(for tab: ContentView.BottomTab) -> Mode {
        switch tab {
        case .differences, .details: return .compare
        case .tidy: return .singleSource
        }
    }

    /// How many provider panes a tab shows: both sides for a comparison, one for a single-source
    /// workspace.
    static func paneCount(for tab: ContentView.BottomTab) -> Int {
        mode(for: tab) == .compare ? 2 : 1
    }

    static func title(panesVisible: Bool, mode: Mode) -> String {
        switch mode {
        case .compare: return panesVisible ? "Hide File Panes" : "Show File Panes"
        case .singleSource: return panesVisible ? "Hide Source Pane" : "Show Source Pane"
        }
    }

    static func helpText(panesVisible: Bool, mode: Mode) -> String {
        switch mode {
        case .compare:
            return panesVisible ? "Hide the Left/Right file panes" : "Show the Left/Right file panes"
        case .singleSource:
            return panesVisible ? "Collapse the source rail" : "Show the source rail to browse or re-scope"
        }
    }

    /// The default *hidden* state for a tab, before any user override: the single-source workspace
    /// starts with its rail collapsed (the workspace fills); the comparison tabs start with both
    /// panes shown.
    static func defaultPanesHidden(for tab: ContentView.BottomTab) -> Bool {
        mode(for: tab) == .singleSource
    }

    /// Resolves whether the panes are hidden for a tab, honoring a stored per-tab override.
    static func panesHidden(for tab: ContentView.BottomTab, override: Bool?) -> Bool {
        override ?? defaultPanesHidden(for: tab)
    }

    // MARK: - Per-tab override persistence

    /// Decodes the persisted override map (tab raw value → hidden). Malformed or empty input
    /// yields an empty map, so every tab falls back to its default. Unknown keys (e.g. a retired
    /// tab's leftover entry) are harmless — lookups are by the current tab's raw value.
    static func decodeOverrides(_ raw: String) -> [String: Bool] {
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return map
    }

    /// Encodes the override map back to a defaults string. Sorted keys keep the stored value
    /// stable (no churn when the contents are unchanged) and make the round-trip pinnable.
    static func encodeOverrides(_ map: [String: Bool]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(map),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    /// Returns a copy of `overrides` with `tab` recorded as `hidden`.
    static func settingOverride(
        _ overrides: [String: Bool],
        tab: ContentView.BottomTab,
        hidden: Bool
    ) -> [String: Bool] {
        var next = overrides
        next[tab.rawValue] = hidden
        return next
    }
}
