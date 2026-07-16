import Testing
import Foundation
import Sync
@testable import SyncCloudCLICore

/// End-to-end tests for the extracted command bodies (`CommandRunner`): every edge — settings
/// discovery, stdout/stderr, the prompt, the copy primitive, verification, the failure log —
/// is injected, so output and exit behavior pin exactly without spawning processes or
/// depending on filesystem permissions. Scans run against real temp trees (the diff engine is
/// exercised for real, as in the shipped binary).
@Suite struct CommandRunnerTests {

    // MARK: Recording environment

    /// Captures everything the runner writes/does. Single-threaded per test.
    private final class Recorder: @unchecked Sendable {
        var out = ""
        var err = ""
        var copies: [(source: URL, target: URL)] = []
        var loggedErrors: [String] = []
    }

    private struct InjectedCopyError: Error, Equatable {
        var localizedDescription: String { "injected copy failure" }
    }

    private func makeRunner(
        _ recorder: Recorder,
        providers: [CloudProvider] = [],
        ignoreDriveDateNoise: Bool = false,
        readLine: @escaping () -> String? = { nil },
        performFileSync: ((URL, URL, FileManager) throws -> Bool)? = nil,
        verify: @escaping (String, String) async -> Bool? = { _, _ in nil }
    ) -> CommandRunner {
        CommandRunner(environment: .init(
            discoverSnapshot: {
                AppSettingsSnapshot(providers: providers, ignoreGoogleDriveNewerDateOnly: ignoreDriveDateNoise)
            },
            logError: { recorder.loggedErrors.append($0) },
            writeOut: { recorder.out += $0 },
            writeErr: { recorder.err += $0 },
            readConfirmationLine: readLine,
            fileManager: .default,
            performFileSync: performFileSync ?? { source, target, _ in
                recorder.copies.append((source, target))
                return false
            },
            verifyFilesHaveSameContent: verify
        ))
    }

    /// A fresh canonicalized temp dir (the engine yields /private/var/... child URLs, and the
    /// relative-path trim matches roots by exact prefix — same rationale as Sync's TestSupport).
    private func makeTempRoot() throws -> URL {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("CLIRunnerTest-\(UUID().uuidString)")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let canonical = try raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        return URL(fileURLWithPath: canonical ?? raw.path, isDirectory: true)
    }

    private func write(_ url: URL, _ contents: String, mtime: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    // MARK: Argument validation / provider resolution

    @Test func scanRejectsAnUnknownProviderOrPathAsValidation() async throws {
        let rec = Recorder()
        let runner = makeRunner(rec)
        await #expect(throws: CLIValidationError(message: "Path or provider 'no-such-provider' for Left could not be found.")) {
            try await runner.runScan(left: "no-such-provider", right: "/tmp",
                                     direction: .auto, showHidden: false, ignore: [], json: false)
        }
        #expect(rec.out.isEmpty)
    }

