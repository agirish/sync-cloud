import Testing
import Foundation

/// Which of a pane's two names the lens workspaces use, at the call site. `PaneProviderNamesTests`
/// proves `plain(isLeft:)` drops the "(left)"/"(right)" a two-pane surface needs, but not that
/// Organize asks for it: `paneNames.left` there would put "iCloud (left) › Documents › …" in every
/// breadcrumb with every other test green. A source scan that fails loudly on an empty read and
/// pins the whole expression, not its ingredients.
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

    /// One declaration's body, bounded by its closing brace rather than a character count, which
    /// would run past a short body into the next member.
    private static func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "`\(declaration)` is gone — this scan would read nothing")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for `\(declaration)`")
        return String(rest[..<end.lowerBound])
    }

    /// The lens workspaces show one source, so their name carries no pane suffix.
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

    /// The other direction: the Differences table shows both panes, so it keeps the suffixed pair;
    /// swapping every `paneNames` for the plain one would give it two identically named columns.
    @Test func theDifferencesTableKeepsTheDisambiguatedPair() throws {
        let source = try Self.contentView()
        #expect(source.contains("DifferencesView(syncManager: syncManager, reviewStore: reviewStore, paneNames: paneNames"),
                "the Differences table no longer takes the disambiguated pane names")
    }
}
