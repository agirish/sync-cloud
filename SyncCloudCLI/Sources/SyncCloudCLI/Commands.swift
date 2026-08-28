import Foundation
import ArgumentParser
import Sync
import SyncCloudCLICore
import Settings
import Events

// MARK: - Wiring the Core runner to its real edges

/// Discovers providers against the app's UserDefaults domain, so path overrides and filter
/// settings set in the app's Settings window apply to the CLI too. The un-bundled CLI's
/// `.standard` defaults resolve to a per-process domain (`synccloud.plist`) that never sees
/// the app's `path_override_*` or `ignoreGoogleDriveNewerDateOnly` keys.
private func discoverProviderSnapshot() async -> AppSettingsSnapshot {
    let settings = await MainActor.run {
        SettingsManager(
            autoDiscover: false,
            userDefaults: UserDefaults(suiteName: SettingsManager.appSuiteName) ?? .standard,
            overridesDomainName: SettingsManager.appSuiteName
        )
    }
    await settings.discoverProviders()
    return await MainActor.run {
        AppSettingsSnapshot(
            providers: settings.availableProviders,
            ignoreGoogleDriveNewerDateOnly: settings.ignoreGoogleDriveNewerDateOnly
        )
    }
}

/// Refuses to run against stored source locations from the layout that predates source roots.
///
/// The CLI shares the app's defaults domain on purpose — Settings you set in the app apply here —
/// and that is exactly what makes this necessary. A legacy `path_override_` named a source's whole
/// tree; under the new model a source's root sits *above* its documents folder, so the same key read
/// today points somewhere different, and a `scan` would answer about the wrong tree while a `sync`
/// would copy into it. The failure is silent, which is what makes it worth an exit code.
///
/// **It refuses rather than migrating.** `RootsMigration` is idempotent and would run happily from
/// here, but it rewrites tab strips, pins, recents and the last-open folder — from a terminal,
/// possibly while the app is running against the same domain — and its unmounted-root defer path
/// would stamp on whatever `~/Library/CloudStorage` happens to look like to a CLI process. The app
/// migrates, once, at launch; this only asks.
///
/// Quiet on a fresh install: `legacyStateAwaitingMigration` answers empty when there is no legacy
/// state, not merely when the stamp is set, so an unstamped machine with nothing to move runs.
func preflightMigration() throws {
    guard let names = pendingMigrationSourceNames() else { return }
    throw CLIValidationError(message:
        "SyncCloud's stored folder locations are from an older layout and have not been migrated "
        + "yet (\(names)). Launch SyncCloud.app once to migrate them, then run this again. "
        + "Until then a run here would scan a different folder than the one you chose.")
}

/// The same question as `preflightMigration`, answered rather than thrown: the source ids still
/// awaiting migration, or nil when there are none.
func pendingMigrationSourceNames() -> String? {
    let pending = RootsMigration.legacyStateAwaitingMigration(
        defaults: UserDefaults(suiteName: SettingsManager.appSuiteName) ?? .standard,
        domainName: SettingsManager.appSuiteName)
    guard !pending.isEmpty else { return nil }
    return pending.keys.sorted().joined(separator: ", ")
}

/// `providers` warns instead of refusing.
///
/// **Because the refusal's own reason does not apply to it.** `preflightMigration` exists because a
/// run would silently *act* on the wrong folder — `scan` answers about it, `sync` copies into it.
/// `providers` touches nothing: it lists what discovery found, which is already the new model's
/// answer and is exactly what someone diagnosing this state needs to see. Refusing it told the one
/// user with a reason to run it that "a run here would scan a different folder than the one you
/// chose", about a command that scans nothing.
///
/// stderr, so a script piping the listing still gets a clean stdout.
func warnIfMigrationPending() {
    guard let names = pendingMigrationSourceNames() else { return }
    FileHandle.standardError.write(Data((
        "warning: SyncCloud's stored folder locations for \(names) are from an older layout. "
        + "The roots below are the ones discovery finds now; launch SyncCloud.app once to move "
        + "your stored folder positions onto them before running scan or sync.\n"
    ).utf8))
}

/// The Core runner with production edges: real settings discovery, the app log, and the
/// default stdout/stderr/prompt/copy/verify seams.
private func makeRunner() -> CommandRunner {
    CommandRunner(environment: .init(
        discoverSnapshot: discoverProviderSnapshot,
        logError: { message in await MainActor.run { _ = Logger.shared.error(message) } }
    ))
}

