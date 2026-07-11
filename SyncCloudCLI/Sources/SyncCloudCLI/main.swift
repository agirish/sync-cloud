import Foundation
import ArgumentParser
import Sync
import SyncCloudCLICore
import Settings
import Events

// MARK: - Top-level command

@main
struct SyncCloudCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "synccloud",
        abstract: "Command line interface for SyncCloud.",
        discussion: """
        A git-like CLI for comparing and synchronizing two directories, with smart defaults for common cloud providers.
        """,
        subcommands: [
            Scan.self,
            SyncFiles.self,
            Providers.self
        ],
        defaultSubcommand: Scan.self
    )
}

// MARK: - Shared helpers

extension Direction: ExpressibleByArgument {}
extension CollisionStrategy: ExpressibleByArgument {}

private struct DiffSummary: Codable {
    let relativePath: String
    let leftPath: String
    let rightPath: String
    let type: String
    let action: String
    let description: String
    let leftSize: Int?
    let rightSize: Int?
}

/// The app settings the CLI honors: discovered providers plus the Google Drive
/// date-noise filter toggle.
private struct AppSettingsSnapshot {
    let providers: [CloudProvider]
    let ignoreGoogleDriveNewerDateOnly: Bool
}

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

/// Runs a command body and flushes the logger's buffered disk writes before returning or
/// rethrowing. The CLI process exits as soon as `run()` finishes, but disk appends are queued
/// at `.background` QoS with no exit-time flush (the app flushes in
/// `applicationShouldTerminate`), so without this barrier a command's log lines - e.g. a
/// failed sync's error - race process exit and can never reach `~/sync-cloud.log`.
private func flushingLogToDisk<T>(_ body: () async throws -> T) async rethrows -> T {
    do {
        let result = try await body()
        await MainActor.run { Logger.shared.flushToDisk() }
        return result
    } catch {
        await MainActor.run { Logger.shared.flushToDisk() }
        throw error
    }
}

/// Discovers providers and resolves both `-L`/`-R` values, converting resolution
/// failures into ArgumentParser validation errors. Also carries the settings snapshot
/// forward so filters that depend on it (Google Drive date noise) see the same state.
private func resolveProviders(
    left: String, right: String
) async throws -> (left: CloudProvider, right: CloudProvider, ignoreGoogleDriveNewerDateOnly: Bool) {
    let snapshot = await discoverProviderSnapshot()
    do {
        let leftProvider = try resolveProviderOrPath(value: left, label: "Left", providers: snapshot.providers)
        let rightProvider = try resolveProviderOrPath(value: right, label: "Right", providers: snapshot.providers)
        return (leftProvider, rightProvider, snapshot.ignoreGoogleDriveNewerDateOnly)
    } catch let error as ProviderResolutionError {
        throw ValidationError(error.message)
    }
}

