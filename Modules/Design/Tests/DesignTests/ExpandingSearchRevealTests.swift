import Testing
import AppKit
import SwiftUI
@testable import Design

/// RD46.10 — in Frosted and Clear the search field's surface travels open out of the magnifier's
/// end of the row, on the selection lens's own curve; Solid keeps today's fade. Only an animated
/// insertion travels: a field that is already open when its view appears is simply there.
///
/// The geometry is a pure function and is pinned as one. The rendered half uses the lens probe,
/// which paints the travelling surface magenta (today's wash is too faint to measure).
@MainActor
@Suite(.serialized) struct ExpandingSearchRevealTests {

    static let field = CGRect(x: 0, y: 0, width: 300, height: 28)

    // MARK: - The geometry

    @Test func openingStartsAsAPillAtTheTrailingEdgeAndEndsAsTheField() {
        let start = ExpandingSearch.surfaceFrame(in: Self.field, elapsed: 0)
        #expect(start.rect == CGRect(x: 272, y: 0, width: 28, height: 28))
        let end = ExpandingSearch.surfaceFrame(in: Self.field, elapsed: SelectionLensMotion.travelDuration)
        #expect(end.rect == Self.field)
        #expect(end.opacity == 1)
    }

    @Test func openingIsTheLensesMoveAndOvershootsOnlySlightly() {
        var deepest = Self.field.minX
        for step in 0...140 {
            let rect = ExpandingSearch.surfaceFrame(in: Self.field, elapsed: Double(step) * 0.005).rect
            // The magnifier's end stays put; only the leading edge travels.
            #expect(abs(rect.maxX - Self.field.maxX) < 0.001, "step \(step): \(rect)")
            #expect(abs(rect.height - Self.field.height) < 0.001, "the field pinched at step \(step)")
            deepest = min(deepest, rect.minX)
        }
        #expect(deepest < Self.field.minX - 1, "the leading edge never overshot — this is not the lens's spring")
        #expect(deepest >= Self.field.minX - Self.field.width * 0.02, "overshot to \(deepest)")
    }

    @Test func theQueryWaitsForRoom() {
        #expect(ExpandingSearch.contentOpacity(elapsed: 0.12) == 0)
        #expect(ExpandingSearch.contentOpacity(elapsed: 0.27) == 1)
        var last = -1.0
        for step in 0...100 {
            let o = ExpandingSearch.contentOpacity(elapsed: Double(step) * 0.005)
            #expect(o >= last)
            last = o
        }
    }

    @Test func aFieldNarrowerThanItIsTallIsItsOwnPill() {
        let narrow = CGRect(x: 0, y: 0, width: 20, height: 28)
        #expect(ExpandingSearch.surfaceFrame(in: narrow, elapsed: 0).rect == narrow)
        #expect(ExpandingSearch.surfaceFrame(in: narrow, elapsed: 0.1).rect.width <= 20.001)
    }

    @Test func onlyGlassTravels() {
        func travels(_ level: GlassLevel, rt: Bool = false, rm: Bool = false) -> Bool {
            ExpandingSearch.travels(appearance: SelectionLensAppearance(level: level, hue: .blue, tint: 0),
                                    reduceTransparency: rt, reduceMotion: rm)
        }
        #expect(!travels(.solid))
        #expect(travels(.frosted))
        #expect(travels(.clear))
        #expect(!travels(.frosted, rt: true), "Reduce Transparency keeps today's opening")
        #expect(!travels(.clear, rm: true), "Reduce Motion keeps today's opening — and that one is instant")
    }

    // MARK: - Rendered

