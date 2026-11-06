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
    /// True when the node is a directory: risky folder names are flagged too, not just files.
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

/// Pure, deterministic detector for cloud-hostile file and folder names. Combines the shared
/// ``ProviderNameRules`` (forbidden characters, affix whitespace, trailing dots, reserved device
/// names) with an invisible-Unicode check for hazards every cloud handles inconsistently:
/// zero-width and BOM characters, non-standard whitespace, and names not in NFC, the kind that
/// mints phantom "missing" rows in the diff engine.
///
/// The invisible check lives here so ``ProviderNameRules`` stays as it is. No disk, no clock, so
/// tests run it on in-memory ``FileNode`` trees.
public enum NameNormalizer {

    /// Zero-width and byte-order-mark scalars (U+200B, U+200C, U+200D, U+FEFF). Unicode calls them
    /// format characters, not whitespace, so they need an explicit strip.
    static let zeroWidthScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    // MARK: Scan

    /// Every provider-risky name in a walked tree, files and folders, for `provider`
    /// (``FileSyncManager/flattenNodesWithRelativePaths(_:prefix:)`` includes directories). Clean
    /// names, and names whose only fix would be a no-op, are skipped.
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

    /// The ``RiskyName`` for a single already-walked node, or nil when its name is cloud-safe. The
    /// public one-node door: the pane row's menu offers "Fix name" only when this answers.
    public static func risky(
        name: String, relativePath: String, absolutePath: String,
        isDirectory: Bool, provider: CloudProvider.ProviderType
    ) -> RiskyName? {
        evaluate(name: name, relativePath: relativePath, absolutePath: absolutePath,
                 isDirectory: isDirectory, provider: provider)
    }

    /// The ``RiskyName`` for one node, or nil when the name is already cloud-safe. Takes the name
    /// and its coordinates rather than a live node.
    static func evaluate(
        name: String,
        relativePath: String,
        absolutePath: String,
        isDirectory: Bool,
        provider: CloudProvider.ProviderType
    ) -> RiskyName? {
        let sanitized = sanitize(name, for: provider)
        // The single gate, deliberately Swift's canonical `!=`, not a scalar compare. NFC and NFD
        // are the same name to Swift and to APFS, and a Foundation rename sends it decomposed, so a
        // normalization-only "fix" couldn't land as written and would flag nearly every accented
        // name. Real hazards (zero-width joiner, no-break space, forbidden character, trailing
        // space) differ canonically from their fix and are still flagged.
        guard sanitized != name else { return nil }

        // Prefer the provider rule's phrasing; fall back to the invisible-hazard one.
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

    /// A cloud-safe replacement for `name` under `provider`, in two layers:
    /// 1. Invisible cleanup, for every provider: drop zero-width and BOM scalars, fold non-standard
    ///    whitespace to an ASCII space, precompose to NFC.
    /// 2. Provider cleanup, only when the provider rejects the name:
    ///    ``ProviderNameRules/sanitized(name:for:)``. Conditional because that helper always trims
    ///    trailing dots and spaces, which would flag names iCloud and Google Drive accept.
    static func sanitize(_ name: String, for provider: CloudProvider.ProviderType) -> String {
        var result = cleanInvisible(name)
        // The fold makes exotic spaces at the ends plain ones, so "report\u{00A0}" would become
        // "report ", which Dropbox and OneDrive refuse, and an all-space name would dodge the
        // `untitled` fallback. Trimmed whenever `cleanInvisible` changed anything, so
        // "a\u{200B}b " becomes "ab": the promise is a name every provider can store. A name with
        // no invisible hazard is left as is, so a trailing space a provider permits isn't flagged.
        if result != name {
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Only let the provider rules rewrite a name (or its cleaned form) that violates them.
        if ProviderNameRules.violation(name: name, provider: provider) != nil
            || ProviderNameRules.violation(name: result, provider: provider) != nil {
            result = ProviderNameRules.sanitized(name: result, for: provider)
        }
        return result.isEmpty ? "untitled" : result
    }

    /// `name` with invisible hazards removed: zero-width and BOM scalars dropped, non-standard
    /// whitespace folded to an ASCII space, precomposed to NFC. A clean name comes back unchanged,
    /// so comparing with the input tells whether anything was invisible.
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

    /// True when `name` carries a fixable invisible hazard the provider rules don't name: a hidden
    /// zero-width character or a non-standard space. Canonical `!=`, as in
    /// ``evaluate(name:relativePath:absolutePath:isDirectory:provider:)``, so a merely decomposed
    /// name answers false.
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
