import Foundation

/// One provider-risky name found by a Name Normalizer scan: what it is, why a cloud provider would
/// choke on it, and a safe replacement to offer. Pure value type — carries no live disk handle, so
/// it can be listed, filtered, and unit-tested without touching the filesystem.
public struct RiskyName: Sendable, Identifiable, Equatable {
    /// The absolute path of the offending file or folder — stable and unique per node, so it
    /// doubles as the `Identifiable` id and the target the engine renames.
    public let id: String
    /// The path relative to the scan root, for a readable "where is it" label in the list.
    public let relativePath: String
    /// The leaf name exactly as it is on disk (the risky one).
    public let currentName: String
    /// A name every cloud provider (and the local FS) can store — what the fix renames it to.
    public let sanitizedName: String
    /// Human-readable reason the current name is risky, suitable for a row subtitle.
    public let reason: String
    /// True when the node is a directory — X8 flags risky FOLDER names too, not just files.
    public let isDirectory: Bool

    public init(
        id: String,
        relativePath: String,
        currentName: String,
        sanitizedName: String,
        reason: String,
        isDirectory: Bool
    ) {
        self.id = id
        self.relativePath = relativePath
        self.currentName = currentName
        self.sanitizedName = sanitizedName
        self.reason = reason
        self.isDirectory = isDirectory
    }
}

/// Pure, deterministic detector for cloud-hostile file & folder names, combining the shared
/// ``ProviderNameRules`` (per-provider forbidden characters, affix whitespace, trailing dots,
/// reserved device names) with a light *invisible-Unicode* check that catches hazards no provider
/// rule spells out but every cloud handles inconsistently: zero-width / BOM characters, non-standard
/// whitespace (no-break space, tab, other Unicode spaces), and names not in canonical (NFC) form —
/// the same class of name that mints phantom "missing" rows in the diff engine.
///
/// The invisible check lives here, not in ``ProviderNameRules``, so that heavily-tested shared file
/// stays untouched. Everything is a pure function of its inputs — no disk, no clock — so the whole
/// detector is exercised against in-memory ``FileNode`` trees in the unit tests.
public enum NameNormalizer {

    /// Zero-width / byte-order-mark scalars: genuinely invisible, and NOT classified as whitespace by
    /// Unicode (they're format characters), so they need an explicit strip rather than a whitespace
    /// pass. U+200B ZERO WIDTH SPACE, U+200C ZWNJ, U+200D ZWJ, U+FEFF ZERO WIDTH NO-BREAK SPACE/BOM.
    static let zeroWidthScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    // MARK: Scan

    /// Every provider-risky name in a walked tree (files AND directories), for `provider`. Walks the
    /// tree dir-inclusively (see ``FileSyncManager/flattenNodesWithRelativePaths(_:prefix:)``) so a
    /// risky folder name is reported alongside the risky files inside it. Already-clean names — and
    /// any name whose only "fix" would be a no-op — are skipped.
    public static func scan(nodes: [FileNode], provider: CloudProvider.ProviderType) -> [RiskyName] {
        var results: [RiskyName] = []
        for item in FileSyncManager.flattenNodesWithRelativePaths(nodes) {
            if let risky = evaluate(
                name: item.name,
                relativePath: item.rel,
                absolutePath: item.id,
                isDirectory: item.isDirectory,
                provider: provider
            ) {
                results.append(risky)
            }
        }
        return results
    }

