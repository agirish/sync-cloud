import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The strip, rendered and read back, in light and dark: what the ladder's arithmetic can't see.
/// The active tab is visibly active (its raised ground and accent rule are all that say which
/// folder the pane shows), each chip draws its name rather than clipping it at the floor, and the
/// mark tells two same-named tabs apart.
@MainActor
// Pinned per test rather than per suite, so the tests that read no pixels aren't held to this
// machine (see `OrganizeRailTests`).
@Suite(.serialized) struct PaneTabStripRenderTests {

    func item(_ title: String, active: Bool = false, mark: String = "folder.fill",
                     path: String = "/Users/x/Documents", pinned: Bool = false) -> PaneTabStrip.Item {
        PaneTabStrip.Item(id: UUID(), title: title, markImageName: mark,
                          isActive: active, fullPath: path, isPinned: pinned)
    }

    /// Mounts a strip at `width` and returns the bitmap. The backdrop is a flat fill, not the
    /// pane's card, as in `CommandPaletteRenderTests`: through a bare hosting view a glass wrapper
    /// renders the subject as white and every colour assertion reads zero. `accent` defaults to the
    /// system accent, the strip's fallback; a test about the accent's colour passes one explicitly,
    /// since the system accent is a machine setting (Graphite is a real choice).
    func render(items: [PaneTabStrip.Item], width: CGFloat,
                       scheme: ColorScheme = .light, scale: CGFloat = 1,
                       accent: Color = .accentColor,
                       isActivePane: Bool = true) -> NSBitmapImageRep {
        let subject = PaneTabStrip(items: items, accent: accent, isActivePane: isActivePane,
                                   onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in },
                                   onDuplicate: { _ in }, onCopyPath: { _ in }, onNew: {})
            .environment(\.appFontScale, scale)
            .frame(width: width, height: PaneTabStripLadder.stripHeight)
            .background(scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.15)
                                        : Color(red: 0.95, green: 0.95, blue: 0.96))
            .environment(\.colorScheme, scheme)
            // The app pins this on its own window; without it SwiftUI renders an inactive window's
            // desaturated version, which the user never sees.
            .environment(\.controlActiveState, .active)
        return PixelDiff.render(subject, size: CGSize(width: width, height: PaneTabStripLadder.stripHeight),
                                appearance: scheme == .dark ? .darkAqua : .aqua, passes: 2)!
    }

    /// The strip as the pane mounts it: the accent wash applied outside the view, over an opaque
    /// backdrop, as `paneColumn` stacks `.contentSurface` under `.paneCardIfNeeded`. The wash sits
    /// between strip and backdrop; the strip alone would read the flat fill whatever the tint.
    func renderWashed(items: [PaneTabStrip.Item], width: CGFloat,
                      hue: LiquidGlassHue, tint: Double,
                      scheme: ColorScheme = .light) -> NSBitmapImageRep {
        let subject = PaneTabStrip(items: items,
                                   onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in },
                                   onDuplicate: { _ in }, onCopyPath: { _ in }, onNew: {})
            .frame(width: width, height: PaneTabStripLadder.stripHeight)
            .contentSurface(hue: hue, tint: tint)
            .background(scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.15)
                                        : Color(red: 0.95, green: 0.95, blue: 0.96))
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .active)
        return PixelDiff.render(subject, size: CGSize(width: width, height: PaneTabStripLadder.stripHeight),
                                appearance: scheme == .dark ? .darkAqua : .aqua, passes: 2)!
    }

    /// A point in the strip's empty stretch, right of the last chip and left of the ＋. With two
    /// chips on a 520pt strip nothing is drawn here, so it reads only the wash.
    private func emptyStretchColor(_ rep: NSBitmapImageRep) -> NSColor {
        rep.colorAt(x: Int(Double(rep.pixelsWide) * 0.72), y: rep.pixelsHigh / 2)!
    }

    // MARK: - The pane's wash reaches the strip

    /// The pane's wash shows through the strip; without it a high Tint leaves a pale stripe across
    /// the top of the pane. `PaneSurfaceTintTests` proves the modifier is at the call site; this
    /// asks whether the wash survives the strip, since an opaque fill anywhere in its body would
    /// paint over it and leave that scan green.
    @Test(.machinePinned(.pixelSampling)) func theWashIsVisibleThroughTheStrip() {
        let items = [item("Documents", active: true), item("Invoices")]
        let bare = emptyStretchColor(renderWashed(items: items, width: 520, hue: .purple, tint: 0))
        let full = emptyStretchColor(renderWashed(items: items, width: 520, hue: .purple, tint: 1))
        // Purple over a near-white ground: blue holds while green falls, so the gap between the two
        // channels is the tint, which dimming can't produce.
        let bareGap = bare.blueComponent - bare.greenComponent
        let fullGap = full.blueComponent - full.greenComponent
        #expect(fullGap - bareGap > 0.05,
                "the strip's empty stretch barely moved between Tint 0 and Tint 100 (gap \(bareGap) -> \(fullGap)) — the wash is not reaching it")
    }

    /// The other half: at Tint 0 a pane is the background, not a wash over it. A strip that painted
    /// its own faint accent regardless would pass the test above and fail here.
    @Test(.machinePinned(.pixelSampling)) func atZeroTintTheStripPaintsNoWashAtAll() {
        let items = [item("Documents", active: true), item("Invoices")]
        let zero = emptyStretchColor(renderWashed(items: items, width: 520, hue: .purple, tint: 0))
        let none = emptyStretchColor(renderWashed(items: items, width: 520, hue: .none, tint: 1))
        // `.none` paints `Color.clear` at every tint, so it is the unwashed ground and needs no
        // hand-built reference colour.
        #expect(abs(zero.redComponent - none.redComponent) < 0.01)
        #expect(abs(zero.greenComponent - none.greenComponent) < 0.01)
        #expect(abs(zero.blueComponent - none.blueComponent) < 0.01)
    }

    /// Pixels differing from the image's own corner (its background), read from the same sRGB
    /// bitmap, not built by hand: `NSColor(white:)` is generic gray and throws on `redComponent`.
    func inked(_ rep: NSBitmapImageRep, in box: NSRect? = nil) -> Int {
        guard let background = rep.colorAt(x: 1, y: 1) else { return 0 }
        return PixelProbe.count(in: rep, box) { PixelProbe.distance($0, background) > 0.04 }
    }

    /// How accent each row of `box` is, as peak against typical. Per row, the mean blue minus red:
    /// callers render with a blue accent, and nothing else on a chip moves along that axis (slab,
    /// mark and title are near-neutral or dark). Peak against median, not a count over a threshold,
    /// because the live chip is accent-washed all over; the 2pt rule is the only thing that can
    /// make one row stand clear, and a wash of any strength moves peak and median together.
    func rowAccentProfile(_ rep: NSBitmapImageRep, in box: NSRect) -> (peak: Double, median: Double) {
        var rows: [Double] = []
        for y in Int(box.minY)..<min(rep.pixelsHigh, Int(box.maxY)) {
            var sum = 0.0, n = 0
            for x in Int(box.minX)..<min(rep.pixelsWide, Int(box.maxX)) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                sum += Double(c.blueComponent - c.redComponent); n += 1
            }
            if n > 0 { rows.append(sum / Double(n)) }
        }
        guard !rows.isEmpty else { return (0, 0) }
        return (rows.max() ?? 0, rows.sorted()[rows.count / 2])
    }

    // MARK: The positive control

    /// Everything below asserts ink somewhere. A harness that rendered an empty canvas would make
    /// the comparisons pass while proving nothing, so this is the floor they stand on.
    @Test(.machinePinned(.pixelSampling)) func theStripDrawsSomethingAtAll() {
        let rep = render(items: [item("Finance", active: true), item("Photos")], width: 620)
        #expect(inked(rep) > 400, "the strip rendered blank — every test below is vacuous")
    }

    // MARK: What a person has to be able to see

    /// Which tab is live, in both appearances: ground and rule together. `.quaternary` grounds can
    /// vanish in one scheme and survive in the other, so the claim is made per appearance.
    @Test(.machinePinned(.pixelSampling)) func theActiveTabIsDistinguishableInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let live = render(items: [item("Finance", active: true), item("Photos")],
                              width: 620, scheme: scheme)
            let parked = render(items: [item("Finance"), item("Photos")], width: 620, scheme: scheme)
            #expect(PixelDiff.differingPixels(live, parked, tolerance: 0.01) > 300,
                    "nothing distinguishes the live tab from a parked one in \(scheme)")
        }
    }

    /// The accent rule itself, which the test above can't see: the chip's wash alone makes the live
    /// chip differ from a parked one. The pane's accent border says which pane is focused; this
    /// rule says which tab is live. A global accent-pixel count would find the wash too, so this
    /// measures the rule's shape: 2pt of a 26pt chip, one row far more accent than the rest.
    @Test(.machinePinned(.pixelSampling)) func theAccentRuleUnderTheActiveTabIsPaintedInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let live = render(items: [item("Finance", active: true), item("Photos")],
                              width: 620, scheme: scheme, accent: .blue)
            let parked = render(items: [item("Finance"), item("Photos")],
                                width: 620, scheme: scheme, accent: .blue)
            // The live chip's own box, found by differencing rather than named: see
            // `activeChipBounds`.
            let chip = activeChipBounds(live, parked: parked)
            #expect(chip.width > 40, "the live chip was not located in \(scheme)")
            let profile = rowAccentProfile(live, in: chip)
            #expect(profile.peak > profile.median + 0.25, """
                    no accent rule under the active tab in \(scheme) — its most accent row reads \
                    \(profile.peak) against a typical \(profile.median), so the chip is washed \
                    evenly and nothing marks its bottom edge
                    """)
        }
    }

    /// A parked chip has a ground of its own (`PaneTabStrip.chipGround`): every chip wears the grey
    /// slab, and only the accent on top says which is live. No "live differs from parked" test can
    /// see this; without the slab the strip reads as one tab with words floating beside it. Read at
    /// the second chip's leading padding, inside its slab and short of its mark.
    @Test(.machinePinned(.pixelSampling)) func aParkedChipIsDrawnOnItsOwnGround() {
        for scheme in [ColorScheme.light, .dark] {
            let rep = render(items: [item("Finance", active: true), item("Photos")],
                             width: 900, scheme: scheme)
            let width = PaneTabStripLadder.layout(available: 890, titles: ["Finance", "Photos"],
                                                  scale: 1).tabWidth
            let ground = groundColor(rep, at: PaneTabStripLadder.stripGutter + width
                                     + PaneTabStripLadder.tabGap + 3)
            guard let backdrop = rep.colorAt(x: 1, y: 1) else {
                Issue.record("no backdrop pixel"); return
            }
            let delta = max(abs(ground.redComponent - backdrop.redComponent),
                            max(abs(ground.greenComponent - backdrop.greenComponent),
                                abs(ground.blueComponent - backdrop.blueComponent)))
            #expect(delta > 0.02, """
                    the parked chip's ground is \(delta) away from the strip's backdrop in \
                    \(scheme) — the chip has no slab and reads as bare text on the strip
                    """)
        }
    }

    /// The live chip dims in the unfocused pane, as that pane's selected rows do, with the same
    /// `PaneSelectionWash` constants, so tab and rows can't disagree about which pane is acting.
    /// Measured as the chip's accent, not "the renders differ": ignoring `isActivePane` and
    /// inverting it both differ from the focused render, and only the direction tells them apart.
    @Test(.machinePinned(.pixelSampling)) func theLiveChipIsQuieterInTheUnfocusedPane() {
        let items = [item("Finance", active: true), item("Photos")]
        let parked = render(items: [item("Finance"), item("Photos")], width: 620, accent: .blue)
        let focused = render(items: items, width: 620, accent: .blue, isActivePane: true)
        let other = render(items: items, width: 620, accent: .blue, isActivePane: false)
        let chip = activeChipBounds(focused, parked: parked)
        #expect(chip.width > 40, "the live chip was not located")
        // The chip's typical row (the wash), not its peak (the rule), which deliberately doesn't
        // dim: it still answers "which tab" in the other pane.
        let strong = rowAccentProfile(focused, in: chip).median
        let quiet = rowAccentProfile(other, in: chip).median
        #expect(strong > quiet + 0.05, """
                the live chip reads \(strong) accent in the focused pane and \(quiet) in the other \
                — the strip is not dimming with its pane
                """)
        // …and still a selection there, not a parked chip: the pane's rows keep 0.10 against 0.22,
        // a subordinate marker, never an absent one.
        #expect(quiet > 0.02, "the unfocused pane's live chip has no wash at all")
        // The rule is the half that doesn't dim.
        let focusedPeak = rowAccentProfile(focused, in: chip).peak
        let otherPeak = rowAccentProfile(other, in: chip).peak
        #expect(abs(focusedPeak - otherPeak) < 0.05, """
                the accent rule dimmed with the pane (\(focusedPeak) against \(otherPeak)) — it is \
                the marker that has to survive there
                """)
    }

    /// A chip squeezed to the floor still draws its name, which is what the measured floor is for;
    /// `visibleCount` is just as happy with a chip whose title was clipped away. Differential,
    /// because the active tab's raised ground inks the title box on its own: rendering the strip
    /// with the title blanked and subtracting is the only form the ground can't satisfy.
    @Test(.machinePinned(.pixelSampling)) func aChipAtTheFloorStillDrawsItsName() {
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

        // Differential: the active chip's ground inks the whole title box, so an ink count saturates.
        let named = render(items: five(firstTitle: "Finance"), width: 340)
        let blank = render(items: five(firstTitle: ""), width: 340)
        let box = titleBox(of: named, tabWidth: layout.tabWidth)
        #expect(PixelDiff.differingPixels(named, blank, tolerance: 0.01, in: box) > 100,
                "the chip's name is not drawn at the floor width")
    }

    /// The first chip's title box in pixels: past the gutter, the mark and the gap, short of the ✕.
    /// The bitmap is 2× on this display, so a box in points would read the wrong part of the strip.
    func titleBox(of rep: NSBitmapImageRep, tabWidth: CGFloat) -> NSRect {
        let pixelsPerPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        let start = PaneTabStripLadder.stripGutter + PaneTabStripLadder.tabPadding
            + PaneTabStripLadder.markSide + PaneTabStripLadder.contentGap
        let end = PaneTabStripLadder.stripGutter + tabWidth
            - PaneTabStripLadder.tabPadding - PaneTabStripLadder.closeSide
        return NSRect(x: start * pixelsPerPoint, y: 0,
                      width: (end - start) * pixelsPerPoint, height: CGFloat(rep.pixelsHigh))
    }

    /// The case the mark is on the chip for: two tabs with the same name from different sources.
    /// Without the mark these two strips would be pixel-identical.
    @Test(.machinePinned(.pixelSampling)) func theProviderMarkTellsTwoSameNamedTabsApart() {
        let same = render(items: [item("Documents", active: true, mark: "folder.fill"),
                                  item("Documents", mark: "folder.fill")], width: 620)
        let mixed = render(items: [item("Documents", active: true, mark: "folder.fill"),
                                   item("Documents", mark: "externaldrive.fill")], width: 620)
        #expect(PixelDiff.differingPixels(same, mixed, tolerance: 0.01) > 30,
                "the two chips render identically — the provider mark is not being drawn")
    }

    /// The narrow rung the Organize/Storage rail gets. What must survive at 220pt is the active
    /// tab's name, never a row of marks.
    @Test(.machinePinned(.pixelSampling)) func theRailWidthStillNamesTheActiveTab() {
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
        #expect(PixelDiff.differingPixels(named, blank, tolerance: 0.01, in: box) > 100,
                "the chip rung drew no name for the active tab")
    }

    /// The chip rung draws the count of parked tabs, the only thing on that rung saying the strip
    /// holds more than the one folder it names.
    @Test(.machinePinned(.pixelSampling)) func theChipRungDrawsHowManyTabsAreParked() {
        let five = [item("Immigration", active: true), item("Photos"), item("Legal"),
                    item("Medical"), item("Finance")]
        let two = [item("Immigration", active: true), item("Photos")]
        #expect(PaneTabStripLadder.layout(available: 220, titles: five.map(\.title), scale: 1).rung == .chip)
        #expect(PaneTabStripLadder.layout(available: 220, titles: two.map(\.title), scale: 1).rung == .chip)

        // "4" against "1": same rung, same active chip, different count, so the pixels that differ
        // are the count itself. An ink count couldn't tell these apart.
        let many = render(items: five, width: 220)
        let few = render(items: two, width: 220)
        // The count's own band: past the chip (which ends about half way on this fixture) and short
        // of the ＋. Measured off the render: a box starting a few percent later misses the digit
        // and reads like "the count is not drawn".
        let countBox = NSRect(x: CGFloat(many.pixelsWide) * 0.52, y: 0,
                              width: CGFloat(many.pixelsWide) * 0.20, height: CGFloat(many.pixelsHigh))
        #expect(PixelDiff.differingPixels(many, few, tolerance: 0.01, in: countBox) > 20,
                "the chip rung draws no count — nothing says the other tabs exist")
        // And not merely a smudge: a clipped digit would pass the check above, so the count's ink
        // is compared against the empty band beside it.
        let emptyBand = NSRect(x: CGFloat(many.pixelsWide) * 0.75, y: 0,
                               width: CGFloat(many.pixelsWide) * 0.10, height: CGFloat(many.pixelsHigh))
        #expect(inked(many, in: countBox) > inked(many, in: emptyBand) + 40,
                "the chip rung's count is clipped to almost nothing")
    }

    /// View ▸ Tab Bar at one tab draws a real chip, not a bare ＋. One tab usually draws no strip,
    /// but that is the pane's decision; this switch exists to show one anyway.
    @Test(.machinePinned(.pixelSampling)) func aOneTabStripDrawsItsTab() {
        let named = render(items: [item("Finance", active: true)], width: 620)
        let blank = render(items: [item("", active: true)], width: 620)
        #expect(inked(named) > 200, "a one-tab strip drew almost nothing")
        let box = titleBox(of: named,
                           tabWidth: PaneTabStripLadder.layout(available: 620 - 10,
                                                               titles: ["Finance"], scale: 1).tabWidth)
        #expect(PixelDiff.differingPixels(named, blank, tolerance: 0.01, in: box) > 100,
                "the one visible tab has no name drawn on it")
    }

    /// A lone tab wears no ✕: clicking it would close the window, with no tab left to fall back to.
    /// The count decides it, so the same chip beside a second tab has one. The two strips share a
    /// layout on purpose: both chips are "Finance" in a wide pane, so the first chip occupies the
    /// same box in each render and the ✕ is the only thing that can differ there.
    @Test(.machinePinned(.pixelSampling)) func aLoneTabHasNoCloseButton() {
        let alone = render(items: [item("Finance", active: true)], width: 900)
        let paired = render(items: [item("Finance", active: true), item("Finance")], width: 900)
        let width = PaneTabStripLadder.layout(available: 890, titles: ["Finance"], scale: 1).tabWidth
        #expect(width == PaneTabStripLadder.layout(available: 890, titles: ["Finance", "Finance"],
                                                   scale: 1).tabWidth,
                "the fixture's two strips no longer share a chip width — the box below compares nothing")

        let perPoint = alone.size.width > 0 ? CGFloat(alone.pixelsWide) / alone.size.width : 1
        let closeBox = NSRect(
            x: (PaneTabStripLadder.stripGutter + width - PaneTabStripLadder.tabPadding
                - PaneTabStripLadder.closeSide) * perPoint,
            y: 0,
            width: PaneTabStripLadder.closeSide * perPoint,
            height: CGFloat(alone.pixelsHigh))
        #expect(PixelDiff.differingPixels(alone, paired, tolerance: 0.01, in: closeBox) > 20,
                "the lone tab draws a ✕ that would close the window")
    }

    /// A parked tab not under the pointer wears no ✕. The strip is mostly parked tabs, and a row of
    /// chips each with a permanent ✕ reads as things to dismiss rather than places to go, so the
    /// button is drawn at `opacity` 0 unless the chip is active or hovered. Measured with
    /// `glyphPixels` against the second chip's own ground, over its interior rows: every chip wears
    /// the grey slab (`PaneTabStrip.chipGround`), which saturates `inked`. Both halves count:
    /// - the parked chip's slot is empty, and
    /// - a glyph would have been seen there: the same slot on a pinned tab carries its pin, on the
    ///   same grey slab.
    @Test(.machinePinned(.pixelSampling)) func anUnhoveredParkedTabDrawsNoCloseButton() {
        // Two chips with the same title in a wide pane, so both strips lay out identically and the
        // second chip's close slot is the same box in each.
        let plain = render(items: [item("Finance", active: true), item("Finance")], width: 900)
        let again = render(items: [item("Finance", active: true), item("Finance")], width: 900)
        let pinned = render(items: [item("Finance", active: true), item("Finance", pinned: true)],
                            width: 900)
        let width = PaneTabStripLadder.layout(available: 890, titles: ["Finance", "Finance"],
                                              scale: 1).tabWidth
        let perPoint = plain.size.width > 0 ? CGFloat(plain.pixelsWide) / plain.size.width : 1
        // The second chip's close slot: past the first chip and the gap, at the trailing end of the
        // second, inset by its padding.
        let chipStart = PaneTabStripLadder.stripGutter + width + PaneTabStripLadder.tabGap
        let slotStart = chipStart + width - PaneTabStripLadder.tabPadding - PaneTabStripLadder.closeSide
        let slotEnd = chipStart + width - PaneTabStripLadder.tabPadding
        let slot = NSRect(x: slotStart * perPoint, y: 0,
                          width: PaneTabStripLadder.closeSide * perPoint,
                          height: CGFloat(plain.pixelsHigh))
        // 3pt into the second chip: inside its slab, short of the mark, which starts at its 7pt
        // padding. The same anchor `theChipRungWearsAChevron` reads its ground from.
        let ground = groundColor(plain, at: chipStart + 3)

        // The harness control: the same render twice differs nowhere, so a difference below is a
        // difference in what was drawn rather than in how it was drawn.
        #expect(PixelDiff.differingPixels(plain, again, tolerance: 0.01, in: slot) == 0,
                "two identical strips differ in the parked chip's close slot — the harness is unstable")
        // The claim.
        let drawn = glyphPixels(plain, from: slotStart, to: slotEnd, ground: ground)
        #expect(drawn < 10, """
                an un-hovered parked tab draws \(drawn) pixels in its close slot — \
                it is wearing a ✕ nobody asked for
                """)
        // …and the slot is the right box, on a ground where a glyph would be seen: a pinned tab's
        // pin sits in exactly this slot.
        #expect(glyphPixels(pinned, from: slotStart, to: slotEnd,
                            ground: groundColor(pinned, at: chipStart + 3)) > 40, """
                the pinned tab's glyph is not in this box either — the box is wrong, so the \
                emptiness above proves nothing
                """)
        #expect(PixelDiff.differingPixels(plain, pinned, tolerance: 0.01, in: slot) > 20)
    }

    // MARK: The chip rung's chevron

    /// The chip rung's chevron, rendered back (`PaneTabStrip.activeChipMenu` names this test). On
    /// this rung the strip draws one chip and a count; the chip is the switcher for every other
    /// tab, and the chevron is the only thing that says so. It must be the system's (a
    /// `chevron.down` in the label renders as nothing, because `.borderlessButton` lays out its
    /// label itself), so it can only be checked in pixels. `.menuIndicator(.hidden)` fails this;
    /// deleting `.menuIndicator(.visible)` doesn't, as `.borderlessButton` shows one by default on
    /// this macOS.
    ///
    /// Counts are pixels unlike the chip's own ground, from the same render: the raised ground
    /// differs from the backdrop across this band, so `inked` saturates. The chip is located from
    /// the parked-render differential (`activeChipBounds`), not the ladder's `tabWidth`, since it
    /// takes its natural width up to that cap, and the question is how much wider than its contents
    /// it is.
    @Test(.machinePinned(.pixelSampling)) func theChipRungWearsAChevron() {
        let five = [item("Immigration", active: true), item("Photos"), item("Legal"),
                    item("Medical"), item("Finance")]
        #expect(PaneTabStripLadder.layout(available: 210, titles: five.map(\.title), scale: 1).rung == .chip,
                "this fixture is meant to be on the chip rung")
        let rep = render(items: five, width: 220)
        let perPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1

        // The chip's span, off its raised ground, which is the chip, so there is no inset to undo.
        let parkedRep = render(items: five.map { item($0.title) }, width: 220)
        let chip = activeChipBounds(rep, parked: parkedRep)
        let chipStart = chip.minX / perPoint
        let chipEnd = chip.maxX / perPoint
        let titleStart = PaneTabStripLadder.stripGutter + PaneTabStripLadder.tabPadding
            + PaneTabStripLadder.markSide + PaneTabStripLadder.contentGap
        let titleEnd = titleStart + LabelMetrics.width(of: "Immigration",
                                                       font: PaneTabStripLadder.titleFont, scale: 1)
        // Half a point of slack: the rule's edge is measured in whole pixels, and this only has to
        // establish that the chip is where the boxes below assume it is.
        #expect(abs(chipStart - PaneTabStripLadder.stripGutter) < 0.6,
                "the chip starts at \(chipStart)pt, not the strip's gutter — every box below is off")

        // The room the indicator takes: the chip is wider than mark + gap + title + its two
        // paddings by the indicator's width; without the indicator it would be exactly that sum.
        let contents = PaneTabStripLadder.tabPadding + PaneTabStripLadder.markSide
            + PaneTabStripLadder.contentGap + (titleEnd - titleStart) + PaneTabStripLadder.tabPadding
        #expect(chipEnd - chipStart > contents + 8, """
                the chip is \(chipEnd - chipStart)pt wide against \(contents)pt of contents — there is \
                no room in it for an indicator, so the rung ends flush after its title
                """)

        // …and that room is painted. The band runs from just past the title to the chip's trailing
        // padding, where the system draws its indicator.
        let ground = groundColor(rep, at: chipStart + 3)
        let chevron = glyphPixels(rep, from: titleEnd + 2, to: chipEnd - PaneTabStripLadder.tabPadding,
                                  ground: ground)
        #expect(chevron > 40, """
                \(chevron) pixels unlike the chip's own ground between its title and its trailing \
                edge — the space is reserved but nothing is drawn in it
                """)

        // The zero control: the same measurement over the 5pt gap between mark and title, which
        // must be bare ground. Otherwise a count that reported the ground itself would pass the
        // assertion above with no chevron drawn.
        #expect(glyphPixels(rep, from: chipStart + PaneTabStripLadder.tabPadding
                            + PaneTabStripLadder.markSide + 1,
                            to: chipStart + PaneTabStripLadder.tabPadding
                            + PaneTabStripLadder.markSide + PaneTabStripLadder.contentGap - 1,
                            ground: ground) == 0,
                "bare ground reads as painted — this measurement cannot tell a glyph from a fill")
        // The positive control: the same measurement over the title finds it.
        #expect(glyphPixels(rep, from: titleStart, to: titleEnd, ground: ground) > 300,
                "the chip's own title does not register — the measurement is blind")
        // And the chevron is inside the chip, not spilling past it: the trailing padding is bare.
        // `rowInset` clears the corner arc, which reaches into this band and is not a glyph.
        let cornerSafe = PaneTabStripLadder.chipRadius
        #expect(glyphPixels(rep, from: chipEnd - PaneTabStripLadder.tabPadding + 1, to: chipEnd - 1,
                            ground: ground, rowInset: cornerSafe) == 0,
                "something is drawn in the chip's trailing padding")
        // The positive control for that narrower band: six points of chip height rather than
        // twenty, and a band that sees nothing would report the zero above too, so the same rows
        // are run over the title, which they must find.
        #expect(glyphPixels(rep, from: titleStart, to: titleEnd,
                            ground: ground, rowInset: cornerSafe) > 40,
                "the corner-safe band cannot see the chip's own title — the zero above proves nothing")
    }

    /// The active tab's rule ends inside the chip it marks, on the chip's own bottom scanline. By
    /// the bottom, a rounded corner has pulled the chip's paint in further than its frame, and
    /// nothing clips the rule (`chipGround` is a plain `ZStack` with no `clipShape`), so a rule
    /// inset less than the corner hangs its ends out over the card behind.
    ///
    /// The chip's silhouette comes from a parked render: on one render the rule is part of the
    /// chip's measured span, so containment could never fail, and parking the tab removes the rule
    /// and nothing else. This asserts containment, not the inset: `PaneTabStripLadder.ruleInset` is
    /// measured (a `.continuous` corner's paint doesn't start at `radius`), and the property holds
    /// whatever the corner style, radius or curve. An inset of 3 fails it.
    @Test(.machinePinned(.pixelSampling)) func theRuleEndsInsideTheChipItMarks() {
        // A saturated accent, so the rule is separable from the chip's own wash: this same colour
        // at 0.22 over grey, nowhere near saturated.
        let accent = Color(red: 1, green: 0, blue: 0)
        let lit = render(items: [item("Immigration", active: true), item("iCloud")],
                         width: 420, accent: accent)
        // The same strip with the first tab parked: identical geometry, no rule under it.
        let parked = render(items: [item("Immigration"), item("iCloud", active: true)],
                            width: 420, accent: accent)

        // The chip's bottom scanline: half a point above its bottom edge, which is where the corner
        // has pulled the paint in the furthest and where the rule sits.
        let inset = (PaneTabStripLadder.stripHeight - PaneTabStripLadder.tabHeight) / 2
        let y = PaneTabStripLadder.stripHeight - inset - 0.5

        // Sampled, not assumed: the `Color(red: 0.95, …)` backdrop reaches the bitmap as
        // 0.959/0.960/0.969 after SwiftUI's colour conversion, and against the nominal value a
        // parked chip's grey falls under the threshold, so the first chip would go undetected.
        let backdrop = parked.colorAt(x: 1, y: 1)!.usingColorSpace(.deviceRGB)!
        let chip = firstRun(parked, atY: y) { p in
            max(abs(p.redComponent - backdrop.redComponent),
                max(abs(p.greenComponent - backdrop.greenComponent),
                    abs(p.blueComponent - backdrop.blueComponent))) > 0.06
        }
        let rule = firstRun(lit, atY: y) { p in
            p.redComponent > 0.8 && p.greenComponent < 0.3 && p.blueComponent < 0.3
        }

        // Positive controls first: an empty run would satisfy every containment claim below.
        #expect(rule != nil, """
                no saturated accent on the chip's bottom scanline — either the rule is not drawn, \
                or this measurement cannot see it
                """)
        #expect(chip != nil, "no chip found on its own bottom scanline — the measurement is blind")
        guard let rule = rule, let chip = chip else { return }
        #expect(rule.hi - rule.lo > 20,
                "the rule spans only \(rule.hi - rule.lo)pt — too little to be the marker")
        // And the parked run really is a whole chip rather than a sliver of one.
        #expect(chip.hi - chip.lo > 60,
                "the parked chip measures \(chip.hi - chip.lo)pt — that is not a chip")

        // The claim. Half a point of tolerance for the corner's antialiased edge, where a hard
        // pixel comparison would read a gradient as an overhang.
        #expect(rule.lo >= chip.lo - 0.5, """
                the rule starts at \(rule.lo)pt but the chip's paint only starts at \(chip.lo)pt — \
                its leading end hangs \(chip.lo - rule.lo)pt out over the card behind it
                """)
        #expect(rule.hi <= chip.hi + 0.5, """
                the rule ends at \(rule.hi)pt but the chip's paint ends at \(chip.hi)pt — \
                its trailing end hangs \(rule.hi - chip.hi)pt out over the card behind it
                """)
    }

    /// The first contiguous run where `matches` holds on the scanline at `y` points from the top,
    /// as (lo, hi) in points, or `nil` when nothing on that row matches. A run, not a min/max: the
    /// row holds several chips and the claims above are about the first, so a bounding span would
    /// reach across the gap to the next chip.
    func firstRun(_ rep: NSBitmapImageRep, atY y: CGFloat,
                  matches: (NSColor) -> Bool) -> (lo: CGFloat, hi: CGFloat)? {
        let perPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        let row = min(rep.pixelsHigh - 1, max(0, Int(y * perPoint)))
        var lo = -1, hi = -1
        for x in 0..<rep.pixelsWide {
            guard let p = rep.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { continue }
            if matches(p) {
                if lo < 0 { lo = x }
                hi = x
            } else if lo >= 0 {
                break
            }
        }
        guard lo >= 0 else { return nil }
        return (CGFloat(lo) / perPoint, CGFloat(hi + 1) / perPoint)
    }

    /// Where the active chip is, measured: the bounding box of everything that changes when the
    /// same strip is rendered with that chip parked. A differential finds the chip's whole raised
    /// ground in either appearance without naming a colour (`.quaternary` is a different grey in
    /// each, and close to the backdrop), whatever marker the chip carries.
    func activeChipBounds(_ live: NSBitmapImageRep, parked: NSBitmapImageRep) -> NSRect {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        guard live.pixelsWide == parked.pixelsWide, live.pixelsHigh == parked.pixelsHigh else { return .zero }
        for y in 0..<live.pixelsHigh {
            for x in 0..<live.pixelsWide {
                guard let a = live.colorAt(x: x, y: y), let b = parked.colorAt(x: x, y: y) else { continue }
                if abs(a.redComponent - b.redComponent) > 0.01
                    || abs(a.greenComponent - b.greenComponent) > 0.01
                    || abs(a.blueComponent - b.blueComponent) > 0.01 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX + 1 - minX, height: maxY + 1 - minY)
    }

    /// The chip's ground, read at a point inside it that nothing is drawn on: `x` points from the
    /// image's leading edge, at the chip's vertical middle.
    func groundColor(_ rep: NSBitmapImageRep, at x: CGFloat) -> NSColor {
        let perPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        let mid = Int(PaneTabStripLadder.stripHeight / 2 * perPoint)
        return rep.colorAt(x: Int(x * perPoint), y: mid) ?? .black
    }

    /// Pixels between `x0` and `x1` (in points) that differ from `ground`, over the chip's interior
    /// rows only: a full-height band would count the backdrop above and below the chip. The rows
    /// come from `stripHeight` and `tabHeight`, which the strip lays itself out from, with the chip
    /// centred between them, so no render is needed to find them.
    ///
    /// `rowInset` is how far in from the chip's top and bottom to start; 3 is safe only away from
    /// the chip's ends, where the corner arc (radius `PaneTabStripLadder.chipRadius`) intrudes
    /// about 3pt and reads as a glyph. Within `chipRadius` of either end, pass `rowInset:
    /// PaneTabStripLadder.chipRadius`, the only band the arc can't reach.
    func glyphPixels(_ rep: NSBitmapImageRep, from x0: CGFloat, to x1: CGFloat,
                     ground: NSColor, rowInset: CGFloat = 3) -> Int {
        guard x1 > x0 else { return -1 }
        let perPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        let inset = (PaneTabStripLadder.stripHeight - PaneTabStripLadder.tabHeight) / 2
        let bottom = Int((PaneTabStripLadder.stripHeight - inset - rowInset) * perPoint)
        let top = max(0, bottom - Int((PaneTabStripLadder.tabHeight - 2 * rowInset) * perPoint))
        let (left, right) = ((x0 * perPoint).rounded(.down), (x1 * perPoint).rounded(.down))
        return PixelProbe.count(in: rep, CGRect(x: left, y: CGFloat(top), width: right - left,
                                                height: CGFloat(bottom - top))) {
            PixelProbe.distance($0, ground) > 0.06
        }
    }

    // MARK: The reorder drag

    /// The gap tracks the drop index: the chips the dragged tab has passed step aside by exactly
    /// one stride, and everything else stands still. Priced from the stride the drop index uses, so
    /// what the row shows and where the tab lands can't disagree.
    @Test func theChipsStepAsideForTheDraggedTab() {
        let items = ["A", "B", "C", "D"].map { item($0) }
        let stride: CGFloat = 100
        let dragged = items[0].id

        // Dragged two strides right: B and C step left, D is untouched, and the dragged chip is
        // excluded (it rides the pointer).
        func step(_ index: Int, offset: CGFloat) -> CGFloat {
            PaneTabStrip.displacement(of: items[index], items: items, visible: items,
                                      dragging: dragged, offset: offset, stride: stride)
        }
        #expect(step(1, offset: 205) == -stride)
        #expect(step(2, offset: 205) == -stride)
        #expect(step(3, offset: 205) == 0)
        #expect(step(0, offset: 205) == 0, "the dragged chip is displaced twice")

        // …and nothing moves until the drag has covered half a stride.
        #expect(step(1, offset: 20) == 0)

        // The other direction, from the trailing end.
        let backwards = PaneTabStrip.displacement(of: items[1], items: items, visible: items,
                                                  dragging: items[3].id, offset: -205, stride: stride)
        #expect(backwards == stride)
    }

    /// The preview and the drop are one rule, so the row can't animate a move it won't make. Two
    /// refusals: a drag across the pin line, which `PaneTabList.move` rejects, and a drag past the
    /// last visible chip, which would drop the tab into the folded-away region, out of sight.
    @Test func aDropCannotCrossThePinLineOrLeaveWhatIsOnScreen() {
        let items = [item("P", pinned: true), item("A"), item("B"), item("C")]

        // An unpinned tab dragged hard left stops at the head of the unpinned run.
        #expect(PaneTabStrip.dropIndex(from: 3, steps: -9, items: items, visible: items) == 1)
        // A pinned tab dragged right stays inside the pinned run — here, exactly where it is.
        #expect(PaneTabStrip.dropIndex(from: 0, steps: 9, items: items, visible: items) == 0)

        // With C folded away, a drag right from B stops at B: there is nothing visible past it.
        let shown = [items[0], items[1], items[2]]
        #expect(PaneTabStrip.dropIndex(from: 2, steps: 3, items: items, visible: shown) == 2)
    }

    /// …and the drawn indices are not always contiguous. `visible(_:slots:)` draws the pinned
    /// prefix plus a window of the unpinned run, so once that window scrolls off the head there is
    /// a folded-away gap between them, and a clamp into `[first, last]` can land in it, sending the
    /// chip into the overflow. The case above has a contiguous `shown`; this one (one pin, four
    /// tabs, three slots) is a rail-width strip.
    @Test func aDropCannotLandInTheGapBetweenThePinsAndTheWindow() {
        let items = [item("P", pinned: true), item("T1"), item("T2"), item("T3"),
                     item("T4", active: true)]
        let shown = PaneTabStrip.visible(items, slots: 3)
        // The premise: the window has scrolled, so indices 1 and 2 are drawn by nothing.
        #expect(shown.map(\.title) == ["P", "T3", "T4"])

        let drawn = Set(shown.map(\.id))
        for from in items.indices where drawn.contains(items[from].id) {
            for steps in -4...4 {
                let to = PaneTabStrip.dropIndex(from: from, steps: steps, items: items, visible: shown)
                #expect(drawn.contains(items[to].id),
                        "\(items[from].title) dropped onto folded-away index \(to) at \(steps) steps")
            }
        }
        // And the snap goes back toward the drag's origin rather than outward past a hidden tab: T3
        // dragged hard left stops where it is, not at the head of the unpinned run.
        #expect(PaneTabStrip.dropIndex(from: 3, steps: -9, items: items, visible: shown) == 3)
    }

    /// The other half, so nobody reads the guarantee as wider than it is. `dropIndex` promises the
    /// tab lands where a chip is drawn, not that it is still drawn afterwards: `visible(_:slots:)`
    /// re-derives its window from the active tab, and the move changes the order. Three tabs in two
    /// slots, dragging the parked one past the active one, puts it in the overflow menu as a newly
    /// opened tab would be: the window's design, not a hole in the drop rule.
    @Test func aLegalDropStillLandsWhereItWasAimed() {
        let items = [item("T0"), item("T1"), item("T2", active: true)]
        let shown = PaneTabStrip.visible(items, slots: 2)
        #expect(shown.map(\.title) == ["T1", "T2"], "the window is not where this case needs it")

        // Dragging the parked chip one step right is a legal drop onto a drawn index…
        let to = PaneTabStrip.dropIndex(from: 1, steps: 1, items: items, visible: shown)
        #expect(to == 2)
        #expect(shown.contains { $0.id == items[to].id }, "the drop did not land on a drawn chip")

        // …and the window, re-derived around the active tab afterwards, no longer covers it.
        var moved = items
        let dragged = moved.remove(at: 1)
        moved.insert(dragged, at: to)
        let after = PaneTabStrip.visible(moved, slots: 2)
        #expect(!after.contains { $0.id == dragged.id },
                "the window now keeps a moved chip: the residual this records is gone, so dropIndex's note about it should go too")
    }

    // MARK: Pinned tabs

    /// A pinned chip wears a pin where an unpinned one wears its ✕. The two strips are otherwise
    /// identical, so the box isolates that slot.
    @Test(.machinePinned(.pixelSampling)) func aPinnedTabWearsAPinInsteadOfItsCloseButton() {
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
        let slot = NSRect(x: (PaneTabStripLadder.stripGutter + width - PaneTabStripLadder.tabPadding
                             - PaneTabStripLadder.closeSide) * perPoint,
                          y: 0,
                          width: PaneTabStripLadder.closeSide * perPoint,
                          height: CGFloat(pinned.pixelsHigh))
        #expect(PixelDiff.differingPixels(pinned, plain, tolerance: 0.01, in: slot) > 20,
                "a pinned tab is drawn exactly like an unpinned one — nothing says it is pinned")
        // The name is untouched: pinning is a position and a protection, not a shrink to mark-only.
        let title = titleBox(of: pinned, tabWidth: width)
        #expect(PixelDiff.differingPixels(pinned, plain, tolerance: 0.01, in: title) < 20, "pinning moved the chip's name")
    }

    /// Pinned tabs never fold away: they are pinned so they stay reachable, and a folded active tab
    /// is still named by the header underneath.
    @Test func pinnedTabsKeepTheirSlotsWhenTheStripRunsOutOfRoom() {
        let items = [item("Pinned", pinned: true), item("A"), item("B"), item("C"), item("D", active: true)]
        let shown = PaneTabStrip.visible(items, slots: 2)
        #expect(shown.map(\.title) == ["Pinned", "D"],
                "a pinned tab was folded away, or the active tab was")

        // With every slot taken by pins, the pins win: an active tab folded away still has the
        // header under it saying where the pane is.
        let allPinned = [item("P1", pinned: true), item("P2", pinned: true), item("Q", active: true)]
        #expect(PaneTabStrip.visible(allPinned, slots: 2).map(\.title) == ["P1", "P2"])
    }

    /// The overflow menu lists the folded-away tabs newest first. A menu's contents never reach the
    /// bitmap, so this claim is made against a value, not pixels; it is here rather than in the
    /// ladder tests because it is about what the strip draws in that menu.
    @Test func theOverflowMenuListsTheNewestTabsFirst() {
        let items = ["A", "B", "C", "D", "E"].map { item($0) }
        let hidden = PaneTabStrip.hidden(from: items, showing: [items[0], items[1]])
        #expect(hidden.map(\.title) == ["E", "D", "C"],
                "the overflow menu buries the tabs you just opened at the bottom")
    }

    /// An empty strip is not a state the app can reach, but this view is public and every rung
    /// indexes into `items`. Drawing nothing beats trapping inside a pane's body.
    @Test(.machinePinned(.pixelSampling)) func anEmptyStripDrawsNothingRatherThanTrapping() {
        let rep = render(items: [], width: 620)
        #expect(inked(rep) < 50, "an empty strip painted something")
    }

    /// The strip is one 34pt row at every rung: it shares the pane's vertical budget with an 81pt
    /// header, and a second row would push the list down. Measured on a canvas taller than a row,
    /// since `render()` sizes its bitmap to the row: `.frame(height:)` doesn't clip, so a rung that
    /// wanted two rows paints outside the row rather than growing it. So the question is asked in
    /// pixels, above and below the row, where nothing may be.
    @Test(.machinePinned(.pixelSampling)) func theStripIsOneRowAtEveryRung() {
        let canvasHeight = PaneTabStripLadder.stripHeight * 3
        for width in [CGFloat(900), 620, 340, 220] {
            let items = [item("Finance", active: true), item("Photos"), item("Legal"),
                         item("Medical"), item("Immigration")]
            let rep = renderInTallCanvas(items: items, width: width, height: canvasHeight)
            let scale = CGFloat(rep.pixelsHigh) / canvasHeight
            let rowHeight = PaneTabStripLadder.stripHeight * scale
            let top = (CGFloat(rep.pixelsHigh) - rowHeight) / 2

            // The control: the row itself drew. Otherwise a strip that rendered nothing would
            // satisfy the emptiness checks below at every width.
            let row = NSRect(x: 0, y: top, width: CGFloat(rep.pixelsWide), height: rowHeight)
            #expect(inked(rep, in: row) > 200,
                    "the strip drew almost nothing at \(width)pt — the checks below would be vacuous")

            // …and a clear band on each side of it. A second rank of chips, or a chip taller than
            // its budget, lands in one or both: `.frame(height:)` centres rather than clips, so it
            // can overflow upward as easily as down.
            for (name, band) in [("above", NSRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: top - 2)),
                                 ("below", NSRect(x: 0, y: top + rowHeight + 2,
                                                  width: CGFloat(rep.pixelsWide),
                                                  height: CGFloat(rep.pixelsHigh) - top - rowHeight - 2))] {
                #expect(inked(rep, in: band) < 30,
                        "the strip paints \(inked(rep, in: band)) pixels \(name) its 34pt row at \(width)pt wide — it is not one row")
            }
        }
    }

    /// Mounts the strip at `width` with no imposed height, centred in a canvas of `height`, so
    /// anything it draws outside one row is visible rather than cropped by the bitmap.
    func renderInTallCanvas(items: [PaneTabStrip.Item], width: CGFloat,
                            height: CGFloat) -> NSBitmapImageRep {
        // Centred, with a clear band on both sides: `.frame(height:)` centres its content, so a
        // chip taller than its budget overflows both ways; top-aligned, half would be off-bitmap.
        let subject = VStack(spacing: 0) {
            Spacer(minLength: 0)
            PaneTabStrip(items: items,
                         onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in },
                         onDuplicate: { _ in }, onCopyPath: { _ in }, onNew: {})
                .frame(width: width)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height)
        .background(Color(red: 0.95, green: 0.95, blue: 0.96))
        .environment(\.colorScheme, .light)
        .environment(\.controlActiveState, .active)
        return PixelDiff.render(subject, size: CGSize(width: width, height: height), passes: 2)!
    }
}
