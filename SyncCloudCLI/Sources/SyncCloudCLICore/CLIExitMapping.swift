import Foundation

/// How a Core outcome error should end the process — the pure half of `Commands.flushingLogToDisk`'s
/// catch ladder, lifted out of the ArgumentParser layer so it can be tested.
///
/// It decides whether a failed sync exits non-zero, which is what every script wrapping this CLI
/// reads. Inline in a `private func` over ArgumentParser's own error types, that decision had no
/// test at all: a drift that swallowed `CLISyncFailuresError` would make a failed sync exit 0 and
/// every caller would see success.
public enum CLIExitOutcome: Equatable {
    /// A usage error: ArgumentParser prints the message with usage text and exits 64.
    case validationFailure(message: String)
    /// The command ran but some items failed — a plain non-zero exit, no usage text.
    case syncFailure
    /// Anything else propagates unchanged (ArgumentParser decides, including its own `ExitCode`s).
    case rethrow
}

public enum CLIExitMapping {
    /// Classifies an error thrown by a command body.
    public static func outcome(for error: Error) -> CLIExitOutcome {
        if let validation = error as? CLIValidationError {
            return .validationFailure(message: validation.message)
        }
        if error is CLISyncFailuresError {
            return .syncFailure
        }
        return .rethrow
    }
}
