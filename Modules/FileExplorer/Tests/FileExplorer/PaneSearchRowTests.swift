import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// What one row draws differently while a search is running.
@MainActor
@Suite struct PaneSearchRowTests {

    private static func results(_ query: String, otherPaths: Set<String>? = nil) -> PaneSearchResults {
        PaneSearchResults(side: .left, generation: 1, query: query,
                          tree: PaneSearchTreeRevealTests.tree(), otherPaths: otherPaths)
    }

    private func context(_ path: String, query: String = "tax", isExpanded: Bool = false,
                         otherPaths: Set<String>? = nil) -> PaneSearchRowContext {
        PaneSearchRowContext(results: Self.results(query, otherPaths: otherPaths),
                             path: path, isExpanded: isExpanded)
    }

    // MARK: - The count pill

    /// A closed folder with hits inside it says so — otherwise the tree hides the answer behind a
    /// row that looks exactly like the ones with nothing in them.
    @Test("A closed folder with matches inside shows its count")
    func aClosedFolderWithMatchesShowsACount() {
        let irs = context("/root/Documents/IRS")
        #expect(irs.containedMatchCount == 1)
        #expect(irs.showsContainedCount)
    }

    /// An OPEN folder's count says nothing its own rows are not already saying — and in Columns it
    /// would sit on the very folder you drilled through.
    @Test("An open folder does not repeat the count its rows already show")
    func anOpenFolderShowsNoCount() {
        #expect(!context("/root/Documents/IRS", isExpanded: true).showsContainedCount)
    }

    @Test("A folder with nothing matching inside shows no count, open or closed")
    func aFolderWithNoMatchesShowsNothing() {
        #expect(!context("/root/Movies").showsContainedCount)
        #expect(!context("/root/Movies", isExpanded: true).showsContainedCount)
    }

    // MARK: - Dimming

    @Test("A row off every path to an answer dims; matches and their ancestors do not")
    func dimmingFollowsTheResults() {
        #expect(context("/root/Movies").isDimmed)
        #expect(!context("/root/Documents").isDimmed)
        #expect(!context("/root/Documents/Finance/tax-notes.md").isDimmed)
    }

    /// The resting value has to be inert in every direction, because it is what every caller that
    /// knows nothing about search passes.
    @Test("With no search running a row draws exactly what it always drew")
    func theRestingContextIsInert() {
        #expect(PaneSearchRowContext.none.match == nil)
        #expect(!PaneSearchRowContext.none.isDimmed)
        #expect(!PaneSearchRowContext.none.showsContainedCount)
        #expect(PaneSearchRowContext.none.side == nil)
    }

    // MARK: - The side annotation

    /// The two panes must not both say “left only”. The label names THIS pane, so it has to come
    /// from the side rather than from the sentence.
    @Test("A one-sided hit names the pane it is on")
    func theOneSidedLabelNamesItsOwnSide() {
        #expect(PaneSearchAnnotation.onlyHereLabel(isLeft: true) == "left only")
        #expect(PaneSearchAnnotation.onlyHereLabel(isLeft: false) == "right only")
    }

    @Test("The annotation is only produced where there is a second tree")
    func theRailAnnotatesNothing() {
        // No `otherPaths` — the single-source rail.
        #expect(context("/root/Documents/Finance/tax-notes.md").side == nil)
        // With one, the hit is annotated.
        let compared = context("/root/Documents/Finance/tax-notes.md",
                               otherPaths: ["Documents/Finance/tax-notes.md"])
        #expect(compared.side == .bothSides)
    }

    // MARK: - The emphasized name

