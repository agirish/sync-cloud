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
///   chips, and the live tab's raised ground plus the accent rule under it are the only things that
///   say which folder the pane below is showing.
/// - **Each chip draws its name.** A chip squeezed to the floor with its title clipped out of it is
///   exactly the failure the measured floor exists to prevent, and it is invisible to the ladder.
/// - **The mark distinguishes two tabs with the same name**, which is the case the mark is on the
///   chip for at all: two "Documents" from different clouds.
///
/// `.machinePinned(.pixelSampling)` — it reads pixels out of a live renderer.
@MainActor
// Pin moved from the suite to the tests that read pixels, so the behavioral remainder is no
// longer hostage to the machine gate — see OrganizeRailTests for the pattern's account.
@Suite(.serialized) struct PaneTabStripRenderTests {

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
    ///
    /// `accent` defaults to the system accent, which is what the strip falls back to when a caller
    /// names no hue. Any test making a claim about the accent's COLOUR passes one explicitly — the
    /// system accent is a machine setting (Graphite is a real choice here), and a test that reads
    /// blue out of it is reading the user's System Settings.
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

    /// The strip as the PANE mounts it: the accent wash applied outside the view, over an opaque
    /// backdrop, exactly as `paneColumn` stacks `.contentSurface` under `.paneCardIfNeeded`.
    ///
    /// The wash goes between the strip and the backdrop, which is what makes it readable here at
    /// all — sampling the strip alone would read the flat fill whatever the tint said.
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

    /// A point in the strip's empty stretch — right of the last chip, left of the ＋. With two
    /// chips on a 520pt strip nothing is drawn here, so it reads the wash and only the wash.
    private func emptyStretchColor(_ rep: NSBitmapImageRep) -> NSColor {
        rep.colorAt(x: Int(Double(rep.pixelsWide) * 0.72), y: rep.pixelsHigh / 2)!
    }

    // MARK: - The pane's wash reaches the strip

