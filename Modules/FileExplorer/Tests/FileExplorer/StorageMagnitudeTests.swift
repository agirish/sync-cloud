import Testing
import SwiftUI
import AppKit
import Sync
import Design
import DesignTestSupport
@testable import FileExplorer

/// The magnitude bar, the share figure, and the rule that hides the row's two glyphs. The rules
/// are pure and asserted directly; the bar is measured off a real render below, because what can be
/// wrong with a bar is its length, and no source scan can see that.
@Suite struct StorageMagnitudeRuleTests {

    /// Only the two size-ordered lists. `stale` arrives oldest-first, and a bar that rose and fell
    /// against that order would be read as a ranking it has nothing to do with.
    @Test func onlyTheSizeOrderedSectionsDrawBars() {
        #expect(StorageMagnitude.showsBar(.largest))
        #expect(StorageMagnitude.showsBar(.reclaim))
        #expect(!StorageMagnitude.showsBar(.stale))
    }

    @Test func theBarIsTheFileAgainstTheSectionsBiggest() {
        #expect(StorageMagnitude.fraction(bytes: 900, largestBytes: 900) == 1)
        #expect(abs(StorageMagnitude.fraction(bytes: 225, largestBytes: 900) - 0.25) < 0.0001)
    }

    /// A denominator that says nothing draws nothing: never a divide by zero, never a full bar
    /// standing in for "unknown".
    @Test func anEmptySectionOrAZeroByteFileDrawsNoBar() {
        #expect(StorageMagnitude.fraction(bytes: 100, largestBytes: 0) == 0)
        #expect(StorageMagnitude.fraction(bytes: 0, largestBytes: 900) == 0)
    }

    /// Rounding away from zero. `0%` claims the file is not there; the file is there and small.
    @Test func aFileTooSmallToRoundToAPercentSaysSoRatherThanZero() {
        #expect(StorageMagnitude.shareText(bytes: 3_000_000, ofTotal: 2_000_000_000) == "<1%")
        #expect(StorageMagnitude.shareText(bytes: 1, ofTotal: 1_000_000_000) == "<1%")
    }

    @Test func theShareRoundsToTheNearestWholePercent() {
        #expect(StorageMagnitude.shareText(bytes: 180, ofTotal: 1000) == "18%")
        #expect(StorageMagnitude.shareText(bytes: 184, ofTotal: 1000) == "18%")
        #expect(StorageMagnitude.shareText(bytes: 186, ofTotal: 1000) == "19%")
        #expect(StorageMagnitude.shareText(bytes: 1000, ofTotal: 1000) == "100%")
    }

    @Test func thereIsNoShareToStateForAnEmptyScanOrAnEmptyFile() {
        #expect(StorageMagnitude.shareText(bytes: 500, ofTotal: 0) == nil)
        #expect(StorageMagnitude.shareText(bytes: 0, ofTotal: 1000) == nil)
    }

    /// Focus reveals, which is the half that keeps the hidden glyphs reachable: the buttons rest at
    /// `opacity(0)`, so without this Full Keyboard Access would ring a control painting nothing.
    @Test func keyboardFocusRevealsTheGlyphsJustAsHoverDoes() {
        #expect(!StorageMagnitude.controlsRevealed(isHovered: false, isFocused: false))
        #expect(StorageMagnitude.controlsRevealed(isHovered: true, isFocused: false))
        #expect(StorageMagnitude.controlsRevealed(isHovered: false, isFocused: true))
    }
}

