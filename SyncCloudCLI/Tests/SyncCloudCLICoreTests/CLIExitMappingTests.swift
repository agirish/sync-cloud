import Testing
import Foundation
@testable import SyncCloudCLICore

/// Pins the CLI's exit-code classification. `Commands.flushingLogToDisk` used to inline this over
/// ArgumentParser's types in a `private func`, so nothing could test it — and the case that matters
/// is silent when wrong: if `CLISyncFailuresError` ever stopped mapping to a failure exit, a sync
/// that failed would exit 0 and every script wrapping this CLI would read it as success.
@Suite struct CLIExitMappingTests {

    @Test func aValidationErrorCarriesItsMessageToTheUsageExit() {
        let outcome = CLIExitMapping.outcome(for: CLIValidationError(message: "left path does not exist"))
        #expect(outcome == .validationFailure(message: "left path does not exist"))
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

    @Test func theValidationCheckPrecedesTheGenericPath() {
        // Order matters: a CLIValidationError must never fall through to `.rethrow`, or the CLI
        // would print a raw error instead of usage text and exit with the wrong code.
        let outcome = CLIExitMapping.outcome(for: CLIValidationError(message: ""))
        #expect(outcome != .rethrow)
    }
}
