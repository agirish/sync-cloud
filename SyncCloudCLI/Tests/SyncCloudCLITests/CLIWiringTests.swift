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

    // MARK: The migration pre-flight

    /// **Every command that touches a tree asks first, and this reads the source to say so.**
    ///
    /// `preflightMigration` refuses when the app's stored source locations are still from the layout
    /// that predates source roots — a legacy `path_override_` read under the new meaning points a
    /// `scan` at a different folder than the user chose, and `sync` is a mass copy. Nothing forces a
    /// new subcommand to call it, and forgetting is silent in the worst possible direction, so the
    /// call is asserted at each site rather than left to a reviewer.
    ///
    /// Source text rather than behaviour because the alternative is not available: the pre-flight
    /// reads the app's real defaults domain, so exercising it would mean writing a legacy override
    /// into this developer's live `~/Library/Preferences` — the domain his running app is on. The
    /// PREDICATE it asks is behaviourally tested, against a scratch suite, in
    /// `RootsMigrationTests.legacyStateIsReportedOnlyWhenThereIsSome`; this is the wiring half.
    @Test func everyCommandThatTouchesATreeAsksBeforeItRuns() throws {
        let source = try Self.commandsSource()
        for command in ["runScan", "runSync"] {
            let body = try #require(Self.runBody(before: command, in: source),
                                    "cannot find the run body that calls \(command)")
            #expect(body.contains("try preflightMigration()"),
                    "the command that calls \(command) runs without asking whether the stored locations have been migrated")
        }
    }

    /// **`providers` warns instead, and that difference is asserted rather than assumed.**
    ///
    /// It listed `runProviders` among the refusers for one commit, which was the pre-flight's own
    /// reason applied where it does not hold: `providers` reads and prints, so there is no wrong
    /// folder for it to act on — and it is the one command someone in this state has a reason to
    /// run, since it shows the roots discovery finds NOW. Refusing it answered a diagnostic
    /// question with "a run here would scan a different folder than the one you chose", about a
    /// command that scans nothing.
    ///
    /// Both halves are checked: that it does not refuse, and that it does not go quiet either.
    @Test func providersWarnsRatherThanRefusing() throws {
        let source = try Self.commandsSource()
        let body = try #require(Self.runBody(before: "runProviders", in: source),
                                "cannot find the run body that calls runProviders")
        #expect(!body.contains("try preflightMigration()"),
                "providers refuses on an unmigrated install — it reads and prints, so it has nothing to refuse over")
        #expect(body.contains("warnIfMigrationPending()"),
                "providers says nothing about an unmigrated install, so its listing reads as the whole truth")
    }

    /// **Every command routes its exit through `flushingLogToDisk`, and that is the rule, not a
    /// habit three of the four happened to share.**
    ///
    /// The wrapper is the only thing that turns a `CLIValidationError` into ArgumentParser's
    /// `ValidationError` (via `CLIExitMapping`), so skipping it is silent in three directions at
    /// once and none of them is a crash: the message a `Failure` composed is replaced by
    /// ArgumentParser stringifying the struct — `Error: CLIValidationError(message: "…\'s …")`,
    /// internal type name included and the apostrophes inside the advice backslash-escaped —
    /// the exit falls from 64 to 1, so a script telling a usage error from a run failure reads
    /// the wrong one, and the log never reaches disk on the path most worth having it.
    ///
    /// `restructure` shipped that way: the one verb added in 5.0, and the only one unwrapped.
    /// Written over the call-site table rather than as one assertion about that verb, because the
    /// next verb is the one this is for.
    @Test func everyCommandExitsThroughTheLogFlushAndErrorLadder() throws {
        let source = try Self.commandsSource()
        for call in ["runScan", "runSync", "runProviders", "RestructureReporting.report"] {
            let body = try #require(Self.runBody(before: call, in: source),
                                    "cannot find the run body that calls \(call)")
            #expect(body.contains("flushingLogToDisk"),
                    "the command that calls \(call) returns without the flush-and-map ladder: its CLIValidationErrors reach the user as a struct dump, exit 1 instead of 64, and its log never reaches disk")
        }
    }

    /// The positive control for the scan above: `runBody` really can come back WITHOUT the
    /// wrapper, so a green result there is the source agreeing rather than the search missing.
    /// Without this, deleting `flushingLogToDisk` from every command would still pass — the
    /// helper would return nil, `#require` would fail... which is the point being pinned: it is
    /// the *`#expect`* that must be able to fail, and here it is, failing on purpose.
    @Test func theFlushScanCanActuallyFail() throws {
        let unwrapped = """
            func run() async throws {
                let output = try RestructureReporting.report(profilesDirectory: nil)
            }
            """
        let body = try #require(Self.runBody(before: "RestructureReporting.report",
                                             in: unwrapped))
        #expect(!body.contains("flushingLogToDisk"),
                "the scan cannot distinguish a wrapped body from an unwrapped one")
    }

    /// `Commands.swift` as text. Located from this file rather than a build setting, so it moves
    /// with the package instead of depending on where the tests are run from.
    static func commandsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SyncCloudCLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SyncCloudCLI
            .appendingPathComponent("Sources/SyncCloudCLI/Commands.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from the `func run()` that precedes `call` up to that call — the body a command
    /// actually executes before reaching the runner. Nil when no `run()` precedes it, which is a
    /// failure rather than a pass: a call site this cannot see is one it cannot check.
    static func runBody(before call: String, in source: String) -> String? {
        guard let callRange = source.range(of: call) else { return nil }
        let head = source[source.startIndex..<callRange.lowerBound]
        guard let runRange = head.range(of: "func run() async throws {", options: .backwards) else {
            return nil
        }
        return String(source[runRange.upperBound..<callRange.lowerBound])
    }

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
