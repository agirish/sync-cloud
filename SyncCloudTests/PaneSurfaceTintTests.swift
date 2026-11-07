import Foundation
import Testing
@testable import SyncCloud

/// Every surface a pane owns takes the same accent wash. A pane is three views in one `VStack`
/// (tab strip, header, file list) that read as one surface only because all three paint
/// `contentSurface(hue:tint:)`. One without it shows as a pale stripe at a high Tint, and nothing
/// else fails, since a missing wash just looks like the window behind it. Pinned for all three.
@MainActor
@Suite struct PaneSurfaceTintTests {

    private static let wash = ".contentSurface(hue: glassHue, tint: surfaceTint)"

    /// A file from the repo, comment-stripped.
    private static func codeFile(_ relativePath: String) throws -> String { sourceCodeOnly(try repoFile(relativePath)) }

    /// The modifier chain on the `PaneTabStrip(...)` call, from its balanced closing parenthesis
    /// to the next view in the stack. Bounded by `PaneHeader(`, the structural boundary, not a
    /// character budget, which an unrelated edit can push past.
    private static func stripModifiers(in source: String) throws -> String {
        let spans = PaneTabWiringTests.callSpans(of: "PaneTabStrip(", in: source)
        try #require(spans.count == 1,
                     "expected one PaneTabStrip( call site, found \(spans.count) — this scan is aimed at the wrong text")
        let afterCall = source[spans[0].upperBound...]
        let nextSibling = try #require(afterCall.range(of: "PaneHeader("),
                                       "the strip is no longer followed by the header — re-derive this slice")
        return String(afterCall[..<nextSibling.lowerBound])
    }

    // MARK: - The premise

    // MARK: - The three surfaces

    @Test func theTabStripTakesTheWash() throws {
        let chain = try Self.stripModifiers(in: try Self.codeFile("MacApp/ContentView.swift"))
        #expect(chain.contains(Self.wash),
                "the tab strip does not paint the tint — it will read as a pale stripe across the pane")
    }

    @Test func theWashIsAppliedBeforeTheCardClips() throws {
        // The wash must come before the card: applied after `surfaceCard` clips, it squares off
        // the rounded corners (as `bottomSectionCard` documents). `contains` can't see order, so
        // this compares positions.
        let chain = try Self.stripModifiers(in: try Self.codeFile("MacApp/ContentView.swift"))
        let wash = try #require(chain.range(of: Self.wash))
        let card = try #require(chain.range(of: ".paneCardIfNeeded("))
        #expect(wash.lowerBound < card.lowerBound,
                "the wash is applied after the card clips — it will poke past the rounded corners")
    }

    /// The `PaneHeader` type's own slice, from its declaration to the next top-level declaration.
    /// Structural, like `stripModifiers`: a file-level `contains` would stay green on any other
    /// wash in DashboardViews.swift while the header lost its own.
    private static func paneHeaderSlice(in source: String) throws -> String {
        let start = try #require(source.range(of: "struct PaneHeader"),
                                 "PaneHeader is gone — the wash has no home to be asserted in")
        let rest = String(source[start.upperBound...])
        // The next declaration at column zero ends the type; anchored to the line start so a
        // nested type can't end the slice early.
        let end = rest.range(of: #"\n(public |private |internal |final )*(struct|enum|class|extension)\s"#,
                             options: .regularExpression)
        return end.map { String(rest[..<$0.lowerBound]) } ?? rest
    }

    @Test func theHeaderTakesTheWash() throws {
        let source = try Self.codeFile("Modules/Dashboard/Sources/Dashboard/DashboardViews.swift")
        let header = try Self.paneHeaderSlice(in: source)
        // The slice is the header's own body, not the whole file: the header's height pin anchors
        // it, and the boundary really cut something.
        try #require(header.contains(".frame(height: LiquidGlass.headerHeight)"),
                     "the slice does not contain the header's own height pin — it is not the right region")
        try #require(header.count < source.count,
                     "the slice is the whole file — the boundary matched nothing and this is the file-level check again")
        #expect(header.contains(Self.wash),
                "the header does not paint the tint — the middle of the pane's three surfaces reads as a pale band")
    }

    @Test func theFileListTakesTheWash() throws {
        // Both presentations: Tree and Columns are separate branches, and washing only one would
        // change the pane's colour when the view mode switches.
        let source = try Self.codeFile("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift")
        let count = source.components(separatedBy: Self.wash).count - 1
        #expect(count >= 2, "expected the Tree and Columns branches to be washed, found \(count)")
    }
}