    nonisolated static let canvas = CGSize(width: 340, height: 60)
    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)

    final class Reveal: ObservableObject {
        @Published var isExpanded: Bool
        init(_ isExpanded: Bool) { self.isExpanded = isExpanded }
    }

    /// The field revealed the way the app reveals it: absent until `isExpanded` flips, then
    /// inserted by that transaction — the field's own clock is the one that runs.
    struct Harness: View {
        @ObservedObject var reveal: Reveal
        let appearance: SelectionLensAppearance
        var timeScale: Double = 1
        /// Holds an opening at this instant — see `expandingSearchFrozenElapsed`.
        var frozenElapsed: TimeInterval?
        /// A second row under the field, as a host's suggestions are.
        var accessories = false
        /// Whether the host fades the field in as it inserts it, as the app's hosts do. Off for the
        /// frozen-clock tests: they read the surface, and the fade runs on the animation's own clock,
        /// which a loaded offscreen run did not advance — the field was still invisible at 0.5 s.
        var fades = true
        @State private var text = ""

        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: 10)
                if reveal.isExpanded {
                    ExpandingSearchField(
                        text: $text,
                        isExpanded: Binding(get: { reveal.isExpanded }, set: { reveal.isExpanded = $0 }),
                        placeholder: "kind:pdf, >5mb…",
                        accessories: { _ in
                            if accessories { Color.clear.frame(height: 20) }
                        })
                    .padding(.horizontal, 20)
                    .transition(fades ? AnyTransition.opacity : .identity)
                }
            }
            .frame(width: ExpandingSearchRevealTests.canvas.width,
                   height: ExpandingSearchRevealTests.canvas.height, alignment: .top)
            .background(Color.white)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.expandingSearchTimeScale, timeScale)
            .environment(\.expandingSearchFrozenElapsed, frozenElapsed)
            .environment(\.colorScheme, .light)
            // Pinned, so the machine's own settings cannot turn the travel off under these tests.
            .environment(\._accessibilityReduceMotion, false)
            .environment(\._accessibilityReduceTransparency, false)
        }
    }

    /// The field's frame in the harness: 20pt in from each side, 10pt down.
    static let fieldMinX: CGFloat = 20
    static let fieldMaxX: CGFloat = canvas.width - 20

    @Test(.machinePinned(.pixelSampling))
    func atRestTheSurfaceIsTheWholeField() throws {
        // Already open when the view appears — no transition runs, and nothing travels.
        let box = try #require(ProbeRig(Harness(reveal: Reveal(true), appearance: Self.probe), size: Self.canvas)
                                .box(Pixel.lensProbe), "the glass path drew no surface")
        #expect(abs(box.minX - Self.fieldMinX) <= 1.01 && abs(box.maxX - Self.fieldMaxX) <= 1.01, "\(box)")
    }

    @Test(.machinePinned(.pixelSampling))
    func solidDrawsTodaysSurfaceNotTheTravellingOne() {
        let solid = SelectionLensAppearance(level: .solid, hue: .blue, tint: 0, drawsProbe: true)
        #expect(ProbeRig(Harness(reveal: Reveal(true), appearance: solid), size: Self.canvas).box(Pixel.lensProbe) == nil)
    }

    /// **The live clock, asked only what a busy machine cannot hide.** The first version sampled the
    /// travel as it ran and needed a frame from inside the overshoot — about 0.16 s of a 0.7 s move,
    /// 1.3 s even slowed eight times — and a main thread held for one pass longer than that missed it
    /// with nothing wrong (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). The instants are
    /// rendered exactly below, on a frozen clock; this pins that the real one starts the travel and
    /// ends it on the field: no open field on the first frame, every frame anchored at the
    /// magnifier's end, and the field at rest at the end.
    static let stretch: Double = 8

    @Test(.machinePinned(.pixelSampling))
    func aToggleOpensTheFieldByTravellingFromTheMagnifiersEnd() async throws {
        let reveal = Reveal(false)
        let rig = ProbeRig(Harness(reveal: reveal, appearance: Self.probe, timeScale: Self.stretch), size: Self.canvas)
        #expect(rig.box(Pixel.lensProbe) == nil)
        withAnimation(ExpandingSearch.animation) { reveal.isExpanded = true }
        let full = Self.fieldMaxX - Self.fieldMinX
        var samples: [CGRect] = []
        if let first = rig.box(Pixel.lensProbe) {
            #expect(first.width < full / 2, "the first frame showed the field open before it travelled: \(first)")
            samples.append(first)
        }
        let wait = await LayoutPumpWait.pump(rig.host, upTo: 30) {
            if let box = rig.box(Pixel.lensProbe) { samples.append(box) }
            return samples.last.map { Pixel.same($0, CGRect(x: Self.fieldMinX, y: $0.minY, width: full, height: $0.height)) } == true
        }
        try #require(!samples.isEmpty, "nothing drawn during the travel")
        for box in samples {
            #expect(abs(box.maxX - Self.fieldMaxX) <= 1.01, "a frame left the magnifier's end: \(box)")
        }
        #expect(wait.held, "the travel never came to rest on the field after \(wait.pumps) passes")
    }

    /// The travel at chosen instants, on a frozen clock: each frame is exactly the one
    /// `ExpandingSearch.surfaceFrame` gives, placed on the field — part-way, overshooting, at rest.
    /// Opens a field on a frozen clock: inserted by an animated transaction, so its own travel
    /// starts, but with no fade from the host, so what is read is the surface at that instant and
    /// nothing that runs on a clock of its own. Slowed a thousandfold, so the real clock never ends
    /// the opening under the frozen one. Waited for in turns, until the surface draws.
    static func frozenOpening(at elapsed: TimeInterval, accessories: Bool = false) async -> ProbeRig<Harness> {
        let reveal = Reveal(false)
        let rig = ProbeRig(Harness(reveal: reveal, appearance: probe, timeScale: 1000,
                                   frozenElapsed: elapsed, accessories: accessories, fades: false), size: canvas)
        withAnimation(ExpandingSearch.animation) { reveal.isExpanded = true }
        _ = await LayoutPumpWait.pump(rig.host, upTo: 15) { rig.box(Pixel.lensProbe) != nil }
        return rig
    }

    @Test(.machinePinned(.pixelSampling), arguments: [0.05, 0.305, SelectionLensMotion.travelDuration])
    func eachInstantOfTheOpeningIsTheSurfaceFrameAtThatInstant(elapsed: TimeInterval) async throws {
        let atRest = try #require(ProbeRig(Harness(reveal: Reveal(true), appearance: Self.probe), size: Self.canvas)
                                    .box(Pixel.lensProbe), "no field at rest to measure against")
        let rig = await Self.frozenOpening(at: elapsed)
        let box = try #require(rig.box(Pixel.lensProbe), "nothing drawn \(elapsed) s in")
        let want = ExpandingSearch.surfaceFrame(in: CGRect(origin: .zero, size: atRest.size), elapsed: elapsed).rect
            .offsetBy(dx: atRest.minX, dy: atRest.minY)
        #expect(Pixel.same(box, want, tolerance: 1.51), "\(elapsed) s in the surface is \(box), want \(want)")
        if elapsed == 0.305 {
            #expect(box.width > atRest.width + 1, "no overshoot at the lead spring's peak: \(box.width) vs \(atRest.width)")
        }
    }

    /// **A field with a second row opens out of its FIRST row.** Hosts show suggestions under the
    /// field once it takes the caret; sized from the whole field, the opening pill jumped from the
    /// row's height to the field's part-way. Frozen just in, the surface is still about a row tall.
    @Test(.machinePinned(.pixelSampling))
    func aFieldWithASecondRowOpensOutOfItsFirst() async throws {
        let whole = try #require(ProbeRig(Harness(reveal: Reveal(true), appearance: Self.probe, accessories: true),
                                          size: Self.canvas).box(Pixel.lensProbe))
        // 0.07 s: early, and past the surface's own 0.08 s fade-in far enough for the probe to read.
        let rig = await Self.frozenOpening(at: 0.07, accessories: true)
        let early = try #require(rig.box(Pixel.lensProbe), "nothing drawn just in")
        // The first row with the field's padding: measured, as a field with no second row.
        let row = try #require(ProbeRig(Harness(reveal: Reveal(true), appearance: Self.probe), size: Self.canvas)
                                .box(Pixel.lensProbe)).height
        let want = ExpandingSearch.surfaceFrame(in: CGRect(origin: .zero, size: whole.size), rowHeight: row,
                                                elapsed: 0.07).rect.offsetBy(dx: whole.minX, dy: whole.minY)
        #expect(early.height < whole.height - 5,
                "the opening started as the whole \(whole.height)pt field, not its first row: \(early)")
        #expect(Pixel.same(early, want, tolerance: 1.51), "the surface is \(early), want \(want)")
    }

    @Test(.machinePinned(.pixelSampling))
    func anUnanimatedInsertionIsSimplyThere() throws {
        // A view coming back with its search already open inserts the field with no animation.
        let reveal = Reveal(false)
        let rig = ProbeRig(Harness(reveal: reveal, appearance: Self.probe), size: Self.canvas)
        reveal.isExpanded = true
        let box = try #require(rig.box(Pixel.lensProbe), "nothing drawn")
        #expect(abs(box.minX - Self.fieldMinX) <= 1.01 && abs(box.maxX - Self.fieldMaxX) <= 1.01,
                "an unanimated insertion travelled: \(box)")
    }
}
