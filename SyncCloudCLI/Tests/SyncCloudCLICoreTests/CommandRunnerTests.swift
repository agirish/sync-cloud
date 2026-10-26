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

    /// A held row's direction is a guess `sync` will not take, and `scan` printed it as a plan in
    /// both forms. The text marks it, and the JSON says so in a field a script can filter on — set
    /// on every row, so the decided row beside it reads `false` rather than nothing.
    @Test func scanMarksTheRowsSyncLeavesForADecision() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try write(left.appendingPathComponent("a-held.txt"), "left, longer", mtime: t)
        try write(right.appendingPathComponent("a-held.txt"), "right", mtime: t)
        try write(left.appendingPathComponent("b-plain.txt"), "abc")

        let text = Recorder()
        try await makeRunner(text).runScan(left: left.path, right: right.path,
                                           direction: .auto, showHidden: false, ignore: [], json: false)
        #expect(text.out.contains("- [different] [needs-decision] a-held.txt\n"), "\(text.out)")
        #expect(text.out.contains("- [missing-on-right] [copy-to-right] b-plain.txt\n"))

        let json = Recorder()
        try await makeRunner(json).runScan(left: left.path, right: right.path,
                                           direction: .auto, showHidden: false, ignore: [], json: true)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])
        let rows = Dictionary(uniqueKeysWithValues: payload.compactMap { row in
            (row["relativePath"] as? String).map { ($0, row) } })
        let held = try #require(rows["a-held.txt"]), plain = try #require(rows["b-plain.txt"])
        #expect(held["needsDecision"] as? Bool == true)
        #expect(held["heldBack"] as? String == "sizes-differ-without-a-newer-side")
        #expect(plain["needsDecision"] as? Bool == false)
        #expect(plain["heldBack"] == nil)
    }

    /// **A file's name is printed as it is on disk, in the text listing and the JSON** (FC10). The
    /// fold is for the tool's own words: "Bob’s.txt" folded to "Bob's.txt" names a file that does
    /// not exist when pasted back into a shell. The names are curly so a fold would show.
    @Test func scanPrintsFileNamesVerbatimInTextAndJSON() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("Bob’s.txt"), "abc")
        try write(left.appendingPathComponent("“Report – Final”.pdf"), "def")

        let text = Recorder()
        try await makeRunner(text).runScan(left: left.path, right: right.path,
                                           direction: .auto, showHidden: false, ignore: [], json: false)
        #expect(text.out.contains("- [missing-on-right] [copy-to-right] Bob’s.txt\n"), "\(text.out)")
        #expect(text.out.contains("- [missing-on-right] [copy-to-right] “Report – Final”.pdf\n"), "\(text.out)")

        let json = Recorder()
        try await makeRunner(json).runScan(left: left.path, right: right.path,
                                           direction: .auto, showHidden: false, ignore: [], json: true)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]], "\(json.out)")
        #expect(Set(payload.compactMap { $0["relativePath"] as? String }) == ["Bob’s.txt", "“Report – Final”.pdf"])
    }

    /// **Every name prints exactly as it is; only the words around it are ASCII** (FC10, RE3).
    /// Every root, file name and provider id and display name below carries `Q’Q` and `R–R`, and
    /// every surface that prints one is run: scan's listing, a sync that fails a copy, skips a
    /// stale row and a name the destination refuses and holds a row, `providers`, and
    /// `restructure`'s text and its failure. Each output must carry the tokens as written, never
    /// `Q'Q` or `R-R`, and nothing else curly — so a missed fold of a shared sentence and a fold
    /// over a name both turn it red.
    @Test func namesPrintVerbatimWhileTheToolsWordsAreASCII() async throws {
        let base = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("Q’Q R–R left"), right = base.appendingPathComponent("Q’Q R–R right")
        let outside = base.appendingPathComponent("outside")
        try write(outside.appendingPathComponent("o.txt"), "outside")
        let leftProvider = CloudProvider(id: "Q’Q-R–R-left", displayName: "Q’Q R–R Left", imageName: "folder",
                                         rootPath: left.path, type: .localFolder)
        let rightProvider = CloudProvider(id: "Q’Q-R–R-dropbox", displayName: "Q’Q R–R Dropbox", imageName: "folder",
                                          rootPath: right.path, type: .dropBox)
        let providers = [leftProvider, rightProvider]

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try write(left.appendingPathComponent("Q’Q R–R a.txt"), "copies")
        try write(left.appendingPathComponent("Q’Q R–R fail.txt"), "fails")
        try write(left.appendingPathComponent("Q’Q R–R stale.txt"), "planned")
        try write(left.appendingPathComponent("Q’Q R–R trail "), "Dropbox refuses the name")
        // A name-conflict row: the description quotes both on-disk spellings (RE2).
        try write(left.appendingPathComponent("Q’Q R–R n.txt "), "newer")
        try write(right.appendingPathComponent("Q’Q R–R n.txt"), "older", mtime: old)
        // A held folder: the description quotes the link inside it (RE2).
        try write(left.appendingPathComponent("Q’Q R–R dir/inside.txt"), "kept")
        try FileManager.default.createSymbolicLink(
            at: left.appendingPathComponent("Q’Q R–R dir/Q’Q R–R link"), withDestinationURL: outside)

        let folded = ["Q'Q", "R-R"]
        func expectVerbatim(_ output: String, _ surface: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(output.contains("Q’Q") && output.contains("R–R"), "\(surface): no token printed\n\(output)",
                    sourceLocation: sourceLocation)
            for form in folded {
                #expect(!output.contains(form), "\(surface): a name was folded to \(form)\n\(output)",
                        sourceLocation: sourceLocation)
            }
            let words = output.replacingOccurrences(of: "Q’Q", with: "").replacingOccurrences(of: "R–R", with: "")
            let curly = words.unicodeScalars.filter { "‘’“”…–—".unicodeScalars.contains($0) }
            #expect(curly.isEmpty, "\(surface): the tool's words carry \(String(String.UnicodeScalarView(curly)))\n\(output)",
                    sourceLocation: sourceLocation)
        }

        // scan
        let scan = Recorder()
        try await makeRunner(scan, providers: providers).runScan(
            left: leftProvider.id, right: rightProvider.id,
            direction: .auto, showHidden: false, ignore: [], json: false)
        expectVerbatim(scan.out, "scan")
        #expect(scan.out.contains("  Left : \(left.path) [Q’Q R–R Left]\n"), "\(scan.out)")
        #expect(scan.out.contains("""
            - [missing-on-right] [copy-to-right] Q’Q R–R a.txt
                Missing on right (Q’Q R–R Dropbox)

            """), "\(scan.out)")
        #expect(scan.out.contains("""
            - [name-conflict] [copy-to-right] Q’Q R–R n.txt\u{20}
                Names differ by a trailing space: "Q’Q R–R n.txt " (Q’Q R–R Left) vs "Q’Q R–R n.txt" (Q’Q R–R Dropbox)

            """), "\(scan.out)")
        let heldNote = "Folder missing on right (Q’Q R–R Dropbox) - \"Q’Q R–R dir/Q’Q R–R link\" inside it is a "
            + "link, so a copy would carry the link, not what it points to"
        #expect(scan.out.contains("- [missing-on-right] [needs-decision] Q’Q R–R dir\n    \(heldNote)\n"), "\(scan.out)")

        // sync: one copy fails, one row goes stale at the prompt, one name is refused, one is held
        let sync = Recorder()
        let stale = left.appendingPathComponent("Q’Q R–R stale.txt")
        let runner = makeRunner(sync, providers: providers, readLine: {
            try? Data("rewritten at the prompt".utf8).write(to: stale)
            return "y"
        }, performFileSync: { source, target, _ in
            guard source.lastPathComponent != "Q’Q R–R fail.txt" else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
                    NSLocalizedDescriptionKey: "The file “Q’Q R–R fail.txt” couldn’t be opened."])
            }
            sync.copies.append((source, target))
            return false
        })
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(left: leftProvider.id, right: rightProvider.id,
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: false, failFast: false, verify: false)
        }
        expectVerbatim(sync.out, "sync stdout")
        expectVerbatim(sync.err, "sync stderr")
        #expect(Set(sync.copies.map(\.source.lastPathComponent)) == ["Q’Q R–R a.txt", "Q’Q R–R n.txt "])
        #expect(sync.out.contains("  Right: \(right.path) [Q’Q R–R Dropbox]\n"), "\(sync.out)")
        #expect(sync.out.contains("- Q’Q R–R a.txt → [missing-on-right]\n"), "\(sync.out)")
        #expect(sync.out.contains("- Q’Q R–R dir [missing-on-right] \(heldNote)\n"), "\(sync.out)")
        #expect(sync.out.contains("""
            Skipped 1 file(s) (name not allowed by the destination provider):
              Q’Q R–R trail  - Dropbox doesn't allow names ending with a space.
            Skipped 1 file(s) that changed after the plan was shown; re-run sync to see the current plan:
              Q’Q R–R stale.txt - the source changed after the plan was shown
            Left 1 item(s) for you to decide, each with its reason:
              Q’Q R–R dir - \(heldNote)

            """), "\(sync.out)")
        #expect(sync.err.contains("Failed to sync Q’Q R–R fail.txt: The file \"Q’Q R–R fail.txt\" couldn't be opened.\n"),
                "\(sync.err)")
        #expect(sync.err.contains("Skipping Q’Q R–R stale.txt: the source changed after the plan was shown. "
                                  + "Re-run sync to see the current plan.\n"), "\(sync.err)")
        #expect(sync.err.contains("Skipping Q’Q R–R trail : Dropbox doesn't allow names ending with a space. "
                                  + "Q’Q R–R Dropbox would not upload it.\n"), "\(sync.err)")
        // The app's log takes the line as written, unfolded, like every other line in it.
        #expect(sync.loggedErrors == ["Failed to sync Q’Q R–R fail.txt: The file “Q’Q R–R fail.txt” couldn’t be opened."])

        // providers
        let listing = Recorder()
        await makeRunner(listing, providers: providers).runProviders()
        expectVerbatim(listing.out, "providers")
        #expect(listing.out.contains("""
            - Q’Q-R–R-dropbox
                name : Q’Q R–R Dropbox
                type : Dropbox
                path : \(right.path)

            """), "\(listing.out)")

        // restructure: its text, and the failure that names the directory
        let profiles = base.appendingPathComponent("Q’Q R–R profiles")
        try write(profiles.appendingPathComponent("profiles.json"),
                  #"{ "schemaVersion": 1, "activeProfileId": "q’q" }"#)
        try write(profiles.appendingPathComponent("q’q/folder-profile.json"), """
            {
              "schemaVersion": 1, "profileId": "q’q", "root": "~/Q’Q R–R",
              "folders": [
                { "path": "Q’Q R–R", "fileCount": 0, "subfolderCount": 3, "anchors": [], "axes": {} },
                { "path": "Q’Q R–R/2023", "fileCount": 0, "subfolderCount": 1, "anchors": [], "axes": {} },
                { "path": "Q’Q R–R/2023/R–R Claims", "fileCount": 4, "subfolderCount": 0, "anchors": [], "axes": {} },
                { "path": "Q’Q R–R/2024", "fileCount": 0, "subfolderCount": 1, "anchors": [], "axes": {} },
                { "path": "Q’Q R–R/2024/R–R Claims", "fileCount": 2, "subfolderCount": 0, "anchors": [], "axes": {} },
                { "path": "Q’Q R–R/2025", "fileCount": 2, "subfolderCount": 0, "anchors": [], "axes": {} }
              ]
            }
            """)
        var restructure = ""
        try RestructureReporting.run(profilesDirectory: profiles, json: false) { restructure += $0 }
        expectVerbatim(restructure, "restructure")
        #expect(restructure.contains("  [backlog] Q’Q R–R/2025 - 2 files, no folders yet (scaffold R–R Claims)\n"),
                "\(restructure)")
        let unread = base.appendingPathComponent("Q’Q R–R empty")
        try FileManager.default.createDirectory(at: unread, withIntermediateDirectories: true)
        do {
            try RestructureReporting.run(profilesDirectory: unread, json: false) { _ in }
            Issue.record("a directory with no profiles.json was reported on")
        } catch let error as CLIValidationError {
            expectVerbatim(error.message, "restructure failure")
            #expect(error.message.hasPrefix("No active profile in \(unread.path). "), "\(error.message)")
        }
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

    /// **A declined prompt exits non-zero** (review E2). It returned normally — exit 0 — and the
    /// README defines 0 as "every planned file was copied", which a declined run never is.
    @Test func syncWithoutYesAbortsWhenThePromptIsDeclined() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "abc")

        let rec = Recorder()
        let runner = makeRunner(rec, readLine: { "n" })
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(
                left: left.path, right: right.path,
                direction: .auto, showHidden: false, ignore: [],
                strategy: .replace, yes: false, failFast: false, verify: false)
        }

        #expect(rec.out.contains("Planned operations (1):"))
        #expect(rec.out.contains("- a.txt → [missing-on-right]"))
        #expect(rec.out.contains("Proceed with these operations? [y/N]: "))
        #expect(rec.out.hasSuffix("Aborted.\n"))
        #expect(rec.err == "Nothing was synced: the prompt was declined.\n")
        #expect(rec.copies.isEmpty, "a declined prompt must not copy anything")
    }

    /// The other abort: stdin closed, so the prompt reads nothing at all — a script that forgot
    /// `--yes`. Same exit, its own stderr line naming the flag.
    @Test func syncWithoutYesAbortsWhenThePromptGetsNoAnswer() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "abc")

        let rec = Recorder()
        let runner = makeRunner(rec, readLine: { nil })
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(
                left: left.path, right: right.path,
                direction: .auto, showHidden: false, ignore: [],
                strategy: .replace, yes: false, failFast: false, verify: false)
        }

        #expect(rec.out.hasSuffix("Aborted.\n"))
        #expect(rec.err == "Nothing was synced: no answer at the prompt (input closed). Pass --yes to sync without asking.\n")
        #expect(rec.copies.isEmpty)
    }

    /// **The plan names both resolved roots before it asks (FR42).** `sync` listed relative
    /// paths only, so a `-L`/`-R` value that resolved to an unexpected tree was confirmed blind.
    /// Asserted on the text BEFORE the prompt, which is the only part that can inform the answer.
    @Test func syncPlanNamesBothResolvedRootsBeforeThePrompt() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        try write(left.appendingPathComponent("a.txt"), "abc")

        let rec = Recorder()
        let runner = makeRunner(rec, readLine: { "n" })
        // Declined, so it exits non-zero (E2); the text before the prompt is what this pins.
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(
                left: left.path, right: right.path,
                direction: .auto, showHidden: false, ignore: [],
                strategy: .replace, yes: false, failFast: false, verify: false)
        }

        let beforePrompt = try #require(rec.out.components(separatedBy: "Proceed with these operations?").first)
        #expect(beforePrompt.contains("  Left : \(left.path) [Left]\n"))
        #expect(beforePrompt.contains("  Right: \(right.path) [Right]\n"))
        #expect(rec.copies.isEmpty)
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
        await #expect(throws: CLISyncFailuresError()) {
            try await makeRunner(rec, providers: [dropbox]).runSync(
                left: left.path, right: "dropbox-test",
                direction: .auto, showHidden: false, ignore: [],
                strategy: .replace, yes: true, failFast: false, verify: false)
        }

        // Exactly one copy: the valid name. The violating one is skipped BEFORE any write.
        #expect(rec.copies.map(\.source.lastPathComponent) == ["normal.txt"])
        // **The reason is printed with ASCII punctuation** (FC10): the shared sentence is curly in
        // the app, and the tool folds it where it writes — stderr and stdout alike.
        #expect(expectedReason == "Dropbox doesn’t allow names ending with a space.", "the premise: a curly reason")
        #expect(rec.err == "Skipping Swimming : Dropbox doesn't allow names ending with a space. Dropbox would not upload it.\n"
                + "1 file(s) have names the destination provider does not allow and were not synced; exiting with a non-zero status.\n")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 1, Failed: 0."))
        #expect(rec.out.contains("Skipped 1 file(s) (name not allowed by the destination provider):"))
        #expect(rec.out.contains("  Swimming  - Dropbox doesn't allow names ending with a space."))
        #expect(!rec.out.contains("’") && !rec.err.contains("’") && !rec.out.contains("—"))
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
        await #expect(throws: CLISyncFailuresError()) {
            try await makeRunner(rec, providers: [oneDrive]).runSync(
                left: "onedrive-test", right: right.path,
                direction: .auto, showHidden: false, ignore: [],
                strategy: .replace, yes: true, failFast: false, verify: false)
        }

        // Exactly one copy: the valid name. The reserved one is refused BEFORE any write, even
        // though the RIGHT (source) side — an ordinary folder — has no name rules at all.
        #expect(rec.copies.map(\.source.lastPathComponent) == ["normal.txt"])
        #expect(rec.err == "Skipping CON.txt: \(CLIOutput.ascii(expectedReason)) OneDrive (Personal) would not upload it.\n"
                + "1 file(s) have names the destination provider does not allow and were not synced; exiting with a non-zero status.\n")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 1, Failed: 0."))
        #expect(rec.out.contains("  CON.txt - \(CLIOutput.ascii(expectedReason))"))
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
        await #expect(throws: CLISyncFailuresError()) {
            try await makeRunner(rec, providers: [oneDrive]).runSync(
                left: left.path, right: addressedRoot.path,
                direction: .auto, showHidden: false, ignore: [],
                strategy: .replace, yes: true, failFast: false, verify: false)
        }

        #expect(rec.copies.map(\.source.lastPathComponent) == ["ok.txt"],
                "a path-addressed OneDrive root must refuse the reserved name, not copy it")
        // The message names the ad-hoc "Right" label, not "OneDrive (Personal)" — proof the root
        // resolved down the PATH branch and still inherited the account's provider type.
        #expect(rec.err == "Skipping CON.txt: \(CLIOutput.ascii(expectedReason)) Right would not upload it.\n"
                + "1 file(s) have names the destination provider does not allow and were not synced; exiting with a non-zero status.\n")
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
        await #expect(throws: CLISyncFailuresError()) {
            try await makeRunner(rec).runSync(left: left.path, right: right.path,
                                              direction: .auto, showHidden: false, ignore: [],
                                              strategy: .skip, yes: true, failFast: false, verify: false)
        }

        #expect(rec.copies.isEmpty)
        #expect(rec.out.contains("Sync complete. Copied: 0, Skipped: 1, Failed: 0."))
        #expect(rec.out.contains("Skipped 1 file(s) (existing files left untouched; use --strategy replace to update them):"))
        #expect(rec.err == "1 file(s) already existed at the destination and were not synced; exiting with a non-zero status.\n")
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
        // A row skipped as changed since the plan exits non-zero (FR43).
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(left: left.path, right: right.path,
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: false, failFast: false, verify: false)
        }

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
        // A row skipped as changed since the plan exits non-zero (FR43).
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(left: left.path, right: right.path,
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: false, failFast: false, verify: false)
        }

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
        // A row skipped as changed since the plan exits non-zero (FR43).
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(left: left.path, right: right.path,
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: false, failFast: false, verify: false)
        }

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
        // A row skipped as changed since the plan exits non-zero (FR43).
        await #expect(throws: CLISyncFailuresError()) {
            try await runner.runSync(left: left.path, right: right.path,
                                     direction: .auto, showHidden: false, ignore: [],
                                     strategy: .replace, yes: false, failFast: false, verify: false)
        }

        #expect(rec.copies.map(\.source.lastPathComponent).sorted() == ["b-keep.txt", "c-keep.txt"],
                "the rows after the stale one must still be copied")
        #expect(rec.out.contains("Sync complete. Copied: 2, Skipped: 1, Failed: 0."), "\(rec.out)")
        // The summary section itself, not merely the name — the "Planned operations" listing at
        // the top of the run prints every path, so a `contains` on the name alone says nothing
        // about whether the run explained the skip at the end.
        #expect(rec.out.contains("""
        Skipped 1 file(s) that changed after the plan was shown; re-run sync to see the current plan:
          a-moved.txt - the destination changed after the plan was shown
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

    // MARK: sync — rows whose direction is a guess (FileDifference.heldBack)

    /// **A pair whose sizes differ at the same time is left out of the plan, not copied
    /// left-wins (FR39).** With one y/N — under `--yes`, none — every planned row is copied in its
    /// suggested direction, so the old "left as truth" default overwrote the right file. The held
    /// row sorts FIRST (testing law 9): a run that stopped at it would leave `b-missing.txt`
    /// uncopied too. Asserted on the sections, not the whole stream, because the plan and the
    /// summary both name the file.
    @Test func syncLeavesASameTimeDifferentSizePairOutAndCopiesTheRest() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try write(left.appendingPathComponent("a-held.txt"), "left, longer", mtime: t)
        try write(right.appendingPathComponent("a-held.txt"), "right", mtime: t)
        try write(left.appendingPathComponent("b-missing.txt"), "only left")

        let rec = Recorder()
        await #expect(throws: CLISyncFailuresError()) {
            try await makeRunner(rec).runSync(left: left.path, right: right.path,
                                              direction: .auto, showHidden: false, ignore: [],
                                              strategy: .replace, yes: true, failFast: false, verify: false)
        }

        #expect(rec.copies.map(\.source.lastPathComponent) == ["b-missing.txt"])
        // The em dash folded to a hyphen where the tool prints it (FC10).
        let note = "Sizes differ but the dates match within the 1 s tolerance - choose which to keep"
        #expect(rec.out.contains("""
        Planned operations (1):
          Left : \(left.path) [Left]
          Right: \(right.path) [Right]

        - b-missing.txt → [missing-on-right]

        Left for you to decide (1), not synced:
        - a-held.txt [different] \(note)

        """), "\(rec.out)")
        #expect(rec.out.contains("Sync complete. Copied: 1, Skipped: 1, Failed: 0."), "\(rec.out)")
        #expect(rec.out.hasSuffix("""
        Left 1 item(s) for you to decide, each with its reason:
          a-held.txt - \(note)

        """), "\(rec.out)")
        #expect(rec.err == "1 item(s) need your decision and were not synced; exiting with a non-zero status.\n")
    }

    /// **A linked folder is never handed to the copy (FR8).** The scan reads it as the folder it
    /// points to; the copy would write the link. With nothing else to do, the run says so and
    /// copies nothing — no prompt, since there is nothing to approve.
    @Test func syncNeverCopiesALinkedFolderAsALink() async throws {
        let left = try makeTempRoot(), right = try makeTempRoot(), original = try makeTempRoot()
        defer {
            for dir in [left, right, original] { try? FileManager.default.removeItem(at: dir) }
        }
        try write(original.appendingPathComponent("inside.txt"), "real content")
        try FileManager.default.createSymbolicLink(at: left.appendingPathComponent("Linked"),
                                                   withDestinationURL: original)

        let rec = Recorder()
        await #expect(throws: CLISyncFailuresError()) {
            try await makeRunner(rec).runSync(left: left.path, right: right.path,
                                              direction: .auto, showHidden: false, ignore: [],
                                              strategy: .replace, yes: true, failFast: false, verify: false)
        }

        #expect(rec.copies.isEmpty, "the link was handed to the copy: \(rec.copies)")
        #expect(rec.out.hasPrefix("Nothing to sync automatically.\n"), "\(rec.out)")
        #expect(rec.out.contains("""
        - Linked [missing-on-right] Folder missing on right (Right) - it is a link, so a copy would be a link too, not what it points to
        """), "\(rec.out)")
        #expect(rec.out.contains("Sync complete. Copied: 0, Skipped: 1, Failed: 0."), "\(rec.out)")
        #expect(rec.err == "1 item(s) need your decision and were not synced; exiting with a non-zero status.\n",
                "a run that copied nothing exits 1 too")
    }
}
