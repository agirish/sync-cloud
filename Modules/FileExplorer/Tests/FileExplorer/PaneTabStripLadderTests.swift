import AppKit
import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// The strip's shedding ladder: the three rungs, and the two properties that make it a ladder
/// rather than a pile of thresholds. It never widens as it sheds, and it moves with the app's font
/// scale. The scale half is the trap: the pane bar's ladder is constant arithmetic, and copying its
/// shape here would keep drawing five chips at Large with their names squeezed out.
@MainActor
@Suite struct PaneTabStripLadderTests {

    private let short = ["Finance", "Photos", "Legal"]
    private let four = ["Finance", "Photos", "Legal", "Medical"]
    private let five = ["Finance", "Photos", "Legal", "Medical", "Immigration"]

    /// The widest pane at which this strip is no longer `full`: the point the ladder sheds at,
    /// which "sheds earlier at a bigger font" is a claim about.
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

    /// The roadmap's rung table, with the tab count stated: its widths are where a four- or
    /// five-tab strip meets each rung, not thresholds the code compares against. Three tabs at
    /// 340pt still get `full` (a test below). The "520+" row is a four-tab strip; five tabs need
    /// 526 (5 × 96 + four gaps + the trailing ＋), pinned separately below. The 340pt and 220pt
    /// rows, five tabs each, are the compact and chip tests below.
    @Test func theTableInTheRoadmapIsReproduced() {
        #expect(PaneTabStripLadder.layout(available: 520, titles: four, scale: 1).rung == .full)
    }

    @Test func fiveTabsCrossIntoFullFivePointsAbove520() {
        #expect(PaneTabStripLadder.layout(available: 520, titles: five, scale: 1).rung == .compact)
        #expect(PaneTabStripLadder.layout(available: 526, titles: five, scale: 1).rung == .full)
    }

    @Test func aTabNeverGrowsPastItsCap() {
        // A very wide pane with two tabs: uncapped they would be ~450pt each and the strip would
        // read as a segmented control.
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

    /// The rail's rung: one named tab and a menu for the rest. What must survive at 220pt is which
    /// folder this pane is showing, never a row of marks.
    @Test func theRailGetsTheChipRungWithEveryOtherTabBehindTheCount() {
        let layout = PaneTabStripLadder.layout(available: 220, titles: five, scale: 1)
        #expect(layout.rung == .chip)
        #expect(layout.visibleCount == 1)
        #expect(layout.overflowCount == 4)
    }

    // MARK: The two ladder properties

    /// Monotonic: from a wide pane down to the rail, what the strip draws never grows as the pane
    /// shrinks. A ladder with an inversion has a rung that can never be chosen.
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

    /// And it always fits: the point of shedding is that the row doesn't overflow its pane.
    @Test func everyRungFitsTheWidthItWasChosenFor() {
        for width in stride(from: CGFloat(900), through: 200, by: -4) {
            let layout = PaneTabStripLadder.layout(available: width, titles: five, scale: 1)
            #expect(PaneTabStripLadder.drawnWidth(layout, scale: 1) <= width + 0.01,
                    "the strip overflows at \(width)pt on the \(layout.rung.rawValue) rung")
        }
    }

