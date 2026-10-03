import Testing
import AppKit
import SwiftUI
@testable import Design

/// Chrome glass (RD46 follow-up): in Frosted and Clear a bar button sits in a glass capsule, and
/// Back/Forward share one; Solid draws the button's own ground exactly as before.
///
/// Rendered with the probe — glass draws nothing into an offscreen capture, so under `drawsProbe`
/// its place is painted cyan (`ChromeGlass.probeColor`) — against a pure-green "today's ground"
/// the harness's buttons draw at rest, so each render says plainly which of the two is showing.
@MainActor
@Suite(.serialized) struct ChromeGlassTests {

    static let canvas = CGSize(width: 200, height: 40)
    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)
    static let solidProbe = SelectionLensAppearance(level: .solid, hue: .blue, tint: 0, drawsProbe: true)
    static let isTodayGreen: Pixel.Match = { r, g, b in g > 229 && r < 26 && b < 26 }

    /// A bar button as a call site writes one: today's resting pill, wrapped; glass outside it.
    struct BarButton: View {
        var outset: CGFloat = 0
        var body: some View {
            Color.clear
                .frame(width: 33, height: 20)
                .background { ChromeGlassTodayGround { Capsule().fill(Color(red: 0, green: 1, blue: 0)) } }
                .chromeGlassGround(.capsule, outset: outset)
        }
    }

    /// `view` on the canvas, pinned to the light scheme and to the accessibility settings given, so
    /// the machine's own cannot decide a verdict.
    static func rig<V: View>(_ view: V, _ appearance: SelectionLensAppearance, reduceTransparency: Bool = false,
                             contrast: ColorSchemeContrast = .standard) -> ProbeRig<AnyView> {
        ProbeRig(AnyView(view
            .padding(10)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.colorScheme, .light)
            .environment(\._accessibilityReduceTransparency, reduceTransparency)
            .environment(\._colorSchemeContrast, contrast)), size: canvas)
    }

    @Test(.machinePinned(.pixelSampling))
    func solidDrawsTodaysGroundAndNoGlass() {
        let rig = Self.rig(BarButton(), Self.solidProbe)
        #expect(rig.box(Pixel.chromeProbe) == nil, "Solid drew glass")
        let ground = rig.box(Self.isTodayGreen)
        #expect(ground?.width == 33 && ground?.height == 20, "Solid's own pill is \(String(describing: ground))")
    }

    @Test(.machinePinned(.pixelSampling))
    func glassStandsExactlyWhereTodaysGroundWas() {
        let solid = Self.rig(BarButton(), Self.solidProbe).box(Self.isTodayGreen)
        let rig = Self.rig(BarButton(), Self.probe)
        #expect(rig.box(Self.isTodayGreen) == nil, "today's ground must step aside under glass")
        #expect(rig.box(Pixel.chromeProbe) == solid, "the glass is not where the pill was")
    }

    @Test(.machinePinned(.pixelSampling))
    func reduceTransparencyKeepsTodaysGround() {
        // The rule is pinned below; this pins that the ground READS the setting.
        let rig = Self.rig(BarButton(), Self.probe, reduceTransparency: true)
        #expect(rig.box(Pixel.chromeProbe) == nil, "glass drew under Reduce Transparency")
        #expect(rig.box(Self.isTodayGreen) != nil, "today's ground went missing under Reduce Transparency")
    }

    @Test(.machinePinned(.pixelSampling))
    func aGroupIsOneCapsuleAndItsMembersDrawNone() {
        // The members carry an outset BIGGER than the group's, so a member that drew its own glass
        // would make the glass taller than the group's 20pt — told apart by size, not colour.
        let pair = HStack(spacing: 4) { BarButton(outset: 6); BarButton(outset: 6) }.chromeGlassGroup()
        let rig = Self.rig(pair, Self.probe)
        let capsule = rig.box(Pixel.chromeProbe)
        #expect(capsule.map { abs($0.width - 70) <= 1 && abs($0.height - 20) <= 1 } == true,
                "the glass is \(String(describing: capsule)) — not the group's one 70 × 20 capsule")
        // One capsule, not two: the 4pt gap between the buttons is glass too.
        let rep = rig.capture()
        let gap = Pixel.at(rep, width: Self.canvas.width, CGPoint(x: 10 + 33 + 2, y: 20))
        #expect(Pixel.chromeProbe(gap.0, gap.1, gap.2), "the gap between Back and Forward is not glass")
        #expect(rig.box(Self.isTodayGreen) == nil, "the members' own grounds must step aside too")
        // And at Solid the members draw their own two pills, untouched.
        let solid = Self.rig(pair, Self.solidProbe)
        #expect(solid.box(Pixel.chromeProbe) == nil)
        #expect(solid.box(Self.isTodayGreen)?.width == 70)
    }

    @Test func reduceTransparencyAndSolidKeepTodaysGround() {
        #expect(ChromeGlass.material(appearance: .today, reduceTransparency: false) == .today)
        #expect(ChromeGlass.material(appearance: SelectionLensAppearance(level: .clear, hue: .rose, tint: 0),
                                     reduceTransparency: true) == .today)
        #expect(ChromeGlass.material(appearance: SelectionLensAppearance(level: .clear, hue: .rose, tint: 0),
                                     reduceTransparency: false) == .clear)
    }

    @Test func aButtonsTintIsTheTintSlidersAlone() {
        #expect(ChromeGlass.tintOpacity(hue: .none, tint: 1) == 0)
        #expect(ChromeGlass.tintOpacity(markerOpacity: 0.18, hue: .rose, tint: 1) == 0.18)
        #expect(ChromeGlass.tintOpacity(hue: .rose, tint: 1) == 1)
        #expect(ChromeGlass.tintOpacity(hue: .rose, tint: 0) == ChromeGlass.tintOpacity(hue: .blue, tint: 0))
        #expect(ChromeGlass.tintOpacity(hue: .rose, tint: 0) > 0)
    }

    @Test func theChromeProbeIsNotTheLensProbe() {
        // The two seams are read apart in the same render — a bar's glass and the lens on it.
        #expect(ChromeGlass.probeColor != SelectionLensRule.probeColor)
    }

    // MARK: - Clear's rim

    @Test func onlyClearHasARimAndIncreaseContrastStrengthensIt() {
        #expect(ChromeGlass.rim(material: .frosted, increasedContrast: true).width == 0)
        #expect(ChromeGlass.rim(material: .today, increasedContrast: true).width == 0)
        let plain = ChromeGlass.rim(material: .clear, increasedContrast: false)
        let strong = ChromeGlass.rim(material: .clear, increasedContrast: true)
        #expect(plain.width > 0 && strong.width > plain.width && strong.opacity > plain.opacity)
    }

    @Test(.machinePinned(.pixelSampling))
    func clearDrawsItsRimAroundTheButton() {
        // At real Clear the glass draws nothing offscreen; its rim, a stroke over it, does — a grey
        // hairline round the button where Frosted draws none.
        let isRim: Pixel.Match = { r, g, b in r < 236 && r > 120 && abs(Int(r) - Int(g)) < 8 && abs(Int(g) - Int(b)) < 8 }
        let clear = Self.rig(BarButton(), SelectionLensAppearance(level: .clear, hue: .blue, tint: 0))
        let rim = clear.box(isRim)
        #expect(rim.map { abs($0.width - 33) <= 1.01 && abs($0.height - 20) <= 1.01 } == true,
                "Clear's rim is \(String(describing: rim)), not round the 33 × 20 button")
        #expect(Self.rig(BarButton(), SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0)).box(isRim) == nil,
                "Frosted drew a rim")
        // Increase Contrast's is darker.
        let darker: Pixel.Match = { r, g, b in r < 175 && abs(Int(r) - Int(g)) < 8 }
        #expect(clear.count(darker) < Self.rig(BarButton(), SelectionLensAppearance(level: .clear, hue: .blue, tint: 0),
                                               contrast: .increased).count(darker))
    }

    // MARK: - The shared bar buttons

    @Test(.machinePinned(.pixelSampling))
    func theCloseButtonIsAGlassCircle() {
        #expect(Self.rig(CloseButton {}, Self.solidProbe).box(Pixel.chromeProbe) == nil)
        let glass = Self.rig(CloseButton {}, Self.probe).box(Pixel.chromeProbe)
        #expect(glass.map { abs($0.width - 26) <= 1 && abs($0.height - 26) <= 1 } == true,
                "the close button's glass is \(String(describing: glass)), not its 26pt circle")
    }

    @Test(.machinePinned(.pixelSampling))
    func aCloseButtonThatIsNotABarButtonWearsNoGlass() {
        // The operation banner's ×: not a bar button, and its Undo neighbour wears none.
        #expect(Self.rig(CloseButton(chromeGlass: false) {}, Self.probe).box(Pixel.chromeProbe) == nil)
    }

    @Test(.machinePinned(.pixelSampling))
    func theSearchMagnifierIsAGlassCircle() {
        let toggle = ExpandingSearchToggle(text: .constant(""), isExpanded: .constant(false),
                                           accent: .blue, help: "Search")
        #expect(Self.rig(toggle, Self.solidProbe).box(Pixel.chromeProbe) == nil)
        let glass = Self.rig(toggle, Self.probe).box(Pixel.chromeProbe)
        #expect(glass.map { $0.width >= 20 && abs($0.width - $0.height) <= 1 } == true,
                "the magnifier's glass is \(String(describing: glass))")
    }

    @Test(.machinePinned(.pixelSampling))
    func theTextSizeStepperIsOneCapsule() {
        let stepper = TextSizeStepper(size: .constant(.medium), tint: .blue)
        #expect(Self.rig(stepper, Self.solidProbe).box(Pixel.chromeProbe) == nil)
        let glass = Self.rig(stepper, Self.probe).box(Pixel.chromeProbe)
        // Both buttons, the A between them, and 3pt past them on every side — one capsule.
        #expect(glass.map { $0.width > 60 && abs($0.height - 26) <= 1 } == true,
                "the stepper's glass is \(String(describing: glass)) — not one capsule round all three")
    }

    @Test(.machinePinned(.pixelSampling))
    func aBorderedHeaderButtonTakesSystemGlassAndBack() {
        // The real branches, not the probe's: at Solid `.bordered` paints its light bezel; at real
        // Frosted the button is the system's glass style, which — like all glass — paints nothing
        // into an offscreen capture, so the bezel's pixels are gone. Only the glyph is left.
        let button = Button {} label: { Image(systemName: "trash") }
            .chromeGlassBorderedButtonStyle()
            .controlSize(.small)
        let isBezel: Pixel.Match = { r, g, b in r > 200 && r < 250 && abs(Int(r) - Int(g)) < 6 && abs(Int(g) - Int(b)) < 6 }
        let solid = Self.rig(button, .today).count(isBezel)
        let frosted = Self.rig(button, SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0)).count(isBezel)
        #expect(solid > 200, "Solid drew no bezel — the fixture is not showing `.bordered`")
        #expect(frosted * 4 < solid, "Frosted still drew a bordered bezel (\(frosted) vs \(solid) pixels)")
        // Under the probe the button keeps `.bordered` over a cyan capsule.
        #expect(Self.rig(button, Self.probe).box(Pixel.chromeProbe) != nil)
    }

    @Test(.machinePinned(.pixelSampling))
    func aSegmentedTrackIsGlass() {
        let track = HStack { Text("Tree"); Text("Columns") }.padding(2).chromeGlassTrack()
        #expect(Self.rig(track, Self.solidProbe).box(Pixel.chromeProbe) == nil)
        #expect(Self.rig(track, Self.probe).box(Pixel.chromeProbe) != nil)
    }
}
