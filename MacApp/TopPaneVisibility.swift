import Foundation

/// State→presentation mapping and per-tab persistence for the file panes that sit alongside the
/// bottom workspace, kept out of the view builder so tests can pin the strings, the symbol, the
/// per-tab defaults, and the override encoding.
///
/// Two layout modes:
///   • **Compare** stacks *two* provider panes — the Left↔Right comparison surface — over the
///     Differences workspace. You navigate, select, and compare across both.
///   • **Single source** (every lens workspace: Organize, Duplicates, Rename, Automations,
///     Storage) scans one folder, so it docks a *single* collapsible provider rail beside it.
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
    static func defaultPanesHidden(for workspace: Workspace) -> Bool { false }

    /// Resolves whether the panes are hidden for a workspace, honoring a stored override.
    static func panesHidden(for workspace: Workspace, override: Bool?) -> Bool {
        override ?? defaultPanesHidden(for: workspace)
    }

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
