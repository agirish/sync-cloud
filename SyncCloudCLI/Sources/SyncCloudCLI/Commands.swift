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
            try await makeRunner().runScan(
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
            try await makeRunner().runSync(
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
        await flushingLogToDisk { await makeRunner().runProviders() }
    }
}
