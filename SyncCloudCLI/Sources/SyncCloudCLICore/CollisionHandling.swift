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

/// Accumulates the per-file outcomes of a sync run for the final
/// "Copied: X, Skipped: Y, Failed: Z" report.
public struct SyncTally: Equatable, Sendable {
    public private(set) var copied = 0
    /// Subset of `copied` that overwrote an existing destination (safeCopy moved the
    /// previous version to the Trash, so the summary can say replacements are recoverable).
    public private(set) var replaced = 0
    public private(set) var failed = 0
    public private(set) var skippedPaths: [String] = []

    public var skipped: Int { skippedPaths.count }

    public init() {}

    public mutating func recordCopied(replacedExisting: Bool = false) {
        copied += 1
        if replacedExisting { replaced += 1 }
    }
    public mutating func recordFailed() { failed += 1 }
    public mutating func recordSkipped(relativePath: String) { skippedPaths.append(relativePath) }
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
    if tally.skipped > 0 {
        // Skips only arise under `.skip` (see resolveCollision), but keep the wording
        // strategy-driven so a future skipping path can't print a misleading reason.
        let reason = strategy == .skip
            ? "existing files left untouched; use --strategy replace to update them"
            : "destination already existed"
        out.append("Skipped \(tally.skipped) file(s) (\(reason)):")
        out.append(contentsOf: tally.skippedPaths.map { "  \($0)" })
    }
    var err: [String] = []
    if tally.failed > 0 {
        err.append("\(tally.failed) file(s) failed to sync (errors above); exiting with a non-zero status.")
    }
    return (out, err, tally.failed > 0)
}
