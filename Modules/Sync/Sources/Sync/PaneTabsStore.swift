import Foundation

/// What survives a quit, for the Browse pane's tab strip.
///
/// **One list is persisted, and it is the left pane's.** Two tab lists exist (v4.x roadmap companion §1: the
/// two browse paths are what the whole feature is a list of), but Browse *is* the left pane, and
/// the right pane's list is Compare's — a workspace whose right-hand location has never been
/// restored across launches. Persisting it would be a behaviour change to Compare smuggled in with
/// a Browse feature; the right pane still seeds as one tab on its stored provider.
///
/// The stored shape is `[{providerId, relativePath, stackDepth, pinned}]` and nothing else,
/// deliberately: every field is part of *where a tab is* or *how the strip is arranged*. Selection,
/// history and the search query are *session* state — a selection restored into a folder whose
/// contents changed while the app was closed points at files that may not be there, and a search
/// query restored into a field the user cannot see reads as the pane filtering itself.
///
/// `relativePath` is the tab's **combined** location (scope + column stack), which is the one thing
/// a person would call "where this tab was" — and `stackDepth` says where to cut it back into the
/// two halves the pane actually holds.
///
/// **Why the split has to be stored, rather than re-derived.** The two halves render differently:
/// scope contributes exactly one column and the stack draws the rest (`columnDirectories`), so a
/// tab restored entirely as scope comes back showing one full-width column no matter how many the
/// user had built. The header's path line reads the same either way — it renders the two joined —
/// which is exactly why this went unnoticed: the breadcrumb was right and only the columns were
/// gone. Nothing in the combined string says where the cut was, so the depth is stored beside it.
///
/// **The format is additive on purpose, and safe in both directions.** `relativePath` keeps meaning
/// what it always meant, so a strip written by a build without `stackDepth` restores exactly as it
/// did before (depth 0 — all scope, one column), and a strip written *with* one still restores in
/// an older build the old way rather than landing it somewhere else. Redefining `relativePath` as
/// the scope alone would have broken that second direction silently: the older build would reopen
/// the tab at an ancestor of where the user left it.
public enum PaneTabsStore {

    /// The v4.x roadmap companion §1 key. `[{"providerId": …, "relativePath": …, "stackDepth": …,
    /// "pinned": …}]` as JSON in a string, matching how the rest of the app parks small structured
    /// values in defaults. Both trailing keys are optional on the way in; see `Entry`.
    public static let tabsKey = "browseTabs"
    public static let selectedKey = "browseSelectedTab"

    /// One persisted tab. A named type rather than the live `PaneTab` because this is a **format**:
    /// `PaneTab` gains fields as the feature grows and none of them should silently start being
    /// written to disk.
    public struct Entry: Codable, Equatable, Sendable {
        public var providerId: String
        public var relativePath: String
        /// How many of `relativePath`'s trailing components were the **column stack** rather than
        /// the scope — i.e. `PaneBrowsePath.depth`. `0` means the whole path is scope, which is
        /// both the pre-`stackDepth` behaviour and the honest reading of a tab that was opened at a
        /// folder rather than drilled into it.
        ///
        /// A count rather than a second path string because the two halves are a *cut* of one
        /// location: storing them separately lets a hand-edited plist disagree with itself about
        /// where the tab was, while a count out of range is clamped on the way back in and cannot.
        public var stackDepth: Int
        /// Whether this tab was pinned. **Optional on the way in**, so a strip written before
        /// pinning existed still decodes — the whole file is rejected on a missing key otherwise,
        /// and a user's tabs would silently vanish on the first launch after an upgrade.
        public var pinned: Bool

        public init(providerId: String, relativePath: String, stackDepth: Int = 0,
                    pinned: Bool = false) {
            self.providerId = providerId
            self.relativePath = relativePath
            self.stackDepth = stackDepth
            self.pinned = pinned
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            providerId = try c.decode(String.self, forKey: .providerId)
            relativePath = try c.decode(String.self, forKey: .relativePath)
            // Same optionality, and the same reason, as `pinned` directly below: a strip written
            // before the column stack was persisted must still decode rather than take the user's
            // whole set of tabs with it.
            stackDepth = try c.decodeIfPresent(Int.self, forKey: .stackDepth) ?? 0
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }
    }

    /// Cuts a stored combined path back into the pane's two halves.
    ///
    /// Clamped, because `stackDepth` arrives from a file and a hand-edited plist can say anything.
    ///
    /// **The two halves of the clamp are not equally load-bearing**, measured by removing each:
    /// `max(0,` is the one that matters — `dropLast` traps outright on a negative count ("Can't drop
    /// a negative number of elements"), so a `-1` in the stored strip would crash the app during
    /// launch's restore, before a window. The upper `min(…, count)` is belt-and-braces: `dropLast`
    /// and `suffix` both saturate at the collection's length, so a depth past the end already lands
    /// on everything-is-stack without it. Kept anyway, so `depth` is a valid count by construction
    /// rather than by two standard-library behaviours a reader has to know.
    static func split(relativePath: String, stackDepth: Int) -> (scope: String, stack: PaneBrowsePath) {
        let components = relativePath.split(separator: "/").map(String.init)
        let depth = min(max(0, stackDepth), components.count)
        return (components.dropLast(depth).joined(separator: "/"),
                PaneBrowsePath(components: Array(components.suffix(depth))))
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
            Entry(providerId: $0.providerId, relativePath: $0.combinedRelativePath,
                  stackDepth: $0.browsePath.depth, pinned: $0.isPinned)
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
            // Checked as the COMBINED path, which is the folder the tab was actually showing.
            // Testing the scope alone would restore a stack into a folder that is gone; the scope
            // is a prefix of what is checked here, so a combined path that exists proves both.
            let exists = folderExists(entry.providerId, entry.relativePath)
            // The fallback drops the stack with the scope, deliberately: the components name
            // folders *under* a path that no longer resolves, so there is nothing left for them to
            // be relative to. That is the same "show the root and say so" answer the doc above
            // gives for the scope.
            let (scope, stack) = exists
                ? split(relativePath: entry.relativePath, stackDepth: entry.stackDepth)
                : ("", PaneBrowsePath())
            if index == selected { selectedAfterDrops = restored.count }
            restored.append(PaneTab(providerId: entry.providerId, relativePath: scope,
                                    browsePath: stack, isPinned: entry.pinned))
        }
        guard !restored.isEmpty else { return nil }
        // **The pinned run is a prefix, and a file is not a promise.** Every rule in `PaneTabList`
        // is stated in terms of that prefix; a strip whose stored order interleaves them — a
        // hand-edited plist, or a format that grows a reorder we did not think about — would leave
        // `pinnedCount` and `pinned` disagreeing about the same list. Sorted here, once, where the
        // untrusted data comes in. `sorted(by:)` is stable in the only sense that matters: equal
        // elements keep their relative order, so pins stay in pin order and the rest in theirs.
        let live = restored[min(selectedAfterDrops ?? 0, restored.count - 1)].id
        restored = restored.enumerated()
            .sorted { ($0.element.isPinned ? 0 : 1, $0.offset) < ($1.element.isPinned ? 0 : 1, $1.offset) }
            .map(\.element)
        let index = restored.firstIndex { $0.id == live } ?? 0
        return PaneTabList(tabs: restored, selectedIndex: index)
    }
}
