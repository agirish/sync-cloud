import Foundation
import Sync

/// Remembers why a name is cloud-hostile, so a row that scrolls back into view does not re-run the
/// rules.
///
/// The badge and the "Fix name" menu item are built eagerly on every visible row of every render
/// (SwiftUI builds a row's context menu with the row), so both ask this memo
/// (`PaneActionDelegate.riskyName(for:)`). `NameNormalizer.risky` rebuilds the name
/// scalar-by-scalar and canonicalises it before it can answer. On real trees, with names bridged
/// from `NSString` as `URL.lastPathComponent` returns them, a memo hit costs ~1.5 µs against
/// ~4–26 µs for the live check.
///
/// Lazy rather than an index built per publish, which would cost ~140 ms on the main actor for a
/// 40,000-node tree; the memo pays only for rows someone looks at, and names repeat heavily.
///
/// Keyed on provider and name, because the verdict depends on exactly those: `evaluate` carries
/// the paths into the result for labelling only. Without the provider, switching a pane's
/// provider would serve the previous ruleset's answers.
///
/// Nothing goes stale: unlike `CloudOnlyBadgeCache`'s disk facts, an entry is a fact about a
/// string and a ruleset, both in the key. So the table is bounded, never invalidated.
@MainActor
public enum RiskyNameBadgeCache {
    /// The verdict for one (provider, name): the reason for the tooltip, or nil when the name is
    /// fine. `String?`, not `Bool`, since `evaluate` has already computed the reason.
    private static var known: [Key: String?] = [:]

    struct Key: Hashable {
        let provider: CloudProvider.ProviderType
        let name: String
    }

    /// Bound on the memo, cleared wholesale at the cap like `CloudOnlyBadgeCache`: being wrong
    /// costs re-running the rules once for names on screen. Sized well above the distinct names a
    /// long session scrolls past (large provider roots hold ~20,000).
    private static let capacity = 16_384

    /// Reports the name on every memo miss. Nil in production; `RiskyNameBadgeMemoTests` installs
    /// one to hold the badge to its cost model.
    ///
    /// A name, not a counter: the memo is process-wide and other suites (`DifferencesView`) hit
    /// it concurrently, so a test counts only its own fixture's names.
    ///
    /// Compiled in, not `#if DEBUG`: one nil check on the miss path, and a `DEBUG`-only seam
    /// couldn't be checked under `swift test -c release`, where cost regressions show.
    static var onEvaluateForTesting: (@MainActor (String) -> Void)?

    /// Why `name` is cloud-hostile for `provider`, or nil when it is fine.
    ///
    /// `isDirectory` is passed through rather than assumed: the detector flags folder names
    /// too, and the flag travels on the `RiskyName` it builds.
    public static func reason(name: String, isDirectory: Bool, provider: CloudProvider.ProviderType) -> String? {
        let key = Key(provider: provider, name: name)
        if let hit = known[key] { return hit }
        onEvaluateForTesting?(name)
        // The paths only label the result (see above), so the name stands in for both; there
        // is no scan root to build a relative path from.
        let reason = NameNormalizer.risky(name: name, relativePath: name, absolutePath: name,
                                          isDirectory: isDirectory, provider: provider)?.reason
        if known.count >= capacity { known.removeAll(keepingCapacity: true) }
        known[key] = reason
        return reason
    }

    /// Drops every entry. Only tests need this, so one case's answers can't decide another's.
    /// Leaves `onEvaluateForTesting` alone: the case that installed an observer removes it, and
    /// clearing it here would unhook a measurement in progress.
    static func resetForTesting() {
        known.removeAll()
    }
}