    @Test func scanRejectsAProviderWhoseRootIsUnmounted() async throws {
        let missingRoot = "/nonexistent-root-\(UUID().uuidString)"
        let provider = CloudProvider(id: "dropbox", displayName: "Dropbox", imageName: "folder",
                                     path: missingRoot, type: .dropBox)
        let rec = Recorder()
        let runner = makeRunner(rec, providers: [provider])
        await #expect(throws: CLIValidationError(message:
            "Root '\(missingRoot)' of provider 'Dropbox' (Right) does not exist. The provider may be unmounted or signed out.")) {
            try await runner.runScan(left: "/tmp", right: "dropbox",
                                     direction: .auto, showHidden: false, ignore: [], json: false)
        }
    }

    @Test func syncSurfacesTheSameValidationErrors() async throws {
        let rec = Recorder()
        let runner = makeRunner(rec)
        await #expect(throws: CLIValidationError(message: "Path or provider 'nope' for Right could not be found.")) {
            try await runner.runSync(left: "/tmp", right: "nope",
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: true, failFast: false, verify: false)
        }
    }

    // MARK: scan output

    @Test func scanPrintsNoDifferencesForIdenticalTrees() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try write(left.appendingPathComponent("same.txt"), "same", mtime: t)
        try write(right.appendingPathComponent("same.txt"), "same", mtime: t)

        let rec = Recorder()
        try await makeRunner(rec).runScan(left: left.path, right: right.path,
                                          direction: .auto, showHidden: false, ignore: [], json: false)

        #expect(rec.out == """
        No differences found between
          Left : \(left.path)
          Right: \(right.path)

        """)
        #expect(rec.err.isEmpty)
    }

    @Test func scanPrintsEachDifferenceWithTypeAndAction() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("only-left.txt"), "abc")

        let rec = Recorder()
        try await makeRunner(rec).runScan(left: left.path, right: right.path,
                                          direction: .auto, showHidden: false, ignore: [], json: false)

        #expect(rec.out.hasPrefix("""
        Differences (1):
          Left : \(left.path) [Left]
          Right: \(right.path) [Right]

        - [missing-on-right] [copy-to-right] only-left.txt
        """))
        #expect(rec.err.isEmpty)
    }

    @Test func scanJSONEmitsTheMachineReadablePayload() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("only-left.txt"), "abc")

        let rec = Recorder()
        try await makeRunner(rec).runScan(left: left.path, right: right.path,
                                          direction: .auto, showHidden: false, ignore: [], json: true)

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(rec.out.utf8)) as? [[String: Any]])
        #expect(payload.count == 1)
        #expect(payload.first?["relativePath"] as? String == "only-left.txt")
        #expect(payload.first?["type"] as? String == "missing-on-right")
        #expect(payload.first?["action"] as? String == "copy-to-right")
        #expect(payload.first?["leftSize"] as? Int == 3)
    }

    @Test func scanHonorsTheDirectionFilter() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("to-right.txt"), "abc")
        try write(right.appendingPathComponent("to-left.txt"), "def")

        let rec = Recorder()
        try await makeRunner(rec).runScan(left: left.path, right: right.path,
                                          direction: .toRight, showHidden: false, ignore: [], json: false)

        #expect(rec.out.contains("to-right.txt"))
        #expect(!rec.out.contains("to-left.txt"))
    }

    // MARK: providers output

    @Test func providersPrintsAPlaceholderWhenNoneDiscovered() async {
        let rec = Recorder()
        await makeRunner(rec).runProviders()
        #expect(rec.out == "No providers discovered.\n")
    }

    @Test func providersListsEachDiscoveredProvider() async {
        let providers = [
            CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "folder", path: "~/Library/Mobile Documents", type: .iCloud),
            CloudProvider(id: "dropbox", displayName: "Dropbox", imageName: "folder", path: "~/Dropbox", type: .dropBox),
        ]
        let rec = Recorder()
        await makeRunner(rec, providers: providers).runProviders()

        #expect(rec.out == """
        Discovered providers:
        - icloud
            name : iCloud Drive
            type : iCloud
            path : ~/Library/Mobile Documents
        - dropbox
            name : Dropbox
            type : Dropbox
            path : ~/Dropbox

        """)
    }

    // MARK: sync — plan, prompt, copies

    @Test func syncReportsNothingToSyncForIdenticalTrees() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }

        let rec = Recorder()
        try await makeRunner(rec).runSync(left: left.path, right: right.path,
                                          direction: .auto, showHidden: false, ignore: [],
                                          strategy: .replace, yes: true, failFast: false, verify: false)

        #expect(rec.out == "Nothing to sync - no differences found.\n")
        #expect(rec.copies.isEmpty)
    }

    @Test func syncWithoutYesAbortsWhenThePromptIsDeclined() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "abc")

        let rec = Recorder()
        try await makeRunner(rec, readLine: { "n" }).runSync(
            left: left.path, right: right.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: false, failFast: false, verify: false)

        #expect(rec.out.contains("Planned operations (1):"))
        #expect(rec.out.contains("- a.txt → [missing-on-right]"))
        #expect(rec.out.contains("Proceed with these operations? [y/N]: "))
        #expect(rec.out.hasSuffix("Aborted.\n"))
        #expect(rec.copies.isEmpty, "a declined prompt must not copy anything")
    }

    @Test func syncWithoutYesProceedsWhenThePromptIsAccepted() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "abc")

        let rec = Recorder()
        try await makeRunner(rec, readLine: { "yes" }).runSync(
            left: left.path, right: right.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: false, failFast: false, verify: false)

        #expect(rec.copies.count == 1)
        #expect(rec.copies.first?.target.path == right.appendingPathComponent("a.txt").path)
        #expect(rec.out.hasSuffix("\nSync complete. Copied: 1, Skipped: 0, Failed: 0.\n"),
                "the clean-run summary closes stdout: \(rec.out)")
    }

    // MARK: sync — failures

    @Test func syncPartialFailurePrintsTheSummaryThenSignalsANonzeroExit() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("bad.txt"), "abc")
        try write(left.appendingPathComponent("good.txt"), "def")

        let rec = Recorder()
        let runner = makeRunner(rec, performFileSync: { source, target, _ in
            if source.lastPathComponent == "bad.txt" { throw InjectedCopyError() }
            rec.copies.append((source, target))
            return false
        })

        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(left: left.path, right: right.path,
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: true, failFast: false, verify: false)
        }

        #expect(rec.copies.count == 1, "the failure must not stop the remaining copies")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 0, Failed: 1."),
                "the summary still prints before the nonzero exit")
        #expect(rec.err.contains("Failed to sync bad.txt:"))
        #expect(rec.err.contains("1 file(s) failed to sync (errors above); exiting with a non-zero status."))
        #expect(rec.loggedErrors.count == 1, "the failure reaches the app log too")
    }

    @Test func syncFailFastRethrowsTheCopyErrorBeforeAnySummary() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "abc")
        try write(left.appendingPathComponent("b.txt"), "def")

        let rec = Recorder()
        let runner = makeRunner(rec, performFileSync: { _, _, _ in throw InjectedCopyError() })

        await #expect(throws: InjectedCopyError()) {
            try await runner.runSync(left: left.path, right: right.path,
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: true, failFast: true, verify: false)
        }

        #expect(rec.err.contains("Aborting due to --fail-fast.\n"))
        #expect(!rec.out.contains("Sync complete."), "--fail-fast aborts before the summary")
    }

    // MARK: sync — the provider-name pre-write guard

    @Test func syncSkipsANameTheDestinationProviderForbidsButCopiesTheRest() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        // "Swimming " (trailing space) violates Dropbox's name rules; normal.txt does not.
        try write(left.appendingPathComponent("Swimming "), "splash")
        try write(left.appendingPathComponent("normal.txt"), "fine")
        let dropbox = CloudProvider(id: "dropbox-test", displayName: "Dropbox", imageName: "folder",
                                    path: right.path, type: .dropBox)
        let expectedReason = try #require(
            ProviderNameRules.violation(inRelativePath: "Swimming ", for: .dropBox)?.reason)

        let rec = Recorder()
        try await makeRunner(rec, providers: [dropbox]).runSync(
            left: left.path, right: "dropbox-test",
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: true, failFast: false, verify: false)

        // Exactly one copy: the valid name. The violating one is skipped BEFORE any write.
        #expect(rec.copies.map(\.source.lastPathComponent) == ["normal.txt"])
        #expect(rec.err == "Skipping Swimming : \(expectedReason) Dropbox would not upload it.\n")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 1, Failed: 0."))
        #expect(rec.out.contains("Skipped 1 file(s) (name not allowed by the destination provider):"))
        #expect(rec.out.contains("  Swimming  — \(expectedReason)"))
    }

    // MARK: sync — collision strategies

    @Test func syncSkipStrategyLeavesExistingDestinationsUntouched() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("changed.txt"), "left version, longer",
                  mtime: Date(timeIntervalSince1970: 1_700_100_000))
        try write(right.appendingPathComponent("changed.txt"), "right",
                  mtime: Date(timeIntervalSince1970: 1_700_000_000))

        let rec = Recorder()
        try await makeRunner(rec).runSync(left: left.path, right: right.path,
                                          direction: .auto, showHidden: false, ignore: [],
                                          strategy: .skip, yes: true, failFast: false, verify: false)

        #expect(rec.copies.isEmpty)
        #expect(rec.out.contains("Sync complete. Copied: 0, Skipped: 1, Failed: 0."))
        #expect(rec.out.contains("Skipped 1 file(s) (existing files left untouched; use --strategy replace to update them):"))
    }

    @Test func syncKeepBothStrategyCopiesToAUniqueName() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("changed.txt"), "left version, longer",
                  mtime: Date(timeIntervalSince1970: 1_700_100_000))
        try write(right.appendingPathComponent("changed.txt"), "right",
                  mtime: Date(timeIntervalSince1970: 1_700_000_000))

        let rec = Recorder()
        try await makeRunner(rec).runSync(left: left.path, right: right.path,
                                          direction: .auto, showHidden: false, ignore: [],
                                          strategy: .keepBoth, yes: true, failFast: false, verify: false)

        #expect(rec.copies.count == 1)
        let target = try #require(rec.copies.first?.target)
        #expect(target.lastPathComponent != "changed.txt", "keep-both must uniquify, not overwrite")
        #expect(target.deletingLastPathComponent().path == right.path)
    }

    // MARK: sync — --verify

    @Test func syncVerifyDropsSameSizeFilesThatVerifyIdentical() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        // Same bytes, different mtimes → a date-only, sizes-match difference.
        try write(left.appendingPathComponent("dated.txt"), "same bytes",
                  mtime: Date(timeIntervalSince1970: 1_700_100_000))
        try write(right.appendingPathComponent("dated.txt"), "same bytes",
                  mtime: Date(timeIntervalSince1970: 1_700_000_000))

        let rec = Recorder()
        try await makeRunner(rec, verify: { _, _ in true }).runSync(
            left: left.path, right: right.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: true, failFast: false, verify: true)

        #expect(rec.out == """
        Verifying files with matching sizes...
        Skipped 1 files that verified as identical.
        Nothing to sync - no differences found.

        """)
        #expect(rec.copies.isEmpty)
    }
}
