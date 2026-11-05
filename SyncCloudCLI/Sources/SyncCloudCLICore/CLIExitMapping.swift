import Foundation

/// How a Core outcome error ends the process: the pure half of `Commands.flushingLogToDisk`'s
/// catch ladder, kept out of the ArgumentParser layer so it can be tested. Scripts wrapping the
/// CLI read the exit status, so a mapping that swallowed `CLISyncFailuresError` would make a
/// failed sync exit 0 and look like success.
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
