import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// The strip's shedding ladder — the three rungs, and the two properties that make a ladder a
/// ladder rather than a pile of thresholds: it never widens as it sheds, and it moves with the
/// app's font scale.
///
/// The scale half is the one the v4.x roadmap calls out as a trap, and it is a real one: the pane
/// bar's ladder is constant arithmetic (the string `scale` does not appear in
/// `PaneBarArrangement.swift` at all) and copying its shape here would give a strip that keeps
/// drawing five chips at Large with their names squeezed out of them.
@MainActor
@Suite struct PaneTabStripLadderTests {

    private let short = ["Finance", "Photos", "Legal"]
    private let four = ["Finance", "Photos", "Legal", "Medical"]
    private let five = ["Finance", "Photos", "Legal", "Medical", "Immigration"]

    /// The widest pane at which this strip is no longer `full` — the point the ladder sheds at,
    /// which is what "sheds earlier at a bigger font" is a claim about.
    private func sheddingWidth(scale: CGFloat) -> CGFloat {
        var width: CGFloat = 900
        while width > 100 {
            if PaneTabStripLadder.layout(available: width, titles: five, scale: scale).rung != .full {
                return width
            }
            width -= 1
        }
        return 100
    }

    // MARK: The roadmap's table

    /// §1's rung table, reproduced **with the tab count stated** — the widths in it are the pane
    /// widths a four- or five-tab strip meets each rung at, not thresholds the code compares
    /// against. Three tabs at 340pt legitimately still get `full`, which is the test below.
    ///
    /// **Measured while writing this, and worth recording rather than rounding away:** five tabs at
    /// 520pt come out five points short of `full` — 5 × 96 + four gaps + the trailing ＋ is 526.
    /// The table's "520+" row is a four-tab strip, which is what this pins; the five-tab strip
    /// crosses at 526 and is pinned separately below so the number is written down somewhere.
    @Test func theTableInTheRoadmapIsReproduced() {
        #expect(PaneTabStripLadder.layout(available: 520, titles: four, scale: 1).rung == .full)
        #expect(PaneTabStripLadder.layout(available: 340, titles: five, scale: 1).rung == .compact)
        #expect(PaneTabStripLadder.layout(available: 220, titles: five, scale: 1).rung == .chip)
    }

    @Test func fiveTabsCrossIntoFullFivePointsAbove520() {
        #expect(PaneTabStripLadder.layout(available: 520, titles: five, scale: 1).rung == .compact)
        #expect(PaneTabStripLadder.layout(available: 526, titles: five, scale: 1).rung == .full)
    }

    @Test func aTabNeverGrowsPastItsCap() {
        // A very wide pane with two tabs: without the cap they would be ~450pt each and the strip
        // would read as a segmented control.
        let layout = PaneTabStripLadder.layout(available: 940, titles: ["A", "B"], scale: 1)
        #expect(layout.rung == .full)
        #expect(layout.tabWidth <= PaneTabStripLadder.maxTabWidth)
    }

    @Test func threeTabsStillFitWhereFiveWouldNot() {
        let three = PaneTabStripLadder.layout(available: 340, titles: short, scale: 1)
        #expect(three.rung == .full)
        #expect(three.visibleCount == 3)
    }

    @Test func theCompactRungFoldsTheSurplusRatherThanShrinkingPastTheFloor() {
        let layout = PaneTabStripLadder.layout(available: 340, titles: five, scale: 1)
        #expect(layout.rung == .compact)
        #expect(layout.tabWidth >= PaneTabStripLadder.minTabWidth)
        #expect(layout.visibleCount < five.count)
        #expect(layout.overflowCount == five.count - layout.visibleCount)
    }

    /// The rail's rung: one named tab and a menu for the rest. What must survive at 220pt is
    /// *which folder this pane is showing* — never a row of marks.
    @Test func theRailGetsTheChipRungWithEveryOtherTabBehindTheCount() {
        let layout = PaneTabStripLadder.layout(available: 220, titles: five, scale: 1)
        #expect(layout.rung == .chip)
        #expect(layout.visibleCount == 1)
        #expect(layout.overflowCount == 4)
    }

    // MARK: The two ladder properties

