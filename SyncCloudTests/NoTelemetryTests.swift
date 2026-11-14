import Foundation
import Testing

/// The app's privacy claim, held to the source. Help ▸ *Reading your documents* promises no server,
/// no usage statistics, no crash reports, and nothing about the reader's files sent to anyone; an
/// updater or analytics call would break it with every other test green. The network surface must
/// be exactly the allow-listed files behind Refine with Claude and Ask Claude (each with the user's
/// own key). A source scan of shipped sources only, since no driven path would make such a call.
@Suite struct NoTelemetryTests {
    // MARK: Reading the shipped sources

    /// The repository root, located from this file, as `macAppDirectory()` is.
    private static func repositoryRoot() -> URL { macAppDirectory().deletingLastPathComponent() }

    /// Every Swift file compiled into something a user installs, as (repo-relative path, text). Any
    /// component ending in `Tests` is excluded (this file names `URLSession` in a string), and so is
    /// build and worktree debris, where a stale copy or another branch could answer the question.
    private static let shippedSources: [(path: String, text: String)] = {
        let root = repositoryRoot()
        let rootPath = root.standardizedFileURL.path
        let excludedComponents: Set<String> = [".build", ".git", ".claude",
                                               "DerivedData", ".dd", "artifact-src"]
        func isExcluded(_ component: String) -> Bool {
            excludedComponents.contains(component) || component.hasSuffix("Tests")
        }

        /// The components of `url` below the repository root, or `nil` outside it. Matching the whole
        /// path would let the checkout's location answer: a worktree under `<repo>/.claude/worktrees`
        /// would exclude every file and leave `shippedSources` empty.
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

    /// SyncCloud's whole network surface: two files post to `CloudFilingProtocol.endpoint`, and the
    /// third checks a pasted key against `api.anthropic.com/v1/models`. None is reachable without a
    /// key the user stored.
    private static let allowedNetworkFiles: Set<String> = [
        // Refine's streamed request: Refine, Try Another and Refine Names.
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

    /// The app target links only local packages: every `project.yml` entry is a `path:`. A `url:`
    /// would give the app a dependency nobody here reviews (the modules pin their own remote ones).
    @Test func theAppTargetLinksOnlyLocalPackages() throws {
        let yaml = try repoFile("project.yml")
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
}
