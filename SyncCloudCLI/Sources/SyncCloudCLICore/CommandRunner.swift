import Foundation
import Sync

// MARK: - Outcome errors

/// An argument/provider-resolution problem. The executable shell maps this onto
/// ArgumentParser's `ValidationError` (usage text + exit 64) with the same message; Core
/// cannot throw that type itself without depending on ArgumentParser.
public struct CLIValidationError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Partial sync failures: thrown AFTER the summary printed, so scripts see a non-zero exit
/// while humans still get the counts. The shell maps it onto `ExitCode.failure`.
public struct CLISyncFailuresError: Error, Equatable, Sendable {
    public init() {}
}

// MARK: - Settings snapshot

/// The app settings the CLI honors: discovered providers plus the Google Drive
/// date-noise filter toggle.
public struct AppSettingsSnapshot: Sendable {
    public let providers: [CloudProvider]
    public let ignoreGoogleDriveNewerDateOnly: Bool

    public init(providers: [CloudProvider], ignoreGoogleDriveNewerDateOnly: Bool) {
        self.providers = providers
        self.ignoreGoogleDriveNewerDateOnly = ignoreGoogleDriveNewerDateOnly
    }
}

// MARK: - Runner

/// The testable body of the three CLI commands (`scan`, `sync`, `providers`), extracted from
/// the executable so argument parsing is the only thing left there. Every edge the commands
/// touch — settings discovery, stdout/stderr, the confirmation prompt, the copy primitive,
/// content verification, the failure log — comes in through ``Environment``, so tests can pin
/// exact output and exit behavior without spawning processes, discovering real providers, or
/// letting a copy failure depend on filesystem permissions.
public struct CommandRunner {

    public struct Environment {
        /// Discovers providers + the Drive date-noise toggle (the app's UserDefaults domain).
        public var discoverSnapshot: () async -> AppSettingsSnapshot
        /// Logs one failed-copy message to the app log (the shell flushes it to disk).
        public var logError: (String) async -> Void
        /// Raw stdout writer — no newline appended (the sync prompt prints without one).
        public var writeOut: (String) -> Void
        /// Raw stderr writer — no newline appended.
        public var writeErr: (String) -> Void
        /// Reads the interactive confirmation line for `sync` without `--yes`.
        public var readConfirmationLine: () -> String?
        public var fileManager: FileManager
        /// Copies source → target with safe replacement; returns whether an existing
        /// destination was replaced (its previous version moved to the Trash).
        public var performFileSync: (_ source: URL, _ target: URL, _ fileManager: FileManager) throws -> Bool
        /// Content-verifies one same-size pair for `--verify` (true = byte-identical).
        public var verifyFilesHaveSameContent: (_ leftPath: String, _ rightPath: String) async -> Bool?

        public init(
            discoverSnapshot: @escaping () async -> AppSettingsSnapshot,
            logError: @escaping (String) async -> Void,
            writeOut: @escaping (String) -> Void = { print($0, terminator: "") },
            writeErr: @escaping (String) -> Void = { fputs($0, stderr) },
            readConfirmationLine: @escaping () -> String? = { readLine() },
            fileManager: FileManager = .default,
            performFileSync: @escaping (URL, URL, FileManager) throws -> Bool = { source, target, fm in
                try FileSyncManager.performFileSyncIO(from: source, to: target, isMove: false, fileManager: fm).trashed != nil
            },
            verifyFilesHaveSameContent: @escaping (String, String) async -> Bool? = { leftPath, rightPath in
                await FileContentVerifier.filesHaveSameContent(
                    leftPath: leftPath, rightPath: rightPath, fileManager: FileManager.default)
            }
        ) {
            self.discoverSnapshot = discoverSnapshot
            self.logError = logError
            self.writeOut = writeOut
            self.writeErr = writeErr
            self.readConfirmationLine = readConfirmationLine
            self.fileManager = fileManager
            self.performFileSync = performFileSync
            self.verifyFilesHaveSameContent = verifyFilesHaveSameContent
        }
    }

    let env: Environment

    public init(environment: Environment) {
        self.env = environment
    }

    /// `print(line)` — one stdout line, newline appended.
    private func printOut(_ line: String) { env.writeOut(line + "\n") }

    // MARK: Shared plumbing

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

    /// Discovers providers and resolves both `-L`/`-R` values, converting resolution
    /// failures into validation errors. Also carries the settings snapshot forward so
    /// filters that depend on it (Google Drive date noise) see the same state.
    private func resolveProviders(
        left: String, right: String
    ) async throws -> (left: CloudProvider, right: CloudProvider, ignoreGoogleDriveNewerDateOnly: Bool) {
        let snapshot = await env.discoverSnapshot()
        do {
            let leftProvider = try resolveProviderOrPath(value: left, label: "Left", providers: snapshot.providers)
            let rightProvider = try resolveProviderOrPath(value: right, label: "Right", providers: snapshot.providers)
            return (leftProvider, rightProvider, snapshot.ignoreGoogleDriveNewerDateOnly)
        } catch let error as ProviderResolutionError {
            throw CLIValidationError(message: error.message)
        }
    }

