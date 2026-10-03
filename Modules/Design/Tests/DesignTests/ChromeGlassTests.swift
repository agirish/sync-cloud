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
        /// Grows the glass up and down only.
        var verticalOnly = false
        var rim = true
        var glass = true
        var body: some View {
            let button = Color.clear
                .frame(width: 33, height: 20)
                .background { ChromeGlassTodayGround { Capsule().fill(Color(red: 0, green: 1, blue: 0)) } }
            if verticalOnly {
                button.chromeGlassGround(.capsule, horizontalOutset: 0, verticalOutset: outset, rim: rim, when: glass)
            } else {
                button.chromeGlassGround(.capsule, outset: outset, rim: rim, when: glass)
            }
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
    func glassStandsExactlyWhereTodaysGroundWas() throws {
        let solid = try #require(Self.rig(BarButton(), Self.solidProbe).box(Self.isTodayGreen), "Solid drew no pill")
        let rig = Self.rig(BarButton(), Self.probe)
        #expect(rig.box(Self.isTodayGreen) == nil, "today's ground must step aside under glass")
        let glass = rig.box(Pixel.chromeProbe)
        #expect(Pixel.same(glass, solid), "the glass \(String(describing: glass)) is not where the pill \(solid) was")
    }

    @Test(.machinePinned(.pixelSampling))
    func anOutsetCanGrowOneAxisOnly() {
        // The tab strip's overflow menu: as tall as the ＋ beside it, no wider than itself.
        let glass = Self.rig(BarButton(outset: 3, verticalOnly: true), Self.probe).box(Pixel.chromeProbe)
        #expect(glass.map { abs($0.width - 33) <= 1.01 && abs($0.height - 26) <= 1.01 } == true,
                "the glass is \(String(describing: glass)), not 33 × 26")
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

    @Test(.machinePinned(.pixelSampling))
    func aMemberWithGlassTurnedOffStaysOnTheGroupsGlass() {
        // `when: false` turns a button's OWN glass off; inside a group the group's capsule is still
        // its ground. Its Solid pill coming back would sit on top of the group's glass.
        let pair = HStack(spacing: 4) { BarButton(glass: false); BarButton() }.chromeGlassGroup()
        let rig = Self.rig(pair, Self.probe)
        #expect(rig.box(Self.isTodayGreen) == nil, "a member put its Solid ground back over the group's glass")
        #expect(rig.box(Pixel.chromeProbe).map { abs($0.width - 70) <= 1 } == true)
    }

    @Test(.machinePinned(.pixelSampling))
    func aGroupInsideAGroupDrawsNoCapsuleOfItsOwn() {
        // The inner group grows 6pt past its member; drawn, it would make the glass 32pt tall.
        let nested = HStack(spacing: 4) {
            HStack { BarButton() }.chromeGlassGroup(outset: 6)
            BarButton()
        }.chromeGlassGroup()
        let glass = Self.rig(nested, Self.probe).box(Pixel.chromeProbe)
        #expect(glass.map { abs($0.width - 70) <= 1 && abs($0.height - 20) <= 1 } == true,
                "the glass is \(String(describing: glass)) — not the outer group's one 70 × 20 capsule")
    }

    @Test(.machinePinned(.pixelSampling))
    func aGroupUnderReduceTransparencyKeepsItsMembersOwnGrounds() {
        let pair = HStack(spacing: 4) { BarButton(); BarButton() }.chromeGlassGroup()
        let rig = Self.rig(pair, Self.probe, reduceTransparency: true)
        #expect(rig.box(Pixel.chromeProbe) == nil, "a group drew glass under Reduce Transparency")
        #expect(rig.box(Self.isTodayGreen)?.width == 70, "the members' own pills went missing")
    }

    @Test func reduceTransparencyAndSolidKeepTodaysGround() {
        #expect(ChromeGlass.material(appearance: .today, reduceTransparency: false) == .today)
        #expect(ChromeGlass.material(appearance: SelectionLensAppearance(level: .clear, hue: .rose, tint: 0),
                                     reduceTransparency: true) == .today)
        #expect(ChromeGlass.material(appearance: SelectionLensAppearance(level: .clear, hue: .rose, tint: 0),
                                     reduceTransparency: false) == .clear)
    }

    @Test func onGlassAHoveredLabelStaysSeated() {
        // The glass does not move, so a label on it does not lift or cast a shadow onto it; its
        // wash, ring and press scale are untouched.
        let lifted = HoverAffordanceMetrics.resolve(variant: .filled, phase: .hover)
        #expect(lifted.lift != 0 && lifted.shadow > 0, "the fixture is meant to lift")
        let seated = lifted.seated(true)
        #expect(seated.lift == 0 && seated.shadow == 0)
        #expect(seated.ring == lifted.ring && seated.wash == lifted.wash && seated.scale == lifted.scale)
        #expect(lifted.seated(false) == lifted)
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
        // A button with an edge of its own takes none, as a lens with a ring takes none.
        #expect(ChromeGlass.rim(material: .clear, increasedContrast: true, ownEdge: true).width == 0)
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
        // And a button that draws its own edge — the breadcrumb's brand hairline — gets none.
        #expect(Self.rig(BarButton(rim: false), SelectionLensAppearance(level: .clear, hue: .blue, tint: 0)).box(isRim) == nil,
                "Clear drew its rim under a button's own edge")
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
    func aSegmentedTrackIsGlass() throws {
        let track = Color.clear.frame(width: 80, height: 20).chromeGlassTrack()
        #expect(Self.rig(track, Self.solidProbe).box(Pixel.chromeProbe) == nil)
        let rig = Self.rig(track, Self.probe)
        let glass = try #require(rig.box(Pixel.chromeProbe), "the track drew no glass")
        // Today's grey capsule steps aside: drawn over the glass it filmed the cyan to (0, 242, 242).
        let face = Pixel.at(rig.capture(), width: Self.canvas.width, CGPoint(x: glass.midX, y: glass.midY))
        #expect(face.0 < 3 && face.1 > 252 && face.2 > 252, "the track's own grey is drawn over its glass: \(face)")
    }
}