    /// The ``RiskyName`` for one node, or nil when the name is already cloud-safe. Pure — takes the
    /// name and its coordinates rather than a live node, so it's trivially unit-testable.
    static func evaluate(
        name: String,
        relativePath: String,
        absolutePath: String,
        isDirectory: Bool,
        provider: CloudProvider.ProviderType
    ) -> RiskyName? {
        let sanitized = sanitize(name, for: provider)
        // The single gate, and deliberately Swift's canonical `!=` (NOT a scalar comparison): if the
        // safe name is *canonically equal* to the current name there is nothing worth fixing.
        //
        // This is exactly what makes the detector safe on macOS. Swift's `String` equality — and the
        // local filesystem — treat NFC and NFD as the same name. APFS goes further: it re-normalizes
        // every filename on write, so a purely-normalization "fix" (café decomposed → café composed)
        // both can't be stored AND would fire on virtually every accented filename on disk. Keying on
        // canonical equality means such names pass through untouched, while genuinely distinct
        // hazards — a zero-width joiner, a no-break space, a forbidden character, a trailing space —
        // are canonically DIFFERENT from their fix and so are still flagged.
        guard sanitized != name else { return nil }

        // Prefer the provider rule's specific phrasing ("… doesn't allow \":\" in names"); fall back
        // to the invisible-hazard phrasing when the only problem is hidden characters / Unicode form.
        let reason = ProviderNameRules.violation(name: name, provider: provider)?.reason
            ?? invisibleReason(name)

        return RiskyName(
            id: absolutePath,
            relativePath: relativePath,
            currentName: name,
            sanitizedName: sanitized,
            reason: reason,
            isDirectory: isDirectory
        )
    }

    // MARK: Sanitize

    /// A cloud-safe replacement for `name` under `provider`.
    ///
    /// Two layers, applied in the order that keeps them from fighting:
    /// 1. **Invisible cleanup** (always, for every provider): drop zero-width/BOM scalars, fold any
    ///    non-standard whitespace (no-break space, tab, Unicode spaces) to a plain ASCII space, then
    ///    precompose to NFC. This is a cross-cloud hazard, independent of the target provider.
    /// 2. **Provider cleanup** (only when the provider actually rejects the name): run
    ///    ``ProviderNameRules/sanitized(name:for:)`` to replace forbidden characters, strip affix
    ///    whitespace / trailing dots, and de-reserve device names. It's applied *conditionally*
    ///    because that helper trims trailing dots/spaces unconditionally — running it on an iCloud
    ///    or Google Drive name (which have no such rule) would "fix" names those providers happily
    ///    accept and flag them as risky when they aren't.
    static func sanitize(_ name: String, for provider: CloudProvider.ProviderType) -> String {
        var result = cleanInvisible(name)
        // Only let the provider ruleset rewrite the name when it (or its invisible-cleaned form)
        // genuinely violates that provider's rules — otherwise leave dots/spaces the provider allows.
        if ProviderNameRules.violation(name: name, provider: provider) != nil
            || ProviderNameRules.violation(name: result, provider: provider) != nil {
            result = ProviderNameRules.sanitized(name: result, for: provider)
        }
        return result.isEmpty ? "untitled" : result
    }

    /// `name` with invisible hazards removed: zero-width/BOM scalars dropped, non-standard whitespace
    /// folded to a plain ASCII space, and the whole thing precomposed to NFC. A name with no hazard
    /// comes back byte-identical (already NFC, no hidden characters), which is what lets the caller
    /// detect "was there anything invisible?" by comparing against the input.
    static func cleanInvisible(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if zeroWidthScalars.contains(scalar) {
                continue  // genuinely invisible — drop it
            }
            if scalar != " " && scalar.properties.isWhitespace {
                // No-break space, tab, or other Unicode space → one canonical ASCII space.
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// True when `name` carries a *fixable* invisible hazard the provider rules don't name — a hidden
    /// zero-width character or a non-standard space. Uses canonical `!=` for the same reason
    /// ``evaluate(name:relativePath:absolutePath:isDirectory:provider:)`` does: a pure NFC/NFD
    /// difference is not a fixable hazard on macOS (APFS re-normalizes on write), so it returns false
    /// for a merely-decomposed name — only genuinely distinct invisibles count.
    public static func hasInvisibleHazard(_ name: String) -> Bool {
        cleanInvisible(name) != name
    }

    /// The specific human phrase for an invisible hazard, most-actionable first.
    static func invisibleReason(_ name: String) -> String {
        if name.unicodeScalars.contains(where: { zeroWidthScalars.contains($0) }) {
            return "Has hidden zero-width characters that can create invisible duplicates in the cloud."
        }
        if name.unicodeScalars.contains(where: { $0 != " " && $0.properties.isWhitespace }) {
            return "Has a non-standard space (like a no-break space) some clouds store differently."
        }
        return "Uses an unusual character form some clouds store differently."
    }
}
