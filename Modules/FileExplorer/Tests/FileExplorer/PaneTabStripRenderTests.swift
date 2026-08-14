import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The strip, **rendered and read back**, in light and dark.
///
/// The ladder tests prove the arithmetic; none of them can see whether a chip's name is drawn,
/// whether the active tab is distinguishable from the parked ones, or whether the ✕ paints at all.
/// This repo's own record is that geometry does not see what a person sees — a blank overview row
/// shipped past 988 green tests — so the claims that matter here are made in pixels:
///
/// - **The active tab is visibly the active one.** The whole strip is otherwise five identical
///   chips, and the accent rule under the live tab is the only thing that says which folder the
///   pane below is showing.
/// - **Each chip draws its name.** A chip squeezed to the floor with its title clipped out of it is
///   exactly the failure the measured floor exists to prevent, and it is invisible to the ladder.
/// - **The mark distinguishes two tabs with the same name**, which is the case the mark is on the
///   chip for at all: two "Documents" from different clouds.
///
/// `.machinePinned(.pixelSampling)` — it reads pixels out of a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneTabStripRenderTests {

    func item(_ title: String, active: Bool = false, mark: String = "folder.fill",
                     path: String = "/Users/x/Documents", pinned: Bool = false) -> PaneTabStrip.Item {
        PaneTabStrip.Item(id: UUID(), title: title, markImageName: mark,
                          isActive: active, fullPath: path, isPinned: pinned)
    }

    /// Mounts a strip at `width` and returns the bitmap.
    ///
    /// The backdrop is a flat fill rather than the pane's card, for `CommandPaletteRenderTests`'
    /// measured reason: a glass wrapper renders the subject beneath it as white through a bare
    /// hosting view, and every colour assertion then reads zero.
    func render(items: [PaneTabStrip.Item], width: CGFloat,
                       scheme: ColorScheme = .light, scale: CGFloat = 1) -> NSBitmapImageRep {
        let subject = PaneTabStrip(items: items,
                                   onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in },
                                   onDuplicate: { _ in }, onCopyPath: { _ in }, onNew: {})
            .environment(\.appFontScale, scale)
            .frame(width: width, height: PaneTabStripLadder.stripHeight)
            .background(scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.15)
                                        : Color(red: 0.95, green: 0.95, blue: 0.96))
            .environment(\.colorScheme, scheme)
            // The app pins this on its own window; without it SwiftUI renders the whole subject as
            // an inactive window's desaturated version and every colour read here is of something
            // the user never sees.
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(x: 0, y: 0, width: width, height: PaneTabStripLadder.stripHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels differing from the image's own corner — its background — which is read out of the
    /// same sRGB bitmap rather than built by hand (`NSColor(white:)` is in the generic gray space
    /// and throws on `redComponent`).
    func inked(_ rep: NSBitmapImageRep, in box: NSRect? = nil) -> Int {
        guard let background = rep.colorAt(x: 1, y: 1) else { return 0 }
        let region = box ?? NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        var count = 0
        for y in Int(region.minY)..<min(rep.pixelsHigh, Int(region.maxY)) {
            for x in Int(region.minX)..<min(rep.pixelsWide, Int(region.maxX)) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - background.redComponent),
                       max(abs(c.greenComponent - background.greenComponent),
                           abs(c.blueComponent - background.blueComponent))) > 0.04 { count += 1 }
            }
        }
        return count
    }

    /// Recognisably-accent pixels — the rule under the active tab.
    func accentPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.blueComponent - c.redComponent > 0.25 && c.blueComponent > 0.4 { count += 1 }
            }
        }
        return count
    }

    /// Differing pixels inside a box.
    ///
    /// **This, not an ink count, is how a glyph on a filled ground is measured.** The active chip's
    /// raised ground already differs from the strip's background at every pixel of the title box,
    /// so "pixels unlike the backdrop" saturates and reads the same with the name drawn and with it
    /// blanked — measured, on the first cut of these tests.
    func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in box: NSRect) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for y in Int(box.minY)..<min(a.pixelsHigh, Int(box.maxY)) {
            for x in Int(box.minX)..<min(a.pixelsWide, Int(box.maxX)) {
                guard let pa = a.colorAt(x: x, y: y), let pb = b.colorAt(x: x, y: y) else { continue }
                if abs(pa.redComponent - pb.redComponent) > 0.01
                    || abs(pa.greenComponent - pb.greenComponent) > 0.01
                    || abs(pa.blueComponent - pb.blueComponent) > 0.01 { differing += 1 }
            }
        }
        return differing
    }

    func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let pa = a.colorAt(x: x, y: y), let pb = b.colorAt(x: x, y: y) else { continue }
                if abs(pa.redComponent - pb.redComponent) > 0.01
                    || abs(pa.greenComponent - pb.greenComponent) > 0.01
                    || abs(pa.blueComponent - pb.blueComponent) > 0.01 { differing += 1 }
            }
        }
        return differing
    }

    // MARK: The positive control

    /// Everything below asserts ink somewhere. A harness that rendered an empty canvas would make
    /// the *comparisons* pass while proving nothing, so this is the floor they all stand on.
    @Test func theStripDrawsSomethingAtAll() {
        let rep = render(items: [item("Finance", active: true), item("Photos")], width: 620)
        #expect(inked(rep) > 400, "the strip rendered blank — every test below is vacuous")
    }

    // MARK: What a person has to be able to see

    /// Which tab is live. Without this the strip is five identical chips and nothing on screen says
    /// which folder the pane belongs to.
    @Test func theActiveTabIsDrawnDifferentlyFromTheParkedOnes() {
        let ids = [UUID(), UUID()]
        func strip(activeIndex: Int) -> [PaneTabStrip.Item] {
            [PaneTabStrip.Item(id: ids[0], title: "Finance", markImageName: "folder.fill",
                               isActive: activeIndex == 0, fullPath: "/x/Finance"),
             PaneTabStrip.Item(id: ids[1], title: "Photos", markImageName: "folder.fill",
                               isActive: activeIndex == 1, fullPath: "/x/Photos")]
        }
        let first = render(items: strip(activeIndex: 0), width: 620)
        let second = render(items: strip(activeIndex: 1), width: 620)
        // Not merely "different somewhere": moving the active state moves a raised ground and a
        // 2pt rule across a whole chip, which is hundreds of pixels.
        #expect(differingPixels(first, second) > 300)
    }

    /// The accent rule itself, in both appearances. `.quaternary` grounds are appearance-dependent
    /// and can vanish in one scheme while surviving in the other — the rule must not.
    @Test func theAccentRuleUnderTheActiveTabIsPaintedInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let live = render(items: [item("Finance", active: true), item("Photos")],
                              width: 620, scheme: scheme)
            let parked = render(items: [item("Finance"), item("Photos")], width: 620, scheme: scheme)
            #expect(accentPixels(live) > accentPixels(parked) + 40,
                    "no accent rule under the active tab in \(scheme)")
        }
    }

    /// A chip squeezed to the floor still draws its name. This is what the measured floor is for,
    /// and the ladder cannot see it: `visibleCount` is just as happy with a chip whose title was
    /// clipped away entirely.
    ///
    /// **Differential, and it has to be.** The first cut asked for ink inside the title box of the
    /// ACTIVE chip and passed with the `Text` replaced by `Text("")` — the active tab's raised
    /// ground inks that box on its own. Rendering the same strip with the title blanked and
    /// subtracting is the only form of this claim that the ground cannot satisfy.
    @Test func aChipAtTheFloorStillDrawsItsName() {
        let ids = (0..<5).map { _ in UUID() }
        func five(firstTitle: String) -> [PaneTabStrip.Item] {
            let titles = [firstTitle, "Photos", "Legal", "Medical", "Immigration"]
            return zip(ids, titles.enumerated()).map { id, pair in
                PaneTabStrip.Item(id: id, title: pair.element, markImageName: "folder.fill",
                                  isActive: pair.offset == 0, fullPath: "/x/\(pair.element)")
            }
        }
        let layout = PaneTabStripLadder.layout(available: 340,
                                               titles: five(firstTitle: "Finance").map(\.title),
                                               scale: 1)
        #expect(layout.rung == .compact, "this fixture is meant to be on the squeezed rung")

        let named = render(items: five(firstTitle: "Finance"), width: 340)
        let blank = render(items: five(firstTitle: ""), width: 340)
        let box = titleBox(of: named, tabWidth: layout.tabWidth)
        #expect(differingPixels(named, blank, in: box) > 100,
                "the chip's name is not drawn at the floor width")
    }

    /// The first chip's title box in PIXELS: past the gutter, the mark and the gap, stopping short
    /// of the ✕. The bitmap is 2× on this display, so a box in points would read the left half of
    /// the strip and call it a title.
    func titleBox(of rep: NSBitmapImageRep, tabWidth: CGFloat) -> NSRect {
        let pixelsPerPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        let start = LiquidGlass.cardGutter + PaneTabStripLadder.tabPadding
            + PaneTabStripLadder.markSide + PaneTabStripLadder.contentGap
        let end = LiquidGlass.cardGutter + tabWidth
            - PaneTabStripLadder.tabPadding - PaneTabStripLadder.closeSide
        return NSRect(x: start * pixelsPerPoint, y: 0,
                      width: (end - start) * pixelsPerPoint, height: CGFloat(rep.pixelsHigh))
    }

    /// The case the mark is on the chip for: two tabs with the SAME name from different sources.
    /// With the mark dropped these two strips would be pixel-identical.
    @Test func theProviderMarkTellsTwoSameNamedTabsApart() {
        let same = render(items: [item("Documents", active: true, mark: "folder.fill"),
                                  item("Documents", mark: "folder.fill")], width: 620)
        let mixed = render(items: [item("Documents", active: true, mark: "folder.fill"),
                                   item("Documents", mark: "externaldrive.fill")], width: 620)
        #expect(differingPixels(same, mixed) > 30,
                "the two chips render identically — the provider mark is not being drawn")
    }

    /// The narrow rung the Organize/Storage rail gets. What must survive at 220pt is the active
    /// tab's NAME — never a row of marks.
    @Test func theRailWidthStillNamesTheActiveTab() {
        let five = [item("Immigration", active: true), item("Photos"), item("Legal"),
                    item("Medical"), item("Finance")]
        let layout = PaneTabStripLadder.layout(available: 220, titles: five.map(\.title), scale: 1)
        #expect(layout.rung == .chip)

        // Differential for the same reason as the compact rung above: the chip menu carries the
        // active ground, which inks the title box whether or not a name is drawn on it.
        let named = render(items: five, width: 220)
        let blank = render(items: [item("", active: true), item("Photos"), item("Legal"),
                                   item("Medical"), item("Finance")], width: 220)
        let box = titleBox(of: named, tabWidth: layout.tabWidth)
        #expect(differingPixels(named, blank, in: box) > 100,
                "the chip rung drew no name for the active tab")
    }

    /// The chip rung draws the count of parked tabs — the number is the only thing on that rung
    /// that says the strip holds more than the one folder it names.
    @Test func theChipRungDrawsHowManyTabsAreParked() {
        let five = [item("Immigration", active: true), item("Photos"), item("Legal"),
                    item("Medical"), item("Finance")]
        let two = [item("Immigration", active: true), item("Photos")]
        #expect(PaneTabStripLadder.layout(available: 220, titles: five.map(\.title), scale: 1).rung == .chip)
        #expect(PaneTabStripLadder.layout(available: 220, titles: two.map(\.title), scale: 1).rung == .chip)

        // "4" against "1": same rung, same active chip, different count — so the pixels that differ
        // are the count itself. An ink count could not tell these apart at all.
        let many = render(items: five, width: 220)
        let few = render(items: two, width: 220)
        // The count's own band: past the chip (which ends around half way on this fixture) and
        // short of the ＋. Measured off the render rather than guessed — the first cut of this box
        // started at 55% and sat just past the digit, which reported three differing pixels and
        // read exactly like "the count is not drawn".
        let countBox = NSRect(x: CGFloat(many.pixelsWide) * 0.52, y: 0,
                              width: CGFloat(many.pixelsWide) * 0.20, height: CGFloat(many.pixelsHigh))
        #expect(differingPixels(many, few, in: countBox) > 20,
                "the chip rung draws no count — nothing says the other tabs exist")
        // And it is not merely a smudge: a clipped digit was the state this rung shipped in for
        // three renders, so the count's own ink is compared against the empty band beside it.
        let emptyBand = NSRect(x: CGFloat(many.pixelsWide) * 0.75, y: 0,
                               width: CGFloat(many.pixelsWide) * 0.10, height: CGFloat(many.pixelsHigh))
        #expect(inked(many, in: countBox) > inked(many, in: emptyBand) + 40,
                "the chip rung's count is clipped to almost nothing")
    }

    /// **View ▸ Tab Bar at one tab draws a real chip, not a bare ＋.** The ladder used to answer
    /// "zero wide" for a one-tab strip on the reasoning that one tab draws no strip — true of the
    /// PANE's decision, and false of this one, which is the state that switch exists to produce.
    @Test func aOneTabStripDrawsItsTab() {
        let rep = render(items: [item("Finance", active: true)], width: 620)
        let named = render(items: [item("Finance", active: true)], width: 620)
        let blank = render(items: [item("", active: true)], width: 620)
        #expect(inked(rep) > 200, "a one-tab strip drew almost nothing")
        let box = titleBox(of: named,
                           tabWidth: PaneTabStripLadder.layout(available: 620 - 10,
                                                               titles: ["Finance"], scale: 1).tabWidth)
        #expect(differingPixels(named, blank, in: box) > 100,
                "the one visible tab has no name drawn on it")
    }

    /// A lone tab wears no ✕ — clicking it would close the window, since there is no tab left to
    /// fall back to. The count is what decides it, so the same chip drawn beside a second tab does
    /// have one.
    ///
    /// **The two strips are made to share a layout on purpose.** Both chips are titled "Finance" in
    /// a wide pane, so the full rung caps them both at the same natural width and the first chip
    /// occupies the same box in each render — leaving the ✕ as the only thing that can differ
    /// there. Comparing a one-tab strip against a two-tab one at their own widths compares two
    /// different boxes, and an ink count inside the active chip's ground saturates either way.
    @Test func aLoneTabHasNoCloseButton() {
        let alone = render(items: [item("Finance", active: true)], width: 900)
        let paired = render(items: [item("Finance", active: true), item("Finance")], width: 900)
        let width = PaneTabStripLadder.layout(available: 890, titles: ["Finance"], scale: 1).tabWidth
        #expect(width == PaneTabStripLadder.layout(available: 890, titles: ["Finance", "Finance"],
                                                   scale: 1).tabWidth,
                "the fixture's two strips no longer share a chip width — the box below compares nothing")

        let perPoint = alone.size.width > 0 ? CGFloat(alone.pixelsWide) / alone.size.width : 1
        let closeBox = NSRect(
            x: (LiquidGlass.cardGutter + width - PaneTabStripLadder.tabPadding
                - PaneTabStripLadder.closeSide) * perPoint,
            y: 0,
            width: PaneTabStripLadder.closeSide * perPoint,
            height: CGFloat(alone.pixelsHigh))
        #expect(differingPixels(alone, paired, in: closeBox) > 20,
                "the lone tab draws a ✕ that would close the window")
    }

    // MARK: Pinned tabs

    /// A pinned chip wears a pin where an unpinned one wears its ✕ — the two strips are otherwise
    /// identical, so the box isolates that slot.
    @Test func aPinnedTabWearsAPinInsteadOfItsCloseButton() {
        let ids = [UUID(), UUID()]
        func strip(pinnedFirst: Bool) -> [PaneTabStrip.Item] {
            [PaneTabStrip.Item(id: ids[0], title: "Finance", markImageName: "folder.fill",
                               isActive: true, fullPath: "/x/Finance", isPinned: pinnedFirst),
             PaneTabStrip.Item(id: ids[1], title: "Finance", markImageName: "folder.fill",
                               isActive: false, fullPath: "/x/Photos", isPinned: false)]
        }
        let pinned = render(items: strip(pinnedFirst: true), width: 900)
        let plain = render(items: strip(pinnedFirst: false), width: 900)
        let width = PaneTabStripLadder.layout(available: 890, titles: ["Finance", "Finance"],
                                              scale: 1).tabWidth
        let perPoint = pinned.size.width > 0 ? CGFloat(pinned.pixelsWide) / pinned.size.width : 1
        let slot = NSRect(x: (LiquidGlass.cardGutter + width - PaneTabStripLadder.tabPadding
                             - PaneTabStripLadder.closeSide) * perPoint,
                          y: 0,
                          width: PaneTabStripLadder.closeSide * perPoint,
                          height: CGFloat(pinned.pixelsHigh))
        #expect(differingPixels(pinned, plain, in: slot) > 20,
                "a pinned tab is drawn exactly like an unpinned one — nothing says it is pinned")
        // The name is untouched: pinning is a position and a protection, not a shrink to mark-only.
        let title = titleBox(of: pinned, tabWidth: width)
        #expect(differingPixels(pinned, plain, in: title) < 20, "pinning moved the chip's name")
    }

    /// **Pinned tabs never fold away.** They are pinned precisely so they stay reachable, and the
    /// active tab is still named by the header underneath it when it folds.
    @Test func pinnedTabsKeepTheirSlotsWhenTheStripRunsOutOfRoom() {
        let items = [item("Pinned", pinned: true), item("A"), item("B"), item("C"), item("D", active: true)]
        let shown = PaneTabStrip.visible(items, slots: 2)
        #expect(shown.map(\.title) == ["Pinned", "D"],
                "a pinned tab was folded away, or the active tab was")

        // With every slot taken by pins, the pins win — an active tab folded away still has the
        // header under it saying where the pane is.
        let allPinned = [item("P1", pinned: true), item("P2", pinned: true), item("Q", active: true)]
        #expect(PaneTabStrip.visible(allPinned, slots: 2).map(\.title) == ["P1", "P2"])
    }

    /// **The overflow menu lists the folded-away tabs newest first** (roadmap Fig. 7). A menu's
    /// contents never reach the bitmap, so this is the one claim in this file made against a value
    /// rather than against pixels — and it is here rather than in the ladder tests because it is
    /// about what the strip DRAWS in that menu.
    @Test func theOverflowMenuListsTheNewestTabsFirst() {
        let items = ["A", "B", "C", "D", "E"].map { item($0) }
        let hidden = PaneTabStrip.hidden(from: items, showing: [items[0], items[1]])
        #expect(hidden.map(\.title) == ["E", "D", "C"],
                "the overflow menu buries the tabs you just opened at the bottom")
    }

    /// An empty strip is not a state the app can reach, but this view is public and every rung
    /// indexes into `items`. Drawing nothing beats trapping inside a pane's body.
    @Test func anEmptyStripDrawsNothingRatherThanTrapping() {
        let rep = render(items: [], width: 620)
        #expect(inked(rep) < 50, "an empty strip painted something")
    }

    /// The strip is one 34pt row, at every rung — it shares the pane's vertical budget with a
    /// header pinned at 81pt, and a strip that grew a second row would push the list down.
    @Test func theStripIsOneRowAtEveryRung() {
        for width in [CGFloat(900), 620, 340, 220] {
            let rep = render(items: [item("Finance", active: true), item("Photos"), item("Legal"),
                                     item("Medical"), item("Immigration")], width: width)
            // `size` is in points; `pixelsHigh` is the backing store, which is 2× on this display.
            #expect(abs(rep.size.height - PaneTabStripLadder.stripHeight) < 0.5,
                    "the strip is \(rep.size.height)pt tall at \(width)pt wide")
        }
    }
}
