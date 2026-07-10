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

    public init(message: String, severity: Severity, id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.severity = severity
    }

    public static func success(_ message: String) -> OperationBanner {
        OperationBanner(message: message, severity: .success)
    }

    public static func warning(_ message: String) -> OperationBanner {
        OperationBanner(message: message, severity: .warning)
    }

    public static func error(_ message: String) -> OperationBanner {
        OperationBanner(message: message, severity: .error)
    }
}
