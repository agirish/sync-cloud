import Foundation
import Testing
@testable import SyncCloud

/// Every surface a pane owns takes the same accent wash. The tab strip, header and file list read
/// as one surface only because all three paint `contentSurface(hue:tint:)`; one without it shows as
/// a pale stripe at a high Tint, and nothing else fails.
@MainActor
@Suite struct PaneSurfaceTintTests {
    private static let wash = ".contentSurface(hue: glassHue, tint: surfaceTint)"

    /// A file from the repo, comment-stripped.
    private static func codeFile(_ relativePath: String) throws -> String { sourceCodeOnly(try repoFile(relativePath)) }

    /// The modifier chain on the `PaneTabStrip(...)` call, bounded by the next view, `PaneHeader(`,
    /// rather than a character budget an unrelated edit can push past.
    private static func stripModifiers(in source: String) throws -> String {
        let spans = PaneTabWiringTests.callSpans(of: "PaneTabStrip(", in: source)
        try #require(spans.count == 1,
                     "expected one PaneTabStrip( call site, found \(spans.count) — this scan is aimed at the wrong text")
        let afterCall = source[spans[0].upperBound...]
        let nextSibling = try #require(afterCall.range(of: "PaneHeader("),
                                       "the strip is no longer followed by the header — re-derive this slice")
        return String(afterCall[..<nextSibling.lowerBound])
    }

    // MARK: - The three surfaces

    @Test func theWashIsAppliedBeforeTheCardClips() throws {
        // Applied after `surfaceCard` clips, the wash squares off the rounded corners
        // (`bottomSectionCard`), so this compares positions.
        let chain = try Self.stripModifiers(in: try Self.codeFile("MacApp/ContentView.swift"))
        let wash = try #require(chain.range(of: Self.wash))
        let card = try #require(chain.range(of: ".paneCardIfNeeded("))
        #expect(wash.lowerBound < card.lowerBound,
                "the wash is applied after the card clips — it will poke past the rounded corners")
    }

    /// The `PaneHeader` type's own body: a file-level `contains` would stay green on any other
    /// wash in DashboardViews.swift while the header lost its own.
    @Test func theHeaderTakesTheWash() throws {
        let source = try Self.codeFile("Modules/Dashboard/Sources/Dashboard/DashboardViews.swift")
        let header = try declarationBody(of: "public struct PaneHeader: View {", in: source)
        // The slice is the header's own body: anchored on its height pin, and shorter than the file.
        try #require(header.contains(".frame(height: LiquidGlass.headerHeight)"),
                     "the slice does not contain the header's own height pin — it is not the right region")
        try #require(header.count < source.count,
                     "the slice is the whole file — the boundary matched nothing and this is the file-level check again")
        #expect(header.contains(Self.wash),
                "the header does not paint the tint — the middle of the pane's three surfaces reads as a pale band")
    }

    @Test func theFileListTakesTheWash() throws {
        // Tree and Columns are separate branches; washing one would change colour on a mode switch.
        let source = try Self.codeFile("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift")
        let count = source.components(separatedBy: Self.wash).count - 1
        #expect(count >= 2, "expected the Tree and Columns branches to be washed, found \(count)")
    }
}
