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
/// The CLI shares the app's defaults domain so its Settings apply here. A legacy `path_override_`
/// named a source's whole tree, while a root now sits *above* its documents folder, so the same key
/// read today points elsewhere: a `scan` would answer about the wrong tree and a `sync` would copy
/// into it, silently. Hence an exit code.
///
/// It refuses rather than migrating: `RootsMigration` rewrites tab strips, pins, recents and the
/// last-open folder, possibly while the app runs on the same domain, and its unmounted-root defer
/// path would act on whatever `~/Library/CloudStorage` looks like to a CLI process. The app
/// migrates at launch; this only asks.
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

/// `providers` warns instead of refusing. `preflightMigration` guards runs that would act on the
/// wrong folder; `providers` acts on nothing and lists what discovery finds under the new model,
/// which is what someone diagnosing this state needs to see. Written to stderr, so a script piping
/// the listing still gets a clean stdout.
func warnIfMigrationPending() {
    guard let names = pendingMigrationSourceNames() else { return }
    FileHandle.standardError.write(Data((
        "warning: SyncCloud's stored folder locations for \(names) are from an older layout. "
        + "The roots below are the ones discovery finds now; launch SyncCloud.app once to move "
        + "your stored folder positions onto them before running scan or sync.\n"
    ).utf8))
}

/// Puts the CLI's log gate at the app's Log level and writes the start line that states it.
///
/// Without this the CLI never set a level, so it wrote Debug into the shared `~/sync-cloud.log`
/// whatever the app's Settings said. Read from the app's suite, as `discoverProviderSnapshot` does:
/// the un-bundled CLI's `.standard` is its own domain. Called at the top of each `run()`, never
/// from `flushingLogToDisk`, which `CLIWiringTests` drives: an explicit suite is read even under a
/// test runner (`Logger.persistedMinimumLevel(from:)`), so the wrapper would hand those tests his
/// live level. `CLIWiringTests.everyCommandAdoptsTheAppsLogLevel` holds every verb to it.
func adoptAppLogLevel(verb: String) {
    let level = UserDefaults(suiteName: SettingsManager.appSuiteName)
        .map { Logger.persistedMinimumLevel(from: $0) } ?? Logger.defaultMinimumLevel
    Logger.shared.minimumLevel = level
    Logger.shared.info("synccloud \(verb) started (log level \(level.settingName))")
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
/// `applicationShouldTerminate`), so without this barrier a command's log lines, such as a
/// failed sync's error, race process exit and may never reach `~/sync-cloud.log`.
///
/// Also maps Core's outcome errors onto ArgumentParser's: `CLIValidationError` becomes a
/// `ValidationError` with the same message (usage text and exit 64), and `CLISyncFailuresError`
/// becomes `ExitCode.failure`.
// Internal, not private, so `CLIWiringTests` can pin the translation and the flush barrier, which
// decide what a wrapping script sees. The classification itself is Core's (`CLIExitMapping`).
func flushingLogToDisk<T>(_ body: () async throws -> T) async rethrows -> T {
    do {
        let result = try await body()
        await MainActor.run { Logger.shared.flushToDisk() }
        return result
    } catch {
        await MainActor.run { Logger.shared.flushToDisk() }
        // Core classifies (`CLIExitMapping`, where it is testable); translating to ArgumentParser's
        // types stays here, since Core must not depend on ArgumentParser.
        switch CLIExitMapping.outcome(for: error) {
        // A validation message is passed on as written: it is this tool's own ASCII words around
        // names the user typed or discovery found (a path, a provider's id or display name), and
        // folding it would print a different name than the one to type back. An error
        // ArgumentParser prints as `Error: …` is someone else's sentence, often Cocoa's, so it is
        // folded.
        case .validationFailure(let message): throw ValidationError(message)
        case .syncFailure: throw ExitCode.failure
        case .rethrow: throw CLIOutput.foldedForPrinting(error)
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
            adoptAppLogLevel(verb: "scan")
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
            adoptAppLogLevel(verb: "sync")
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
            adoptAppLogLevel(verb: "providers")
            warnIfMigrationPending()
            await makeRunner().runProviders()
        }
    }
}

// MARK: - restructure

/// Report-only, deliberately: no `--apply` or `--plan`. Apply's invariants rest on a person
/// reading a manifest before anything moves, and a flag that skips the reading skips them. No
/// migration preflight either: this reads `folder-profile.json` and never touches providers,
/// roots or the disk it describes.
struct Restructure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restructure",
        abstract: "Report where the surveyed tree disagrees with its own habits."
    )

    @Flag(name: .long, help: "Emit the full report as JSON (stable format; includes the crowding path lists the text summary only counts).")
    var json: Bool = false

    @Option(name: .long, help: "Profiles directory to read instead of the app's own - for fixtures and other machines' surveys.",
            completion: .directory)
    var profilesDir: String?

    /// Wrapped in `flushingLogToDisk` like every other verb: only that wrapper turns a
    /// `CLIValidationError` into ArgumentParser's `ValidationError`. Without it the sentences
    /// `Failure.errorDescription` composes never reach the reader (ArgumentParser prints the
    /// struct, type name and escaped apostrophes included), the exit is 1 instead of 64, and the
    /// log is not flushed.
    func run() async throws {
        try await flushingLogToDisk {
            adoptAppLogLevel(verb: "restructure")
            let directory = profilesDir.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            }
            try RestructureReporting.run(profilesDirectory: directory, json: json) { print($0) }
        }
    }
}
