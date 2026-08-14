import Foundation

/// What survives a quit, for the Browse pane's tab strip.
///
/// **One list is persisted, and it is the left pane's.** Two tab lists exist (v4.x roadmap §1: the
/// two browse paths are what the whole feature is a list of), but Browse *is* the left pane, and
/// the right pane's list is Compare's — a workspace whose right-hand location has never been
/// restored across launches. Persisting it would be a behaviour change to Compare smuggled in with
/// a Browse feature; the right pane still seeds as one tab on its stored provider.
///
/// The stored shape is `[{providerId, relativePath}]` and nothing else, deliberately. Selection,
/// history and the search query are *session* state — a selection restored into a folder whose
/// contents changed while the app was closed points at files that may not be there, and a search
/// query restored into a field the user cannot see reads as the pane filtering itself.
///
/// `relativePath` is the tab's **combined** location (scope + column stack), which is the one thing
/// a person would call "where this tab was". It comes back as the tab's scope with an empty stack:
/// the pane then shows that folder, which is what was on screen, and the header's path line reads
/// the same string it did before the quit.
public enum PaneTabsStore {

    /// The v4.x roadmap §1 key. `[{"providerId": …, "relativePath": …}]` as JSON in a string,
    /// matching how the rest of the app parks small structured values in defaults.
    public static let tabsKey = "browseTabs"
    public static let selectedKey = "browseSelectedTab"

    /// One persisted tab. A named type rather than the live `PaneTab` because this is a **format**:
    /// `PaneTab` gains fields as the feature grows and none of them should silently start being
    /// written to disk.
    public struct Entry: Codable, Equatable, Sendable {
        public var providerId: String
        public var relativePath: String
        /// Whether this tab was pinned. **Optional on the way in**, so a strip written before
        /// pinning existed still decodes — the whole file is rejected on a missing key otherwise,
        /// and a user's tabs would silently vanish on the first launch after an upgrade.
        public var pinned: Bool

        public init(providerId: String, relativePath: String, pinned: Bool = false) {
            self.providerId = providerId
            self.relativePath = relativePath
            self.pinned = pinned
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            providerId = try c.decode(String.self, forKey: .providerId)
            relativePath = try c.decode(String.self, forKey: .relativePath)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }
    }

    /// Reads the stored strip. `nil` — not an empty array — when the key has never been written,
    /// which is what tells the caller to seed from the pane's own stored provider instead.
    public static func load(from defaults: UserDefaults = .standard) -> (entries: [Entry], selected: Int)? {
        guard let raw = defaults.string(forKey: tabsKey), let data = raw.data(using: .utf8) else {
            return nil
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data), !entries.isEmpty else {
            // A key that decodes to nothing is indistinguishable, for the caller, from no key at
            // all — and seeding is the right answer for both.
            return nil
        }
        let selected = min(max(0, defaults.integer(forKey: selectedKey)), entries.count - 1)
        return (entries, selected)
    }

    /// Writes the strip. Called on every tab mutation, which is cheap: this is at most a handful of
    /// short strings, and `UserDefaults` coalesces its own writes to disk.
    public static func save(tabs: [PaneTab], selected: Int, to defaults: UserDefaults = .standard) {
        let entries = tabs.map {
            Entry(providerId: $0.providerId, relativePath: $0.combinedRelativePath, pinned: $0.isPinned)
        }
        guard let data = try? JSONEncoder().encode(entries),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: tabsKey)
        defaults.set(min(max(0, selected), max(0, entries.count - 1)), forKey: selectedKey)
    }

    /// Turns stored entries back into tabs, dropping any whose provider is gone and any whose
    /// folder no longer exists.
    ///
    /// **A stored path is a claim about a disk that has been out of this app's sight since the last
    /// quit.** A folder deleted, renamed or moved while the app was closed would otherwise restore
    /// a tab onto nothing: an empty pane with a path in the header and no way to tell whether the
    /// folder is missing or merely empty. Falling back to the provider root loses the location and
    /// says so by showing the root; keeping the tab and letting it fail says nothing.
    ///
    /// `folderExists` is injected rather than called: the roots come from the host's settings and
    /// the check hits the disk, neither of which belongs in a decoder.
    public static func restore(entries: [Entry],
                               selected: Int,
                               isKnownProvider: (String) -> Bool,
                               folderExists: (_ providerId: String, _ relativePath: String) -> Bool) -> PaneTabList? {
        var restored: [PaneTab] = []
        // **Where the stored selection ends up after entries are dropped.** Clamping the stored
        // index into the shortened list is right only by accident: drop entry 0 of four with entry
        // 2 selected and a clamp lands on the wrong tab, silently opening the pane somewhere the
        // user did not leave it. Counting the survivors ahead of it is the answer that holds.
        var selectedAfterDrops: Int?
        for (index, entry) in entries.enumerated() {
            guard isKnownProvider(entry.providerId) else { continue }
            let path = folderExists(entry.providerId, entry.relativePath) ? entry.relativePath : ""
            if index == selected { selectedAfterDrops = restored.count }
            restored.append(PaneTab(providerId: entry.providerId, relativePath: path,
                                    isPinned: entry.pinned))
        }
        guard !restored.isEmpty else { return nil }
        // The selected entry itself may be one of the dropped ones; the nearest survivor is a
        // better answer than tab 0, and both are better than refusing the whole strip.
        let index = selectedAfterDrops ?? min(selected, restored.count - 1)
        return PaneTabList(tabs: restored, selectedIndex: index)
    }
}
