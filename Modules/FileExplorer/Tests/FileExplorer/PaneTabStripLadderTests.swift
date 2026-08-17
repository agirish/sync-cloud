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

    /// **`.compact` never draws a SINGLE chip beside a chevron** — the state `chipCeiling` exists
    /// to refuse, in its own words "strictly worse than naming the active tab and menuing the rest".
    ///
    /// It was reachable, and the arithmetic is why: the ceiling was priced with
    /// `gaps(children: 4)` while the narrowest compact row it stands in for —
    /// `[tab] [tab] [overflow] [spacer] [＋]` — has FIVE children. One gap, 4pt, of daylight between
    /// the two prices, and inside it `layout` skipped the chip rung, failed to fit the second chip,
    /// and returned exactly the rung the ceiling had just declined to return. Twelve or more tabs at
    /// 269–270pt, scale 1.0, seventeen (count, width) pairs.
    ///
    /// Swept rather than spot-checked at the two failing widths: the band is narrow and moves with
    /// the scale, so a fixture pinned to 269 would pass the moment a font metric shifted it.
    @Test(arguments: [CGFloat(1.0), 1.35]) func compactNeverDrawsOneChipBesideAChevron(scale: CGFloat) {
        for count in 2...20 {
            let titles = (0..<count).map { "Folder\($0)" }
            var width = CGFloat(120)
            while width <= 900 {
                let layout = PaneTabStripLadder.layout(available: width, titles: titles, scale: scale)
                #expect(!(layout.rung == .compact && layout.visibleCount == 1),
                        "one chip and a chevron at \(width)pt with \(count) tabs, scale \(scale)")
                width += 1
            }
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

    /// **One tab still gets a real chip.** Usually there is no strip at all — the pane checks
    /// `showsStrip` — but View ▸ Tab Bar keeps a one-tab strip on screen on purpose, and this
    /// returned zero width for that case: a strip with nothing in it but its ＋.
    @Test func oneTabIsLaidOutLikeAnyOther() {
        let layout = PaneTabStripLadder.layout(available: 620, titles: ["Finance"], scale: 1)
        #expect(layout.rung == .full)
        #expect(layout.visibleCount == 1)
        #expect(layout.overflowCount == 0)
        #expect(layout.tabWidth >= PaneTabStripLadder.floorWidth(scale: 1),
                "the one visible tab is drawn narrower than a chip's floor")
        #expect(layout.tabWidth <= PaneTabStripLadder.maxTabWidth)
    }

    /// A one-tab strip in a narrow pane reserves no room for a count it will not draw — that track
    /// belongs to the one thing this rung has to keep, the name.
    @Test func aOneTabChipRungReservesNoCount() {
        let narrow = PaneTabStripLadder.layout(available: 200, titles: ["Immigration"], scale: 1)
        let withCount = PaneTabStripLadder.layout(available: 200, titles: ["Immigration", "Photos"], scale: 1)
        #expect(narrow.overflowCount == 0)
        #expect(narrow.tabWidth > withCount.tabWidth,
                "the one-tab strip gave up room for a count that is never drawn")
        #expect(PaneTabStripLadder.drawnWidth(narrow, scale: 1) <= 200.01)
    }

    /// Never more chips than there are tabs, at any width.
    @Test func theRungNeverClaimsMoreChipsThanTabs() {
        for width in stride(from: CGFloat(1400), through: 120, by: -7) {
            for titles in [["A"], ["A", "B"], five] {
                let layout = PaneTabStripLadder.layout(available: width, titles: titles, scale: 1)
                #expect(layout.visibleCount <= titles.count,
                        "\(layout.visibleCount) chips claimed for \(titles.count) tabs at \(width)pt")
                #expect(layout.overflowCount >= 0)
            }
        }
    }

    /// No tabs at all is not a state the app can reach (`PaneTabList` is never empty), but the
    /// ladder is public and must answer rather than divide by zero.
    @Test func noTabsAnswersWithNothingToDraw() {
        let layout = PaneTabStripLadder.layout(available: 620, titles: [], scale: 1)
        #expect(layout.visibleCount == 0)
        #expect(layout.tabWidth == 0)
    }

    /// A pane narrower than anything sensible still answers, and answers with the rung that keeps
    /// the active tab's name.
    @Test func anAbsurdlyNarrowPaneStillNamesTheActiveTab() {
        let layout = PaneTabStripLadder.layout(available: 120, titles: five, scale: 1)
        #expect(layout.rung == .chip)
        #expect(layout.visibleCount == 1)
        #expect(layout.tabWidth >= 0)
    }

    // MARK: Close Other Tabs, when the others are pinned

    /// **Pins survive Close Other Tabs**, so the number of tabs is not the number it would close.
    /// A `count < 2` gate leaves the item enabled on a strip where it does nothing — the one item
    /// on that menu that would lie about being available.
    ///
    /// In *this* suite because `PaneTabStrip` is `@MainActor` and this one is too. Written into the
    /// gesture suite below first, it compiled and then trapped at runtime in
    /// `_swift_task_checkIsolatedSwift` — an isolation crash rather than a failure, which takes the
    /// whole bundle down and reports as `signal code 5` with no test named.
    @Test func closeOtherTabsCountsOnlyTheTabsItWouldActuallyClose() {
        func tab(_ title: String, pinned: Bool = false) -> PaneTabStrip.Item {
            PaneTabStrip.Item(id: UUID(), title: title, markImageName: "folder.fill",
                              isActive: false, fullPath: "/r/\(title)", isPinned: pinned)
        }
        let target = tab("Target")
        let pinnedA = tab("Pinned A", pinned: true)
        let pinnedB = tab("Pinned B", pinned: true)
        let plain = tab("Plain")

        #expect(PaneTabStrip.closableOthers(of: target, in: [target, pinnedA, pinnedB]) == 0,
                "a strip whose every other tab is pinned still offers to close them")
        #expect(PaneTabStrip.closableOthers(of: target, in: [target, pinnedA, plain]) == 1)
        #expect(PaneTabStrip.closableOthers(of: target, in: [target]) == 0,
                "a lone tab counted itself")
        // A pinned tab's own menu still closes the unpinned others — pinning protects the tab, it
        // does not disarm the gesture.
        #expect(PaneTabStrip.closableOthers(of: pinnedA, in: [pinnedA, pinnedB, plain]) == 1)
    }

    /// **…and the MENU asks that rule**, which the test above cannot see.
    ///
    /// `closableOthers` had exactly one reader — the test. Putting `.disabled(items.count < 2)`
    /// back on the item leaves the rule in place, every assertion above green, and the inert item
    /// back on the menu: the "extracted for testability, one revert from unused" shape this repo
    /// has shipped before. So this reads the REAL menu.
    ///
    /// Right-clicking a hosted SwiftUI view is the one interaction a unit test can drive here —
    /// SwiftUI answers `NSView.menu(for:)` by hit-testing the point, which
    /// `PaneBarCustomizeSheetTests` established and which also makes this a check that the chip is
    /// aimable at all. A `TapGesture` would not be reachable; a context menu is.
    @Test func theMenuDisablesCloseOtherTabsWhenEveryOtherTabIsPinned() throws {
        func tab(_ title: String, active: Bool = false, pinned: Bool = false) -> PaneTabStrip.Item {
            PaneTabStrip.Item(id: UUID(), title: title, markImageName: "folder.fill",
                              isActive: active, fullPath: "/r/\(title)", isPinned: pinned)
        }
        /// Right-clicks the FIRST chip and returns its menu items by title and enablement.
        func menuOnFirstChip(of items: [PaneTabStrip.Item]) throws -> [(String, Bool)] {
            let strip = PaneTabStrip(items: items,
                                     onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in },
                                     onDuplicate: { _ in }, onCopyPath: { _ in }, onNew: {})
                .frame(width: 600, height: PaneTabStripLadder.stripHeight)
            let host = NSHostingView(rootView: AnyView(strip))
            host.frame = CGRect(x: 0, y: 0, width: 600, height: PaneTabStripLadder.stripHeight)
            // Borderless and never ordered in: a `.titled` window cannot be parked off screen —
            // `constrainFrameRect` drags it back over whatever he is doing.
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            // Inside the first chip: past the leading edge, at the row's middle.
            let point = CGPoint(x: 30, y: host.bounds.midY)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
                                                        location: host.convert(point, to: nil),
                                                        modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1),
                                     "could not synthesize a right-click")
            let menu = try #require(host.menu(for: event),
                                    "right-clicking a tab chip offered no menu at all — it is not aimable")
            return menu.items.map { ($0.title, $0.isEnabled) }
        }

        // Three tabs, and the two that are not the target are pinned: nothing to close.
        let allPinned = try menuOnFirstChip(of: [tab("Target", active: true),
                                                 tab("Pinned A", pinned: true),
                                                 tab("Pinned B", pinned: true)])
        // WHICH chip was hit, before anything is read off its menu: the target is the only unpinned
        // tab in this fixture, so its menu offers "Pin Tab" where a pinned neighbour's would offer
        // "Unpin Tab". Without this the assertions below could be answered by the wrong chip.
        #expect(allPinned.contains { $0.0 == "Pin Tab" },
                "the right-click did not land on the unpinned target chip — found \(allPinned.map(\.0))")
        let closeOthers = try #require(allPinned.first { $0.0 == "Close Other Tabs" },
                                       "the menu no longer offers Close Other Tabs — found \(allPinned.map(\.0))")
        #expect(!closeOthers.1,
                "Close Other Tabs is enabled on a strip where every other tab is pinned")

        // The control: one unpinned other, and the same item is live. Without this the check above
        // would pass just as well on a menu whose every item was disabled.
        let oneClosable = try menuOnFirstChip(of: [tab("Target", active: true),
                                                  tab("Pinned A", pinned: true),
                                                  tab("Plain")])
        let live = try #require(oneClosable.first { $0.0 == "Close Other Tabs" })
        #expect(live.1, "Close Other Tabs is disabled even though an unpinned other exists")
    }
}