    /// Monotonic: at every width from a wide pane down to the rail, what the strip draws never
    /// grows as the pane shrinks. A ladder with an inversion has a rung that can never be chosen —
    /// `PaneBarLadder` documents living with exactly that, and this one must not.
    @Test func theLadderNeverWidensAsItSheds() {
        var previous = CGFloat.greatestFiniteMagnitude
        for width in stride(from: CGFloat(900), through: 180, by: -4) {
            let layout = PaneTabStripLadder.layout(available: width, titles: five, scale: 1)
            let drawn = PaneTabStripLadder.drawnWidth(layout, scale: 1)
            #expect(drawn <= previous + 0.01,
                    "the strip got WIDER at \(width)pt: \(drawn) after \(previous)")
            previous = drawn
        }
    }

    /// And it always fits: the whole point of shedding is that the row does not overflow its pane.
    @Test func everyRungFitsTheWidthItWasChosenFor() {
        for width in stride(from: CGFloat(900), through: 200, by: -4) {
            let layout = PaneTabStripLadder.layout(available: width, titles: five, scale: 1)
            #expect(PaneTabStripLadder.drawnWidth(layout, scale: 1) <= width + 0.01,
                    "the strip overflows at \(width)pt on the \(layout.rung.rawValue) rung")
        }
    }

    /// **The trap.** The app scales its own type, so the same five tabs that fit at the default do
    /// not at Large — and a chip's floor is its chrome plus a legible stub of a name, both of which
    /// move with the font.
    @Test func aLargerFontShedsEarlier() {
        #expect(PaneTabStripLadder.floorWidth(scale: 1.35) > PaneTabStripLadder.floorWidth(scale: 1))
        // The claim in the width the user actually sees: the same five tabs stop fitting in a WIDER
        // pane once the type grows. A ladder of constants — the pane bar's shape — returns the same
        // number at both scales, and this is the assertion it fails.
        #expect(sheddingWidth(scale: 1.35) > sheddingWidth(scale: 1))
        // And at the wider pane where both are still `full`, the larger type gets the wider chip.
        let wide: CGFloat = 900
        #expect(PaneTabStripLadder.layout(available: wide, titles: five, scale: 1.35).tabWidth
                > PaneTabStripLadder.layout(available: wide, titles: five, scale: 1).tabWidth)
    }

    /// The floor is a MEASUREMENT, not the constant 96 — that constant is only its lower bound.
    /// A test that pinned 96 at every scale would pass with the measurement deleted.
    @Test func theFloorIsMeasuredNotAssumed() {
        #expect(PaneTabStripLadder.floorWidth(scale: 1) >= PaneTabStripLadder.minTabWidth)
        // At the largest text size the chrome plus a five-character stub exceeds the constant.
        #expect(PaneTabStripLadder.floorWidth(scale: 1.35) > PaneTabStripLadder.minTabWidth)
    }

    /// A longer name asks for a wider chip, up to the cap — the measurement is of the actual title,
    /// not of a placeholder.
    @Test func aLongerNameWantsAWiderChip() {
        let brief = PaneTabStripLadder.naturalWidth(title: "US", scale: 1)
        let long = PaneTabStripLadder.naturalWidth(title: "Immigration Paperwork 2019", scale: 1)
        #expect(long > brief)
        #expect(long <= PaneTabStripLadder.maxTabWidth)
    }

    // MARK: The degenerate cases

    /// One tab draws no strip, so the layout for one is inert rather than a rung with a width that
    /// something might draw.
    @Test func oneTabHasNoStripToLayOut() {
        let layout = PaneTabStripLadder.layout(available: 620, titles: ["Finance"], scale: 1)
        #expect(layout.tabWidth == 0)
        #expect(layout.overflowCount == 0)
    }

    /// A pane narrower than anything sensible still answers, and answers with the rung that keeps
    /// the active tab's name.
    @Test func anAbsurdlyNarrowPaneStillNamesTheActiveTab() {
        let layout = PaneTabStripLadder.layout(available: 120, titles: five, scale: 1)
        #expect(layout.rung == .chip)
        #expect(layout.visibleCount == 1)
        #expect(layout.tabWidth >= 0)
    }
}
