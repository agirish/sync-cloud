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
                                     rootPath: missingRoot, type: .dropBox)
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
            CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "folder", rootPath: "~/Library/Mobile Documents", type: .iCloud),
            CloudProvider(id: "dropbox", displayName: "Dropbox", imageName: "folder", rootPath: "~/Dropbox", type: .dropBox),
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
                                    rootPath: right.path, type: .dropBox)
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

    // MARK: sync — the right→left direction
    // Every leftward mechanism (the source/target swap, the guard reading the LEFT provider's
    // type, the validated path taken against the LEFT root) was unit-tested in isolation, but the
    // sync loop that composes them only ever ran left→right — so no test could catch them being
    // wired together the wrong way round.

    @Test func syncCopiesRightOnlyFilesLeftwardWithTheEndpointsSwapped() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(right.appendingPathComponent("only-right.txt"), "abc")

        let rec = Recorder()
        try await makeRunner(rec).runSync(left: left.path, right: right.path,
                                          direction: .toLeft, showHidden: false, ignore: [],
                                          strategy: .replace, yes: true, failFast: false, verify: false)

        #expect(rec.out.contains("- only-right.txt ← [missing-on-left]"),
                "the plan must show the leftward arrow: \(rec.out)")
        #expect(rec.copies.count == 1)
        let copy = try #require(rec.copies.first)
        #expect(copy.source.path == right.appendingPathComponent("only-right.txt").path,
                "copying leftward reads from the RIGHT side")
        #expect(copy.target.path == left.appendingPathComponent("only-right.txt").path,
                "copying leftward writes into the LEFT root")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 0, Failed: 0."))
        #expect(rec.err.isEmpty)
    }

    @Test func syncSkipsANameTheLeftProviderForbidsWhenCopyingRightToLeft() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        // "CON" is reserved on OneDrive. The offending file sits on the RIGHT and would be
        // written into the LEFT (OneDrive) root, so it is the LEFT provider's rules that decide.
        try write(right.appendingPathComponent("CON.txt"), "reserved")
        try write(right.appendingPathComponent("normal.txt"), "fine")
        let oneDrive = CloudProvider(id: "onedrive-test", displayName: "OneDrive (Personal)",
                                     imageName: "folder", rootPath: left.path, type: .oneDrive)
        let expectedReason = try #require(
            ProviderNameRules.violation(inRelativePath: "CON.txt", for: .oneDrive)?.reason)

        let rec = Recorder()
        try await makeRunner(rec, providers: [oneDrive]).runSync(
            left: "onedrive-test", right: right.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: true, failFast: false, verify: false)

        // Exactly one copy: the valid name. The reserved one is refused BEFORE any write, even
        // though the RIGHT (source) side — an ordinary folder — has no name rules at all.
        #expect(rec.copies.map(\.source.lastPathComponent) == ["normal.txt"])
        #expect(rec.err == "Skipping CON.txt: \(expectedReason) OneDrive (Personal) would not upload it.\n")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 1, Failed: 0."))
        #expect(rec.out.contains("  CON.txt — \(expectedReason)"))
    }

    @Test func syncLeftwardValidatesTheDestinationSpellingNotTheSourceOne() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        // A name-conflict pair: the LEFT (Dropbox) side already holds the provider-valid spelling,
        // the RIGHT holds the trailing-space doppelganger and is newer, so the row syncs right→left
        // ONTO the existing, valid left path. Validating the source spelling would wrongly skip a
        // write that never creates the offending name.
        try write(left.appendingPathComponent("Swimming"), "old",
                  mtime: Date(timeIntervalSince1970: 1_700_000_000))
        try write(right.appendingPathComponent("Swimming "), "new",
                  mtime: Date(timeIntervalSince1970: 1_700_100_000))
        let dropbox = CloudProvider(id: "dropbox-test", displayName: "Dropbox", imageName: "folder",
                                    rootPath: left.path, type: .dropBox)
        // Premise: the SOURCE spelling really is one Dropbox refuses (otherwise this pins nothing).
        #expect(ProviderNameRules.violation(inRelativePath: "Swimming ", for: .dropBox) != nil)

        let rec = Recorder()
        try await makeRunner(rec, providers: [dropbox]).runSync(
            left: "dropbox-test", right: right.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: true, failFast: false, verify: false)

        #expect(rec.out.contains("- Swimming ← [name-conflict]"),
                "expected one leftward name-conflict row: \(rec.out)")
        #expect(rec.copies.count == 1)
        let copy = try #require(rec.copies.first)
        #expect(copy.source.path == right.appendingPathComponent("Swimming ").path)
        #expect(copy.target.path == left.appendingPathComponent("Swimming").path)
        #expect(rec.err.isEmpty, "the destination spelling is valid, so nothing may be skipped: \(rec.err)")
    }

    // MARK: sync — path-addressed cloud roots
    // A `-L`/`-R` PATH inherits the provider type of whichever discovered provider contains it.
    // `ProviderResolutionTests` pins the resolution; these pin the CONSEQUENCE — that the two
    // type-gated guards actually engage for a path-addressed root, which is what the old fixed
    // `.iCloud` typing silently switched off.

    @Test func syncSkipsAProviderInvalidNameForAPathAddressedOneDriveDestination() async throws {
        let left = try makeTempRoot(), cloud = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: cloud) }
        // A realistic CloudStorage layout: discovery found ".../OneDrive-Personal/Documents", and
        // the user points -R at its sibling ".../OneDrive-Personal/Photos" — a PATH that matches
        // no provider id or display name, but belongs to the same OneDrive account.
        let account = cloud.appendingPathComponent("Library/CloudStorage/OneDrive-Personal")
        let discoveredRoot = account.appendingPathComponent("Documents")
        let addressedRoot = account.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: discoveredRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addressedRoot, withIntermediateDirectories: true)
        try write(left.appendingPathComponent("CON.txt"), "reserved")
        try write(left.appendingPathComponent("ok.txt"), "fine")
        let oneDrive = CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)",
                                     imageName: "folder", rootPath: discoveredRoot.path, type: .oneDrive)
        let expectedReason = try #require(
            ProviderNameRules.violation(inRelativePath: "CON.txt", for: .oneDrive)?.reason)

        let rec = Recorder()
        try await makeRunner(rec, providers: [oneDrive]).runSync(
            left: left.path, right: addressedRoot.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: true, failFast: false, verify: false)

        #expect(rec.copies.map(\.source.lastPathComponent) == ["ok.txt"],
                "a path-addressed OneDrive root must refuse the reserved name, not copy it")
        // The message names the ad-hoc "Right" label, not "OneDrive (Personal)" — proof the root
        // resolved down the PATH branch and still inherited the account's provider type.
        #expect(rec.err == "Skipping CON.txt: \(expectedReason) Right would not upload it.\n")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 1, Failed: 0."))
    }

    @Test func syncAppliesTheDriveDateNoiseFilterToAPathAddressedGoogleDriveRight() async throws {
        let left = try makeTempRoot(), cloud = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: cloud) }
        let driveRoot = cloud.appendingPathComponent("Library/CloudStorage/GoogleDrive-me/My Drive/Documents")
        try FileManager.default.createDirectory(at: driveRoot, withIntermediateDirectories: true)
        // Same size, right newer — exactly the shape Drive manufactures by rewriting file dates.
        try write(left.appendingPathComponent("notes.txt"), "aaaa",
                  mtime: Date(timeIntervalSince1970: 1_700_000_000))
        try write(driveRoot.appendingPathComponent("notes.txt"), "bbbb",
                  mtime: Date(timeIntervalSince1970: 1_700_100_000))
        let drive = CloudProvider(id: "GoogleDrive-me", displayName: "Google Drive (me)",
                                  imageName: "folder", rootPath: driveRoot.path, type: .googleDrive)

        // Control: with the setting off this is a real, syncable difference — so a later "nothing
        // to sync" can only come from the filter, never from the fixture failing to produce a row.
        let control = Recorder()
        try await makeRunner(control, providers: [drive], ignoreDriveDateNoise: false).runSync(
            left: left.path, right: driveRoot.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: true, failFast: false, verify: false)
        #expect(control.out.contains("- notes.txt ← [different]"), "expected a date-only row: \(control.out)")
        #expect(control.copies.count == 1)

        // The copy primitive is injected, so the control run left the fixture untouched.
        let rec = Recorder()
        try await makeRunner(rec, providers: [drive], ignoreDriveDateNoise: true).runSync(
            left: left.path, right: driveRoot.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: true, failFast: false, verify: false)

        #expect(rec.out == "Nothing to sync - no differences found.\n",
                "a path-addressed Drive root must be typed .googleDrive for the filter to engage")
        #expect(rec.copies.isEmpty)
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

    // MARK: sync — the plan is re-checked between the prompt and the write

    /// The plan is executed however long the [y/N] prompt sat there, and nothing looked at the
    /// files again in between. A destination that did not exist when the plan was drawn — the
    /// row reads "missing on right" — can be created by a cloud daemon while the user reads the
    /// list, and `--strategy replace` then overwrites a file the plan never mentioned.
    ///
    /// The mutation is a real write performed from inside the prompt closure, which is exactly
    /// where the window is.
    @Test func syncSkipsARowWhoseDestinationAppearedWhileThePromptWaited() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "from-left")

        let rec = Recorder()
        let arrival = right.appendingPathComponent("a.txt")
        let runner = makeRunner(rec, readLine: {
            try? Data("landed-while-you-read".utf8).write(to: arrival)
            return "y"
        })
        try await runner.runSync(left: left.path, right: right.path,
                                 direction: .auto, showHidden: false, ignore: [],
                                 strategy: .replace, yes: false, failFast: false, verify: false)

        #expect(rec.copies.isEmpty, "the plan said this destination was empty; it is not any more")
        #expect(try Data(contentsOf: arrival) == Data("landed-while-you-read".utf8))
        #expect(rec.out.contains("Sync complete. Copied: 0, Skipped: 1, Failed: 0."), "\(rec.out)")
    }

    /// The case a re-scan alone cannot see. Left is newer than right, so the row is
    /// "left is newer → copy right"; the destination is then rewritten with DIFFERENT bytes at a
    /// timestamp that is still older than left's, so a fresh scan produces a row of exactly the
    /// same shape — same type, same action, same two sizes — and the stale left copy would go
    /// straight over the new bytes.
    @Test func syncSkipsARowWhoseDestinationWasRewrittenUnderTheSamePlanShape() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try write(left.appendingPathComponent("a.txt"), "LLLLLLLLL", mtime: base.addingTimeInterval(100))
        let target = right.appendingPathComponent("a.txt")
        try write(target, "rrrrrrrrr", mtime: base)

        let rec = Recorder()
        let runner = makeRunner(rec, readLine: {
            // Same length, and still older than left: the row's type, action and both sizes are
            // unchanged, so only a reading of the file itself can tell.
            try? write(target, "NNNNNNNNN", mtime: base.addingTimeInterval(50))
            return "y"
        })
        try await runner.runSync(left: left.path, right: right.path,
                                 direction: .auto, showHidden: false, ignore: [],
                                 strategy: .replace, yes: false, failFast: false, verify: false)

        #expect(rec.copies.isEmpty, "the destination is no longer the file the plan measured")
        #expect(try Data(contentsOf: target) == Data("NNNNNNNNN".utf8))
        #expect(rec.out.contains("Sync complete. Copied: 0, Skipped: 1, Failed: 0."), "\(rec.out)")
    }

    /// The other end. A source rewritten while the prompt waited means the bytes about to be
    /// copied are not the bytes the plan (and `--verify`, which runs BEFORE the prompt) was
    /// drawn from — and a source caught mid-write copies a torn file.
    @Test func syncSkipsARowWhoseSourceChangedWhileThePromptWaited() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        let source = left.appendingPathComponent("a.txt")
        try write(source, "planned")

        let rec = Recorder()
        let runner = makeRunner(rec, readLine: {
            try? Data("rewritten-while-you-read".utf8).write(to: source)
            return "y"
        })
        try await runner.runSync(left: left.path, right: right.path,
                                 direction: .auto, showHidden: false, ignore: [],
                                 strategy: .replace, yes: false, failFast: false, verify: false)

        #expect(rec.copies.isEmpty, "these are not the bytes the plan described")
        #expect(rec.out.contains("Sync complete. Copied: 0, Skipped: 1, Failed: 0."), "\(rec.out)")
    }

    /// The re-check is per row, not a whole-run abort, and it names the file. On an actively
    /// synced cloud folder a single moving file must not cost the other 499 — that is a livelock,
    /// since the next run meets the next daemon write.
    @Test func syncCopiesTheUntouchedRowsAndNamesTheOneItSkipped() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        // The stale row sorts FIRST on purpose. With it last, a run that abandoned the whole
        // plan on the first stale row would produce exactly the same copies as one that skipped
        // just that row, and this test would be blind to the difference.
        try write(left.appendingPathComponent("a-moved.txt"), "two")
        try write(left.appendingPathComponent("b-keep.txt"), "one")
        try write(left.appendingPathComponent("c-keep.txt"), "three")

        let rec = Recorder()
        let arrival = right.appendingPathComponent("a-moved.txt")
        let runner = makeRunner(rec, readLine: {
            try? Data("arrived".utf8).write(to: arrival)
            return "y"
        })
        try await runner.runSync(left: left.path, right: right.path,
                                 direction: .auto, showHidden: false, ignore: [],
                                 strategy: .replace, yes: false, failFast: false, verify: false)

        #expect(rec.copies.map(\.source.lastPathComponent).sorted() == ["b-keep.txt", "c-keep.txt"],
                "the rows after the stale one must still be copied")
        #expect(rec.out.contains("Sync complete. Copied: 2, Skipped: 1, Failed: 0."), "\(rec.out)")
        // The summary section itself, not merely the name — the "Planned operations" listing at
        // the top of the run prints every path, so a `contains` on the name alone says nothing
        // about whether the run explained the skip at the end.
        #expect(rec.out.contains("""
        Skipped 1 file(s) that changed after the plan was shown; re-run sync to see the current plan:
          a-moved.txt — the destination changed after the plan was shown
        """), "\(rec.out)")
        #expect(rec.err.contains(
            "Skipping a-moved.txt: the destination changed after the plan was shown. "
            + "Re-run sync to see the current plan.\n"), "\(rec.err)")
    }

    /// The control the four above need: with nothing touched during the prompt, every planned
    /// row still copies. Without it they would pass just as well against a re-check that refuses
    /// everything.
    @Test func syncCopiesEverythingWhenNothingMovedDuringThePrompt() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "one")
        try write(left.appendingPathComponent("b.txt"), "two")

        let rec = Recorder()
        try await makeRunner(rec, readLine: { "y" }).runSync(
            left: left.path, right: right.path,
            direction: .auto, showHidden: false, ignore: [],
            strategy: .replace, yes: false, failFast: false, verify: false)

        #expect(rec.copies.count == 2)
        #expect(rec.out.contains("Sync complete. Copied: 2, Skipped: 0, Failed: 0."), "\(rec.out)")
    }
}
