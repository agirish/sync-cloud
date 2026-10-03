import Testing
import AppKit
import SwiftUI
@testable import Design

/// The selection lens (roadmap RD46) — its rules, its motion, and that a host really draws it where
/// its stops are.
///
/// Glass renders nothing offscreen, so the rendered half uses the probe (`drawsProbe`): the lens's
/// exact geometry in flat magenta. The decisions it pins are the ones taken 2026-10-02 — glass all
/// the time in Frosted and Clear, today's marker untouched in Solid, the Tint slider the only thing
/// that tints, labels never touched.
@MainActor
@Suite(.serialized) struct SelectionLensTests {

    // MARK: - Material

    @Test func solidDrawsTodaysMarkerAndTheGlassLevelsDrawGlass() {
        let solid = SelectionLensAppearance(level: .solid, hue: .rose, tint: 0)
        let frosted = SelectionLensAppearance(level: .frosted, hue: .rose, tint: 0)
        let clear = SelectionLensAppearance(level: .clear, hue: .rose, tint: 0)
        #expect(SelectionLensRule.material(for: solid, reduceTransparency: false) == .today)
        #expect(SelectionLensRule.material(for: frosted, reduceTransparency: false) == .frosted)
        #expect(SelectionLensRule.material(for: clear, reduceTransparency: false) == .clear)
    }

    @Test func reduceTransparencyDrawsTodaysMarkerAtEveryLevel() {
        for level in GlassLevel.allCases {
            let appearance = SelectionLensAppearance(level: level, hue: .blue, tint: 0.5)
            #expect(SelectionLensRule.material(for: appearance, reduceTransparency: true) == .today)
        }
    }

