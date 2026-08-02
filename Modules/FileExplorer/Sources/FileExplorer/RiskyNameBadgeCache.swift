import Foundation
import Sync

/// Remembers why a name is cloud-hostile, so a row that scrolls back into view does not re-run the
/// rules.
///
/// **Why the badge needs a memo at all.** The row badge is rendered eagerly, on every visible row of
/// every render pass — unlike the "Fix name…" menu item, whose check runs once, on menu open, which
/// is what made *that* free. `NameNormalizer.risky` is pure string work, but it is not cheap string
/// work: it rebuilds the name scalar-by-scalar and runs `precomposedStringWithCanonicalMapping` over
/// the result, unconditionally, before it can say "nothing wrong here". Measured in Release against
/// this Mac's real provider trees (~40,000 names, `NameCheckBenchmark`):
///
/// | | live check | memo hit |
/// |---|---|---|
/// | native Swift strings | 2.5–7.4 µs | 77–135 ns |
/// | strings bridged from `NSString` | 4.4–26 µs | 1.2–2.1 µs |
///
/// **Production is the bottom row, not the top.** `FileNode.name` comes from
/// `URL.lastPathComponent`, which hands back a string lazily bridged from `NSString`, and every hash
/// of one of those takes the ObjC slow path. So a hit here costs ~1.5 µs, not ~100 ns — about 60
/// visible rows per pane, two panes, is ~0.2 ms a pass against ~0.5–3 ms for the live check. Worth
/// roughly 10x, and worth quoting honestly: the native column is what this code *would* cost if the
/// tree walk stopped handing out bridged names, and is not a number any pane pays today.
///
/// **Why not an index built up front instead.** It was the obvious alternative — walk the pane's
/// tree once per publish, keep a `Set` of risky paths, and let each row do a membership test. At the
/// cold-memo rate above that is ~140 ms per publish on a 40,000-node tree, on the main actor, on the
/// path that decides how long "show me this folder" takes; and it would have to be redone whenever
/// the provider changed. A lazy memo pays only for rows somebody actually looked at, and repeats —
/// which names are, heavily, across folders and across re-renders — cost one dictionary lookup.
///
/// **Keyed on the provider as well as the name.** The verdict is a pure function of exactly those
/// two: `NameNormalizer.evaluate` reads the name and the ruleset and nothing else — the relative and
/// absolute paths it also takes are carried into the resulting `RiskyName` for labelling, and never
/// consulted in deciding. That is what makes memoizing by name sound, and it is also why the
/// provider must be in the key: without it, switching a pane from iCloud to OneDrive would serve
/// every row the previous ruleset's answer, silently, until something else evicted it.
///
/// **Staleness.** There is none to manage. Unlike `CloudOnlyBadgeCache`, whose answers are facts
/// about the disk that a download can invalidate, an entry here is a fact about a string and a
/// ruleset — both of which are in the key. A name that changes is a different key. So the table is
/// only ever bounded, never invalidated.
@MainActor
public enum RiskyNameBadgeCache {
    /// The verdict for one (provider, name): the human reason to show in the tooltip, or nil when
    /// the name is fine. `String?` rather than `Bool` because the reason costs nothing extra to
    /// keep — `evaluate` has already computed it by the time it answers — and the badge needs it.
    private static var known: [Key: String?] = [:]

    struct Key: Hashable {
        let provider: CloudProvider.ProviderType
        let name: String
    }

    /// Bound on the memo. Cleared wholesale at the cap rather than evicted one entry at a time, the
    /// same O(1) trade `CloudOnlyBadgeCache` makes: the cost of being wrong is re-running the rules
    /// for names still on screen, once. Sized well above the number of distinct names a long
    /// session can scroll past — this Mac's two largest provider roots hold ~20,000 distinct names
    /// each, and a pane only ever realizes the rows it shows.
    private static let capacity = 16_384

    /// Reports the name every time the rules actually run — that is, on every memo MISS. Nil in
    /// production; `RiskyNameBadgeMemoTests` installs one to hold the badge to its cost model.
    ///
    /// **Why a name and not a counter.** A bare `evaluationCount` was tried first and is not
    /// sound in this target: the memo is one process-wide table, and `DifferencesView` asks it
    /// directly, so the four suites that mount a differences table raise the count from outside
    /// whatever is being measured. Observed — a mounted-pane case expecting 15 evaluations saw 19,
    /// intermittently, depending on which suite happened to be running alongside. Reporting the
    /// name lets a test count only its own fixture's names and be indifferent to everyone else's,
    /// which no amount of serializing suites achieves: the next suite to mount one of these would
    /// reintroduce it silently.
    ///
    /// Compiled in rather than `#if DEBUG`-gated: it is one nil check on the miss path — which is
    /// already about to rebuild a string scalar-by-scalar — and absent from the hit path
    /// altogether. A `DEBUG`-only seam could not be asserted against under `swift test -c release`,
    /// which is where cost regressions actually show.
    static var onEvaluateForTesting: (@MainActor (String) -> Void)?

    /// Why `name` is cloud-hostile for `provider`, or nil when it is fine.
    ///
    /// `isDirectory` is threaded through to `NameNormalizer` rather than assumed: the detector flags
    /// risky FOLDER names too, and the flag travels on the `RiskyName` it builds.
    public static func reason(name: String, isDirectory: Bool, provider: CloudProvider.ProviderType) -> String? {
        let key = Key(provider: provider, name: name)
        if let hit = known[key] { return hit }
        onEvaluateForTesting?(name)
        // The paths are labelling fields on the result, not inputs to the verdict (see the note
        // above), so the name stands in for both — this asks about a name, and has no scan root to
        // reconstruct a relative path against.
        let reason = NameNormalizer.risky(name: name, relativePath: name, absolutePath: name,
                                          isDirectory: isDirectory, provider: provider)?.reason
        if known.count >= capacity { known.removeAll(keepingCapacity: true) }
        known[key] = reason
        return reason
    }

    /// Drops every entry. Only the tests need this — production has nothing to invalidate (see the
    /// note on staleness) — but a memo that outlives a test case would let one case's answers
    /// decide another's.
    ///
    /// Deliberately leaves `onEvaluateForTesting` alone: the case that installed an observer is the
    /// one that removes it, and clearing it here would silently unhook a measurement in progress.
    static func resetForTesting() {
        known.removeAll()
    }
}