/// The bar, measured off a render. A geometry assertion can say a bar view exists; only a bitmap
/// can say it is the length the data asked for. The fixture is a 4:3:2:1 ladder, so a correct
/// render draws four bars whose right edges stand in that ratio, and a `fraction` stuck at 1 or
/// scaled to the wrong yardstick puts them all in the same place.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct StorageMagnitudeRenderTests {

    static let canvas = CGSize(width: 620, height: 420)
    /// A 4:3:2:1 ladder, largest first, as `StorageLens` emits `largest`.
    static let ladder = [800_000_000, 600_000_000, 400_000_000, 200_000_000]

    static func report() -> StorageLensReport {
        let entries = ladder.enumerated().map { index, bytes in
            StorageEntry(path: "/root/Files/file\(index).mov", name: "file\(index).mov", bytes: bytes,
                         modified: Date(timeIntervalSince1970: 1_600_000_000))
        }
        return StorageLensReport(treemap: [TreemapNode(name: "Files", path: "Files", bytes: 2_000_000_000)],
                                 largest: entries, stale: entries, reclaimCandidates: entries,
                                 totalBytes: 2_000_000_000, fileCount: entries.count,
                                 staleCount: entries.count, reclaimCount: entries.count,
                                 reclaimableBytes: entries.reduce(0) { $0 + $1.bytes })
    }

    /// The window background matters: without one the content composites against the borderless
    /// window's own buffer and every comparison reads zero difference.
    private func render(section: StorageSection, query: String = "") -> NSBitmapImageRep? {
        let manager = FileSyncManager()
        manager.storageLensReport = Self.report()
        let subject = StorageLensView(syncManager: manager, providerName: "Projects",
                                      query: StorageSearch.parse(query),
                                      onBuild: {}, onReveal: { _ in }, section: .constant(section))
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        return ProbeRig(AnyView(subject), size: Self.canvas).capture()
    }

    /// The rightmost chromatic pixel on each scanline: the bar's edge. Chroma, not "is it blue":
    /// the ground and the row text are achromatic while the bar is a hue at 16%, so this holds
    /// whatever accent the host's defaults carry. Scanlines above ``belowTheSwitcher`` are skipped:
    /// the section switcher's selected segment is a wide accent fill above every list and would
    /// read as a bar. So the capsule is excluded by row, as the file-type glyphs are by column.
    private func chromaEdges(_ rep: NSBitmapImageRep, from top: Int = StorageMagnitudeRenderTests.belowTheSwitcher) -> [Int: Int] {
        var edges: [Int: Int] = [:]
        for y in top..<rep.pixelsHigh {
            var edge = -1
            for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let hi = max(c.redComponent, max(c.greenComponent, c.blueComponent))
                let lo = min(c.redComponent, min(c.greenComponent, c.blueComponent))
                if hi - lo > 0.03 { edge = x; break }
            }
            if edge > 0 { edges[y] = edge }
        }
        return edges
    }

    /// The first scanline below the section switcher, in device pixels (this bitmap is 2×). 120
    /// sits between the capsule's last inked row (70) and the first bar's first (177), far enough
    /// from both that a few points of drift can't cross either.
    /// `theSwitcherIsAboveTheBandTheBarsAreMeasuredIn` fails if it drifts into the list.
    static let belowTheSwitcher = 120

    /// The distinct bar lengths on the page, largest first. The bitmap is 2× on this display, so
    /// the tolerances are device pixels (a 620pt canvas is 1240 wide). A bar's rounded right corner
    /// spreads its edge over about ten scanlines, so edges within 14px are one bar; a tighter
    /// bucket counts the top bar several times. `beyondTheGlyph` drops the row's file-type glyph
    /// and the section header's icon, the only other chromatic ink, inside the first 100 pixels.
    private func barEdges(_ rep: NSBitmapImageRep) -> [Int] {
        let beyondTheGlyph = 200
        var buckets: [Int] = []
        for edge in chromaEdges(rep).values.sorted(by: >) where edge > beyondTheGlyph {
            if !buckets.contains(where: { abs($0 - edge) <= 14 }) { buckets.append(edge) }
        }
        return buckets
    }

    /// The bars stand in the ratio of the files they measure. Asserted on differences between
    /// edges, so the row's left inset cancels: `(e₀ − eₖ) / (e₀ − e₃)` for a 4:3:2:1 ladder must
    /// normalise to 0, ⅓, ⅔, 1, and a `fraction` stuck at 1 or on the wrong yardstick collapses it.
    @Test func theFourBarsStandInTheRatioOfTheFilesTheyMeasure() throws {
        let rep = try #require(render(section: .largest), "the largest page did not render")
        let edges = barEdges(rep)
        try #require(edges.count == 4, "found \(edges.count) bars, expected 4: \(edges)")
        let span = Double(edges[0] - edges[3])
        try #require(span > 100, "the four bars are within \(span)px of each other — nothing is ramping")
        let measured = edges.map { Double(edges[0] - $0) / span }
        let widest = Double(Self.ladder[0])
        let expected = Self.ladder.map { (1 - Double($0) / widest) / (1 - Double(Self.ladder[3]) / widest) }
        for (index, (got, want)) in zip(measured, expected).enumerated() {
            #expect(abs(got - want) < 0.03,
                    "bar \(index) normalises to \(got) where its file normalises to \(want)")
        }
    }

    /// The yardstick is the section's own biggest file, not the biggest still on screen: a query
    /// hiding the 800 MB file must leave the other three bars where they were, not grow the 600 MB
    /// one to full length. Rendered through the view, because the rule is which list the view
    /// takes its maximum from, and `fraction` is handed the answer either way.
    @Test func aQueryHidingTheBiggestFileDoesNotRescaleTheRestsBars() throws {
        let all = barEdges(try #require(render(section: .largest), "the largest page did not render"))
        let narrowed = barEdges(try #require(render(section: .largest, query: "<700mb"),
                                             "the narrowed page did not render"))
        try #require(all.count == 4, "found \(all.count) bars unfiltered, expected 4: \(all)")
        try #require(narrowed.count == 3, "found \(narrowed.count) bars under the query, expected 3: \(narrowed)")
        try #require(all[0] - all[1] > 40, "the two longest bars are \(all[0] - all[1])px apart — they can't be told apart")
        #expect(abs(narrowed[0] - all[1]) <= 14,
                "the 600 MB bar ends at \(narrowed[0]) under the query and at \(all[1]) without it — the bars rescaled to what is visible")
    }

    /// The other half of `showsBar`, which catches the rule inverted: the same four files listed by
    /// age draw no bar. Their file-type glyphs still paint, which is why `barEdges` measures past
    /// them rather than counting chromatic pixels.
    @Test func theAgeOrderedListDrawsNoBars() throws {
        let stale = try #require(render(section: .stale))
        let largest = try #require(render(section: .largest))
        #expect(barEdges(largest).count == 4, "the largest list lost its bars: \(barEdges(largest))")
        #expect(barEdges(stale).isEmpty, "the untouched list is drawing bars: \(barEdges(stale))")
    }

    /// The exclusion above cuts the switcher and nothing else. A skipped band is a place bugs hide,
    /// so both edges are pinned: the capsule must sit entirely inside it (or its fill leaks back in
    /// as a phantom bar), and it must hold no bar (or every count above is one short and the ratio
    /// test measures the wrong four).
    @Test func theSwitcherIsAboveTheBandTheBarsAreMeasuredIn() throws {
        let rep = try #require(render(section: .largest))
        // Scanlines whose rightmost chromatic pixel is past the glyph column, over the whole page.
        let chromatic = chromaEdges(rep, from: 0).filter { $0.value >= 200 }.map(\.key)
        let above = chromatic.filter { $0 < Self.belowTheSwitcher }
        let below = chromatic.filter { $0 >= Self.belowTheSwitcher }
        // The capsule is there, above the cut; "nothing above the cut" would also pass if the
        // switcher stopped rendering.
        #expect(!above.isEmpty,
                "nothing chromatic above the cut — the section capsule is not drawing at all, so this exclusion is protecting nothing")
        #expect((above.max() ?? 0) < Self.belowTheSwitcher - 20,
                "the capsule inks up to device-y \(above.max() ?? 0), within 20px of the \(Self.belowTheSwitcher) cut — one layout nudge and its fill is a phantom bar again")
        #expect((below.min() ?? .max) > Self.belowTheSwitcher + 20,
                "a bar starts at device-y \(below.min() ?? -1), within 20px of the \(Self.belowTheSwitcher) cut — the exclusion is about to start eating real bars")
    }
}
