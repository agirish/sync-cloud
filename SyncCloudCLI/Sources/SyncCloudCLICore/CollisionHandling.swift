import Foundation

/// Non-interactive collision policy chosen with `--strategy` (the CLI equivalent of the
/// app's Replace / Skip / Keep Both dialog).
public enum CollisionStrategy: String, Sendable {
    case replace
    case skip
    case keepBoth = "keep-both"
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
    public private(set) var failed = 0
    public private(set) var skippedPaths: [String] = []

    public var skipped: Int { skippedPaths.count }

    public init() {}

    public mutating func recordCopied() { copied += 1 }
    public mutating func recordFailed() { failed += 1 }
    public mutating func recordSkipped(relativePath: String) { skippedPaths.append(relativePath) }
}