    /// Scans both directories and returns the differences after the hidden/ignore/direction
    /// filters plus, when enabled in the app's settings, the Google Drive date-noise filter.
    private func scanForDifferences(
        left: CloudProvider, right: CloudProvider,
        direction: Direction, showHidden: Bool, ignore: [String],
        ignoreGoogleDriveNewerDateOnly: Bool
    ) throws -> (diffs: [FileDifference], leftURL: URL, rightURL: URL) {
        // **The LANDING folder, not the root.** `-L iCloud` names a source, and what it has always
        // scanned is that source's documents folder — which is exactly what `landingPath` still
        // resolves to now that a source's root is the account above it. Scanning `rootPath` would
        // silently widen every provider-addressed CLI run to the whole account. A path-addressed
        // root is unaffected: it is its own root with an empty `openAt`, so the two agree.
        let leftURL = URL(fileURLWithPath: expandPath(left.landingPath))
        let rightURL = URL(fileURLWithPath: expandPath(right.landingPath))

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

    // MARK: scan

    public func runScan(
        left: String, right: String,
        direction: Direction, showHidden: Bool, ignore: [String],
        json: Bool
    ) async throws {
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
                printOut(jsonString)
            }
        } else {
            if diffs.isEmpty {
                printOut("No differences found between")
                printOut("  Left : \(leftURL.path)")
                printOut("  Right: \(rightURL.path)")
                return
            }

            printOut("Differences (\(diffs.count)):")
            printOut("  Left : \(leftURL.path) [\(leftProvider.displayName)]")
            printOut("  Right: \(rightURL.path) [\(rightProvider.displayName)]")
            printOut("")

            for diff in diffs {
                let type = DifferenceProcessing.typeString(diff.type)
                let action = DifferenceProcessing.actionString(diff.action)
                printOut("- [\(type)] [\(action)] \(diff.relativePath)")
                printOut("    \(diff.description)")
            }
        }
    }

    // MARK: sync

    public func runSync(
        left: String, right: String,
        direction: Direction, showHidden: Bool, ignore: [String],
        strategy: CollisionStrategy, yes: Bool, failFast: Bool, verify: Bool
    ) async throws {
        let (leftProvider, rightProvider, ignoreDriveDateNoise) = try await resolveProviders(left: left, right: right)
        let scanResult = try scanForDifferences(
            left: leftProvider, right: rightProvider,
            direction: direction, showHidden: showHidden, ignore: ignore,
            ignoreGoogleDriveNewerDateOnly: ignoreDriveDateNoise
        )
        var diffs = scanResult.diffs
        let (leftURL, rightURL) = (scanResult.leftURL, scanResult.rightURL)

        // Stamp both ends of every planned row NOW, while the scan that produced them is the
        // current truth, and re-check each one immediately before its own write (below).
        //
        // Everything between here and the write is time the plan spends aging: `--verify` hashes
        // first, and then the [y/N] prompt sits there for however long the user takes. Nothing
        // looked at the files again in between, so a right-side file rewritten while the prompt
        // waited was overwritten by the stale left copy the plan had chosen — recoverable from
        // the Trash, but below the bar the app itself sets, which re-stats both ends before it
        // writes. The CLI should not be the weaker path onto the same data.
        //
        // Taken BEFORE `--verify` rather than after, so an unmoved stamp also certifies the
        // verification: a pair neither end of which has changed since before it was hashed is
        // still described by the verdict that hashing produced.
        let stampFM = env.fileManager
        let planStamps = Dictionary(uniqueKeysWithValues: diffs.map {
            ($0.id, FilePairStamp.read($0, fileManager: stampFM))
        })

        if verify {
            printOut("Verifying files with matching sizes...")
            let (kept, verifiedCount) = await DifferenceProcessing.partitionByVerification(diffs) { diff in
                await env.verifyFilesHaveSameContent(diff.leftItemPath, diff.rightItemPath)
            }
            diffs = kept
            if verifiedCount > 0 {
                printOut("Skipped \(verifiedCount) files that verified as identical.")
            }
        }

        if diffs.isEmpty {
            printOut("Nothing to sync - no differences found.")
            return
        }

        printOut("Planned operations (\(diffs.count)):")
        for diff in diffs {
            let arrow = diff.action == .copyToRight ? "→" : "←"
            printOut("- \(diff.relativePath) \(arrow) [\(DifferenceProcessing.typeString(diff.type))]")
        }

        if !yes {
            printOut("")
            env.writeOut("Proceed with these operations? [y/N]: ")
            guard let line = env.readConfirmationLine(), line.lowercased().hasPrefix("y") else {
                printOut("Aborted.")
                return
            }
        }

        let fm = env.fileManager
        var tally = SyncTally()

        for diff in diffs {
            let (sourcePath, targetPath) = DifferenceProcessing.sourceAndTarget(for: diff)
            let sourceURL = URL(fileURLWithPath: sourcePath)
            var targetURL = URL(fileURLWithPath: targetPath)

            // Match the app's pre-write guard: never write a name the DESTINATION provider forbids
            // (Dropbox trailing space/period; OneDrive forbidden chars, reserved names, affixes).
            // The app prompts to sanitize; non-interactively we skip with a clear message, because
            // writing it would create a local-only file the provider silently never uploads.
            // Validate the TARGET's own relative path, not diff.relativePath (the left spelling):
            // for .nameConflict rows the write lands on the destination's existing, provider-valid
            // path (e.g. left "Swimming " → right "Swimming"), which must not be skipped.
            let targetProvider = diff.action == .copyToRight ? rightProvider : leftProvider
            let targetRoot = diff.action == .copyToRight ? rightURL : leftURL
            let validatedRelativePath = DifferenceProcessing.targetRelativePath(for: diff, targetRoot: targetRoot)
            if let violation = ProviderNameRules.violation(inRelativePath: validatedRelativePath, for: targetProvider.type) {
                env.writeErr("Skipping \(diff.relativePath): \(violation.reason) \(targetProvider.displayName) would not upload it.\n")
                // Carry the rule text into the tally so the stdout summary can list
                // "path — reason" inline (the stderr line above scrolls away / can be redirected).
                tally.recordSkipped(relativePath: diff.relativePath, reason: .nameViolation,
                                    detail: violation.reason)
                continue
            }

            // Re-check the plan against the disk, at the point of writing (see `planStamps`).
            // Both ends, not just the destination: a source rewritten since the plan was drawn
            // means the bytes about to be copied are not the bytes anything measured, and a
            // source caught mid-write copies a torn file.
            //
            // Per row, not a whole-run abort. On an actively synced cloud folder — which is the
            // only place this fires — one moving file must not cost the other 499, and a run
            // that refuses wholesale just meets the next daemon write on the re-run.
            //
            // Checked before the collision strategy resolves, so the message names the real
            // cause: under `--strategy skip` a destination that APPEARED during the prompt would
            // otherwise be filed as an ordinary collision, which reads as policy rather than as
            // the plan having gone stale. Under `--strategy keep-both` the write would land on a
            // uniquified name and overwrite nothing, and it is still refused: the plan the user
            // approved said this destination was a different file (or no file), and minting a
            // "name 2" beside something it never saw is not what they approved either.
            if let side = planStamps[diff.id]?.sideThatChanged(of: diff, fileManager: fm) {
                let sourceSide: FilePairStamp.Side = diff.action == .copyToRight ? .left : .right
                let reason = "the \(side == sourceSide ? "source" : "destination") changed after the plan was shown"
                env.writeErr("Skipping \(diff.relativePath): \(reason). Re-run sync to see the current plan.\n")
                tally.recordSkipped(relativePath: diff.relativePath, reason: .changedSincePlan,
                                    detail: reason)
                continue
            }

            switch resolveCollision(strategy: strategy, targetExists: fm.fileExists(atPath: targetURL.path)) {
            case .skip:
                tally.recordSkipped(relativePath: diff.relativePath, reason: .collision)
                continue
            case .copyToUnique:
                targetURL = FileSyncManager.generateUniqueURL(for: targetURL, fileManager: fm)
            case .proceed:
                break
            }

            do {
                // `replaced` is true exactly when an existing destination was replaced
                // (safeCopy backs it up to the Trash), which is what the summary reports.
                let replaced = try env.performFileSync(sourceURL, targetURL, fm)
                tally.recordCopied(replacedExisting: replaced)
            } catch {
                tally.recordFailed()
                let message = "Failed to sync \(diff.relativePath): \(error.localizedDescription)"
                await env.logError(message)
                env.writeErr(message + "\n")

                if failFast {
                    env.writeErr("Aborting due to --fail-fast.\n")
                    throw error
                }
            }
        }

        printOut("")
        let summary = syncSummary(tally: tally, strategy: strategy)
        for line in summary.stdoutLines { printOut(line) }
        for line in summary.stderrLines { env.writeErr(line + "\n") }
        // Partial failures must be visible to scripts, not just in the text summary. Thrown
        // after the summary so the counts still print; the shell's flushingLogToDisk flushes
        // on this throw path too. (--fail-fast still aborts immediately above, before the
        // summary.)
        if summary.exitNonzero {
            throw CLISyncFailuresError()
        }
    }

    // MARK: providers

    public func runProviders() async {
        let providers = await env.discoverSnapshot().providers
        if providers.isEmpty {
            printOut("No providers discovered.")
            return
        }

        printOut("Discovered providers:")
        for provider in providers {
            printOut("- \(provider.id)")
            printOut("    name : \(provider.displayName)")
            printOut("    type : \(provider.type.rawValue)")
            printOut("    path : \(provider.rootPath)")
        }
    }
}