    /// `.compact` never draws a single chip beside a chevron, the state `chipCeiling` refuses as
    /// worse than naming the active tab and menuing the rest. The ceiling must be priced for the
    /// narrowest compact row, `[tab] [tab] [overflow] [spacer] [＋]`, five children: priced a gap
    /// short, `layout` falls into that state in a 4pt band. Swept rather than spot-checked, because
    /// the band is narrow and moves with the scale.
    @Test(arguments: [CGFloat(1.0), 1.35]) func compactNeverDrawsOneChipBesideAChevron(scale: CGFloat) {
        for count in 1...8 {
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

    /// The trap. The app scales its own type, so five tabs that fit at the default don't at Large:
    /// a chip's floor is its chrome plus a legible stub of a name, and both move with the font.
    ///
    /// The floor is a measurement, not the constant 96, which is only its lower bound: at the
    /// largest size the chrome plus a five-character stub exceeds the constant, which follows from
    /// the first two lines here. A test that pinned 96 at every scale would pass with the
    /// measurement deleted.
    @Test func aLargerFontShedsEarlier() {
        #expect(PaneTabStripLadder.floorWidth(scale: 1) >= PaneTabStripLadder.minTabWidth)
        #expect(PaneTabStripLadder.floorWidth(scale: 1.35) > PaneTabStripLadder.floorWidth(scale: 1))
        // The claim in the width the user sees: the same five tabs stop fitting in a wider pane
        // once the type grows. A ladder of constants, the pane bar's shape, fails this.
        #expect(sheddingWidth(scale: 1.35) > sheddingWidth(scale: 1))
        // And at the wider pane where both are still `full`, the larger type gets the wider chip.
        let wide: CGFloat = 900
        #expect(PaneTabStripLadder.layout(available: wide, titles: five, scale: 1.35).tabWidth
                > PaneTabStripLadder.layout(available: wide, titles: five, scale: 1).tabWidth)
    }

    /// A longer name asks for a wider chip, up to the cap: the measurement is of the actual title,
    /// not a placeholder.
    @Test func aLongerNameWantsAWiderChip() {
        let brief = PaneTabStripLadder.naturalWidth(title: "US", scale: 1)
        let long = PaneTabStripLadder.naturalWidth(title: "Immigration Paperwork 2019", scale: 1)
        #expect(long > brief)
        #expect(long <= PaneTabStripLadder.maxTabWidth)
    }

    // MARK: The degenerate cases

    /// One tab still gets a real chip. Usually there is no strip (the pane checks `showsStrip`),
    /// but View ▸ Tab Bar keeps a one-tab strip on screen on purpose, and it must not be a strip
    /// with nothing in it but its ＋.
    @Test func oneTabIsLaidOutLikeAnyOther() {
        let layout = PaneTabStripLadder.layout(available: 620, titles: ["Finance"], scale: 1)
        #expect(layout.rung == .full)
        #expect(layout.visibleCount == 1)
        #expect(layout.overflowCount == 0)
        #expect(layout.tabWidth >= PaneTabStripLadder.floorWidth(scale: 1),
                "the one visible tab is drawn narrower than a chip's floor")
        #expect(layout.tabWidth <= PaneTabStripLadder.maxTabWidth)
    }