/// Scans both directories and returns the differences after the hidden/ignore/direction
/// filters plus, when enabled in the app's settings, the Google Drive date-noise filter.
private func scanForDifferences(
    left: CloudProvider, right: CloudProvider,
    direction: Direction, showHidden: Bool, ignore: [String],
    ignoreGoogleDriveNewerDateOnly: Bool
) throws -> (diffs: [FileDifference], leftURL: URL, rightURL: URL) {
    let leftURL = URL(fileURLWithPath: expandPath(left.path))
    let rightURL = URL(fileURLWithPath: expandPath(right.path))

    let leftInfo = try FileDiffEngine.getFilesInDirectory(leftURL)
    let rightInfo = try FileDiffEngine.getFilesInDirectory(rightURL)

    // Case-variant paths only collapse into one pair when neither volume distinguishes
    // case; with mixed sensitivity the engine keeps exact-case matching.
    let caseInsensitive = !FileSyncManager.volumeSupportsCaseSensitiveNames(for: leftURL)
        && !FileSyncManager.volumeSupportsCaseSensitiveNames(for: rightURL)

    let allDiffs = FileDiffEngine.computeDifferences(
        left: left,
        leftURL: leftURL,
        right: right,
        rightURL: rightURL,
        leftFilesInfo: leftInfo,
        rightFilesInfo: rightInfo,
        caseInsensitive: caseInsensitive
    )
    let diffs = DifferenceProcessing.filterDifferences(
        allDiffs, direction: direction, showHidden: showHidden, ignore: ignore,
        ignoreGoogleDriveNewerDateOnly: ignoreGoogleDriveNewerDateOnly,
        rightProviderType: right.type
    )
    return (diffs, leftURL, rightURL)
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan two directories and print their differences."
    )

    @Option(name: [.customShort("L"), .long], help: "Left side provider id or path.")
    var left: String

    @Option(name: [.customShort("R"), .long], help: "Right side provider id or path.")
    var right: String

    @Flag(name: .shortAndLong, help: "Output machine-readable JSON.")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Filter by direction: auto, to-right, to-left.")
    var direction: Direction = .auto

    @Flag(name: .customLong("show-hidden"), help: "Include hidden files and folders.")
    var showHidden: Bool = false

    @Option(name: .long, help: "Paths to ignore.")
    var ignore: [String] = []

    func run() async throws {
        try await flushingLogToDisk { try await scanAndReport() }
    }

    private func scanAndReport() async throws {
        let (leftProvider, rightProvider, ignoreDriveDateNoise) = try await resolveProviders(left: left, right: right)
        let (diffs, leftURL, rightURL) = try scanForDifferences(
            left: leftProvider, right: rightProvider,
            direction: direction, showHidden: showHidden, ignore: ignore,
            ignoreGoogleDriveNewerDateOnly: ignoreDriveDateNoise
        )

        if json {
            let payload = diffs.map {
                DiffSummary(
                    relativePath: $0.relativePath,
                    leftPath: $0.leftItemPath,
                    rightPath: $0.rightItemPath,
                    type: DifferenceProcessing.typeString($0.type),
                    action: DifferenceProcessing.actionString($0.action),
                    description: $0.description,
                    leftSize: $0.leftFileSize,
                    rightSize: $0.rightFileSize
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
        } else {
            if diffs.isEmpty {
                print("No differences found between")
                print("  Left : \(leftURL.path)")
                print("  Right: \(rightURL.path)")
                return
            }

            print("Differences (\(diffs.count)):")
            print("  Left : \(leftURL.path) [\(leftProvider.displayName)]")
            print("  Right: \(rightURL.path) [\(rightProvider.displayName)]")
            print("")

            for diff in diffs {
                let type = DifferenceProcessing.typeString(diff.type)
                let action = DifferenceProcessing.actionString(diff.action)
                print("- [\(type)] [\(action)] \(diff.relativePath)")
                print("    \(diff.description)")
            }
        }
    }
}

// MARK: - sync

struct SyncFiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Synchronize differences between two directories."
    )

    @Option(name: [.customShort("L"), .long], help: "Left side provider id or path.")
    var left: String

    @Option(name: [.customShort("R"), .long], help: "Right side provider id or path.")
    var right: String

    @Option(name: .shortAndLong, help: "Limit to a specific direction: auto | to-right | to-left.")
    var direction: Direction = .auto

    @Option(name: .shortAndLong, help: """
    Collision strategy when the destination exists: replace (default) updates it, moving the \
    previous version to the Trash (recoverable); skip leaves existing files untouched; \
    keep-both copies alongside under a unique name.
    """)
    var strategy: CollisionStrategy = .cliDefault

    @Flag(name: .shortAndLong, help: "Run without interactive confirmation.")
    var yes: Bool = false

    @Flag(name: .customLong("show-hidden"), help: "Include hidden files and folders.")
    var showHidden: Bool = false

    @Option(name: .long, help: "Paths to ignore.")
    var ignore: [String] = []

    @Flag(name: .customLong("fail-fast"), help: "Abort the synchronization immediately if any file copy fails.")
    var failFast: Bool = false

    @Flag(name: .long, help: "Verify file contents using checksums before syncing files with different dates but identical sizes.")
    var verify: Bool = false

    func run() async throws {
        try await flushingLogToDisk { try await syncDifferences() }
    }

    private func syncDifferences() async throws {
        let (leftProvider, rightProvider, ignoreDriveDateNoise) = try await resolveProviders(left: left, right: right)
        var (diffs, _, _) = try scanForDifferences(
            left: leftProvider, right: rightProvider,
            direction: direction, showHidden: showHidden, ignore: ignore,
            ignoreGoogleDriveNewerDateOnly: ignoreDriveDateNoise
        )

        if verify {
            print("Verifying files with matching sizes...")
            let (kept, verifiedCount) = await DifferenceProcessing.partitionByVerification(diffs) { diff in
                await FileContentVerifier.filesHaveSameContent(
                    leftPath: diff.leftItemPath,
                    rightPath: diff.rightItemPath,
                    fileManager: FileManager.default
                )
            }
            diffs = kept
            if verifiedCount > 0 {
                print("Skipped \(verifiedCount) files that verified as identical.")
            }
        }

        if diffs.isEmpty {
            print("Nothing to sync - no differences found.")
            return
        }

        print("Planned operations (\(diffs.count)):")
        for diff in diffs {
            let arrow = diff.action == .copyToRight ? "→" : "←"
            print("- \(diff.relativePath) \(arrow) [\(DifferenceProcessing.typeString(diff.type))]")
        }

        if !yes {
            print("")
            print("Proceed with these operations? [y/N]: ", terminator: "")
            guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                print("Aborted.")
                return
            }
        }

        let fm = FileManager.default
        var tally = SyncTally()

        for diff in diffs {
            let (sourcePath, targetPath) = DifferenceProcessing.sourceAndTarget(for: diff)
            let sourceURL = URL(fileURLWithPath: sourcePath)
            var targetURL = URL(fileURLWithPath: targetPath)

            switch resolveCollision(strategy: strategy, targetExists: fm.fileExists(atPath: targetURL.path)) {
            case .skip:
                tally.recordSkipped(relativePath: diff.relativePath)
                continue
            case .copyToUnique:
                targetURL = FileSyncManager.generateUniqueURL(for: targetURL, fileManager: fm)
            case .proceed:
                break
            }

            do {
                // `trashed` is non-nil exactly when an existing destination was replaced
                // (safeCopy backs it up to the Trash), which is what the summary reports.
                let result = try FileSyncManager.performFileSyncIO(from: sourceURL, to: targetURL, isMove: false, fileManager: fm)
                tally.recordCopied(replacedExisting: result.trashed != nil)
            } catch {
                tally.recordFailed()
                let message = "Failed to sync \(diff.relativePath): \(error.localizedDescription)"
                await MainActor.run { _ = Logger.shared.error(message) }
                fputs(message + "\n", stderr)

                if failFast {
                    fputs("Aborting due to --fail-fast.\n", stderr)
                    throw error
                }
            }
        }

        print("")
        let summary = syncSummary(tally: tally, strategy: strategy)
        for line in summary.stdoutLines { print(line) }
        for line in summary.stderrLines { fputs(line + "\n", stderr) }
        // Partial failures must be visible to scripts, not just in the text summary. Thrown
        // after the summary so the counts still print; flushingLogToDisk flushes on this
        // throw path too. (--fail-fast still aborts immediately above, before the summary.)
        if summary.exitNonzero {
            throw ExitCode.failure
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
        await flushingLogToDisk { await listProviders() }
    }

    private func listProviders() async {
        let providers = await discoverProviderSnapshot().providers
        if providers.isEmpty {
            print("No providers discovered.")
            return
        }

        print("Discovered providers:")
        for provider in providers {
            print("- \(provider.id)")
            print("    name : \(provider.displayName)")
            print("    type : \(provider.type.rawValue)")
            print("    path : \(provider.path)")
        }
    }
}