/// The pane column's ⌘-double-click, which opens a folder in a new tab.
///
/// A source scan, and it is the honest form: the gesture cannot be exercised from a test — a
/// `TapGesture` installs no recognizer an `NSEvent` can reach, which this repo has measured more
/// than once. What a scan CAN hold is that the gesture exists, that it is a *double*, that it is a
/// sibling of the single-tap navigation rather than a replacement for it, and that it is gated on
/// ⌘ and on a folder — the four things that make it not break plain clicking.
@Suite struct PaneColumnOpenInNewTabGestureTests {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/PaneColumnsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The positive control: the scan reads the file it claims to.
    @Test func theScanCanActuallyFail() throws {
        let code = try source()
        #expect(code.contains("struct PaneColumnsView"))
        #expect(!code.contains("a string that is definitely not in the columns view"))
    }

    /// **Drag-to-reorder exists, is simultaneous, and needs real movement.** Fig. 8 calls this the
    /// free half of the drag work (dropping FILES on a tab is the expensive half and is not here).
    /// The three things that keep it from breaking tab-switching: a minimum distance, a
    /// `simultaneousGesture` so the `Button` still fires, and an index computed from the chip's own
    /// stride rather than a drop target that could disagree with what is drawn.
    @Test func tabsCanBeDraggedIntoAnotherOrder() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/PaneTabStrip.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        #expect(code.contains("struct PaneTabStrip"), "this is not the strip — the scan is vacuous")
        let gesture = try #require(code.range(of: "DragGesture(minimumDistance: 6)"),
                                   "the reorder drag is gone, or fires on a click")
        let body = String(code[gesture.upperBound...].prefix(900))
        #expect(body.contains("onReorder("), "the drag is wired to nothing")
        #expect(body.contains("PaneTabStripLadder.tabGap"),
                "the drop index ignores the gap between chips, so it drifts one tab per few dragged")
        #expect(code.contains(".simultaneousGesture(\n            DragGesture(minimumDistance: 6)")
                || code.contains(".simultaneousGesture(DragGesture(minimumDistance: 6)"),
                "the reorder drag is not simultaneous — it can swallow the click that switches tabs")
    }

    @Test func aCommandDoubleClickOnAFolderOpensItInANewTab() throws {
        let code = try source()
        let gesture = try #require(code.range(of: "TapGesture(count: 2)"),
                                   "the ⌘-double-click gesture is gone")
        let body = String(code[gesture.upperBound...].prefix(400))
        #expect(body.contains("clickModifiers.contains(.command)"),
                "the double-click opens a tab without ⌘ — plain double-click now forks the pane")
        #expect(body.contains("node.isDirectory"), "a FILE can be opened as a tab")
        #expect(body.contains("delegate.canOpenInNewTab"),
                "a host with no strip is offered the gesture anyway")
        #expect(body.contains("handleOpenInNewTab"), "the gesture is wired to nothing")
    }

    /// **Simultaneous, and declared beside the single tap rather than around it.** The single-click
    /// navigation is the pane's most delicate contract — it already has a "dead click" regression in
    /// its history — and a double-tap that consumed the first click would take column navigation
    /// with it.
    @Test func theDoubleTapDoesNotReplaceTheSingleTap() throws {
        let code = try source()
        #expect(code.contains(".simultaneousGesture(TapGesture(count: 2)"),
                "the double-click is not a simultaneous gesture — it can swallow the single click")
        let double = try #require(code.range(of: ".simultaneousGesture(TapGesture(count: 2)"))
        let single = try #require(code.range(of: ".simultaneousGesture(TapGesture().onEnded"),
                                  "the single-click column navigation is gone")
        // **The order the source states, asserted as an order.** This read
        // `double.lowerBound < single.lowerBound || single.lowerBound < double.lowerBound`, which is
        // `a < b || b < a` over two distinct ranges — true of every arrangement of the two, so it
        // could not fail on the thing this test is named for. The claim beside the gesture is
        // specific: the double is "Declared BEFORE the single-tap gesture so the two are siblings
        // rather than one wrapping the other".
        #expect(double.lowerBound < single.lowerBound, """
                the ⌘-double-click is declared AFTER the single tap — the two are no longer in the \
                order the source describes, and a re-order here is how one ends up wrapping the other
                """)
        // …and beside it, not somewhere else in the file: siblings are adjacent modifiers on one
        // row, so the single tap follows within a few lines of the double. A `single` matched in
        // some other subtree would satisfy the order above while proving nothing about this row.
        #expect(code.distance(from: double.upperBound, to: single.lowerBound) < 400, """
                the two gestures are \(code.distance(from: double.upperBound, to: single.lowerBound)) \
                characters apart — they are no longer declared beside each other on the same row
                """)
        #expect(code.components(separatedBy: ".simultaneousGesture(TapGesture().onEnded").count - 1 == 1,
                "there is more than one single-tap handler on a column row")
    }
}
