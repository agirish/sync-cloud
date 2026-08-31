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
    /// log every failure individually and present this single summary. `verb` is the lowercase
    /// operation name ("sync", "copy", "move") and drives both the title and the message.
    ///
    /// The first failure supplies the alert's `path` and `reason` — the detail rows — but no longer
    /// its NAME: naming one item out of N was the old message's way of gesturing at a list it
    /// could not show, and the Failed filter shows the list. The path row still identifies it.
    public static func bulkFailed(
        verb: String,
        failureCount: Int,
        firstPath: String?,
        firstReason: String
    ) -> SyncError {
        SyncError(
            title: "\(verb.capitalized) Failed",
            // Names where the failed ROWS are, not just where the error text is. The Activity Log
            // has every reason and is still worth naming, but it is a separate window holding a
            // text log — sending someone there to work out which 12 of 400 files to retry was the
            // only answer this alert had, and the rows themselves were sitting in the table the
            // whole time.
            message: "Couldn't \(verb) \(failureCount) items. They are listed under the “Failed to transfer” filter; the reason for each is in the Activity Log.",
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

    /// macOS refused to move an item to the Trash because this app is not permitted to.
    ///
    /// **Its own case, because "couldn't be moved to the trash because you don't have permission"
    /// is not a fault in the file and not something a retry fixes.** Foundation's string names the
    /// symptom and stops; a reader is left with a file they own, in a folder they own, that the app
    /// says it may not touch. What is actually missing is a macOS privacy grant — and for a file
    /// inside iCloud Drive the Trash is `~/Library/Mobile Documents/.Trash`, which sits OUTSIDE the
    /// folder grants (Documents, Desktop, Downloads) an app is usually given, so an app that can
    /// read every one of those files can still be refused the move.
    ///
    /// Not retryable: pressing the same button again cannot change a permission.
    ///
    /// **What this message may NOT say.** An earlier version told the reader to grant Full Disk
    /// Access, as though that were the fix. It was measured and it is not: the grant was made and
    /// the refusal stood. So the message names what is known — the system refused, both ways, and
    /// nothing was removed — offers the one check that costs nothing, and points at the log rather
    /// than promising a remedy nobody has confirmed. A dialog that sends someone to change a
    /// setting that will not help is worse than one that admits the limit.
    public static func trashNotPermitted(path: String, reason: String) -> SyncError {
        SyncError(
            title: "Not Allowed to Move to the Trash",
            message: "macOS refused to move this item to the Trash, both directly and through the "
                + "system's own Trash service. Nothing was removed and the file is untouched.\n\n"
                + "Worth checking that SyncCloud has Full Disk Access in System Settings ▸ Privacy "
                + "& Security — though that has not been enough on its own. Moving the file in "
                + "Finder still works. The exact refusal, with its error codes, is in "
                + "~/sync-cloud.log.",
            path: path,
            reason: reason,
            isRetryable: false
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
    /// ORDERING CONTRACT: when `.retry` is present it must stay FIRST. The app pins
    /// `.keyboardShortcut(.defaultAction)` on the Retry button, and SwiftUI auto-promotes the
    /// first non-cancel button when nothing is pinned — keeping Retry first makes the explicit
    /// default and the auto-default coincide. Reordering would render two default-looking
    /// buttons (or split the highlight from the Return key).
    ///
    /// - Retry first (the primary recovery), only when the error is retryable *and* the caller
    ///   actually wired a re-invocation (`hasRetryHandler`) — a retryable error with nothing to
    ///   perform the retry offers none.
    /// - Reveal in Finder whenever a `path` is known.
    /// - Dismiss always.
    public func alertActions(hasRetryHandler: Bool) -> [SyncErrorAction] {
        var actions: [SyncErrorAction] = []
        if isRetryable && hasRetryHandler { actions.append(.retry) }
        if path != nil { actions.append(.revealInFinder) }
        actions.append(.dismiss)
        return actions
    }
}
