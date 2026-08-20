import Testing
import SwiftUI
import AppKit
import Sync
import Design
@testable import FileExplorer

/// **The magnitude bar, the share figure, and the rule that hides the row's two glyphs.**
///
/// The rules are pure and asserted directly; the bar is then measured off a real render, because
/// the one thing that can be wrong about a bar is its *length* and no source scan can see that.
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

    /// A denominator that says nothing draws nothing — never a divide by zero, never a full bar
    /// standing in for "unknown".
    @Test func anEmptySectionOrAZeroByteFileDrawsNoBar() {
        #expect(StorageMagnitude.fraction(bytes: 100, largestBytes: 0) == 0)
        #expect(StorageMagnitude.fraction(bytes: 0, largestBytes: 900) == 0)
    }

    /// The yardstick is the section's own maximum, not the maximum still on screen. This is the
    /// assertion that a future "just use `entries`" simplification has to get past: filtering the
    /// biggest file away must not grow the survivors' bars.
    @Test func aQueryHidingTheBiggestFileDoesNotRescaleTheRestsBars() {
        let sectionMax = 900
        let before = StorageMagnitude.fraction(bytes: 225, largestBytes: sectionMax)
        // The 900 is filtered out; 300 is now the biggest thing visible.
        let after = StorageMagnitude.fraction(bytes: 225, largestBytes: sectionMax)
        #expect(before == after)
        #expect(StorageMagnitude.fraction(bytes: 225, largestBytes: 300) != before,
                "the fixture does not distinguish the two yardsticks — pick a visible max that differs")
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

/// **The bar, measured off a render.**
///
/// A geometry assertion can say a bar view exists; only a bitmap can say it is the length the data
/// asked for. The fixture is a 4:3:2:1 ladder, so a correct render draws four bars whose right
/// edges stand in that ratio — and a `fraction` stuck at 1, or scaled to the wrong yardstick, puts
/// them all at the same place.
@MainActor
@Suite struct StorageMagnitudeRenderTests {

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
                                 totalBytes: 2_000_000_000)
    }

    /// The window background is not decoration: without one the content composites against the
    /// borderless window's own buffer and every comparison reads as zero difference.
    private func render(section: StorageSection) -> NSBitmapImageRep? {
        let manager = FileSyncManager()
        manager.storageLensReport = Self.report()
        let subject = StorageLensView(syncManager: manager, providerName: "Projects",
                                      onBuild: {}, onReveal: { _ in }, section: section)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The rightmost chromatic pixel on each scanline — the bar's edge.
    ///
    /// Chroma rather than "is it blue": the ground is `Color.primary` at 4% over a neutral window
    /// background and the row text is gray, so both are achromatic, while the bar is a hue at 16%.
    /// That keeps the measurement true whichever accent hue the host's defaults happen to carry.
    private func chromaEdges(_ rep: NSBitmapImageRep) -> [Int: Int] {
        var edges: [Int: Int] = [:]
        for y in 0..<rep.pixelsHigh {
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

    /// The distinct bar lengths on the page, largest first.
    ///
    /// Two calibrations, both learned from the first render rather than assumed. The bitmap is
    /// **2× on this display**, so these are device pixels and a 620pt canvas is 1240 wide — the
    /// tolerances below are in that unit. And a bar's rounded right corner spreads its edge over
    /// about ten scanlines, so edges within 14px are one bar; a tighter bucket reported the top
    /// bar three times and pushed the real ones out of the list.
    ///
    /// `beyondTheGlyph` drops the row's file-type glyph and the section header's icon, which are
    /// the only other chromatic ink on the page and sit inside the first 100 pixels.
    private func barEdges(_ rep: NSBitmapImageRep) -> [Int] {
        let beyondTheGlyph = 200
        var buckets: [Int] = []
        for edge in chromaEdges(rep).values.sorted(by: >) where edge > beyondTheGlyph {
            if !buckets.contains(where: { abs($0 - edge) <= 14 }) { buckets.append(edge) }
        }
        return buckets
    }

    /// The bars stand in the ratio of the files they measure.
    ///
    /// Asserted on **differences** between edges rather than on the edges themselves, which is
    /// what makes the numbers exact instead of approximate: every edge carries the row's left
    /// inset, and `(e₀ − eₖ) / (e₀ − e₃)` cancels it. A 4:3:2:1 ladder must normalise to
    /// 0, ⅓, ⅔, 1 — and a `fraction` stuck at 1, or measured against the wrong yardstick,
    /// collapses that spread.
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

    /// The other half of `showsBar`, and the direction that catches the rule inverted: the same
    /// four files, listed by age, draw no bar at all. Their file-type glyphs still paint — which is
    /// why `barEdges` measures past them rather than counting chromatic pixels.
    @Test func theAgeOrderedListDrawsNoBars() throws {
        let stale = try #require(render(section: .stale))
        let largest = try #require(render(section: .largest))
        #expect(barEdges(largest).count == 4, "the largest list lost its bars: \(barEdges(largest))")
        #expect(barEdges(stale).isEmpty, "the untouched list is drawing bars: \(barEdges(stale))")
    }
}
