import Foundation

/// A transient in-app notification describing the outcome of a file operation.
/// Pure data — how each severity is rendered (icon, tint, dismissal rules) is the UI layer's job.
public struct OperationBanner: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        /// The operation completed fully.
        case success
        /// The operation was cancelled or completed only partially (e.g. some items failed or were skipped).
        case warning
        /// The operation failed outright.
        case error
    }

    /// Per-publish identity, deliberately part of equality: two back-to-back banners with the
    /// same message must still register as a change, or UI observers (`onChange`, the dismiss
    /// timer) never see the second one and it inherits the first's nearly-elapsed timer.
    public let id: UUID
    public var message: String
    public var severity: Severity
    /// Whether one `UndoManager.undo()` reverses the operation: it registered exactly one
    /// (possibly grouped) undo step. Then the banner offers an Undo button, the same as ⌘Z. False
    /// for outcomes that aren't a single undo (a guided-review session, a partial batch).
    public var isUndoable: Bool
    /// A second, quieter line under the sentence — a batch naming each file it skipped, and why.
    public var detail: String?
    /// What the result leaves behind that the reader may want next, each drawn as a button beside
    /// Undo. Pure data like the rest: the UI names the buttons and performs them.
    public var followUps: [FollowUp]

    /// The level the banner's copy in the log is written at (`FileSyncManager.banner`'s mirror).
    /// Separate from `severity`, which sets the banner's icon, tint and how long it stays: a busy
    /// guard looks like a warning on screen and is no fault in the log. Required on every warning
    /// and error, so each site says what its banner is to someone reading the log later.
    public enum LogLevel: Equatable, Sendable {
        case info, warn, error

        /// The level the mirror wrote before banners carried their own: the severity's. For a
        /// site whose severity is decided at run time.
        public init(mirroring severity: Severity) {
            switch severity {
            case .success: self = .info
            case .warning: self = .warn
            case .error: self = .error
            }
        }
    }

    /// See ``LogLevel``.
    public var log: LogLevel

    /// A door out of a finished result.
    public enum FollowUp: Equatable, Sendable {
        /// "Open in Edit" — the file just written.
        case openInEdit(String)
        /// "Reveal in Browse" — the file or files just written, selected.
        case revealInBrowse([String])
        /// "Download" — a file only in the cloud now, which the request could not read.
        case download(String)
    }

    public init(message: String, severity: Severity, log: LogLevel, isUndoable: Bool = false,
                detail: String? = nil, followUps: [FollowUp] = [], id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.severity = severity
        self.log = log
        self.isUndoable = isUndoable
        self.detail = detail
        self.followUps = followUps
    }

    /// A finished operation: logged at INFO unless a site says otherwise.
    public static func success(_ message: String, undoable: Bool = false, log: LogLevel = .info) -> OperationBanner {
        OperationBanner(message: message, severity: .success, log: log, isUndoable: undoable)
    }

    public static func warning(_ message: String, undoable: Bool = false, log: LogLevel) -> OperationBanner {
        OperationBanner(message: message, severity: .warning, log: log, isUndoable: undoable)
    }

    public static func error(_ message: String, log: LogLevel) -> OperationBanner {
        OperationBanner(message: message, severity: .error, log: log)
    }
}
