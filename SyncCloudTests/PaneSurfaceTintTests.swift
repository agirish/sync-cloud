import Foundation
import Testing
@testable import SyncCloud

/// Every surface a pane owns takes the same accent wash.
///
/// A pane is three views stacked in one `VStack` — the tab strip, the header, the file list — and
/// they read as one surface only because all three paint the same `contentSurface(hue:tint:)`.
/// The strip did not: it was the one pane-owned surface without the wash, so at a high Tint it was
/// a pale stripe cut through the top of the pane. Nothing failed when it was added without one,
/// because a missing wash is a surface that looks like the window behind it.
///
/// **Pinned as the SET of three, not as the one that was wrong.** The strip is the third view to
/// join this stack; a fourth is what this is really guarding against, and a test naming only the
/// strip would have nothing to say about it.
@MainActor
@Suite struct PaneSurfaceTintTests {

    private static let wash = ".contentSurface(hue: glassHue, tint: surfaceTint)"

    /// A file from the repo, with the truncation guard every scan in this target carries: a
    /// partially-read file answers `contains` with false and makes an absence-scan vacuous.
    private static func repoFile(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.count > 500, "\(relativePath) read as \(text.count) characters — truncated?")
        return SyncCloudTests.strippingComments(text)
    }

    /// The modifier chain hung on the `PaneTabStrip(...)` call: from its balanced closing
    /// parenthesis to the next view in the stack.
    ///
    /// **Bounded by `PaneHeader(` — the real structural boundary — and not by a character budget.**
    /// A budget is what `QuickLookOriginTests` used, and one extra argument on an unrelated call
    /// pushed the line it looked for out of range, failing a test about something else entirely.
    /// The strip's chain ends where the next sibling begins, whatever grows in between.
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

    @Test func theSliceIsTheStripsOwnModifierChain() throws {
        let source = try Self.repoFile("MacApp/ContentView.swift")
        let chain = try Self.stripModifiers(in: source)
        // A modifier the strip has carried since it shipped, so a slice that came back empty or
        // pointed at the wrong region cannot report every assertion below as satisfied.
        #expect(chain.contains(".paneCardIfNeeded("),
                "the slice does not contain the strip's own card modifier — it is not the right region")
        // And it stops before the sibling: a slice that ran on into the header would find the
        // header's wash and credit it to the strip, which is precisely the bug being pinned.
        #expect(!chain.contains("PaneHeader("))
        #expect(chain.count < source.count)
    }

    @Test func theScanWouldNoticeTheWashGoing() throws {
        // The negative control. `wash` is matched verbatim, so this asserts the spelling the three
        // checks below look for is one this file actually contains somewhere — a renamed modifier
        // or a re-spelled argument label would otherwise make all three pass by never matching.
        let source = try Self.repoFile("MacApp/ContentView.swift")
        #expect(source.contains(Self.wash), "the wash is spelled differently now — every scan here is vacuous")
        #expect(!source.contains(".contentSurface(hue: glassHue, tint: surfaceTintt)"))
    }

    // MARK: - The three surfaces

    @Test func theTabStripTakesTheWash() throws {
        let chain = try Self.stripModifiers(in: try Self.repoFile("MacApp/ContentView.swift"))
        #expect(chain.contains(Self.wash),
                "the tab strip does not paint the tint — it will read as a pale stripe across the pane")
    }

    @Test func theWashIsAppliedBeforeTheCardClips() throws {
        // `surfaceCard` clip-shapes first, so a wash applied AFTER it squares off the rounded
        // corners — the same ordering `bottomSectionCard` documents. Order in a modifier chain is
        // invisible to a `contains` check, which is why this asks where each one sits.
        let chain = try Self.stripModifiers(in: try Self.repoFile("MacApp/ContentView.swift"))
        let wash = try #require(chain.range(of: Self.wash))
        let card = try #require(chain.range(of: ".paneCardIfNeeded("))
        #expect(wash.lowerBound < card.lowerBound,
                "the wash is applied after the card clips — it will poke past the rounded corners")
    }

    /// The `PaneHeader` type's own slice: from its declaration to the file's next top-level
    /// declaration. Structural, like `stripModifiers` above, and for the same reason — a
    /// character budget truncates under unrelated edits, and a file-level `contains` is worse:
    /// a wash anywhere else in DashboardViews.swift would keep it green while the header lost
    /// its own, which is precisely the drift the strip's slice exists to rule out.
    private static func paneHeaderSlice(in source: String) throws -> String {
        let start = try #require(source.range(of: "struct PaneHeader"),
                                 "PaneHeader is gone — the wash has no home to be asserted in")
        let rest = String(source[start.upperBound...])
        // The next declaration at column zero ends the type. Anchored to the line start so a
        // nested type inside PaneHeader's body cannot end the slice early.
        let end = rest.range(of: #"\n(public |private |internal |final )*(struct|enum|class|extension)\s"#,
                             options: .regularExpression)
        return end.map { String(rest[..<$0.lowerBound]) } ?? rest
    }

    @Test func theHeaderTakesTheWash() throws {
        let source = try Self.repoFile("Modules/Dashboard/Sources/Dashboard/DashboardViews.swift")
        let header = try Self.paneHeaderSlice(in: source)
        // The slice is the header's own body, not the whole file: a modifier the header has
        // carried since the height rule landed anchors it, and the boundary really cut something.
        try #require(header.contains(".frame(height: LiquidGlass.headerHeight)"),
                     "the slice does not contain the header's own height pin — it is not the right region")
        try #require(header.count < source.count,
                     "the slice is the whole file — the boundary matched nothing and this is the file-level check again")
        #expect(header.contains(Self.wash),
                "the header does not paint the tint — the middle of the pane's three surfaces reads as a pale band")
    }

    @Test func theFileListTakesTheWash() throws {
        // Both presentations: Tree and Columns are separate branches, and only one of them being
        // washed is a pane that changes colour when the view mode switches.
        let source = try Self.repoFile("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift")
        let count = source.components(separatedBy: Self.wash).count - 1
        #expect(count >= 2, "expected the Tree and Columns branches to be washed, found \(count)")
    }
}
