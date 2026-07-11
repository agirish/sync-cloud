import Foundation

/// A structured, presentation-agnostic description of a failed sync / file operation.
///
/// Pure data — how it is rendered (alert title, body, buttons) is the UI layer's job,
/// mirroring `OperationBanner`. The Sync module stays free of SwiftUI/AppKit; the app target
/// turns a `SyncError` into an alert.
public struct SyncError: Error, Equatable, Sendable {
    /// Short headline suitable for an alert title (e.g. "Copy Failed").
    public let title: String
    /// Human-readable explanation of what went wrong, without system jargon.
    public let message: String
    /// Absolute filesystem path of the item involved, when known. Drives "Reveal in Finder".
    public let path: String?
    /// The underlying system reason (typically `error.localizedDescription`), when known.
    public let reason: String?
    /// Whether re-attempting the same operation could plausibly succeed (a transient I/O
    /// failure), as opposed to a deterministic one (a name collision, a content mismatch).
    public let isRetryable: Bool

    public init(
        title: String,
        message: String,
        path: String? = nil,
        reason: String? = nil,
        isRetryable: Bool = false
    ) {
        self.title = title
        self.message = message
        self.path = path
        self.reason = reason
        self.isRetryable = isRetryable
    }

    /// One-line rendering for the Activity Log, folding every known field into a single string
    /// so nothing that used to be logged is lost when the error is structured.
    public var logDescription: String {
        var parts = ["\(title): \(message)"]
        if let reason, !reason.isEmpty { parts.append("(\(reason))") }
        if let path { parts.append("[\(path)]") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Ergonomic constructors

extension SyncError {
    /// A single file could not be copied or moved between the two panes.
    public static func syncFailed(
        item: String,
        path: String?,
        reason: String,
        isRetryable: Bool = true
    ) -> SyncError {
        SyncError(
            title: "Sync Failed",
            message: "Couldn't sync \"\(item)\".",
            path: path,
            reason: reason,
            isRetryable: isRetryable
        )
    }

    /// A bulk run finished with several failures. Presenting one `SyncError` per failure would
    /// overwrite `currentError` each time (last one wins, the rest become log-only), so callers
    /// log every failure individually and present this single summary built from the first one.
    /// `verb` is the lowercase operation name ("sync", "copy", "move") and drives both the title
    /// and the message.
    public static func bulkFailed(
        verb: String,
        failureCount: Int,
        firstItem: String,
        firstPath: String?,
        firstReason: String
    ) -> SyncError {
        SyncError(
            title: "\(verb.capitalized) Failed",
            message: "Couldn't \(verb) \(failureCount) items. The first failure was \"\(firstItem)\"; the rest are in the Activity Log.",
            path: firstPath,
            reason: firstReason,
            isRetryable: false
        )
    }

    /// One or more items could not be copied to a destination folder.
    public static func copyFailed(
        items: String,
        path: String? = nil,
        reason: String,
        isRetryable: Bool = false
    ) -> SyncError {
        SyncError(
            title: "Copy Failed",
            message: "Couldn't copy \(items).",
            path: path,
            reason: reason,
            isRetryable: isRetryable
        )
    }

    /// One or more items could not be moved to a destination folder.
    public static func moveFailed(
        items: String,
        path: String? = nil,
        reason: String,
        isRetryable: Bool = false
    ) -> SyncError {
        SyncError(
            title: "Move Failed",
            message: "Couldn't move \(items).",
            path: path,
            reason: reason,
            isRetryable: isRetryable
        )
    }

    /// An item could not be renamed (disk error). Name collisions build a `SyncError` directly
    /// with a specific message, since they are deterministic rather than a system failure.
    public static func renameFailed(reason: String, path: String? = nil) -> SyncError {
        SyncError(
            title: "Rename Failed",
            message: "Couldn't rename the item.",
            path: path,
            reason: reason
        )
    }

    /// A new folder could not be created.
    public static func createFolderFailed(reason: String, path: String? = nil) -> SyncError {
        SyncError(
            title: "Couldn't Create Folder",
            message: "The folder couldn't be created.",
            path: path,
            reason: reason
        )
    }

    /// One or more items could not be deleted.
    public static func deleteFailed(reason: String, path: String? = nil) -> SyncError {
        SyncError(
            title: "Delete Failed",
            message: "Some items couldn't be deleted.",
            path: path,
            reason: reason
        )
    }
}

// MARK: - Which alert actions apply (pure decision, UI renders it)

/// An abstract action an error alert can offer. Presentation (button label, role, side effect)
/// is the UI layer's job; this only names *which* actions apply to a given error.
public enum SyncErrorAction: String, CaseIterable, Hashable, Sendable {
    case revealInFinder
    case retry
    case dismiss
}

extension SyncError {
    /// The actions an alert for this error should offer, in display order.
    ///
    /// - Reveal in Finder whenever a `path` is known.
    /// - Retry only when the error is retryable *and* the caller actually wired a re-invocation
    ///   (`hasRetryHandler`) — a retryable error with nothing to perform the retry offers none.
    /// - Dismiss always.
    public func alertActions(hasRetryHandler: Bool) -> [SyncErrorAction] {
        var actions: [SyncErrorAction] = []
        if path != nil { actions.append(.revealInFinder) }
        if isRetryable && hasRetryHandler { actions.append(.retry) }
        actions.append(.dismiss)
        return actions
    }
}
