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

    public var message: String
    public var severity: Severity

    public init(message: String, severity: Severity) {
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
