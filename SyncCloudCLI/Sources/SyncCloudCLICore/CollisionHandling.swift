import Foundation

/// Non-interactive collision policy chosen with `--strategy` (the CLI equivalent of the
/// app's Replace / Skip / Keep Both dialog). Defaults to `.replace` — matching the app's
/// sync buttons — because a modified file always has an existing destination, so a skip
/// default would make `sync` never update anything.
public enum CollisionStrategy: String, Sendable {
    case replace
    case skip
    case keepBoth = "keep-both"

    /// The `--strategy` default. Lives here (not in the @Option declaration) so tests can pin it.
    public static let cliDefault: CollisionStrategy = .replace
}

/// What the sync loop should do with one planned copy.
public enum CollisionAction: Equatable, Sendable {
    /// Copy to the planned destination (free or to be safely replaced).
    case proceed
    /// Copy to a uniquified destination next to the existing one (keep-both).
    case copyToUnique
    /// Don't copy; count the item as skipped.
    case skip
}

/// Resolves what to do for one planned copy given the strategy and whether the
/// destination already exists.
public func resolveCollision(strategy: CollisionStrategy, targetExists: Bool) -> CollisionAction {
    guard targetExists else { return .proceed }
    switch strategy {
    case .skip: return .skip
    case .replace: return .proceed // performFileSyncIO handles safe replacement
    case .keepBoth: return .copyToUnique
    }
}

/// Why one planned copy was skipped. Threaded through the tally so the summary reports each
/// cause truthfully — the sync loop has TWO skipping paths (`--strategy skip` collisions and
/// the pre-write provider-name guard) and lumping them together mislabeled name-rule skips
/// as collision skips.
public enum SkipReason: Equatable, Sendable {
    /// The destination already existed and `--strategy skip` left it untouched.
    case collision
    /// The destination provider's name rules reject the path (pre-write guard;
    /// writing it would create a local-only file the provider never uploads).
    case nameViolation
}

/// One skipped item: the path plus why it was skipped.
public struct SkippedItem: Equatable, Sendable {
    public let relativePath: String
    public let reason: SkipReason

    public init(relativePath: String, reason: SkipReason) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

/// Accumulates the per-file outcomes of a sync run for the final
/// "Copied: X, Skipped: Y, Failed: Z" report.
public struct SyncTally: Equatable, Sendable {
    public private(set) var copied = 0
    /// Subset of `copied` that overwrote an existing destination (safeCopy moved the
    /// previous version to the Trash, so the summary can say replacements are recoverable).
    public private(set) var replaced = 0
    public private(set) var failed = 0
    public private(set) var skippedItems: [SkippedItem] = []

    public var skipped: Int { skippedItems.count }
    public var skippedPaths: [String] { skippedItems.map(\.relativePath) }

    public init() {}

    public mutating func recordCopied(replacedExisting: Bool = false) {
        copied += 1
        if replacedExisting { replaced += 1 }
    }
    public mutating func recordFailed() { failed += 1 }
    public mutating func recordSkipped(relativePath: String, reason: SkipReason) {
        skippedItems.append(SkippedItem(relativePath: relativePath, reason: reason))
    }
}

/// The end-of-run report for `sync`, split by stream so failures land on stderr. Pure so the
/// summary/exit-code story is testable: `exitNonzero` must match `stderrLines` mentioning
/// failures, and any skipped count must come with the reason and the flag that changes it.
public func syncSummary(tally: SyncTally, strategy: CollisionStrategy) -> (
    stdoutLines: [String], stderrLines: [String], exitNonzero: Bool
) {
    var out = ["Sync complete. Copied: \(tally.copied), Skipped: \(tally.skipped), Failed: \(tally.failed)."]
    if tally.replaced > 0 {
        // The Trash backups carry hidden ".rollback_<UUID>" names (Finder won't show them),
        // so the per-file recovery paths logged by the replace primitive are the real pointer.
        out.append("Replaced \(tally.replaced) existing file(s); previous versions are recoverable from the Trash (exact paths in ~/sync-cloud.log).")
    }
    // Report each skip cause separately: collision skips (from `--strategy skip`) and
    // provider-name skips (the pre-write guard) are different problems with different fixes,
    // and lumping them under the collision wording mislabeled the name-rule ones.
    let collisionSkips = tally.skippedItems.filter { $0.reason == .collision }
    if !collisionSkips.isEmpty {
        let reason = strategy == .skip
            ? "existing files left untouched; use --strategy replace to update them"
            : "destination already existed"
        out.append("Skipped \(collisionSkips.count) file(s) (\(reason)):")
        out.append(contentsOf: collisionSkips.map { "  \($0.relativePath)" })
    }
    let nameSkips = tally.skippedItems.filter { $0.reason == .nameViolation }
    if !nameSkips.isEmpty {
        // The per-file "Skipping <path>: <rule> …" lines are printed by the sync loop as it
        // goes — on STDERR. This summary lands on stdout, so "reasons above" was wrong for
        // anyone piping or redirecting one of the streams; point at stderr explicitly.
        out.append("Skipped \(nameSkips.count) file(s) (name not allowed by the destination provider; per-file reasons on stderr):")
        out.append(contentsOf: nameSkips.map { "  \($0.relativePath)" })
    }
    var err: [String] = []
    if tally.failed > 0 {
        err.append("\(tally.failed) file(s) failed to sync (errors above); exiting with a non-zero status.")
    }
    return (out, err, tally.failed > 0)
}
