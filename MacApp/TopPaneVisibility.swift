import Foundation

/// State→presentation mapping and per-tab persistence for the "hide the top file panes"
/// feature, kept out of the view builder so tests can pin the strings, the symbol, the
/// per-tab defaults, and the override encoding.
///
/// The top two panes are the Left↔Right comparison surface. Differences and Details need
/// them (you navigate, select, and compare across both). The single-provider workspaces —
/// Tidy and Storage Lens — scan one folder, so the second pane is dead space there. Those
/// two tabs therefore default to top-hidden (the workspace fills the window), and a toolbar
/// toggle lets the user override it per tab. Overrides persist across launches, encoded into
/// one defaults string keyed by the tab's raw value, so a deliberate show/hide sticks.
///
/// Mirrors `BottomPaneToggle`; unlike the bottom glyph, `rectangle.topthird.inset` (an
/// outline sibling) does resolve, but state is still conveyed with tint so this toggle reads
/// as a pair with the adjacent bottom-pane toggle rather than switching mechanisms mid-row.
enum TopPaneVisibility {

    static let symbol = "rectangle.topthird.inset.filled"

    static func title(topVisible: Bool) -> String {
        topVisible ? "Hide Top Panes" : "Show Top Panes"
    }

    static func helpText(topVisible: Bool) -> String {
        topVisible ? "Hide the Left/Right file panes" : "Show the Left/Right file panes"
    }

    /// Help text shown when the toggle is disabled (a comparison tab, where the panes are
    /// essential and can't be hidden).
    static let disabledHelpText = "The Left/Right panes stay visible on this tab"

    /// Whether the top-pane toggle is meaningful for a tab. Only the single-provider
    /// workspaces can hide the comparison panes; Differences/Details always keep them.
    static func canHideTopPanes(for tab: ContentView.BottomTab) -> Bool {
        switch tab {
        case .tidy, .storageLens: return true
        case .differences, .details: return false
        }
    }

    /// The default top-hidden state for a tab, before any user override: the single-provider
    /// workspaces collapse the panes automatically; the comparison tabs keep them. Today this
    /// is exactly the hide-capable set, but the two concepts are named separately so a future
    /// hide-capable-but-shown-by-default tab wouldn't need both call sites changed.
    static func defaultTopHidden(for tab: ContentView.BottomTab) -> Bool {
        canHideTopPanes(for: tab)
    }

    /// Resolves whether the top panes are hidden for a tab, honoring a stored override. A tab
    /// that can't hide its panes is never hidden, even if a stale override from a format change
    /// says otherwise — the guard keeps a bad value from ever emptying the comparison view.
    static func topHidden(for tab: ContentView.BottomTab, override: Bool?) -> Bool {
        guard canHideTopPanes(for: tab) else { return false }
        return override ?? defaultTopHidden(for: tab)
    }

    // MARK: - Per-tab override persistence

    /// Decodes the persisted override map (tab raw value → hidden). Malformed or empty input
    /// yields an empty map, so every tab falls back to its default.
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
