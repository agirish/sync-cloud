import Testing
import Foundation

/// **Which of a pane's two names the lens workspaces use, at the call site.**
///
/// `PaneProviderNamesTests` proves the rule — `plain(isLeft:)` drops the "(left)"/"(right)" a
/// two-pane surface needs. It cannot prove that Organize asks for it: reverting `lensProviderName`
/// to `paneNames.left` is a one-line change that leaves every test in every package green, and
/// puts "iCloud (left) › Documents › …" back in every breadcrumb on a tab showing one source.
/// That is the state this fix started from.
///
/// Source-level, therefore, with the blind spot that implies — and with the two habits the other
/// call-site scans here use: the read fails loudly rather than scanning an empty haystack, and the
/// check pins the whole expression rather than asserting its ingredients appear somewhere.
@Suite struct LensProviderNameCallSiteTests {

    private static func contentView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)      // …/SyncCloudTests/<this>.swift
            .deletingLastPathComponent()               // …/SyncCloudTests
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("MacApp/ContentView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read ContentView.swift — every check below would be vacuous")
        try #require(text.count > 500,
                     "ContentView.swift is implausibly short — the checks would be near-vacuous")
        return text
    }

    /// One declaration's body, bounded by its closing brace rather than a character count — a fixed
    /// window runs past a short body into the next member and answers about the wrong text.
    private static func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "`\(declaration)` is gone — this scan would read nothing")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for `\(declaration)`")
        return String(rest[..<end.lowerBound])
    }

    /// The lens workspaces show ONE source, so their name carries no pane suffix.
    @Test func theLensNameIsThePlainOne() throws {
        let body = try Self.body(of: "var lensProviderName: String {", in: try Self.contentView())
        #expect(body.contains("paneNames.plain(isLeft: !lensTargetIsRight)"), """
                `lensProviderName` no longer asks for the plain name. A lens workspace shows one \
                pane, so a "(left)"/"(right)" suffix there disambiguates against a pane that is \
                not on screen — which is what put "iCloud (left)" in every Organize breadcrumb. \
                Body was: \(body)
                """)
        #expect(!body.contains("paneNames.left"),
                "the disambiguated name is back in a single-pane surface: \(body)")
        #expect(!body.contains("paneNames.right"),
                "the disambiguated name is back in a single-pane surface: \(body)")
    }

    /// **The other direction, and the reason this is a scan of TWO things.** The Differences table
    /// really does show both panes, so it must keep the suffixed pair — a fix that swapped every
    /// `paneNames` for a plain one would leave two identically-named columns there.
    @Test func theDifferencesTableKeepsTheDisambiguatedPair() throws {
        let source = try Self.contentView()
        #expect(source.contains("DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames"),
                "the Differences table no longer takes the disambiguated pane names")
    }
}