/// Runs a command body and flushes the logger's buffered disk writes before returning or
/// rethrowing. The CLI process exits as soon as `run()` finishes, but disk appends are queued
/// at `.background` QoS with no exit-time flush (the app flushes in
/// `applicationShouldTerminate`), so without this barrier a command's log lines - e.g. a
/// failed sync's error - race process exit and can never reach `~/sync-cloud.log`.
///
/// Also maps Core's outcome errors onto ArgumentParser's: `CLIValidationError` becomes a
/// `ValidationError` with the same message (usage text + exit 64, exactly as when the command
/// bodies threw it directly), and `CLISyncFailuresError` becomes `ExitCode.failure`.
// Internal, not private, for one consumer: `CLIWiringTests`. The outcome CLASSIFICATION lives in
// Core (`CLIExitMapping`, tested there); what only this function does is the translation onto
// ArgumentParser's types and the flush barrier, and both were dead code to every test while this
// was private — the exit code a wrapping script sees, unpinned.
func flushingLogToDisk<T>(_ body: () async throws -> T) async rethrows -> T {
    do {
        let result = try await body()
        await MainActor.run { Logger.shared.flushToDisk() }
        return result
    } catch {
        await MainActor.run { Logger.shared.flushToDisk() }
        // The classification itself lives in Core (`CLIExitMapping`), where it is testable — this
        // decides whether a failed sync exits non-zero, which is the only thing a script wrapping
        // this CLI can see. Translating to ArgumentParser's types stays here, since Core must not
        // depend on ArgumentParser.
        switch CLIExitMapping.outcome(for: error) {
        case .validationFailure(let message): throw ValidationError(message)
        case .syncFailure: throw ExitCode.failure
        case .rethrow: throw error
        }
    }
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan two directories and print their differences."
    )

    @OptionGroup var options: CommonOptions

    @Flag(name: .shortAndLong, help: "Output machine-readable JSON.")
    var json: Bool = false

    func run() async throws {
        try await flushingLogToDisk {
            try preflightMigration()
            return try await makeRunner().runScan(
                left: options.left, right: options.right,
                direction: options.direction, showHidden: options.showHidden, ignore: options.ignore,
                json: json
            )
        }
    }
}

// MARK: - sync

struct SyncFiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Synchronize differences between two directories."
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .shortAndLong, help: """
    Collision strategy when the destination exists: replace (default) updates it, moving the \
    previous version to the Trash (recoverable); skip leaves existing files untouched; \
    keep-both copies alongside under a unique name.
    """)
    var strategy: CollisionStrategy = .cliDefault

    @Flag(name: .shortAndLong, help: "Run without interactive confirmation.")
    var yes: Bool = false

    @Flag(name: .customLong("fail-fast"), help: "Abort the synchronization immediately if any file copy fails.")
    var failFast: Bool = false

    @Flag(name: .long, help: "Verify file contents using checksums before syncing files with different dates but identical sizes.")
    var verify: Bool = false

    func run() async throws {
        try await flushingLogToDisk {
            try preflightMigration()
            return try await makeRunner().runSync(
                left: options.left, right: options.right,
                direction: options.direction, showHidden: options.showHidden, ignore: options.ignore,
                strategy: strategy, yes: yes, failFast: failFast, verify: verify
            )
        }
    }
}

// MARK: - providers

struct Providers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "List discovered cloud providers and their root paths."
    )

    func run() async throws {
        await flushingLogToDisk {
            warnIfMigrationPending()
            await makeRunner().runProviders()
        }
    }
}

// MARK: - restructure

/// Report-only, deliberately: no `--apply`, no `--plan`, not in 5.0 — the Apply invariants are
/// all about a person reading a manifest before anything moves, and a flag that skips the
/// reading skips the invariants (ROADMAP_V5 §13). No migration preflight either: this reads
/// `folder-profile.json` and never touches providers, roots or the disk it describes.
struct Restructure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restructure",
        abstract: "Report where the surveyed tree disagrees with its own habits."
    )

    @Flag(name: .long, help: "Emit the full report as JSON (stable format; includes the crowding path lists the text summary only counts).")
    var json: Bool = false

    @Option(name: .long, help: "Profiles directory to read instead of the app's own — for fixtures and other machines' surveys.",
            completion: .directory)
    var profilesDir: String?

    func run() async throws {
        let directory = profilesDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let output: RestructureReporting.Output
        do {
            output = try RestructureReporting.report(profilesDirectory: directory)
        } catch let failure as RestructureReporting.Failure {
            throw CLIValidationError(message: failure.errorDescription ?? "\(failure)")
        }
        print(json ? try RestructureReporting.renderJSON(output)
                   : RestructureReporting.renderText(output))
    }
}
