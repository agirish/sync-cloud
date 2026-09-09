import Foundation
import Testing

/// The app's privacy claim, held to the source.
///
/// **This is the one suite that guards a published promise rather than a behaviour.** Help ▸
/// *Reading your documents* tells the reader, in the app's own words, that SyncCloud has no server,
/// collects no usage statistics and sends no crash reports, and that nothing about their files
/// reaches the developer or anyone else. Every one of those sentences is true at the time of
/// writing and none of them is enforced by anything: the day somebody adds an updater, an analytics
/// call or a crash reporter, the app quietly starts lying to its users and all 1,800-odd other
/// tests stay green. Nothing *fails* when a privacy claim goes stale — which is exactly why it
/// needs a test rather than a comment.
///
/// **The claim is deliberately narrow, and so is the scan.** SyncCloud does reach the network in
/// one place: *Refine with Claude*, which posts to Anthropic's API with a key the user supplies and
/// stores in their own Keychain. The article names that exception itself. So this suite does not
/// assert "no network" — it asserts that the network surface is **exactly** the three files behind
/// that one feature, which is the sentence the article actually makes.
///
/// **A source scan, and the reasons are the ordinary ones for this kind of check.** What is being
/// defended is the absence of code, and a behavioural test cannot observe a call that is not made
/// by any code path a test drives. A `URLProtocol` stub over one flow would prove that flow quiet
/// and say nothing about a launch-time beacon three files away.
///
/// Scoped to **shipped** sources: `MacApp/`, every module's `Sources/`, and the CLI's. Test targets
/// are excluded because a test may legitimately reach for `URLSession` to stub one, and a test's
/// network use never ships.
@Suite struct NoTelemetryTests {

    // MARK: Reading the shipped sources