    /// The clamp, exercised: the range and the string reach this view from different places — the
    /// results computed against the tree that was published when the query ran, the row rendered
    /// from the tree published since — so one republish between them hands it a range past the end.
    /// Without the bounds check `display[..<match.lowerBound]` traps and takes the process with it,
    /// which is why this test renders rather than asserting a return value.
    @Test("A stale match range past the end of the name renders instead of trapping")
    func aStaleMatchRangeIsClamped() {
        for match in [40..<45, -3..<2, 2..<2, 0..<3] {
            let host = NSHostingView(rootView:
                PaneSearchName(name: "notes.md", match: match, font: .body))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0, "the name should still lay out for \(match)")
        }
    }

    // MARK: - The annotation must not resize the row

    /// **A row is one line tall, however long its name and whether or not a search annotates it.**
    /// The name is held to one line and cut, and the annotation is shown whole or not at all. It was
    /// not always so: while the name had no line limit, a 60-character filename at the 250pt clamp
    /// the pane split enforces went from 60pt to 76pt the moment it matched — the annotation took
    /// the width that made it wrap.
    ///
    /// Measured against a SHORT, plain row rather than against the same row unannotated, at three
    /// widths: a name that wraps on its own would make both of those taller alike, and pass.
    @Test("Annotating a row never makes it taller", .machinePinned(.layoutMetrics))
    func theAnnotationNeverGrowsTheRow() {
        let long = "Quarterly Tax Return and Supporting Schedules 2025 final.pdf"
        let info = FileRowInfo(FileNode(id: "/r/\(long)", name: long, isDirectory: false))
        let short = FileRowInfo(FileNode(id: "/r/a.pdf", name: "a.pdf", isDirectory: false))
        var annotated = PaneSearchRowContext.none
        annotated.match = 10..<13
        annotated.side = .thisSideOnly

        for width in [250.0, 400.0, 900.0] as [CGFloat] {
            let oneLine = Self.laidOutHeight(row(short, context: .none), width: width)
            let plain = Self.laidOutHeight(row(info, context: .none), width: width)
            let searched = Self.laidOutHeight(row(info, context: annotated), width: width)
            #expect(plain == oneLine, "at \(Int(width))pt a long name made its row \(plain)pt, not one line (\(oneLine))")
            #expect(searched == oneLine,
                    "at \(Int(width))pt the annotated row is \(searched)pt, not one line (\(oneLine))")
        }
    }

    /// What a row's annotation says — the one definition the row's gate (`hasAnnotation`) and the
    /// label both read, so a kind added to one cannot go missing from the other.
    @Test("Each kind of annotation, and none, is said once")
    func theAnnotationIsOneDefinition() {
        var context = PaneSearchRowContext.none
        #expect(context.annotation == nil && !context.hasAnnotation)
        context.containedMatchCount = 3
        #expect(context.annotation == .containedMatches(3) && context.hasAnnotation)
        context.isExpanded = true
        #expect(context.annotation == nil, "an open folder repeated the count its rows already show")
        context.side = .bothSides
        #expect(context.annotation == .bothSides && context.hasAnnotation)
        context.side = .thisSideOnly
        #expect(context.annotation == .thisSideOnly && context.hasAnnotation)
        context.isExpanded = false
        #expect(context.annotation == .containedMatches(3), "the count outranks the side, as the label draws it")
    }

    /// …and where it does not fit it is omitted WHOLE rather than truncated to a bare “…”, which is
    /// a glyph with no meaning and a tooltip nobody will find.
    ///
    /// **Counted in painted pixels, because nothing else can tell the two apart.** Both an omitted
    /// annotation and one truncated to an ellipsis occupy no useful width and change no laid-out
    /// size — the row is width-constrained either way. The difference is entirely whether anything
    /// is drawn, and the annotation is the only tinted thing on the row, so its own colour is the
    /// probe. A test that measured geometry here passed against the truncating version.
    @Test("Where it cannot fit, the annotation is omitted rather than left as an ellipsis", .machinePinned(.pixelSampling))
    func theAnnotationDegradesToNothing() {
        let long = "Quarterly Tax Return and Supporting Schedules 2025 final.pdf"
        let info = FileRowInfo(FileNode(id: "/r/\(long)", name: long, isDirectory: false))
        var annotated = PaneSearchRowContext.none
        annotated.match = 10..<13
        annotated.side = .thisSideOnly

        // The control: with room, the annotation really does paint. Without this the assertion
        // below would hold for a build that never draws it at all.
        #expect(Self.tintedPixels(row(info, context: annotated), width: 900) > 0,
                "the annotation must paint when there is room, or this test proves nothing")
        #expect(Self.tintedPixels(row(info, context: annotated), width: 250) == 0,
                "a row too narrow for the label should show none of it, not an ellipsis")
    }

    /// Pixels carrying the annotation's warning tint. It is the only tinted element on the row —
    /// the name, badges and detail are all greyscale — so a non-grey pixel is the annotation.
    private static func tintedPixels(_ view: some View, width: CGFloat) -> Int {
        let host = NSHostingView(rootView: view.frame(width: width)
            .background(Color(nsColor: .textBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                // Warm and saturated: red well clear of blue. Greys and the near-black name text
                // have r ≈ g ≈ b, and the file icon is confined to the leading edge.
                if a > 0.5, r - b > 0.25, r > 0.5, x > rep.pixelsWide / 2 { count += 1 }
            }
        }
        return count
    }

    private func row(_ info: FileRowInfo, context: PaneSearchRowContext) -> some View {
        FileRowView(node: info, isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                    density: .comfortable, searchContext: context, isLeftPane: true,
                    otherPaneName: "Dropbox", accent: .blue)
    }

    private static func laidOutHeight(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private static func laidOutWidth(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// The emphasis is drawn on the MARKED form (“Swimming ” → “Swimming␣”), and the offsets have to
    /// survive that substitution — `NameDisplay.visibleName` replaces one character with one, so
    /// they do. A fold that changed the length here would silently bold the wrong run.
    @Test("A name whose affix whitespace is marked keeps the same character count")
    func theMarkedNameIsTheSameLength() {
        #expect(Array(NameDisplay.visibleName("Swimming ")).count == Array("Swimming ").count)
        #expect(Array(NameDisplay.visibleName("  a  ")).count == Array("  a  ").count)
    }
}
