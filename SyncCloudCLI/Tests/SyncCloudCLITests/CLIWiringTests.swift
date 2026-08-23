import Foundation
import Testing
import ArgumentParser
import Events
import SyncCloudCLICore
@testable import SyncCloudCLI

/// First coverage for the executable target. `SyncCloudCLICore` is well tested; the shell around
/// it was not, and everything here is shell: dropping the default subcommand turns a bare
/// `synccloud -L … -R …` into a usage error, a renamed short strands every script that spells
/// `-L`, and the error translation decides the exit code — the only thing a wrapping script can
/// see. None of that was reachable while the target had no tests.
@Suite struct CLIWiringTests {

    // MARK: Parsing

    @Test func aBareInvocationIsAScan() throws {
        #expect(SyncCloudCommand.configuration.defaultSubcommand == Scan.self,
                "without the default, `synccloud -L … -R …` becomes a usage error")
        let parsed = try SyncCloudCommand.parseAsRoot(["-L", "/tmp/a", "-R", "/tmp/b"])
        let scan = try #require(parsed as? Scan, "the bare invocation parsed as \(type(of: parsed))")
        #expect(scan.options.left == "/tmp/a")
        #expect(scan.options.right == "/tmp/b")
    }

    @Test func theDocumentedSpellingsAllReachTheSameOptions() throws {
        // The custom shorts and the customLong: each is API to someone's shell history.
        let short = try Scan.parse(["-L", "/a", "-R", "/b", "-d", "to-right", "-j"])
        #expect(short.options.left == "/a" && short.options.right == "/b")
        #expect(short.options.direction == .toRight)
        #expect(short.json)

        let long = try Scan.parse(["--left", "/a", "--right", "/b",
                                   "--direction", "to-left", "--show-hidden",
                                   "--ignore", "*.tmp", "--ignore", "node_modules"])
        #expect(long.options.direction == .toLeft)
        #expect(long.options.showHidden)
        #expect(long.options.ignore == ["*.tmp", "node_modules"],
                "repeated --ignore must accumulate, not replace")
    }

    /// The sync subcommand's own wire surface — its name, the strategy short, `-y`, `--verify`,
    /// and the `customLong` fail-fast, which is exactly the spelling class a rename breaks with
    /// every other suite green. The first landing of this file stopped at Scan; `sync` is the
    /// subcommand that MOVES files, so its scripts have the most to lose from a renamed flag.
    @Test func theSyncSubcommandsDocumentedSpellingsAllParse() throws {
        let parsed = try SyncCloudCommand.parseAsRoot(
            ["sync", "-L", "/a", "-R", "/b", "-s", "keep-both", "-y", "--fail-fast", "--verify"])
        let sync = try #require(parsed as? SyncFiles,
                                "`sync` no longer names the SyncFiles subcommand — parsed \(type(of: parsed))")
        #expect(sync.options.left == "/a" && sync.options.right == "/b")
        #expect(sync.strategy == .keepBoth)
        #expect(sync.yes)
        #expect(sync.failFast)
        #expect(sync.verify)

        let providers = try SyncCloudCommand.parseAsRoot(["providers"])
        #expect(providers is Providers, "`providers` no longer names its subcommand")
    }

    /// The flag strings are the wire format scripts speak; `DifferenceProcessingTests` pins the
    /// raw values from Core's side, and this pins that ArgumentParser still maps the flags onto
    /// them — the half a rename of the conformance would break with Core's pins green.
    @Test func directionAndCollisionFlagStringsStillParse() {
        #expect(Direction(argument: "to-right") == .toRight)
        #expect(Direction(argument: "to-left") == .toLeft)
        #expect(Direction(argument: "auto") == .auto)
        #expect(Direction(argument: "rightward") == nil)
        #expect(CollisionStrategy(argument: "keep-both") == .keepBoth)
        #expect(CollisionStrategy(argument: "skip") == .skip)
        #expect(CollisionStrategy(argument: "replace") == .replace)
    }

    // MARK: The exit-code translation

    /// Core classifies (`CLIExitMapping`, tested there); this is the other half — the
    /// ArgumentParser types the classification is translated onto, which decide the process's
    /// exit code and usage text.
    @Test func aCoreValidationErrorBecomesAnArgumentParserValidationError() async {
        do {
            try await flushingLogToDisk {
                throw CLIValidationError(message: "left and right resolve to the same folder")
            }
            Issue.record("nothing was thrown")
        } catch let error as ValidationError {
            // The same message, verbatim: usage text + exit 64, exactly as when the command
            // bodies threw ArgumentParser's type directly.
            #expect(error.message == "left and right resolve to the same folder")
        } catch {
            Issue.record("threw \(error) instead of ArgumentParser's ValidationError — the exit code and usage text are gone")
        }
    }

    @Test func syncFailuresBecomeExitCodeFailure() async {
        await #expect(throws: ExitCode.failure) {
            try await flushingLogToDisk { throw CLISyncFailuresError() }
        }
    }

    @Test func anUnclassifiedErrorIsRethrownAsItself() async {
        struct Unrelated: Error, Equatable {}
        await #expect(throws: Unrelated()) {
            try await flushingLogToDisk { throw Unrelated() }
        }
    }

    /// Durability across the wrapper: a line logged before a failing body is on DISK once
    /// `flushingLogToDisk` rethrows. Honest scope: the writer appends from its own serial queue,
    /// so a deleted flush would usually STILL land the line during this test's suspension points —
    /// what this pins is the observable contract (line durable when the wrapper returns), not the
    /// flush call's presence; the barrier's own semantics are Events' to test. Under `swift test`
    /// the logger writes a per-process temp file, so this reads the real path the wrapper
    /// protects without touching `~/sync-cloud.log`.
    @Test func aFailedBodysLogLineIsOnDiskWhenTheWrapperRethrows() async throws {
        let tag = "cli-flush-\(UUID().uuidString)"
        struct Boom: Error {}
        _ = await MainActor.run { Logger.shared.error("flush barrier probe \(tag)") }
        await #expect(throws: Boom.self) {
            try await flushingLogToDisk { throw Boom() }
        }
        let logURL = await MainActor.run { Logger.shared.logFileURL }
        let onDisk = try #require(
            try? String(contentsOf: logURL, encoding: .utf8),
            "the test logger's file is unreadable — the barrier assertion below would be vacuous")
        #expect(onDisk.contains(tag),
                "the logged line had not reached disk when flushingLogToDisk returned — the barrier is gone")
    }
}