    /// The repository root, located from this file rather than from a working directory — the test
    /// bundle does not promise one. Same derivation as `macAppDirectory()`.
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)      // …/SyncCloudTests/NoTelemetryTests.swift
            .deletingLastPathComponent()     // …/SyncCloudTests
            .deletingLastPathComponent()     // repo root
    }

    /// Every Swift file that is compiled into something a user installs, as (repo-relative path,
    /// text).
    ///
    /// **Directory-shaped exclusions, not name-shaped.** Any component named `Tests` or ending in
    /// `Tests` goes, which takes all six test targets at once — the modules' `Tests/` directories
    /// and `SyncCloudTests/` alike. That second half is not tidiness: **this very file names
    /// `URLSession` in a string literal**, so a scan that read its own target would report itself
    /// as a telemetry call. `.build`, `DerivedData`, `.dd` and `.claude` are build and worktree
    /// debris that would otherwise let a stale copy of a deleted file answer the question;
    /// `.claude/worktrees` in particular holds whole checkouts of other branches, and reading them
    /// would report another session's in-progress work as this branch's.
    ///
    /// Every one of those names is matched **below the repository root only** — see
    /// `componentsBelowRoot`, which exists because matching them against the whole absolute path
    /// made this suite fail in every worktree CLAUDE.md tells a session to work in.
    private static let shippedSources: [(path: String, text: String)] = {
        let root = repositoryRoot()
        let rootPath = root.standardizedFileURL.path
        let excludedComponents: Set<String> = [".build", ".git", ".claude",
                                               "DerivedData", ".dd", "artifact-src"]
        func isExcluded(_ component: String) -> Bool {
            excludedComponents.contains(component) || component.hasSuffix("Tests")
        }

        /// The components of `url` **below the repository root** — the only ones the exclusions
        /// above may read — or `nil` for a URL that is not under the root at all.
        ///
        /// **Testing the whole absolute path let the checkout's own ancestry answer the
        /// question, and it did.** CLAUDE.md requires every session to work in a worktree under
        /// `<repo>/.claude/worktrees/<name>`, so the repository root itself contained a `.claude`
        /// component; every file beneath it matched, `shippedSources` came back **empty**, and
        /// three tests in this suite failed for a reason that had nothing to do with telemetry.
        /// CI never saw it, because the runner checks out to a path with no excluded component —
        /// so the suite was green on CI and red in the only place anybody was allowed to work.
        ///
        /// The exclusions are about where a file sits **inside** the repository — a `.build` or
        /// `.dd` copy, another branch's whole checkout under `.claude/worktrees` — and where the
        /// repository itself sits is none of their business.
        func componentsBelowRoot(_ url: URL) -> [String]? {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { return nil }
            return String(full.dropFirst(rootPath.count + 1))
                .split(separator: "/").map(String.init)
        }

        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(String, String)] = []
        for case let url as URL in walker {
            guard let components = componentsBelowRoot(url) else { continue }
            if components.contains(where: isExcluded) {
                if url.hasDirectoryPath { walker.skipDescendants() }
                continue
            }
            guard !url.hasDirectoryPath, url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Comment-stripped, for the reason `sourceCodeOnly` exists: prose is not code. The
            // doc comment on Help's own privacy article names these very symbols in order to say
            // which files hold them, and against raw text that sentence reported ITSELF as a
            // telemetry call. A scan a writer has to phrase around is a scan that will eventually
            // be phrased around.
            out.append((components.joined(separator: "/"), sourceCodeOnly(text)))
        }
        return out.sorted { $0.0 < $1.0 }
    }()

    /// The three files behind *Refine with Claude*, and the whole of SyncCloud's network surface.
    ///
    /// Two post to `CloudFilingProtocol.endpoint` (`api.anthropic.com/v1/messages`); the third
    /// checks a pasted key against `api.anthropic.com/v1/models` so Settings can say whether it
    /// works. All three are unreachable without a key the user has stored themselves.
    private static let allowedNetworkFiles: Set<String> = [
        "MacApp/CloudFilingClassifier.swift",
        "MacApp/CloudMappingRefiner.swift",
        "Modules/Sync/Sources/Sync/AnthropicKeyCheck.swift",
    ]

    /// Every way this codebase could open a socket. Named types rather than a general "http"
    /// substring, which the doc comments are full of.
    private static let networkSymbols = [
        "URLSession", "NSURLConnection", "NWConnection", "NWBrowser", "NWListener",
        "CFStreamCreatePairWithSocket", "CFHTTPMessage", "Socket(",
    ]

    // MARK: The scans

    @Test func theScanCanSeeTheSources() {
        #expect(Self.shippedSources.count > 200,
                """
                read \(Self.shippedSources.count) shipped Swift files — the scans below would be \
                near-vacuous. A count at or near zero is not a finding about telemetry: it means \
                the WALK excluded everything, and the usual cause is a repository root that itself \
                sits inside a directory the exclusions name — a checkout under `.claude/worktrees`, \
                `DerivedData` or `.build`. Root read: \(Self.repositoryRoot().path)
                """)
        #expect(Self.shippedSources.contains { $0.path == "MacApp/SyncCloudApp.swift" },
                "MacApp/SyncCloudApp.swift was not read — the walk is not reaching the app")
        #expect(Self.shippedSources.contains { $0.path.hasPrefix("Modules/Sync/Sources/") },
                "no Sync sources were read — the walk is not reaching the modules")
        #expect(!Self.shippedSources.contains { $0.path.contains("/Tests/") },
                "a test target was read as shipped source — the exclusion is not working")
    }

    /// The network surface is exactly the Refine path, and nothing else.
    ///
    /// A new file here is not necessarily wrong — but it is a change to what the app tells its
    /// users, so it belongs in the same commit as the Help copy that describes it.
    @Test func onlyTheRefinePathReachesTheNetwork() {
        var found: Set<String> = []
        for source in Self.shippedSources
        where Self.networkSymbols.contains(where: { source.text.contains($0) }) {
            found.insert(source.path)
        }
        let unexpected = found.subtracting(Self.allowedNetworkFiles).sorted()
        #expect(unexpected.isEmpty,
                """
                \(unexpected.count) shipped file(s) opened a network connection that Help does not \
                account for: \(unexpected.joined(separator: ", ")). Help ▸ Reading your documents \
                tells the reader nothing about their files reaches anyone, and names Refine with \
                Claude as the single exception. Either this call belongs to that feature, or the \
                article needs rewriting in the same commit.
                """)

        let vanished = Self.allowedNetworkFiles.subtracting(found).sorted()
        #expect(vanished.isEmpty,
                """
                \(vanished.joined(separator: ", ")) no longer reaches the network. That may be \
                right — but this suite's allow-list is now looser than the app, and Help still \
                names a feature that may be gone.
                """)
    }

    /// No analytics, crash reporting, telemetry or auto-update SDK is imported anywhere.
    ///
    /// Separate from the socket scan because these arrive as a *dependency*, not as a hand-written
    /// request: the point at which one lands, nobody writes `URLSession` at all.
    @Test func noAnalyticsOrCrashReporterIsImported() {
        let forbidden = ["Sentry", "FirebaseAnalytics", "FirebaseCrashlytics", "Crashlytics",
                         "Mixpanel", "Amplitude", "PostHog", "TelemetryClient", "TelemetryDeck",
                         "Bugsnag", "AppCenter", "Sparkle", "Adjust", "Segment", "Datadog"]
        for source in Self.shippedSources {
            for module in forbidden where source.text.contains("import \(module)") {
                Issue.record("""
                             \(source.path) imports \(module) — SyncCloud claims to collect no \
                             usage statistics and send no crash reports
                             """)
            }
        }
    }

    /// The shipped app links no third-party code at all.
    ///
    /// `project.yml` is the app target's only package list, and every entry in it is a `path:` to a
    /// module in this repository. The four remote packages in the repo are snapshot-testing
    /// dependencies declared by module `Package.swift` files and consumed only by their test
    /// targets — nothing a user installs contains a line of them. A `url:` appearing here would be
    /// the app itself gaining a dependency whose behaviour nobody in this repository reviews.
    @Test func theAppTargetLinksOnlyLocalPackages() throws {
        let yaml = try #require(
            try? String(contentsOf: Self.repositoryRoot().appendingPathComponent("project.yml"),
                        encoding: .utf8),
            "project.yml could not be read — this check would be vacuous")
        let packages = try #require(yaml.range(of: "\npackages:\n"),
                                    "project.yml has no packages: block — the scan is reading the wrong file")
        let block = String(yaml[packages.upperBound...])
        #expect(block.contains("path: Modules/Sync"),
                "the packages: block does not name the local modules — the slice is wrong")
        #expect(!block.contains("url:"),
                """
                the app target now links a remote package. Everything a user installs is written \
                in this repository, and Help's privacy claims are made about this repository.
                """)
    }

    // MARK: Positive controls

    /// The scans can actually fail — each one shown finding what it is looking for.
    @Test func theScansAreNotVacuous() {
        #expect(Self.networkSymbols.contains { symbol in
            Self.shippedSources.first { $0.path == "MacApp/CloudFilingClassifier.swift" }?
                .text.contains(symbol) == true
        }, "the network scan cannot even see the known network call — every result above is meaningless")

        let text = "import Sentry\n"
        #expect(["Sentry"].contains { text.contains("import \($0)") },
                "the import scan's own matcher does not match an import")
    }
}
