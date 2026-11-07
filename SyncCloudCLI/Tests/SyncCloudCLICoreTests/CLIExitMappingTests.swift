import Testing
import Foundation
@testable import SyncCloudCLICore

/// Pins the CLI's exit-code classification. The case that matters is silent when wrong: if
/// `CLISyncFailuresError` stopped mapping to a failure exit, a failed sync would exit 0 and every
/// script wrapping this CLI would read it as success.
@Suite struct CLIExitMappingTests {

    @Test func aValidationErrorCarriesItsMessageToTheUsageExit() {
        let outcome = CLIExitMapping.outcome(for: CLIValidationError(message: "left path does not exist"))
        #expect(outcome == .validationFailure(message: "left path does not exist"))
        #expect(CLIExitMapping.outcome(for: CLIValidationError(message: "")) == .validationFailure(message: ""))
    }

    @Test func syncFailuresExitNonZero() {
        #expect(CLIExitMapping.outcome(for: CLISyncFailuresError()) == .syncFailure)
    }

    @Test func everythingElsePropagatesUnchanged() {
        // Including ArgumentParser's own control-flow errors, which must reach it untouched —
        // swallowing them here would turn `--help` into an error exit.
        #expect(CLIExitMapping.outcome(for: NSError(domain: NSCocoaErrorDomain, code: 4)) == .rethrow)
        struct Custom: Error {}
        #expect(CLIExitMapping.outcome(for: Custom()) == .rethrow)
    }
}