    /// The strip painted no wash at all until `d76e885f`: the header and both list branches called
    /// `contentSurface` and the strip had only its card, so at a high Tint it was a pale stripe cut
    /// across the top of the pane.
    ///
    /// **This asks whether the wash SURVIVES the strip, which the call-site scan cannot.**
    /// `PaneSurfaceTintTests` proves the modifier is written at the call site; a background of the
    /// strip's own — an opaque fill anywhere in its body — would paint straight over it and leave
    /// that scan green with the stripe still there.
    @Test(.machinePinned(.pixelSampling)) func theWashIsVisibleThroughTheStrip() {
        let items = [item("Documents", active: true), item("Invoices")]
        let bare = emptyStretchColor(renderWashed(items: items, width: 520, hue: .purple, tint: 0))
        let full = emptyStretchColor(renderWashed(items: items, width: 520, hue: .purple, tint: 1))
        // Purple over a near-white ground: blue holds up while green falls away, so the gap
        // between the two channels is the tint, and it cannot be produced by dimming.
        let bareGap = bare.blueComponent - bare.greenComponent
        let fullGap = full.blueComponent - full.greenComponent
        #expect(fullGap - bareGap > 0.05,
                "the strip's empty stretch barely moved between Tint 0 and Tint 100 (gap \(bareGap) -> \(fullGap)) — the wash is not reaching it")
    }

    /// The floor's other half, and the reason the wash keeps a ramp that starts at zero: at Tint 0
    /// a pane is the background rather than a wash over it. A strip that painted its own faint
    /// accent regardless would pass the test above and still be wrong here.
    @Test(.machinePinned(.pixelSampling)) func atZeroTintTheStripPaintsNoWashAtAll() {
        let items = [item("Documents", active: true), item("Invoices")]
        let zero = emptyStretchColor(renderWashed(items: items, width: 520, hue: .purple, tint: 0))
        let none = emptyStretchColor(renderWashed(items: items, width: 520, hue: .none, tint: 1))
        // `.none` paints `Color.clear` at every tint, so it IS the unwashed ground — comparing
        // against it needs no hand-built reference colour.
        #expect(abs(zero.redComponent - none.redComponent) < 0.01)
        #expect(abs(zero.greenComponent - none.greenComponent) < 0.01)
        #expect(abs(zero.blueComponent - none.blueComponent) < 0.01)
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


    /// How accent each ROW of `box` is, as peak against typical.
    ///
    /// The statistic per row is the mean blue-minus-red across the row — the strip is rendered with
    /// an explicitly blue accent wherever this is used, so that axis is the accent and nothing else
    /// on a chip travels along it (the grey slab, the folder mark and the title ink are all
    /// near-neutral or dark).
    ///
    /// **Peak against median, rather than a count against a threshold**, because the live chip is
    /// now accent-washed all over: a count says "there is accent here" and the wash answers it. The
    /// rule is 2pt of a 26pt chip, so it is the only thing that can make ONE row stand clear of the
    /// rest, and a wash of any strength moves peak and median together.
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
    @Test(.machinePinned(.pixelSampling)) func theStripDrawsSomethingAtAll() {
        let rep = render(items: [item("Finance", active: true), item("Photos")], width: 620)
        #expect(inked(rep) > 400, "the strip rendered blank — every test below is vacuous")
    }

    // MARK: What a person has to be able to see

    /// Which tab is live. Without this the strip is five identical chips and nothing on screen says
    /// which folder the pane belongs to.
    @Test(.machinePinned(.pixelSampling)) func theActiveTabIsDrawnDifferentlyFromTheParkedOnes() {
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

    /// **Which tab is live, in BOTH appearances** — the whole treatment, ground and rule together.
    ///
    /// `.quaternary` grounds are appearance-dependent and can vanish in one scheme while surviving
    /// in the other, so this is a claim about pixels rather than about code, and it has to be made
    /// per appearance rather than once.
    @Test(.machinePinned(.pixelSampling)) func theActiveTabIsDistinguishableInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let live = render(items: [item("Finance", active: true), item("Photos")],
                              width: 620, scheme: scheme)
            let parked = render(items: [item("Finance"), item("Photos")], width: 620, scheme: scheme)
            #expect(differingPixels(live, parked) > 300,
                    "nothing distinguishes the live tab from a parked one in \(scheme)")
        }
    }

    /// **The accent rule specifically**, and it needs its own assertion because the test above
    /// cannot see it: that one measures "the live chip differs from a parked one", which the chip's
    /// accent wash satisfies on its own.
    ///
    /// **That gap is not hypothetical — it is why this test exists twice.** The rule was removed on
    /// 2026-08-24 as a duplicate of the pane's new accent card border, and the differential test
    /// stayed green throughout, because the ground alone does distinguish the chip. It went back in
    /// the same day: the border says which PANE is focused, this says which TAB is live, and no
    /// measurement of "are they different" can tell one missing marker from two present ones.
    ///
    /// **A global accent-pixel count no longer measures it, and the near miss is worth recording.**
    /// Until the live chip took `PaneSelectionWash` the rule was the only accent in the strip, so
    /// counting accent-coloured pixels found it. The wash is accent too, and it lands just under
    /// the old count's threshold — mutating the rule out today still reads 0, by about two
    /// hundredths of blue. That is a test that works by luck and would go blind the day the wash
    /// was deepened, without failing. So this measures the rule's SHAPE: it is 2pt of a 26pt chip,
    /// which makes one row of the chip far more accent than the rest, and a wash of any strength
    /// moves every row together.
    @Test(.machinePinned(.pixelSampling)) func theAccentRuleUnderTheActiveTabIsPaintedInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let live = render(items: [item("Finance", active: true), item("Photos")],
                              width: 620, scheme: scheme, accent: .blue)
            let parked = render(items: [item("Finance"), item("Photos")],
                                width: 620, scheme: scheme, accent: .blue)
            // The live chip's own box, found by differencing rather than named — see
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

    /// **A PARKED chip has a ground of its own.** Every chip wears the grey slab; only the accent
    /// on top of it says which one is live. This is the half of that arrangement no differential
    /// test can see — every "live differs from parked" measurement in this file passes just as
    /// happily with the parked chips drawn on bare backdrop, which is what they were until
    /// `PaneTabStrip.chipGround`, and which read as one tab with some words floating beside it.
    ///
    /// Read at the SECOND chip's leading padding: inside its slab, short of its mark, so nothing is
    /// drawn there and the colour is the ground or it is the backdrop.
    @Test(.machinePinned(.pixelSampling)) func aParkedChipIsDrawnOnItsOwnGround() {
        for scheme in [ColorScheme.light, .dark] {
            let rep = render(items: [item("Finance", active: true), item("Photos")],
                             width: 900, scheme: scheme)
            let width = PaneTabStripLadder.layout(available: 890, titles: ["Finance", "Photos"],
                                                  scale: 1).tabWidth
            let ground = groundColor(rep, at: LiquidGlass.cardGutter + width
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

    /// **The live chip dims in the pane that is not focused**, exactly as that pane's selected rows
    /// do — same `PaneSelectionWash` constants, so the tab and the rows under it can never disagree
    /// about which pane the window is acting on.
    ///
    /// Measured as the chip's accent, not as "the two renders differ": a strip that ignored
    /// `isActivePane` and one that inverted it both differ from the focused render, and only the
    /// direction says which.
    @Test(.machinePinned(.pixelSampling)) func theLiveChipIsQuieterInTheUnfocusedPane() {
        let items = [item("Finance", active: true), item("Photos")]
        let parked = render(items: [item("Finance"), item("Photos")], width: 620, accent: .blue)
        let focused = render(items: items, width: 620, accent: .blue, isActivePane: true)
        let other = render(items: items, width: 620, accent: .blue, isActivePane: false)
        let chip = activeChipBounds(focused, parked: parked)
        #expect(chip.width > 40, "the live chip was not located")
        // The chip's TYPICAL row — the wash — rather than its peak, which is the rule, and the rule
        // deliberately does not dim: it is the marker that still answers "which tab" over there.
        let strong = rowAccentProfile(focused, in: chip).median
        let quiet = rowAccentProfile(other, in: chip).median
        #expect(strong > quiet + 0.05, """
                the live chip reads \(strong) accent in the focused pane and \(quiet) in the other \
                — the strip is not dimming with its pane
                """)
        // …and it is still a selection over there, not a parked chip: the ratio the pane's rows
        // keep (0.10 against 0.22) is a subordinate marker, never an absent one.
        #expect(quiet > 0.02, "the unfocused pane's live chip has no wash at all")
        // The rule is the half that does NOT dim.
        let focusedPeak = rowAccentProfile(focused, in: chip).peak
        let otherPeak = rowAccentProfile(other, in: chip).peak
        #expect(abs(focusedPeak - otherPeak) < 0.05, """
                the accent rule dimmed with the pane (\(focusedPeak) against \(otherPeak)) — it is \
                the marker that has to survive there
                """)
    }

    /// A chip squeezed to the floor still draws its name. This is what the measured floor is for,
    /// and the ladder cannot see it: `visibleCount` is just as happy with a chip whose title was
    /// clipped away entirely.
    ///
    /// **Differential, and it has to be.** The first cut asked for ink inside the title box of the
    /// ACTIVE chip and passed with the `Text` replaced by `Text("")` — the active tab's raised
    /// ground inks that box on its own. Rendering the same strip with the title blanked and
    /// subtracting is the only form of this claim that the ground cannot satisfy.
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
    @Test(.machinePinned(.pixelSampling)) func theProviderMarkTellsTwoSameNamedTabsApart() {
        let same = render(items: [item("Documents", active: true, mark: "folder.fill"),
                                  item("Documents", mark: "folder.fill")], width: 620)
        let mixed = render(items: [item("Documents", active: true, mark: "folder.fill"),
                                   item("Documents", mark: "externaldrive.fill")], width: 620)
        #expect(differingPixels(same, mixed) > 30,
                "the two chips render identically — the provider mark is not being drawn")
    }

    /// The narrow rung the Organize/Storage rail gets. What must survive at 220pt is the active
    /// tab's NAME — never a row of marks.
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
        #expect(differingPixels(named, blank, in: box) > 100,
                "the chip rung drew no name for the active tab")
    }

    /// The chip rung draws the count of parked tabs — the number is the only thing on that rung
    /// that says the strip holds more than the one folder it names.
    @Test(.machinePinned(.pixelSampling)) func theChipRungDrawsHowManyTabsAreParked() {
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
    @Test(.machinePinned(.pixelSampling)) func aOneTabStripDrawsItsTab() {
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
    @Test(.machinePinned(.pixelSampling)) func aLoneTabHasNoCloseButton() {
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

    /// **A parked tab that is not under the pointer wears NO ✕.** The strip is mostly parked tabs,
    /// and a row of chips each carrying a permanent ✕ reads as a row of things to dismiss rather
    /// than places to go — which is why the button is drawn at `opacity` 0 unless the chip is active
    /// or hovered. Nothing pinned that, and the condition is one edit from being lost.
    ///
    /// **Measured against the chip's own ground, and it has to be.** This test read `inked` — pixels
    /// unlike the image's CORNER — for as long as a parked chip was drawn on bare backdrop, so its
    /// close slot was the corner colour and zero meant zero. Every chip carries the grey slab now
    /// (see `PaneTabStrip.chipGround`), and that count went straight to **1,664 out of 1,664**: the
    /// slab alone saturates it, and the test would have passed with a ✕ on every parked chip. The
    /// measure is `glyphPixels` instead — pixels unlike the SECOND CHIP's own ground, sampled out of
    /// the same render, over the chip's interior rows only.
    ///
    /// Both halves are asserted, because the interesting direction is the silent one:
    /// - the parked chip's slot is **empty**, and
    /// - a glyph really would have been seen there — the same slot in a strip whose second tab is
    ///   PINNED carries its pin, on the same grey slab.
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
        // The SECOND chip's close slot: past the first chip and the gap, at the trailing end of the
        // second, inset by its padding.
        let chipStart = LiquidGlass.cardGutter + width + PaneTabStripLadder.tabGap
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
        #expect(differingPixels(plain, again, in: slot) == 0,
                "two identical strips differ in the parked chip's close slot — the harness is unstable")
        // The claim.
        let drawn = glyphPixels(plain, from: slotStart, to: slotEnd, ground: ground)
        #expect(drawn < 10, """
                an un-hovered parked tab draws \(drawn) pixels in its close slot — \
                it is wearing a ✕ nobody asked for
                """)
        // …and the slot is the right box, on a ground where a glyph WOULD have been seen: the pin
        // a pinned tab wears sits in exactly this slot.
        #expect(glyphPixels(pinned, from: slotStart, to: slotEnd,
                            ground: groundColor(pinned, at: chipStart + 3)) > 40, """
                the pinned tab's glyph is not in this box either — the box is wrong, so the \
                emptiness above proves nothing
                """)
        #expect(differingPixels(plain, pinned, in: slot) > 20)
    }

    // MARK: The chip rung's chevron

    /// **The chip rung's chevron, rendered back** — the test `PaneTabStrip.activeChipMenu` names in
    /// prose ("`theChipRungWearsAChevron` renders it back") and which did not exist.
    ///
    /// On this rung the strip draws ONE chip and a count; the chip is the switcher for every other
    /// tab, and the chevron is the only thing that says so. It has to be the system's — a
    /// `chevron.down` drawn in the label renders as nothing, because `.borderlessButton` lays its
    /// label out itself and drops the trailing image — so the claim can only be checked in pixels.
    ///
    /// **What this does and does not catch, measured rather than assumed.** Forcing the indicator off
    /// (`.menuIndicator(.hidden)`) fails this test twice over: the chip comes out 99.5pt wide against
    /// 96.5pt of contents, and the band past its title reads 7 pixels instead of 135. *Deleting*
    /// `.menuIndicator(.visible)` changes nothing at all — `.borderlessButton` shows its indicator by
    /// default on this macOS, so that line is belt-and-braces rather than the thing holding the
    /// chevron up. This test pins the chevron being DRAWN, which is the claim the rung actually
    /// rests on; it cannot report the modifier going missing while the default keeps agreeing with it.
    ///
    /// **Measured against the chip's own ground, not against the strip's backdrop.** The chip's
    /// raised ground differs from the backdrop at every pixel of this band, so `inked` saturates
    /// there (1,871 of 2,448 with or without a chevron). Every count below is instead "pixels unlike
    /// the ground the chip is drawn on", sampled out of the same render — a per-pixel difference
    /// against the local surface, which is what makes a glyph visible and a flat fill invisible.
    ///
    /// The chip is **located from the parked-render differential** (`activeChipBounds`) rather than
    /// from the ladder's `tabWidth`: the chip takes its NATURAL width up to that cap (112.5pt
    /// against a 156.5pt cap on this fixture), and the whole question here is how much wider than
    /// its contents that natural width is.
    @Test(.machinePinned(.pixelSampling)) func theChipRungWearsAChevron() {
        let five = [item("Immigration", active: true), item("Photos"), item("Legal"),
                    item("Medical"), item("Finance")]
        #expect(PaneTabStripLadder.layout(available: 210, titles: five.map(\.title), scale: 1).rung == .chip,
                "this fixture is meant to be on the chip rung")
        let rep = render(items: five, width: 220)
        let perPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1

        // The chip's span, off its raised ground — which IS the chip, so there is no inset to undo
        // (the accent rule this used to measure was inset 3pt each side by `activeGround`).
        let parkedRep = render(items: five.map { item($0.title) }, width: 220)
        let chip = activeChipBounds(rep, parked: parkedRep)
        let chipStart = chip.minX / perPoint
        let chipEnd = chip.maxX / perPoint
        let titleStart = LiquidGlass.cardGutter + PaneTabStripLadder.tabPadding
            + PaneTabStripLadder.markSide + PaneTabStripLadder.contentGap
        let titleEnd = titleStart + LabelMetrics.width(of: "Immigration",
                                                       font: PaneTabStripLadder.titleFont, scale: 1)
        // Half a point of slack: the rule's edge is measured in whole pixels, and this only has to
        // establish that the chip is where the boxes below assume it is.
        #expect(abs(chipStart - LiquidGlass.cardGutter) < 0.6,
                "the chip starts at \(chipStart)pt, not the strip's gutter — every box below is off")

        // **The room the indicator takes.** The chip is wider than mark + gap + title + its two
        // paddings by the indicator's width; with the indicator gone it would be exactly that sum.
        let contents = PaneTabStripLadder.tabPadding + PaneTabStripLadder.markSide
            + PaneTabStripLadder.contentGap + (titleEnd - titleStart) + PaneTabStripLadder.tabPadding
        #expect(chipEnd - chipStart > contents + 8, """
                the chip is \(chipEnd - chipStart)pt wide against \(contents)pt of contents — there is \
                no room in it for an indicator, so the rung ends flush after its title
                """)

        // …and that room is PAINTED. The band runs from just past the title to the chip's trailing
        // padding, which is where the system draws its indicator.
        let ground = groundColor(rep, at: chipStart + 3)
        let chevron = glyphPixels(rep, from: titleEnd + 2, to: chipEnd - PaneTabStripLadder.tabPadding,
                                  ground: ground)
        #expect(chevron > 40, """
                \(chevron) pixels unlike the chip's own ground between its title and its trailing \
                edge — the space is reserved but nothing is drawn in it
                """)

        // The zero control: the 5pt gap between the mark and the title is the same measurement over
        // a band that must be bare ground. Without it, a count that reported the ground itself would
        // make the assertion above pass with no chevron drawn at all.
        #expect(glyphPixels(rep, from: chipStart + PaneTabStripLadder.tabPadding
                            + PaneTabStripLadder.markSide + 1,
                            to: chipStart + PaneTabStripLadder.tabPadding
                            + PaneTabStripLadder.markSide + PaneTabStripLadder.contentGap - 1,
                            ground: ground) == 0,
                "bare ground reads as painted — this measurement cannot tell a glyph from a fill")
        // The positive control: the same measurement over the title finds it.
        #expect(glyphPixels(rep, from: titleStart, to: titleEnd, ground: ground) > 300,
                "the chip's own title does not register — the measurement is blind")
        // And the chevron is INSIDE the chip, not spilling past it: the trailing padding is bare.
        #expect(glyphPixels(rep, from: chipEnd - PaneTabStripLadder.tabPadding + 1, to: chipEnd - 1,
                            ground: ground) == 0,
                "something is drawn in the chip's trailing padding")
    }

    /// **Where the active chip is, measured rather than assumed** — the bounding box of everything
    /// that changes when the same strip is rendered with that chip parked instead.
    ///
    /// It used to be the bounds of *accent-coloured* pixels, anchored on the chip's 2pt accent
    /// rule. The rule was removed and put back the same day (2026-08-24 — `activeGround` keeps the
    /// story), but the colour anchor did not come back with it: a differential against the parked
    /// render finds the chip's whole raised ground in either appearance without naming a colour —
    /// `.quaternary` is a different grey in each appearance and deliberately close to the backdrop
    /// — and it keeps finding the chip whatever marker the chip happens to carry.
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
    /// rows only.
    ///
    /// The rows matter: the chip is shorter than the strip, so a full-height band would count the
    /// backdrop above and below it as "unlike the ground" and report hundreds of pixels for a band
    /// that is bare.
    ///
    /// The band comes from the LADDER now. It used to be located from the accent rule under the
    /// chip — `accentBounds(rep).minY - 2` — an anchor that vanished when the rule was briefly
    /// removed on 2026-08-24; the rule came back the same day, the render-derived anchor did not.
    /// `stripHeight` and `tabHeight` are the same two numbers the strip lays itself out from, and
    /// the chip is centred between them, so this needs no render to find.
    func glyphPixels(_ rep: NSBitmapImageRep, from x0: CGFloat, to x1: CGFloat,
                     ground: NSColor) -> Int {
        guard x1 > x0 else { return -1 }
        let perPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        let inset = (PaneTabStripLadder.stripHeight - PaneTabStripLadder.tabHeight) / 2
        let bottom = Int((PaneTabStripLadder.stripHeight - inset - 3) * perPoint)
        let top = max(0, bottom - Int((PaneTabStripLadder.tabHeight - 6) * perPoint))
        var count = 0
        for y in top..<min(rep.pixelsHigh, bottom) {
            for x in Int(x0 * perPoint)..<min(rep.pixelsWide, Int(x1 * perPoint)) {
                guard let p = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(p.redComponent - ground.redComponent),
                       max(abs(p.greenComponent - ground.greenComponent),
                           abs(p.blueComponent - ground.blueComponent))) > 0.06 { count += 1 }
            }
        }
        return count
    }

    // MARK: The reorder drag

    /// **The gap tracks the drop index** (roadmap Fig. 8): the chips the dragged tab has passed
    /// step aside by exactly one stride, and everything else stands still. Priced from the same
    /// stride the drop index uses, so what the row shows and where the tab lands cannot disagree.
    @Test func theChipsStepAsideForTheDraggedTab() {
        let items = ["A", "B", "C", "D"].map { item($0) }
        let stride: CGFloat = 100
        let dragged = items[0].id

        // Dragged two strides right: B and C step left, D is untouched, and the dragged chip is
        // excluded (it rides the pointer instead).
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

    /// **The preview and the drop are one rule**, so the row cannot animate a move it will not make.
    /// Both refusals below were real: a drag across the pin line, which `PaneTabList.move` rejects,
    /// and a drag past the last visible chip, which would drop the tab into the folded-away region
    /// where — from the strip — it looks like it vanished.
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

    /// …and **the drawn indices are not always contiguous**, which the clamp above quietly assumed.
    ///
    /// `visible(_:slots:)` draws the pinned PREFIX plus a WINDOW of the unpinned run, so once that
    /// window has scrolled off the head there is a folded-away gap between the two — and a clamp
    /// into `[first, last]` still lands inside it. The case above cannot see this, because its
    /// `shown` is a contiguous prefix; the fixture here is the shape that fails, and it is not
    /// contrived: one pin, four tabs and three slots is a rail-width strip.
    ///
    /// The consequence was the exact one `dropIndex` is named for. Dropping T3 at index 1 or 2 and
    /// recomputing the window leaves T3 out of it — the chip vanishes into the overflow.
    @Test func aDropCannotLandInTheGapBetweenThePinsAndTheWindow() {
        let items = [item("P", pinned: true), item("T1"), item("T2"), item("T3"),
                     item("T4", active: true)]
        let shown = PaneTabStrip.visible(items, slots: 3)
        // The premise: the window really has scrolled, so indices 1 and 2 are drawn by nothing.
        #expect(shown.map(\.title) == ["P", "T3", "T4"])

        let drawn = Set(shown.map(\.id))
        for from in items.indices where drawn.contains(items[from].id) {
            for steps in -4...4 {
                let to = PaneTabStrip.dropIndex(from: from, steps: steps, items: items, visible: shown)
                #expect(drawn.contains(items[to].id),
                        "\(items[from].title) dropped onto folded-away index \(to) at \(steps) steps")
            }
        }
        // And the snap goes BACK toward the drag's origin rather than outward past a hidden tab:
        // T3 dragged hard left stops where it is, not at the head of the unpinned run.
        #expect(PaneTabStrip.dropIndex(from: 3, steps: -9, items: items, visible: shown) == 3)
    }

    /// **The other half, stated so nobody reads the guarantee as the wider one.**
    ///
    /// `dropIndex` promises the tab LANDS where a chip is drawn. It does not promise the chip is
    /// still drawn afterwards: `visible(_:slots:)` re-derives its window from the ACTIVE tab, and
    /// the move changes the order that window is taken from. The case below needs no pins at all —
    /// three tabs in two slots, dragging the parked one past the active one — and it is the
    /// window's design rather than a hole in the drop rule, since the tab is then in the overflow
    /// menu exactly as a newly opened tab would be.
    ///
    /// Pinned as a fact rather than left implicit, because the first version of the fix beside this
    /// described itself as stopping a chip from "appearing to disappear" — true of the mechanism it
    /// closed and not of this one, and an overstated guarantee is how the next reader stops looking.
    @Test func aLegalDropStillLandsWhereItWasAimed() {
        let items = [item("T0"), item("T1"), item("T2", active: true)]
        let shown = PaneTabStrip.visible(items, slots: 2)
        #expect(shown.map(\.title) == ["T1", "T2"], "the window is not where this case needs it")

        // Dragging the parked chip one step right is a legal drop onto a DRAWN index…
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

    /// A pinned chip wears a pin where an unpinned one wears its ✕ — the two strips are otherwise
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
    @Test(.machinePinned(.pixelSampling)) func anEmptyStripDrawsNothingRatherThanTrapping() {
        let rep = render(items: [], width: 620)
        #expect(inked(rep) < 50, "an empty strip painted something")
    }

    /// The strip is one 34pt row, at every rung — it shares the pane's vertical budget with a
    /// header pinned at 81pt, and a strip that grew a second row would push the list down.
    ///
    /// **Measured on a canvas TALLER than a row, because the strip pins its own height.** This
    /// asserted `rep.size.height == stripHeight` against a bitmap `render()` had just sized to
    /// `stripHeight` — true by construction at every width, and it could not have failed. The
    /// clamp is also not a clip: SwiftUI's `.frame(height:)` lets content overflow, so a rung that
    /// wanted two rows paints *outside* the row rather than growing it, and the pane below wears
    /// the difference. So the question is asked in pixels, below the row where nothing may be.
    @Test(.machinePinned(.pixelSampling)) func theStripIsOneRowAtEveryRung() {
        let canvasHeight = PaneTabStripLadder.stripHeight * 3
        for width in [CGFloat(900), 620, 340, 220] {
            let items = [item("Finance", active: true), item("Photos"), item("Legal"),
                         item("Medical"), item("Immigration")]
            let rep = renderInTallCanvas(items: items, width: width, height: canvasHeight)
            let scale = CGFloat(rep.pixelsHigh) / canvasHeight
            let rowHeight = PaneTabStripLadder.stripHeight * scale
            let top = (CGFloat(rep.pixelsHigh) - rowHeight) / 2

            // The control: the row itself really did draw. Without it, a strip that rendered
            // nothing at all would satisfy the emptiness checks below at every width.
            let row = NSRect(x: 0, y: top, width: CGFloat(rep.pixelsWide), height: rowHeight)
            #expect(inked(rep, in: row) > 200,
                    "the strip drew almost nothing at \(width)pt — the checks below would be vacuous")

            // …and a clear band on each side of it. A second rank of chips, or a chip taller than
            // its budget, lands in one or both — `.frame(height:)` centres rather than clips, so it
            // can overflow upward just as easily as down.
            for (name, band) in [("above", NSRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: top - 2)),
                                 ("below", NSRect(x: 0, y: top + rowHeight + 2,
                                                  width: CGFloat(rep.pixelsWide),
                                                  height: CGFloat(rep.pixelsHigh) - top - rowHeight - 2))] {
                #expect(inked(rep, in: band) < 30,
                        "the strip paints \(inked(rep, in: band)) pixels \(name) its 34pt row at \(width)pt wide — it is not one row")
            }
        }
    }

    /// Mounts the strip at `width` with **no imposed height**, centred in a canvas of `height`, so
    /// anything the strip draws outside one row is visible rather than cropped by the bitmap. The
    /// note below says why centred rather than top-aligned, which this line used to contradict.
    func renderInTallCanvas(items: [PaneTabStrip.Item], width: CGFloat,
                            height: CGFloat) -> NSBitmapImageRep {
        // **Centred, with a clear band on BOTH sides.** Top-aligned, the region above the row was
        // off-bitmap — and `.frame(height:)` centres its content, so a chip taller than its budget
        // overflows equally in both directions and only half the evidence was measurable.
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
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
}