    /// A one-tab strip in a narrow pane reserves no room for a count it won't draw; that room
    /// belongs to the one thing this rung must keep, the name.
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
        // Not `>= 0`, which the production `max(0, min(…))` makes true by construction. The chip
        // must be wider than its chrome (mark, close button, the gap between them and padding on
        // both sides), or it leaves no room for a name, the state this rung exists to avoid. Today
        // ~14pt of name is left at 120pt; shrinking the rung by 24pt fails this.
        let chrome = PaneTabStripLadder.markSide + PaneTabStripLadder.closeSide
            + PaneTabStripLadder.contentGap + PaneTabStripLadder.tabPadding * 2
        #expect(layout.tabWidth > chrome,
                "the chip rung has no room left for a name: \(layout.tabWidth)pt against \(chrome)pt of chrome")
    }

    // MARK: Close Other Tabs, when the others are pinned

    /// Pins survive Close Other Tabs, so the number of tabs is not the number it would close. A
    /// `count < 2` gate would leave the item enabled on a strip where it does nothing. In this
    /// suite because `PaneTabStrip` is `@MainActor` and so is this one: from a nonisolated suite it
    /// compiles, then traps in `_swift_task_checkIsolatedSwift`, taking the whole bundle down.
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
        // A pinned tab's own menu still closes the unpinned others: pinning protects the tab, it
        // doesn't disarm the gesture.
        #expect(PaneTabStrip.closableOthers(of: pinnedA, in: [pinnedA, pinnedB, plain]) == 1)
    }

    /// …and the menu asks that rule, which the test above can't see: a `.disabled(items.count < 2)`
    /// on the item would leave the rule unused and every assertion above green. So this reads the
    /// real menu. A right-click is the one interaction a unit test can drive here: SwiftUI answers
    /// `NSView.menu(for:)` by hit-testing the point (as in `PaneBarCustomizeSheetTests`), which
    /// also checks the chip is aimable at all.
    @Test func theMenuDisablesCloseOtherTabsWhenEveryOtherTabIsPinned() throws {
        func tab(_ title: String, active: Bool = false, pinned: Bool = false) -> PaneTabStrip.Item {
            PaneTabStrip.Item(id: UUID(), title: title, markImageName: "folder.fill",
                              isActive: active, fullPath: "/r/\(title)", isPinned: pinned)
        }
        /// Right-clicks the first chip and returns its menu items by title and enablement.
        func menuOnFirstChip(of items: [PaneTabStrip.Item]) throws -> [(String, Bool)] {
            let strip = PaneTabStrip(items: items,
                                     onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in },
                                     onDuplicate: { _ in }, onCopyPath: { _ in }, onNew: {})
                .frame(width: 600, height: PaneTabStripLadder.stripHeight)
            let host = NSHostingView(rootView: AnyView(strip))
            host.frame = CGRect(x: 0, y: 0, width: 600, height: PaneTabStripLadder.stripHeight)
            // Borderless and never ordered in: a `.titled` window can't be parked off screen, since
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
        // Which chip was hit, before anything is read off its menu: the target is the only unpinned
        // tab here, so its menu offers "Pin Tab" where a pinned neighbour's offers "Unpin Tab".
        // Otherwise the wrong chip could answer the assertions below.
        #expect(allPinned.contains { $0.0 == "Pin Tab" },
                "the right-click did not land on the unpinned target chip — found \(allPinned.map(\.0))")
        let closeOthers = try #require(allPinned.first { $0.0 == "Close Other Tabs" },
                                       "the menu no longer offers Close Other Tabs — found \(allPinned.map(\.0))")
        #expect(!closeOthers.1,
                "Close Other Tabs is enabled on a strip where every other tab is pinned")

        // The control: one unpinned other, and the same item is live. Otherwise the check above
        // would pass on a menu whose every item was disabled.
        let oneClosable = try menuOnFirstChip(of: [tab("Target", active: true),
                                                  tab("Pinned A", pinned: true),
                                                  tab("Plain")])
        let live = try #require(oneClosable.first { $0.0 == "Close Other Tabs" })
        #expect(live.1, "Close Other Tabs is disabled even though an unpinned other exists")
    }

    /// The chip nests concentrically inside the strip card, on every corner, by arithmetic: an
    /// inner corner sits inside an outer one without the curves fighting when its radius is the
    /// outer radius less the gap. That needs the horizontal gutter to equal the vertical inset, so
    /// one radius serves both. Pinned as a relationship rather than three numbers, because the
    /// numbers are only right together: moving any one alone reopens the mismatch.
    @Test func theChipNestsConcentricallyInsideTheCard() {
        let verticalInset = (PaneTabStripLadder.stripHeight - PaneTabStripLadder.tabHeight) / 2
        #expect(PaneTabStripLadder.stripGutter == verticalInset, """
                the strip insets its chips by \(PaneTabStripLadder.stripGutter)pt across and \
                \(verticalInset)pt down — a single chip radius cannot be concentric on both
                """)
        #expect(PaneTabStripLadder.chipRadius == LiquidGlass.cardCornerRadius - verticalInset, """
                the chip's \(PaneTabStripLadder.chipRadius)pt corner sits \(verticalInset)pt inside \
                a \(LiquidGlass.cardCornerRadius)pt one — concentricity wants \
                \(LiquidGlass.cardCornerRadius - verticalInset)
                """)
        // And the radius is a stop on the scale rather than a number invented for the strip.
        #expect(Radius.all.contains(PaneTabStripLadder.chipRadius),
                "\(PaneTabStripLadder.chipRadius) is not on the radius scale")
        // The rule then has to clear that corner: see `ruleInset`, and
        // `theRuleEndsInsideTheChipItMarks` for the pixels.
        #expect(PaneTabStripLadder.ruleInset > PaneTabStripLadder.chipRadius, """
                the rule is inset \(PaneTabStripLadder.ruleInset)pt inside a \
                \(PaneTabStripLadder.chipRadius)pt corner, so its ends hang off the chip
                """)
    }
}

/// No gesture on a column row, ever. A tap gesture on a row swallows the mouse-up the List needs to
/// commit a selection, so most ⌘/⇧ clicks, and clicks with the slightest travel, select nothing
/// (see the note on `columnRow`). A source scan, because a `TapGesture` installs no recognizer an
/// `NSEvent` can reach, so no unit test can exercise the failure; the scan refuses the construct.
@Suite struct PaneColumnRowHasNoGestureTests {

    private func source() throws -> String { try SourceText.fileExplorer("PaneColumnsView.swift") }

    /// The row itself carries no gesture of any kind. Scoped to the row's own modifier chain,
    /// because `.onTapGesture` is legitimate elsewhere in the file: the trailing deselect filler is
    /// not a row and has no List selection to protect.
    @Test func theColumnRowCarriesNoGesture() throws {
        let code = try source()
        let row = try #require(code.range(of: ".tag(node.id)"), "the column row is gone")
        // Comment lines stripped: the note on the row names the constructs it forbids, and a scan
        // that read prose would convict the explanation.
        let chain = SourceText.codeOnly(String(code[row.upperBound...].prefix(4000)))
        for construct in ["TapGesture", "onTapGesture", "simultaneousGesture",
                          "highPriorityGesture", "DragGesture", ".gesture("] {
            #expect(!chain.contains(construct), """
                    `\(construct)` is back on the column row. It claims the mouse-down and the \
                    table never selects — 3 of 28 clicks landed last time. See the note on `columnRow`.
                    """)
        }
    }

    /// …and the column drill lives in the List's selection commit, so clicking a folder still opens
    /// its column.
    @Test func theListsSelectionCommitStillNavigates() throws {
        let code = try source()
        let setter = try #require(code.range(of: "set: { newValue in"), "the column selection binding is gone")
        let body = SourceText.codeOnly(String(code[setter.upperBound...].prefix(4000)))
        #expect(body.contains("navigation(for: row, depth: depth)"),
                "the column drill is gone — clicking a folder no longer opens its column")
        #expect(body.contains("PaneViewMode.clickNavigates(modifiers: clickModifiers)"),
                "the drill no longer refuses ⌘/⇧, so a multi-select click navigates as well")
        #expect(body.contains("DeferredColumnNavigation.isStillValid"),
                "the deferred navigation lost its staleness check")
    }

    /// With no gesture there is no ⌘-double-click, so Open in New Tab must stay reachable from the
    /// row's menu.
    @Test func openInNewTabIsStillReachableFromTheRowMenu() throws {
        let code = try SourceText.fileExplorer("FileTreeView.swift")
        #expect(code.contains("Label(\"Open in New Tab\""),
                "the row menu lost Open in New Tab, which is now its only pointer-driven route")
    }
}

/// The invariant the pane strip's travelling marker rests on, separate from the ladder suite
/// because it isn't about widths. `@MainActor`, and not optionally: `PaneTabStrip` is a SwiftUI
/// `View`, so `visible(_:slots:)` inherits main-actor isolation, and its closure in
/// `items.filter { !$0.isPinned }` carries it. Called from a nonisolated test it compiles, then
/// traps in `_swift_task_checkIsolatedSwift` with no message. A case that returns before that
/// closure (more pinned tabs than slots) passes either way and proves nothing about it.
@Suite @MainActor struct PaneTabStripActiveVisibilityTests {

    /// The sliding marker assumes exactly one source exists. `activeGround` is rendered only for
    /// the active item and carries a `matchedGeometryEffect`, so the effect is well-defined only
    /// while the active tab is among the ones drawn. `visible(_:slots:)` windows around the active
    /// index to keep it there, an invariant the marker depends on.
    @Test func theActiveTabSurvivesEveryWindowWidth() {
        for count in 1...8 {
            let items = (0..<count).map { i in
                PaneTabStrip.Item(id: UUID(), title: "Tab \(i)", markImageName: "folder",
                                  isActive: false, fullPath: "/x/\(i)")
            }
            for activeIndex in 0..<count {
                var withActive = items
                let original = withActive[activeIndex]
                withActive[activeIndex] = PaneTabStrip.Item(
                    id: original.id, title: original.title, markImageName: original.markImageName,
                    isActive: true, fullPath: original.fullPath)
                for slots in 1...count {
                    let shown = PaneTabStrip.visible(withActive, slots: slots)
                    let activeShown = shown.filter { $0.isActive }.count
                    #expect(activeShown == 1,
                            "active tab \(activeIndex) of \(count) is not shown at \(slots) slot(s) — the marker would have no source")
                }
            }
        }
    }
}