    @Test func theProbeStandsInForGlassOnlyWhereGlassWouldBe() {
        #expect(SelectionLensRule.material(
            for: SelectionLensAppearance(level: .solid, hue: .blue, tint: 0, drawsProbe: true),
            reduceTransparency: false) == .today)
        #expect(SelectionLensRule.material(
            for: SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true),
            reduceTransparency: false) == .probe)
        #expect(SelectionLensRule.material(
            for: SelectionLensAppearance(level: .clear, hue: .blue, tint: 0, drawsProbe: true),
            reduceTransparency: false) == .probe)
    }

    @Test func anUnsetAppearanceIsSolid() {
        // What every control outside a window root sees — and so what every package render test
        // sees: today's marker, untouched.
        #expect(SelectionLensAppearance.today.level == .solid)
        #expect(EnvironmentValues().selectionLensAppearance == .today)
        #expect(EnvironmentValues().selectionLensMaterial == .today)
    }

    // MARK: - Tint: the slider, and nothing else

    @Test func theTintFollowsTheWindowBackgroundsCurve() {
        // A quarter of the marker's colour at Tint 0, all of it at Tint 100.
        #expect(SelectionLensRule.tintStrength(hue: .blue, tint: 0) == 0.25)
        #expect(SelectionLensRule.tintStrength(hue: .blue, tint: 1) == 1.0)
        for tint in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(SelectionLensRule.tintStrength(hue: .rose, tint: tint)
                    == LiquidGlass.backgroundHueStrength(forTint: tint))
        }
    }

    @Test func theTintIsTheSameForEveryHue() {
        // No per-hue adjustment: the slider is the only knob.
        for hue in LiquidGlassHue.allCases where hue != .none {
            #expect(SelectionLensRule.tintStrength(hue: hue, tint: 0.4)
                    == SelectionLensRule.tintStrength(hue: .blue, tint: 0.4))
        }
    }

    @Test func noneIsUntintedAtEveryTint() {
        for tint in [0.0, 0.5, 1.0] {
            #expect(SelectionLensRule.tintStrength(hue: .none, tint: tint) == 0)
        }
    }

    @Test func atFullTintTheGlassCarriesExactlyTodaysColour() {
        #expect(SelectionLensRule.tintOpacity(markerOpacity: 1, hue: .blue, tint: 1) == 1)
        #expect(SelectionLensRule.tintOpacity(markerOpacity: 0.22, hue: .blue, tint: 1) == 0.22)
        #expect(SelectionLensRule.tintOpacity(markerOpacity: 1, hue: .blue, tint: 0) == 0.25)
        #expect(SelectionLensRule.tintOpacity(markerOpacity: 0, hue: .blue, tint: 1) == 0)
    }

    // MARK: - Clear's rim

    @Test func clearAlwaysDrawsARimAndFrostedOnlyWhereItWouldNotSayEnough() {
        #expect(SelectionLensRule.rimWidth(material: .clear, hasRing: false, increasedContrast: false) == 1.5)
        #expect(SelectionLensRule.rimWidth(material: .frosted, hasRing: false, increasedContrast: false) == 0)
        #expect(SelectionLensRule.rimWidth(material: .today, hasRing: false, increasedContrast: true, colourless: true) == 0)
        #expect(SelectionLensRule.rimWidth(material: .probe, hasRing: false, increasedContrast: true, colourless: true) == 0)
        // Frosted: Increase Contrast asks for edges; a colourless lens (accent None) needs one.
        #expect(SelectionLensRule.rimWidth(material: .frosted, hasRing: false, increasedContrast: true) == 2.5)
        #expect(SelectionLensRule.rimWidth(material: .frosted, hasRing: false, increasedContrast: false, colourless: true) == 1.5)
    }

    @Test func aRingIsItsOwnRim() {
        #expect(SelectionLensRule.rimWidth(material: .clear, hasRing: true, increasedContrast: false) == 0)
        #expect(SelectionLensRule.rimWidth(material: .clear, hasRing: true, increasedContrast: true) == 0)
        #expect(SelectionLensRule.rimWidth(material: .frosted, hasRing: true, increasedContrast: true, colourless: true) == 0)
    }

    @Test func increaseContrastThickensTheRim() {
        #expect(SelectionLensRule.rimWidth(material: .clear, hasRing: false, increasedContrast: true) == 2.5)
    }

    // MARK: - What a host hands its lens

    @Test func eachMaterialDrawsItsOwnGlass() {
        #expect(SelectionLensRule.glassVariant(.frosted) == .regular)
        #expect(SelectionLensRule.glassVariant(.clear) == .clear)
        #expect(SelectionLensRule.glassVariant(.today) == nil)
        #expect(SelectionLensRule.glassVariant(.probe) == nil)
    }

    @Test func theHostPassesTheStylesOwnTintAndRim() {
        let rose100 = SelectionLensAppearance(level: .frosted, hue: .rose, tint: 1)
        // A fill carries all of its colour at Tint 100; a halo (marker opacity 0) carries none.
        let fill = SelectionLensRule.lensSpec(style: .fill(.capsule, color: .red), appearance: rose100,
                                              reduceTransparency: false, increasedContrast: false)
        #expect(fill == .init(material: .frosted, tintOpacity: 1, rimWidth: 0))
        let halo = SelectionLensStyle(shape: .circle, color: .gray, markerOpacity: 0,
                                      ring: .init(color: .gray, width: 2), outset: 3)
        #expect(SelectionLensRule.lensSpec(style: halo, appearance: rose100, reduceTransparency: false,
                                           increasedContrast: true).tintOpacity == 0)
        // Accent None: colourless glass, so Frosted takes an edge.
        let none = SelectionLensAppearance(level: .frosted, hue: .none, tint: 1)
        #expect(SelectionLensRule.lensSpec(style: .fill(.capsule, color: .red), appearance: none,
                                           reduceTransparency: false, increasedContrast: false)
                == .init(material: .frosted, tintOpacity: 0, rimWidth: SelectionLensRule.rimWidth))
        // Reduce Transparency: no lens.
        #expect(SelectionLensRule.lensSpec(style: .fill(.capsule, color: .red), appearance: rose100,
                                           reduceTransparency: true, increasedContrast: false).material == .today)
    }

    @Test func theChosenChoiceIsFilledOnlyWhereNoLensIs() {
        #expect(SelectionLensRule.choiceVariant(isSelected: true, material: .today, unselected: .segment) == .filled)
        for material in [SelectionLensMaterial.frosted, .clear, .probe] {
            #expect(SelectionLensRule.choiceVariant(isSelected: true, material: material, unselected: .row) == .row)
        }
        #expect(SelectionLensRule.choiceVariant(isSelected: false, material: .today, unselected: .segment) == .segment)
    }

    @Test func aFilledChoicesRingTakesTheOnFillTintAndNothingElseDoes() {
        #expect(SelectionLensRule.choiceTint(variant: .filled, tint: .blue, filledTint: .white) == .white)
        #expect(SelectionLensRule.choiceTint(variant: .filled, tint: .blue, filledTint: nil) == .blue)
        // The chosen one under a lens is `.segment`, and washes in the accent like its neighbours.
        #expect(SelectionLensRule.choiceTint(variant: .segment, tint: .blue, filledTint: .white) == .blue)
    }

    // MARK: - Motion

    private let left = CGRect(x: 10, y: 4, width: 60, height: 20)
    private let right = CGRect(x: 150, y: 4, width: 40, height: 20)
    private let top = CGRect(x: 4, y: 10, width: 120, height: 24)
    private let bottom = CGRect(x: 4, y: 130, width: 120, height: 24)

    /// The move sampled every 5 ms, as a test needs it.
    private func samples(from: CGRect?, to: CGRect?,
                         velocity: SelectionLensMotion.EdgeVelocity = .zero) -> [SelectionLensMotion.Frame] {
        stride(from: 0.0, through: SelectionLensMotion.travelDuration, by: 0.005).compactMap {
            SelectionLensMotion.frame(from: from, velocity: velocity, to: to, elapsed: $0)
        }
    }

    @Test func aMoveStartsWhereTheLensWasAndEndsExactlyOnTheNewStop() {
        #expect(SelectionLensMotion.frame(from: left, to: right, elapsed: 0)?.rect == left)
        #expect(SelectionLensMotion.frame(from: left, to: right, elapsed: SelectionLensMotion.travelDuration)?.rect == right)
        #expect(SelectionLensMotion.frame(from: left, to: right, elapsed: 5)?.rect == right)
        #expect(SelectionLensMotion.frame(from: right, to: left, elapsed: 5)?.rect == left)
        #expect(SelectionLensMotion.frame(from: top, to: bottom, elapsed: 5)?.rect == bottom)
    }

    @Test func itIsAlreadyThereBeforeTheClockStops() throws {
        // The leg's end snaps the lens onto its stop; by then the springs must have done it, or the
        // snap is a visible jump.
        let last = try #require(SelectionLensMotion.frame(from: left, to: right,
                                                           elapsed: SelectionLensMotion.travelDuration - 0.001))
        #expect(abs(last.rect.minX - right.minX) < 0.2 && abs(last.rect.maxX - right.maxX) < 0.2)
        let far = CGRect(x: 10, y: 410, width: 60, height: 20)
        let longest = try #require(SelectionLensMotion.frame(from: left, to: far,
                                                              elapsed: SelectionLensMotion.travelDuration - 0.001))
        #expect(abs(longest.rect.minY - far.minY) < 0.2 && abs(longest.rect.maxY - far.maxY) < 0.2,
                "a 400pt move is still \(longest.rect) short of \(far) when the clock stops")
    }

    @Test func theLeadingEdgeArrivesFirstSoTheLensStretchesALittle() throws {
        let frames = samples(from: left, to: right)
        let longest = frames.map(\.rect.width).max() ?? 0
        // A stretch, and a slight one: longer than either stop, well short of spanning the trip.
        #expect(longest > left.width + 5, "no stretch — the edges are moving together")
        #expect(longest < left.width + (right.maxX - left.maxX) * 0.3, "stretched \(longest) — more than slight")
        // Going left, the left edge leads.
        let back = samples(from: right, to: left)
        let early = try #require(back.first { $0.rect.minX < right.minX - 20 })
        #expect(early.rect.maxX > left.maxX + 20, "the trailing edge left with the leading one")
    }

    @Test func aVerticalMoveStretchesVertically() {
        #expect(SelectionLensMotion.isVertical(from: top, to: bottom))
        #expect(!SelectionLensMotion.isVertical(from: left, to: right))
        let frames = samples(from: top, to: bottom)
        #expect((frames.map(\.rect.height).max() ?? 0) > top.height + 5)
        #expect(frames.allSatisfy { abs($0.rect.width - top.width) < 0.001 }, "a vertical move changed the width")
    }

    @Test func itOvershootsOnceAndSlightlyWithNoHardStop() {
        let frames = samples(from: left, to: right)
        let past = frames.map { $0.rect.maxX - right.maxX }
        let furthest = past.max() ?? 0
        #expect(furthest > 0.2, "the leading edge should overshoot a little")
        #expect(furthest < (right.maxX - left.maxX) * 0.02, "overshot \(furthest)pt")
        // Settles ONCE: after coming back from the overshoot it never goes past again by a visible amount.
        let peak = past.firstIndex(of: furthest)!
        let back = past[peak...].firstIndex { $0 <= 0.05 } ?? past.endIndex
        #expect(past[back...].allSatisfy { $0 < 0.1 }, "the leading edge bounced past its stop a second time")
        // No hard stop: the old curve clamped the edge flat at its limit. A spring's speed is continuous,
        // so no two neighbouring 5 ms samples differ by much more than their neighbours do.
        let steps = zip(frames.dropFirst(), frames).map { $0.rect.maxX - $1.rect.maxX }
        for (a, b) in zip(steps.dropFirst(), steps) {
            #expect(abs(a - b) < 1.5, "the leading edge's speed jumped by \(abs(a - b))pt in 5 ms")
        }
        // And no pinch: across the move, the lens keeps its height.
        #expect(frames.allSatisfy { abs($0.rect.height - left.height) < 0.001 })
    }

    @Test func aSecondClickMidMoveCarriesTheSpeedOn() throws {
        // Halfway out to `right`, the user picks `left` again: the new move starts where the lens is,
        // moving the way it was — no dead stop.
        let elapsed = 0.06
        let here = try #require(SelectionLensMotion.frame(from: left, to: right, elapsed: elapsed)).rect
        let speed = SelectionLensMotion.velocity(from: left, to: right, elapsed: elapsed)
        #expect(speed.maxX > 100, "the leading edge was moving at \(speed.maxX)pt/s")
        let next = SelectionLensMotion.frame(from: here, velocity: speed, to: left, elapsed: 0.005)!.rect
        #expect(next.maxX > here.maxX, "the lens stopped dead instead of carrying on before turning back")
        #expect(SelectionLensMotion.frame(from: here, velocity: speed, to: left, elapsed: 5)?.rect == left)
    }

    @Test func aLensGrowsOutOfNothingAndMeltsBackIntoIt() throws {
        let grown = try #require(SelectionLensMotion.frame(from: nil, to: right,
                                                            elapsed: SelectionLensMotion.appearDuration))
        #expect(grown.rect == right)
        #expect(grown.opacity == 1)
        let seed = try #require(SelectionLensMotion.frame(from: nil, to: right, elapsed: 0))
        #expect(seed.opacity == 0)
        #expect(abs(seed.rect.width - right.width * SelectionLensMotion.seedScale) < 0.001)
        #expect(abs(seed.rect.midX - right.midX) < 0.001)
        let melting = try #require(SelectionLensMotion.frame(from: left, to: nil, elapsed: 0.1))
        #expect(melting.rect.width < left.width && melting.opacity < 1)
        // A melt that catches a growth part-way fades on from there, never back up to full.
        let caught = try #require(SelectionLensMotion.frame(from: left, opacity: 0.3, to: nil, elapsed: 0))
        #expect(abs(caught.opacity - 0.3) < 0.001)
        #expect(SelectionLensMotion.frame(from: left, to: nil, elapsed: SelectionLensMotion.meltDuration) == nil)
        #expect(SelectionLensMotion.frame(from: nil, to: nil, elapsed: 0.1) == nil)
    }

    @Test func eachKindOfMoveSettlesOnItsOwnClock() {
        // Grown by `appearDuration`, melted by `meltDuration`, travelled by `travelDuration` — the
        // longest, which is what every leg in the layer now runs for.
        #expect(SelectionLensMotion.frame(from: nil, to: right, elapsed: SelectionLensMotion.appearDuration)?.rect == right)
        #expect(SelectionLensMotion.frame(from: left, to: nil, elapsed: SelectionLensMotion.meltDuration) == nil)
        #expect(SelectionLensMotion.travelDuration >= SelectionLensMotion.appearDuration)
        #expect(SelectionLensMotion.travelDuration >= SelectionLensMotion.meltDuration)
    }

    @Test func aTravelCaughtMidGrowthFadesTheRestOfTheWayIn() {
        // A second click while the lens is half-grown: it travels on from where it is, and its
        // opacity carries on from where it was rather than jumping to full.
        let start = SelectionLensMotion.frame(from: left, opacity: 0.5, to: right, elapsed: 0)
        #expect(start?.opacity == 0.5)
        let later = SelectionLensMotion.frame(from: left, opacity: 0.5, to: right, elapsed: SelectionLensMotion.appearFade / 2)
        #expect(later.map { $0.opacity > 0.5 && $0.opacity < 1 } == true)
        #expect(SelectionLensMotion.frame(from: left, opacity: 0.5, to: right, elapsed: 1)?.opacity == 1)
        #expect(SelectionLensMotion.frame(from: left, to: right, elapsed: 0)?.opacity == 1)
    }

    @Test func aGrowthAndAMeltCarryTheirSpeedToo() {
        // So a click mid-growth moves on at the speed the lens was opening out at.
        let growing = SelectionLensMotion.velocity(from: nil, to: right, elapsed: 0.05)
        #expect(growing.maxX > 0 && growing.minX < 0, "a growing lens's edges move outward: \(growing)")
        let melting = SelectionLensMotion.velocity(from: left, to: nil, elapsed: 0.05)
        #expect(melting.maxX < 0 && melting.minX > 0, "a melting lens's edges move inward: \(melting)")
        #expect(SelectionLensMotion.velocity(from: nil, to: right, elapsed: SelectionLensMotion.appearDuration) == .zero)
    }

    @Test func progressIsHowFarTheCentreHasCome() {
        #expect(SelectionLensMotion.progress(from: left, to: right, at: left) == 0)
        #expect(SelectionLensMotion.progress(from: left, to: right, at: right) == 1)
        let half = CGRect(x: (left.midX + right.midX) / 2 - 25, y: 4, width: 50, height: 20)
        #expect(abs(SelectionLensMotion.progress(from: left, to: right, at: half) - 0.5) < 0.001)
        // Past the end (an overshoot) is still there; a resize in place is already there.
        #expect(SelectionLensMotion.progress(from: left, to: right, at: right.offsetBy(dx: 5, dy: 0)) == 1)
        #expect(SelectionLensMotion.progress(from: left, to: left.insetBy(dx: 5, dy: 0), at: left) == 1)
    }

    @Test func theSpringsAreSwiftUIsOwn() {
        // A spring at rest stays put; a critically damped one never overshoots; its speed starts as given.
        let s = SelectionLensMotion.Spring.trail
        #expect(s.step(from: 5, velocity: 0, to: 5, at: 0.3).value == 5)
        let path = stride(from: 0.0, through: 1, by: 0.01).map { s.step(from: 0, velocity: 0, to: 100, at: $0).value }
        #expect(path.allSatisfy { $0 <= 100.0001 })
        #expect(abs(SelectionLensMotion.Spring.lead.step(from: 0, velocity: 42, to: 100, at: 0).velocity - 42) < 1e-9)
    }

    // MARK: - The launch breadcrumb

    @Test func theLogLineNamesTheSettingsAndThePathTaken() {
        let clear = SelectionLensAppearance(level: .clear, hue: .rose, tint: 0)
        #expect(clear.logLine(reduceTransparency: false, reduceMotion: false)
                == "[glass] Clear, Rose accent, Tint 0% — glass selection and bar buttons; moves glide")
        #expect(clear.logLine(reduceTransparency: false, reduceMotion: true).hasSuffix(
            "moves are instant (Reduce Motion is on)"))
        #expect(clear.logLine(reduceTransparency: true, reduceMotion: false).hasSuffix(
            "Reduce Transparency is on, so selection and bar buttons as Solid draws them"))
        #expect(clear.logLine(reduceTransparency: false, reduceMotion: false, increasedContrast: true)
                .hasSuffix("moves glide; edged for Increase Contrast"))
        let solid = SelectionLensAppearance(level: .solid, hue: .blue, tint: 0.5)
        #expect(solid.logLine(reduceTransparency: true, reduceMotion: true, increasedContrast: true)
                == "[glass] Solid, Blue accent, Tint 50% — selection and bar buttons as Solid draws them")
        #expect(SelectionLensAppearance(level: .frosted, hue: .none, tint: 0)
                .logLine(reduceTransparency: false, reduceMotion: false).hasPrefix("[glass] Frosted, no accent,"))
    }

    @Test func theStoredAppearanceUsesTheWindowRootsDefaults() {
        let defaults = ScratchDefaults("SelectionLensTests.stored")
        #expect(SelectionLensAppearance.stored(in: defaults)
                == SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0))
        defaults.set("clear", forKey: LiquidGlass.levelKey)
        defaults.set("rose", forKey: LiquidGlass.hueKey)
        defaults.set(0.25, forKey: LiquidGlass.tintKey)
        #expect(SelectionLensAppearance.stored(in: defaults)
                == SelectionLensAppearance(level: .clear, hue: .rose, tint: 0.25))
    }

    @Test func reduceMotionArrivesWithoutTravelling() {
        #expect(SelectionLensMotion.travels(from: left, to: right, visibleRect: nil, reduceMotion: false))
        #expect(!SelectionLensMotion.travels(from: left, to: right, visibleRect: nil, reduceMotion: true))
        #expect(!SelectionLensMotion.travels(from: nil, to: right, visibleRect: nil, reduceMotion: true))
    }

    @Test func aMoveWithAnEndOffScreenSwitchesInstantly() {
        let visible = CGRect(x: 0, y: 0, width: 200, height: 100)
        #expect(SelectionLensMotion.travels(from: top, to: CGRect(x: 4, y: 60, width: 120, height: 24),
                                            visibleRect: visible, reduceMotion: false))
        #expect(!SelectionLensMotion.travels(from: top, to: bottom, visibleRect: visible, reduceMotion: false))
        #expect(!SelectionLensMotion.travels(from: bottom, to: top, visibleRect: visible, reduceMotion: false))
    }

    @Test func nothingMovesWhenNothingChanges() {
        #expect(!SelectionLensMotion.travels(from: left, to: left, visibleRect: nil, reduceMotion: false))
        #expect(!SelectionLensMotion.travels(from: nil, to: nil, visibleRect: nil, reduceMotion: false))
    }

    // MARK: - The window roots' reader

    /// What a view under `selectionLensAppearanceFromDefaults()` actually receives.
    private struct AppearanceProbe: View {
        @Environment(\.selectionLensAppearance) private var appearance
        let seen: (SelectionLensAppearance) -> Void
        var body: some View {
            Color.clear.onAppear { seen(appearance) }
        }
    }

    @Test(arguments: [nil, ("clear", "rose", 0.25), ("solid", "graphite", 1.0)] as [(String, String, Double)?])
    func theWindowRootsReadWhatStoredReads(stored: (String, String, Double)?) throws {
        // `stored(in:)` (the launch line) and the window roots' modifier read the same three keys
        // with the same defaults — checked by mounting the modifier, not by reading its source.
        let defaults = ScratchDefaults("SelectionLensTests.roots")
        if let stored {
            defaults.set(stored.0, forKey: LiquidGlass.levelKey)
            defaults.set(stored.1, forKey: LiquidGlass.hueKey)
            defaults.set(stored.2, forKey: LiquidGlass.tintKey)
        }
        var seen: SelectionLensAppearance?
        let rig = ProbeRig(AnyView(AppearanceProbe { seen = $0 }
            .selectionLensAppearanceFromDefaults()
            .defaultAppStorage(defaults)), size: CGSize(width: 10, height: 10))
        _ = rig.capture()
        let read = try #require(seen, "the probe view never appeared")
        #expect(read == SelectionLensAppearance.stored(in: defaults))
        #expect(read.drawsProbe == false, "the app's appearance must never draw the test probe")
    }

    // MARK: - A host draws its lens on its stops

    private static let channel = SelectionLensChannel("test.harness")
    /// Today's marker in the harness: pure green, so it is told apart from the probe at a glance.
    private static let todayGreen = Color(red: 0, green: 1, blue: 0)
    private static let isTodayGreen: Pixel.Match = { r, g, b in g > 229 && r < 26 && b < 26 }
    /// The harness's ring and rule: pure blue.
    private static let ringBlue = Color(red: 0, green: 0, blue: 1)
    private static let isRingBlue: Pixel.Match = { r, g, b in b > 229 && r < 26 && g < 60 }
    private static let size = CGSize(width: 160, height: 40)
    private static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)

    struct Harness: View {
        var selected: Int?
        var appearance: SelectionLensAppearance
        var style: SelectionLensStyle = .fill(.capsule, color: .blue)
        var reduceMotion = false
        var reduceTransparency = false
        var contrast: ColorSchemeContrast = .standard
        var region: SelectionLensVisibleRegion?

        var body: some View {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    Color.clear
                        .frame(width: 40, height: 20)
                        .background {
                            if selected == i {
                                SelectionLensTodayMarker { Capsule().fill(SelectionLensTests.todayGreen) }
                            }
                        }
                        .selectionLensStop(SelectionLensTests.channel, id: i)
                }
            }
            .selectionLensHost(SelectionLensTests.channel, selected: selected, style: style, visibleRegion: region)
            .padding(10)
            .frame(width: 160, height: 40, alignment: .topLeading)
            .background(Color.white)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.controlActiveState, .active)
            // Pinned, so the machine's own settings cannot decide these tests.
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .environment(\._accessibilityReduceTransparency, reduceTransparency)
            .environment(\._colorSchemeContrast, contrast)
        }
    }

    /// Segment `i`'s frame in the harness: 10pt padding, 40pt segments, 10pt gaps.
    private func segment(_ i: Int) -> CGRect {
        CGRect(x: 10 + CGFloat(i) * 50, y: 10, width: 40, height: 20)
    }

    private func expectNear(_ a: CGRect?, _ b: CGRect, tolerance: CGFloat = 1.01,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Pixel.same(a, b, tolerance: tolerance), "\(String(describing: a)) is not \(b)",
                sourceLocation: sourceLocation)
    }

    @Test(.machinePinned(.pixelSampling))
    func solidDrawsTheControlsOwnMarkerAndNoLens() {
        let rig = ProbeRig(Harness(selected: 1, appearance: .today), size: Self.size)
        expectNear(rig.box(Self.isTodayGreen), segment(1))
        #expect(rig.box(Pixel.lensProbe) == nil)
    }

    // One level, not both: the probe stands in for Frosted and Clear alike (`material(for:)`), so a
    // Clear arm ran the same code again. The rim — Clear's difference — is read at real Clear below.
    @Test(.machinePinned(.pixelSampling))
    func theGlassDrawsTheLensOnTheSelectedStopAndHidesTheOldMarker() {
        let rig = ProbeRig(Harness(selected: 2, appearance: Self.probe), size: Self.size)
        expectNear(rig.box(Pixel.lensProbe), segment(2))
        #expect(rig.box(Self.isTodayGreen) == nil, "today's marker must not draw under a lens")
    }

    @Test(.machinePinned(.pixelSampling))
    func reduceTransparencyDrawsTodaysMarkerThroughTheWholeHost() {
        // The rule is pinned above; this pins that the HOST reads the setting.
        let rig = ProbeRig(Harness(selected: 1, appearance: Self.probe, reduceTransparency: true), size: Self.size)
        #expect(rig.box(Pixel.lensProbe) == nil, "a lens drew under Reduce Transparency")
        expectNear(rig.box(Self.isTodayGreen), segment(1))
    }

    @Test(.machinePinned(.pixelSampling))
    func realGlassHidesTheOldMarkerToo() {
        // Glass itself is invisible offscreen; what CAN be seen is that the control's own marker
        // stepped aside for it.
        let rig = ProbeRig(Harness(selected: 0, appearance: SelectionLensAppearance(
            level: .frosted, hue: .blue, tint: 1)), size: Self.size)
        #expect(rig.box(Self.isTodayGreen) == nil)
    }

    @Test(.machinePinned(.pixelSampling))
    func nothingSelectedDrawsNothing() {
        let rig = ProbeRig(Harness(selected: nil, appearance: SelectionLensAppearance(
            level: .clear, hue: .blue, tint: 0, drawsProbe: true)), size: Self.size)
        #expect(rig.box(Pixel.lensProbe) == nil)
    }

    // MARK: The lens's strokes

    @Test(.machinePinned(.pixelSampling))
    func theProbeDrawsTheRingAndTheRuleOnTheLens() {
        // Ring and rule are drawn outside the glass container, so the probe shows them: a ring
        // style's lens is ringed, a rule style's has its rule along the bottom.
        let ringed = ProbeRig(Harness(selected: 1, appearance: Self.probe, style: SelectionLensStyle(
            shape: .capsule, color: .blue, markerOpacity: 0.2, ring: .init(color: Self.ringBlue, width: 2))),
                              size: Self.size)
        expectNear(ringed.box(Self.isRingBlue), segment(1))
        let ruled = ProbeRig(Harness(selected: 1, appearance: Self.probe, style: SelectionLensStyle(
            shape: .roundedRect(4), color: .blue, markerOpacity: 0.2,
            rule: .init(color: Self.ringBlue, height: 2, inset: 6))), size: Self.size)
        let rule = ruled.box(Self.isRingBlue)
        #expect(rule.map { abs($0.maxY - segment(1).maxY) <= 1.01 && $0.height <= 3
                           && abs($0.minX - (segment(1).minX + 6)) <= 1.01 } == true,
                "the rule is \(String(describing: rule)), not a 2pt bar along the lens's bottom")
    }

    @Test(.machinePinned(.pixelSampling), arguments: [ColorSchemeContrast.standard, .increased])
    func clearGlassHasARimAndIncreaseContrastThickensIt(contrast: ColorSchemeContrast) {
        // At real Clear the glass draws nothing offscreen, but its rim — a stroke outside the glass
        // container — does: in the marker's colour, around the stop.
        let rig = ProbeRig(Harness(selected: 1, appearance: SelectionLensAppearance(level: .clear, hue: .blue, tint: 0),
                                   style: .fill(.capsule, color: Self.ringBlue), contrast: contrast),
                           size: Self.size)
        let rim = rig.box(Self.isRingBlue)
        expectNear(rim, segment(1))
        // How thick: the run of rim pixels straight down from the stop's top edge, at its middle.
        let rep = rig.capture()
        var thickness: CGFloat = 0
        var y = segment(1).minY
        while y < segment(1).midY {
            let px = Pixel.at(rep, width: Self.size.width, CGPoint(x: segment(1).midX, y: y + 0.25))
            if Self.isRingBlue(px.0, px.1, px.2) { thickness += 0.5 }
            y += 0.5
        }
        let want = SelectionLensRule.rimWidth(material: .clear, hasRing: false, increasedContrast: contrast == .increased)
        #expect(abs(thickness - want) <= 0.6, "rim \(thickness)pt, want \(want)pt")
    }

    // MARK: The layer's motion

    @Test(.machinePinned(.pixelSampling))
    func aChangeStartsFromTheOldStopRatherThanArrivingAtOnce() {
        // The first frame after a change is the start of a move: still at the old stop. Deterministic
        // — elapsed is near zero — and it is what an always-instant layer would fail.
        let rig = ProbeRig(Harness(selected: 0, appearance: Self.probe), size: Self.size)
        expectNear(rig.box(Pixel.lensProbe), segment(0))
        rig.host.rootView = Harness(selected: 2, appearance: Self.probe)
        let first = rig.box(Pixel.lensProbe)
        #expect(first.map { $0.minX < segment(1).minX } == true,
                "the first frame after the change is \(String(describing: first)) — the lens arrived without moving")
    }

    @Test(.machinePinned(.pixelSampling))
    func reduceMotionArrivesAtOnce() {
        let rig = ProbeRig(Harness(selected: 0, appearance: Self.probe, reduceMotion: true), size: Self.size)
        rig.host.rootView = Harness(selected: 2, appearance: Self.probe, reduceMotion: true)
        expectNear(rig.box(Pixel.lensProbe), segment(2))
    }

    @Test(.machinePinned(.pixelSampling))
    func aMoveToAStopOffScreenArrivesAtOnce() {
        // Segment 2 lies outside the visible region, so the move switches instead of travelling.
        // In the host's own coordinates — inside the padding — it starts at x = 100, so the region
        // ends 10pt short of it rather than on its edge, where `intersects` would decide the test.
        let region = SelectionLensVisibleRegion()
        region.rect = CGRect(x: 0, y: 0, width: 90, height: 40)
        let rig = ProbeRig(Harness(selected: 0, appearance: Self.probe, region: region), size: Self.size)
        rig.host.rootView = Harness(selected: 2, appearance: Self.probe, region: region)
        expectNear(rig.box(Pixel.lensProbe), segment(2))
    }

    /// **A scroll view reports what it shows, and a move off it switches.** The region above is
    /// handed in; here a real scroll view writes it (`selectionLensTracksVisibleRegion`), 100pt
    /// wide over stops that run to 150, with the host on its padded content as every call site has
    /// it. A move to the stop past its edge lands at once — out of sight; a move to one on screen
    /// travels — its first frame still at the old stop.
    struct ScrollHarness: View {
        var selected: Int
        let region: SelectionLensVisibleRegion

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        Color.clear.frame(width: 40, height: 20)
                            .selectionLensStop(SelectionLensTests.channel, id: i)
                    }
                }
                .padding(10)
                .selectionLensHost(SelectionLensTests.channel, selected: selected,
                                   style: .fill(.capsule, color: .blue), visibleRegion: region)
            }
            .scrollIndicators(.never)
            .selectionLensTracksVisibleRegion(region)
            .frame(width: 100, height: 40)
            .background(Color.white)
            .environment(\.selectionLensAppearance, SelectionLensTests.probe)
            .environment(\._accessibilityReduceMotion, false)
            .environment(\._accessibilityReduceTransparency, false)
        }
    }

    @Test(.machinePinned(.pixelSampling))
    func aScrollViewTellsTheHostWhatItShows() async throws {
        let region = SelectionLensVisibleRegion()
        let size = CGSize(width: 100, height: 40)
        let rig = ProbeRig(ScrollHarness(selected: 0, region: region), size: size)
        // The scroll view reports its geometry as it lays out; give it the turns to.
        _ = await LayoutPumpWait.pump(rig.host, upTo: 2) { region.rect != nil }
        let seen = try #require(region.rect, "the scroll view never reported what it shows")
        #expect(abs(seen.width - 100) <= 1, "the reported region is \(seen)")
        // Off screen: the lens leaves at once, so nothing of it is left at the old stop.
        rig.host.rootView = ScrollHarness(selected: 2, region: region)
        #expect(rig.box(Pixel.lensProbe) == nil, "a move to a stop out of view travelled")
        // On screen: it travels, so the first frame is still by the old stop.
        let back = ProbeRig(ScrollHarness(selected: 0, region: region), size: size)
        back.host.rootView = ScrollHarness(selected: 1, region: region)
        let first = back.box(Pixel.lensProbe)
        #expect(first.map { $0.minX < 30 } == true, "a move on screen arrived without travelling: \(String(describing: first))")
    }

    /// A host whose stops change in the same update as its selection — what a tab strip does.
    /// `onlyChosen`: one stop, in slot 0, under the chosen id (the chip rung). `window`: the ids
    /// shown start at `window`, so moving it moves every stop one slot (a compact rung re-windowed).
    /// `dimmed`: ids whose rows are drawn dimmed, as a sidebar's unavailable places are.
    struct ShiftingHarness: View {
        var selected: Int
        var onlyChosen = false
        var window = 0
        var dimmed: Set<Int> = []

        var body: some View {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { slot in
                    let id = onlyChosen ? (slot == 0 ? selected : nil) : window + slot
                    Color.clear.frame(width: 40, height: 20)
                        .selectionLensStop(SelectionLensTests.channel, id: id ?? -1 - slot)
                }
            }
            .selectionLensHost(SelectionLensTests.channel, selected: selected,
                               style: SelectionLensStyle(shape: .capsule, color: .blue, markerOpacity: 1,
                                                         opacity: dimmed.contains(selected) ? 0.45 : 1))
            .padding(10)
            .frame(width: 160, height: 40, alignment: .topLeading)
            .background(Color.white)
            .environment(\.selectionLensAppearance, SelectionLensTests.probe)
            .environment(\._accessibilityReduceMotion, false)
            .environment(\._accessibilityReduceTransparency, false)
        }
    }

    @Test(.machinePinned(.pixelSampling))
    func aLensWhoseOnlyStopChangesHandsStaysPut() {
        // The chip rung: choosing another tab re-labels the one stop. The lens was drawn there and
        // is wanted there; the first version found no rect for the old id, called it a growth, and
        // blinked out to regrow from 40% on the same chip.
        let rig = ProbeRig(ShiftingHarness(selected: 0, onlyChosen: true), size: Self.size)
        expectNear(rig.box(Pixel.lensProbe), segment(0))
        rig.host.rootView = ShiftingHarness(selected: 7, onlyChosen: true)
        expectNear(rig.box(Pixel.lensProbe), segment(0))
    }

    @Test(.machinePinned(.pixelSampling))
    func aMoveStartsWhereTheLensWasDrawnNotWhereTheOldStopWent() {
        // A compact rung re-windowed by the change: the active tab stays in slot 2 while its old id
        // slides to slot 1. Started from the old stop, the lens dipped a slot left and came back.
        let rig = ProbeRig(ShiftingHarness(selected: 2, window: 0), size: Self.size)
        expectNear(rig.box(Pixel.lensProbe), segment(2))
        rig.host.rootView = ShiftingHarness(selected: 3, window: 1)
        expectNear(rig.box(Pixel.lensProbe), segment(2))
    }

    @Test(.machinePinned(.pixelSampling))
    func aDimmedRowsLensStaysDimmedAsItLeaves() async throws {
        // 0.45 of the probe over white is (255, 140, 255); full strength is (255, 0, 255). Read at the
        // lens's middle: on the first frame of a move from a dimmed row it is still the dimmed row's.
        let rig = ProbeRig(ShiftingHarness(selected: 0, dimmed: [0]), size: Self.size)
        func green(_ at: CGRect) -> Int { Int(Pixel.at(rig.capture(), width: Self.size.width,
                                                        CGPoint(x: at.midX, y: at.midY)).1) }
        #expect(abs(green(segment(0)) - 140) <= 15, "the dimmed row's lens is not dimmed")
        rig.host.rootView = ShiftingHarness(selected: 2, dimmed: [0])
        #expect(abs(green(segment(0)) - 140) <= 15, "the lens brightened before it left the dimmed row")
        let wait = await LayoutPumpWait.pump(rig.host, upTo: 15) { green(segment(2)) < 10 }
        #expect(wait.held, "the lens never came to full strength on the bright row")
    }

    @Test(.machinePinned(.pixelSampling))
    func aSecondClickMidMoveCarriesOnFromWhereTheLensIs() {
        // 0 → 2, and before it has gone anywhere, 2 → 1: the second move starts where the lens is —
        // by segment 0 — not at segment 2, where the first was heading.
        let rig = ProbeRig(Harness(selected: 0, appearance: Self.probe), size: Self.size)
        rig.host.rootView = Harness(selected: 2, appearance: Self.probe)
        _ = rig.capture()
        rig.host.rootView = Harness(selected: 1, appearance: Self.probe)
        let first = rig.box(Pixel.lensProbe)
        #expect(first.map { $0.minX < segment(1).minX } == true,
                "the second move started at \(String(describing: first)), not where the lens was")
    }

    @Test(.machinePinned(.pixelSampling))
    func aNewSelectionEndsWithTheLensOnTheNewStop() async {
        let rig = ProbeRig(Harness(selected: 0, appearance: Self.probe), size: Self.size)
        rig.host.rootView = Harness(selected: 2, appearance: Self.probe)
        // Counted in turns, not slept for — see `LayoutPumpWait`.
        let wait = await LayoutPumpWait.pump(rig.host, upTo: 15) {
            Pixel.same(rig.box(Pixel.lensProbe), segment(2))
        }
        #expect(wait.held, "the lens never settled on the new stop after \(wait.pumps) passes")
    }

    @Test(.machinePinned(.pixelSampling))
    func clearingTheSelectionMeltsTheLensAway() async {
        let rig = ProbeRig(Harness(selected: 1, appearance: Self.probe), size: Self.size)
        expectNear(rig.box(Pixel.lensProbe), segment(1))
        rig.host.rootView = Harness(selected: nil, appearance: Self.probe)
        // Melting, not removed: on the first frame it is still there.
        #expect(rig.box(Pixel.lensProbe) != nil, "the lens vanished at once rather than melting")
        let wait = await LayoutPumpWait.pump(rig.host, upTo: 15) { rig.box(Pixel.lensProbe) == nil }
        #expect(wait.held, "the lens was still drawn after \(wait.pumps) passes")
    }

    // MARK: - A choice's ground

    @Test(.machinePinned(.pixelSampling))
    func aSelectedGroundIsTheLensUnderGlassAndTodaysFillAtSolid() {
        func view(_ appearance: SelectionLensAppearance) -> some View {
            SelectionLensGround(Capsule(), isSelected: true, selected: Self.ringBlue, unselected: Color.gray)
                .frame(width: 40, height: 20)
                .selectionLensHost(Self.channel, selected: Optional<Int>.none, style: .fill(.capsule, color: .blue))
                .padding(10)
                .frame(width: 160, height: 40, alignment: .topLeading)
                .background(Color.white)
                .environment(\.selectionLensAppearance, appearance)
        }
        #expect(ProbeRig(view(.today), size: Self.size).box(Self.isRingBlue) != nil, "Solid lost the selected fill")
        #expect(ProbeRig(view(Self.probe), size: Self.size).box(Self.isRingBlue) == nil,
                "the selected fill drew under a lens")
    }

    // MARK: - A choice's label

    /// Three choices whose "labels" are 20 × 8 bars in the label's ink — a flat shape rather than
    /// text, so the ink is read exactly instead of off anti-aliased glyphs. White on the fill, red
    /// for the rest, so each render says which ink each bar took.
    struct LabelHarness: View {
        var selected: Int
        var appearance: SelectionLensAppearance
        var scheme: ColorScheme = .light
        var reduceTransparency = false
        var onGlass: Color?

        var body: some View {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    label(isSelected: selected == i)
                        .frame(width: 40, height: 20)
                        .background {
                            if selected == i {
                                SelectionLensTodayMarker { Capsule().fill(SelectionLensTests.todayGreen) }
                            }
                        }
                        .selectionLensStop(SelectionLensTests.channel, id: i)
                }
            }
            .selectionLensHost(SelectionLensTests.channel, selected: selected, style: .fill(.capsule, color: .blue))
            .padding(10)
            .frame(width: 160, height: 40, alignment: .topLeading)
            .background(scheme == .light ? Color.white : Color.black)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.colorScheme, scheme)
            .environment(\._accessibilityReduceTransparency, reduceTransparency)
        }

        @ViewBuilder
        private func label(isSelected: Bool) -> some View {
            let bar = Rectangle().frame(width: 20, height: 8)
            if let onGlass {
                bar.selectionLensLabelInk(isSelected: isSelected, onFill: Color.white, onGlass: onGlass,
                                          unselected: Color(red: 1, green: 0, blue: 0))
            } else {
                bar.selectionLensLabelInk(isSelected: isSelected, onFill: Color.white,
                                          unselected: Color(red: 1, green: 0, blue: 0))
            }
        }
    }

    /// The ink of segment `i`'s bar, read at its centre.
    private func ink(_ view: LabelHarness, _ i: Int) -> (UInt8, UInt8, UInt8) {
        let rep = ProbeRig(view, size: Self.size).capture()
        let c = segment(i)
        return Pixel.at(rep, width: Self.size.width, CGPoint(x: c.midX, y: c.midY))
    }

    private static func isRed(_ c: (UInt8, UInt8, UInt8)) -> Bool { c.0 > 240 && c.1 < 20 && c.2 < 20 }

    @Test(.machinePinned(.pixelSampling))
    func atSolidTheChosenLabelIsTheFillsInk() {
        let view = LabelHarness(selected: 1, appearance: .today)
        let chosen = ink(view, 1)
        #expect(chosen.0 > 245 && chosen.1 > 245 && chosen.2 > 245, "Solid's chosen label is \(chosen), not white")
        #expect(Self.isRed(ink(view, 0)) && Self.isRed(ink(view, 2)), "the rest are not their own ink")
    }

    /// **On a glass lens in light mode the chosen label is `.primary`, black.** White on a lens at
    /// Tint 0 was all but invisible: there is no fill behind it any more, only pale glass.
    @Test(.machinePinned(.pixelSampling))
    func onGlassTheChosenLabelIsPrimary() {
        let view = LabelHarness(selected: 1, appearance: Self.probe)
        let chosen = ink(view, 1)
        #expect(chosen.0 < 60 && chosen.1 < 60 && chosen.2 < 60, "the chosen label on glass is \(chosen), not black")
        #expect(Self.isRed(ink(view, 0)) && Self.isRed(ink(view, 2)), "the rest are not their own ink")
    }

    /// **In dark mode the chosen label keeps the fill's white** — the user's call. Dark glass carries
    /// white well, and `.primary` would not be it: it is white at 85%, which over the probe reads
    /// `(255, 217, 255)`, so this asks for the fill's ink exactly.
    @Test(.machinePinned(.pixelSampling))
    func inDarkTheChosenLabelOnGlassKeepsTheFillsWhite() {
        let chosen = ink(LabelHarness(selected: 0, appearance: Self.probe, scheme: .dark), 0)
        #expect(chosen.0 > 245 && chosen.1 > 245 && chosen.2 > 245, "the chosen label on dark glass is \(chosen), not white")
    }

    @Test(.machinePinned(.pixelSampling))
    func underReduceTransparencyTheChosenLabelKeepsTheFillsInk() {
        // No lens is drawn, so the control's own fill is back, and the ink that goes with it.
        let chosen = ink(LabelHarness(selected: 2, appearance: Self.probe, reduceTransparency: true), 2)
        #expect(chosen.0 > 245 && chosen.1 > 245 && chosen.2 > 245, "the chosen label is \(chosen), not white")
    }

    @Test(.machinePinned(.pixelSampling))
    func aLabelsQuieterHalfTakesTheGlassInkItIsGiven() {
        let chosen = ink(LabelHarness(selected: 1, appearance: Self.probe, onGlass: Color(red: 0, green: 0, blue: 1)), 1)
        #expect(chosen.2 > 240 && chosen.0 < 20 && chosen.1 < 20, "the glass ink given was not used: \(chosen)")
    }
}
