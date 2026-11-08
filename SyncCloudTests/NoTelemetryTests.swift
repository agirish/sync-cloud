import Foundation
import Testing

/// The app's privacy claim, held to the source: a published promise, not a behaviour. Help ▸
/// *Reading your documents* says SyncCloud has no server, collects no usage statistics, sends no
/// crash reports, and sends nothing about the reader's files to anyone. An updater, analytics call
/// or crash reporter would make that false with every other test green. The network surface must be
/// exactly the allow-listed files behind the features the article names (Refine with Claude and Ask
/// Claude, each with the user's own key). A source scan, since a behavioural test can't observe a
/// call no driven path makes. Shipped sources only: tests may use `URLSession` to stub, and never
/// ship.
@Suite struct NoTelemetryTests {

    // MARK: Reading the shipped sources

    /// The repository root, located from this file rather than a working directory, which the test
    /// bundle doesn't promise. Same derivation as `macAppDirectory()`.
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)      // …/SyncCloudTests/NoTelemetryTests.swift
            .deletingLastPathComponent()     // …/SyncCloudTests
            .deletingLastPathComponent()     // repo root
    }

    /// Every Swift file compiled into something a user installs, as (repo-relative path, text).
    /// Directory-shaped exclusions: any component ending in `Tests` goes, taking every test target
    /// at once, including this one, which names `URLSession` in a string literal. `.build`,
    /// `DerivedData`, `.dd` and `.claude` are build and worktree debris, where a stale copy or
    /// another branch's checkout could answer the question. Matched below the repository root only
    /// (`componentsBelowRoot`).
    private static let shippedSources: [(path: String, text: String)] = {
        let root = repositoryRoot()
        let rootPath = root.standardizedFileURL.path
        let excludedComponents: Set<String> = [".build", ".git", ".claude",
                                               "DerivedData", ".dd", "artifact-src"]
        func isExcluded(_ component: String) -> Bool {
            excludedComponents.contains(component) || component.hasSuffix("Tests")
        }

        /// The components of `url` below the repository root, the only ones the exclusions may
        /// read, or `nil` for a URL outside the root. Matching the whole absolute path would let the
        /// checkout's own location answer: a worktree under `<repo>/.claude/worktrees/<name>` would
        /// exclude every file and leave `shippedSources` empty.
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
            // Comment-stripped, since prose isn't code: the doc comment on Help's privacy article
            // names these symbols to say which files hold them, and would report itself.
            out.append((components.joined(separator: "/"), sourceCodeOnly(text)))
        }
        return out.sorted { $0.0 < $1.0 }
    }()

    /// The files behind *Refine with Claude*, plus Ask Claude's engine: SyncCloud's whole
    /// network surface. Two post to `CloudFilingProtocol.endpoint` (`api.anthropic.com/v1/messages`);
    /// the third checks a pasted key against `api.anthropic.com/v1/models` so Settings can say
    /// whether it works. None is reachable without a key the user stored.
    private static let allowedNetworkFiles: Set<String> = [
        "MacApp/CloudFilingClassifier.swift",
        // Refine's streamed request (TE335). The same call as the classifier above, which it replaces
        // in the app, so Help's account of Refine covers it.
        "Modules/Sync/Sources/Sync/CloudFilingRefiner.swift",
        "Modules/Sync/Sources/Sync/AnthropicKeyCheck.swift",
        // Ask Claude, the toolbar chat. Help ▸ Reading your documents names it as the second feature
        // that reaches the internet, and what it sends.
        "Modules/Sync/Sources/Sync/AskClaudeEngine.swift",
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

    /// The network surface is exactly the allow-listed files. A new file isn't necessarily wrong,
    /// but it changes what the app tells its users, so it belongs with the Help copy describing it.
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

    /// No analytics, crash reporting, telemetry or auto-update SDK is imported anywhere. Separate
    /// from the socket scan, because these arrive as a dependency and nobody writes `URLSession`.
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

    /// The shipped app links no third-party code. `project.yml` is the app target's only package
    /// list, and every entry is a `path:` to a module here. The repo's remote packages are pinned in
    /// those modules' own manifests. A `url:` here would give the
    /// app a dependency nobody in this repository reviews.
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

    /// The scans can actually fail: each is shown finding what it looks for.
    @Test func theScansAreNotVacuous() {
        #expect(Self.networkSymbols.contains { symbol in
            Self.shippedSources.first { $0.path == "MacApp/CloudFilingClassifier.swift" }?
                .text.contains(symbol) == true
        }, "the network scan cannot even see the known network call — every result above is meaningless")
    }
}
