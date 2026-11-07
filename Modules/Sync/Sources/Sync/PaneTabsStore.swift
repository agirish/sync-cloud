import Foundation
import Events

/// What survives a quit, for a pane's tab strip.
///
/// Both panes' strips are persisted, under separate keys. The left keeps the original
/// `browseTabs` / `browseSelectedTab` names so no existing strip is orphaned; the right has its
/// own. A right strip never written reads as nothing stored, so the pane falls back on the older
/// `lastRightFocusPath` restore until it has a strip worth remembering.
///
/// The stored shape is `[{providerId, relativePath, stackDepth, pinned}]` and nothing else: where a
/// tab is and how the strip is arranged. Selection, history and the search query are session
/// state: a restored selection may point at files gone since, and a query restored into a field
/// the user can't see reads as the pane filtering itself.
///
/// `relativePath` is the tab's combined location (scope + column stack), and `stackDepth` says
/// where to cut it back into the pane's two halves. The cut must be stored: scope draws one column
/// and the stack the rest (`columnDirectories`), so a tab restored as all scope shows one
/// full-width column however many the user had, and the combined string can't say where the cut
/// was.
///
/// The format is additive and safe both ways: a strip without `stackDepth` restores as depth 0
/// (all scope), and an older build still reads one with it the old way. Redefining `relativePath`
/// as the scope alone would make an older build reopen the tab at an ancestor of where it was.
public enum PaneTabsStore {
    /// Why a stored strip didn't decode, in a few words: which key or value, not the whole error,
    /// whose description repeats the raw value the line already shows.
    static func decodeReason(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): return "missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context): return "not readable as tabs: \(context.debugDescription)"
        default: return LogError.describe(error)
        }
    }


    /// The left pane's keys, named without a side because they predate the right pane's: renaming
    /// them would orphan every strip already on disk.
    ///
    /// `[{"providerId": …, "relativePath": …, "stackDepth": …, "pinned": …}]` as JSON in a string,
    /// matching how the rest of the app parks small structured values in defaults. Both trailing
    /// keys are optional on the way in; see `Entry`.
    public static let tabsKey = "browseTabs"
    public static let selectedKey = "browseSelectedTab"

    /// The right pane's. Separate keys rather than one two-element value: the strips are written at
    /// different moments by different panes, and one blob would make every left-pane save a
    /// read-modify-write of the right pane's state.
    public static let rightTabsKey = "browseTabsRight"
    public static let rightSelectedKey = "browseSelectedTabRight"

    /// The one place a side becomes a key: `load` and `save` both resolve through it, so a strip
    /// can never be written under one pane's key and read back under the other's.
    static func keys(isLeft: Bool) -> (tabs: String, selected: String) {
        isLeft ? (tabsKey, selectedKey) : (rightTabsKey, rightSelectedKey)
    }

    /// One persisted tab. A named type rather than the live `PaneTab` because this is a format:
    /// `PaneTab` gains fields, and none should silently start being written to disk.
    public struct Entry: Codable, Equatable, Sendable {
        public var providerId: String
        public var relativePath: String
        /// How many of `relativePath`'s trailing components were the column stack rather than the
        /// scope (`PaneBrowsePath.depth`). `0` means all scope: a strip written before
        /// `stackDepth`, or a tab opened at a folder rather than drilled into it.
        ///
        /// A count rather than a second path, because the halves are a cut of one location: two
        /// paths in a hand-edited plist could disagree, while an out-of-range count is clamped.
        public var stackDepth: Int
        /// Whether this tab was pinned. Optional on the way in, so a strip written before pinning
        /// still decodes: a missing key would otherwise reject the whole strip and lose the tabs.
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
            // Optional like `pinned` below, for the same reason: a strip written before the column
            // stack was persisted must still decode.
            stackDepth = try c.decodeIfPresent(Int.self, forKey: .stackDepth) ?? 0
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }
    }

    /// Cuts a stored combined path back into the pane's two halves.
    ///
    /// Clamped, because `stackDepth` comes from a file and a hand-edited plist can say anything.
    /// **Keep `max(0,`**: `dropLast` traps on a negative count, so a `-1` would crash the launch
    /// restore before a window opens. The `min(…, count)` half keeps `depth` a valid count by
    /// construction, though `dropLast` and `suffix` already saturate.
    static func split(relativePath: String, stackDepth: Int) -> (scope: String, stack: PaneBrowsePath) {
        let components = relativePath.split(separator: "/").map(String.init)
        let depth = min(max(0, stackDepth), components.count)
        return (components.dropLast(depth).joined(separator: "/"),
                PaneBrowsePath(components: Array(components.suffix(depth))))
    }

    /// Reads the stored strip. `nil`, not an empty array, when the key has never been written,
    /// which tells the caller to seed from the pane's own stored provider instead.
    public static func load(isLeft: Bool,
                            from defaults: UserDefaults = .standard) -> (entries: [Entry], selected: Int)? {
        let key = keys(isLeft: isLeft)
        guard let raw = defaults.string(forKey: key.tabs), let data = raw.data(using: .utf8) else {
            // No key: the ordinary case, and the one this `nil` is for. Silent on purpose: every
            // fresh install and every never-used right pane comes through here.
            return nil
        }
        let decoded: [Entry]
        do {
            decoded = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            // A key that is there but unreadable is worth a line: the caller can't tell it from
            // "never written", seeds a fresh strip, and the next save overwrites it for good. Right,
            // since there is nothing to restore, but not in silence. Reachable by a hand-edited
            // plist or a newer format. Deliberately no more: no backup key and no refusal to
            // overwrite, or the pane could never save its tabs.
            Logger.shared.warning(
                "The stored \(isLeft ? "left" : "right") browse tab strip could not be read and will "
                + "be replaced by the next save (\(Self.decodeReason(error))): \(raw.prefix(200))")
            return nil
        }
        // A key that decodes to nothing is, for the caller, no key at all: seeding is right for
        // both.
        guard !decoded.isEmpty else { return nil }
        let selected = min(max(0, defaults.integer(forKey: key.selected)), decoded.count - 1)
        return (decoded, selected)
    }

    /// Writes the strip. Called on every tab mutation, which is cheap: this is at most a handful of
    /// short strings, and `UserDefaults` coalesces its own writes to disk.
    public static func save(tabs: [PaneTab], selected: Int, isLeft: Bool,
                            to defaults: UserDefaults = .standard) {
        let entries = tabs.map {
            Entry(providerId: $0.providerId, relativePath: $0.combinedRelativePath,
                  stackDepth: $0.browsePath.depth, pinned: $0.isPinned)
        }
        guard let data = try? JSONEncoder().encode(entries),
              let raw = String(data: data, encoding: .utf8) else {
            // A silent return here would quietly stop the strip persisting while the UI looks
            // fine. Unreachable for these plain string fields, so it must announce itself if it
            // ever fires.
            Logger.shared.error("The \(isLeft ? "left" : "right") pane's tab strip could not be encoded for saving — tab changes from this session will not survive a relaunch")
            return
        }
        let key = keys(isLeft: isLeft)
        defaults.set(raw, forKey: key.tabs)
        defaults.set(min(max(0, selected), max(0, entries.count - 1)), forKey: key.selected)
    }

    /// What a restore produced: the strip, and what it had to give up to produce it.
    ///
    /// A tab whose folder is gone comes back at its source root, which the list alone can't tell
    /// from a tab left at the root, and the next save writes the root over the stored path for
    /// good. Only the caller can say where that folder was, and only if told.
    ///
    /// A report, not a value to hold: only `restore` builds one and the host reads and drops it, so
    /// both halves are `let` and the memberwise initializer stays internal. Not `Equatable`: every
    /// `PaneTab` gets a fresh `UUID`, so two reports of one restore could never compare equal.
    public struct Restored: Sendable {
        /// The strip, ready to install.
        public let list: PaneTabList
        /// The stored combined path of every entry that came back at its source root because its
        /// folder no longer exists, in stored order: the file's, not the strip's, which floats the
        /// pinned run to the front. Empty is the ordinary case.
        public let lostFolders: [String]
    }

    /// Turns stored entries back into tabs, dropping any whose provider is gone and re-rooting any
    /// whose folder no longer exists.
    ///
    /// A stored path is a claim about a disk the app hasn't seen since the last quit. A folder
    /// deleted, renamed or moved meanwhile would restore a tab onto nothing: an empty pane, with no
    /// way to tell missing from empty. Falling back to the provider root loses the location but
    /// shows it; keeping the tab says nothing.
    ///
    /// `folderExists` is injected: the roots come from the host's settings and the check hits the
    /// disk, neither of which belongs in a decoder.
    public static func restore(entries: [Entry],
                               selected: Int,
                               isKnownProvider: (String) -> Bool,
                               folderExists: (_ providerId: String, _ relativePath: String) -> Bool) -> Restored? {
        var restored: [PaneTab] = []
        // Reported, not just counted: the stored path is the only record of which folder was
        // lost, and the first save rewrites the entry at the root.
        var lostFolders: [String] = []
        // Where the stored selection lands after entries are dropped: clamping the stored index
        // into the shorter list can pick the wrong tab (drop entry 0 of four with entry 2
        // selected), so count the survivors ahead of it.
        var selectedAfterDrops: Int?
        for (index, entry) in entries.enumerated() {
            guard isKnownProvider(entry.providerId) else { continue }
            // Checked as the combined path, the folder the tab was showing: the scope is a prefix
            // of it, so one check proves both, while the scope alone could restore a stack into a
            // folder that is gone.
            let exists = folderExists(entry.providerId, entry.relativePath)
            // The fallback drops the stack with the scope: its components name folders under a
            // path that no longer resolves.
            let (scope, stack) = exists
                ? split(relativePath: entry.relativePath, stackDepth: entry.stackDepth)
                : ("", PaneBrowsePath())
            // An entry already at the root can't have fallen back to it; reporting one would warn on
            // every ordinary launch about a folder never lost.
            if !exists, !entry.relativePath.isEmpty { lostFolders.append(entry.relativePath) }
            if index == selected { selectedAfterDrops = restored.count }
            restored.append(PaneTab(providerId: entry.providerId, relativePath: scope,
                                    browsePath: stack, isPinned: entry.pinned))
        }
        guard !restored.isEmpty else { return nil }
        // The pinned run must be a prefix, and a file is no promise: a stored order that
        // interleaves pins (a hand-edited plist, a future format) would leave `pinnedCount` and
        // `pinned` disagreeing. Sorted once, where the untrusted data comes in; sorting on
        // (pin, offset) keeps pins in pin order and the rest in theirs.
        let live = restored[min(selectedAfterDrops ?? 0, restored.count - 1)].id
        restored = restored.enumerated()
            .sorted { ($0.element.isPinned ? 0 : 1, $0.offset) < ($1.element.isPinned ? 0 : 1, $1.offset) }
            .map(\.element)
        let index = restored.firstIndex { $0.id == live } ?? 0
        return Restored(list: PaneTabList(tabs: restored, selectedIndex: index),
                        lostFolders: lostFolders)
    }
}
