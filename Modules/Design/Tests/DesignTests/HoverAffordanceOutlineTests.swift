import AppKit
import SwiftUI
import Testing
@testable import Design

/// `HoverAffordanceOutline`, **rendered against the shapes it replaced**.
///
/// The style used to switch over `HoverAffordanceShape` inline — one switch filling the wash, a
/// second stroking the ring — so the outline a control drew for its own ground and the outline the
/// wash was painted in were two independent spellings with nothing holding them together. That is
/// how `PaneTabStrip` and `DestinationPicker` both came to draw a 6pt rounded rect under a capsule
/// wash. `HoverAffordanceOutline` exists so a call site can hand its ground, its hit shape and this
/// style one shared value.
///
/// Replacing a drawing switch with a `Shape` is exactly the kind of change that looks obviously
/// equivalent and is not: `strokeBorder` insets by half the line width **and tightens a rounded
/// corner by the same amount as it goes**, which nothing documents and which a hand-written
/// `inset(by:)` gets wrong by default. **So the equivalence is asserted in pixels rather than
/// argued**, filled and stroked, for every case the app actually uses. Dropping the corner
/// tightening reddens the three rounded-rect cases here by 221, 279 and 256 pixels; it is the only
/// part of this refactor that was not free.
///
/// The last test here is the defect itself, priced: how much of a `Radius.chip` row a capsule wash
/// misses. It is what makes "the mismatch is only ever visible in pixels" a number instead of a
/// claim.
///
/// `.machinePinned(.pixelSampling)` — it reads painted pixels back out of a live renderer.
/// Every shape the app hands the style, at file scope rather than on the suite: `@Test(arguments:)`
/// evaluates its argument list outside the actor, so a `static let` on this `@MainActor` suite is a
/// compile error rather than a runtime one.
let outlineCases: [(name: String, shape: HoverAffordanceShape)] = [
    ("capsule", .capsule),
    ("circle", .circle),
    ("chip 6pt", .roundedRect(Radius.chip)),
    ("control 8pt", .roundedRect(Radius.control)),
    ("row 7pt", .roundedRect(7)),
]

@MainActor
@Suite(.serialized) struct HoverAffordanceOutlineTests {

    /// Renders `view` at `size` and hands back its pixels.
    ///
    /// `controlActiveState` pinned for `PaneTabStripRenderTests`' measured reason: without it
    /// SwiftUI renders the inactive-window desaturated variant, and every colour read is of
    /// something the user never sees. Nothing here is translucent, so a flat opaque backdrop is
    /// enough — no glass is involved, which is what lets these specimens render offscreen at all.
    func render(_ view: some View, size: CGSize) -> NSBitmapImageRep {
        let subject = view
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
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

    /// Pixels where the two bitmaps differ by more than a rounding wobble on any channel.
    ///
    /// A tolerance rather than exact equality on each channel: the same path filled twice through
    /// two different `Shape` types can land a hair differently in the antialiased fringe, and a
    /// test that fails on the last bit of one edge pixel would be a machine report, not a claim
    /// about the outline. 0.02 is far below the difference a real shape change makes — the last
    /// test in this suite measures that difference at more than a thousand pixels.
    func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        #expect(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh)
        var count = 0
        for x in 0..<min(a.pixelsWide, b.pixelsWide) {
            for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent),
                                max(abs(p.greenComponent - q.greenComponent),
                                    abs(p.blueComponent - q.blueComponent)))
                if delta > 0.02 { count += 1 }
            }
        }
        return count
    }

    /// Black, so a missed pixel is the largest difference the comparison can register rather than
    /// a tint that half-hides it.
    let ink = Color(red: 0, green: 0, blue: 0)

    @ViewBuilder
    func swiftUIShape(_ shape: HoverAffordanceShape, stroked: Bool) -> some View {
        switch shape {
        case .capsule:
            if stroked { Capsule().strokeBorder(ink, lineWidth: 0.75) } else { Capsule().fill(ink) }
        case .circle:
            if stroked { Circle().strokeBorder(ink, lineWidth: 0.75) } else { Circle().fill(ink) }
        case .roundedRect(let r):
            let rr = RoundedRectangle(cornerRadius: r, style: .continuous)
            if stroked { rr.strokeBorder(ink, lineWidth: 0.75) } else { rr.fill(ink) }
        }
    }

    // MARK: - The refactor changed no pixels

    /// **The wash.** `washShape` was a three-case switch filling `Capsule()`, `Circle()` and a
    /// continuous `RoundedRectangle`; it is now one line through `HoverAffordanceOutline`. If those
    /// are not the same fill, every hovered control in the app changed shape.
    @Test(.machinePinned(.pixelSampling), arguments: outlineCases)
    func theOutlineFillsExactlyWhatTheStyleUsedToFill(_ c: (name: String, shape: HoverAffordanceShape)) {
        let size = CGSize(width: 220, height: 28)
        let before = render(swiftUIShape(c.shape, stroked: false), size: size)
        let after = render(c.shape.outline.fill(ink), size: size)
        #expect(differingPixels(before, after) == 0,
                "\(c.name): the outline's fill is not the fill the style used to paint")
    }

    /// **The ring.** The harder half, and the reason this is rendered rather than reasoned about:
    /// `strokeBorder` pulls the shape in by half the line width *and* tightens a rounded corner by
    /// the same amount, which is behaviour `RoundedRectangle.inset(by:)` is documented nowhere to
    /// have. `HoverAffordanceOutline.inset(by:)` reproduces it, and this is what says so.
    @Test(.machinePinned(.pixelSampling), arguments: outlineCases)
    func theOutlineStrokesExactlyWhatTheStyleUsedToStroke(_ c: (name: String, shape: HoverAffordanceShape)) {
        let size = CGSize(width: 220, height: 28)
        let before = render(swiftUIShape(c.shape, stroked: true), size: size)
        let after = render(c.shape.outline.strokeBorder(ink, lineWidth: 0.75), size: size)
        #expect(differingPixels(before, after) == 0,
                "\(c.name): the outline's stroked border is not the ring the style used to paint")
    }

    // MARK: - The defect, in pixels

    /// **A capsule wash does not cover a `Radius.chip` row, and this is by how much.**
    ///
    /// The claim the whole audit rests on. On a 220×28 row a capsule's radius is 14pt — the full
    /// half-height — against the 6pt the row's ground is actually drawn with, so the wash pulls its
    /// ends in well inside the accent fill underneath and the chosen row shows a pill floating in a
    /// rounded rectangle. Nothing about this is visible in a static screenshot of the app either,
    /// because it takes a hover to paint; comparing the two outlines directly is what makes it
    /// checkable at all.
    ///
    /// Asserted as a floor rather than an exact count so it stays a statement about the shapes
    /// disagreeing and not a golden number, but printed in the message so the next reader gets the
    /// measurement instead of the adjective.
    @Test(.machinePinned(.pixelSampling)) func aCapsuleWashMissesTheCornersOfAChipRow() {
        let size = CGSize(width: 220, height: 28)
        let ground = render(HoverAffordanceShape.roundedRect(Radius.chip).outline.fill(ink), size: size)
        let capsuleWash = render(HoverAffordanceShape.capsule.outline.fill(ink), size: size)
        let missed = differingPixels(ground, capsuleWash)
        #expect(missed > 500,
                "a capsule and a \(Radius.chip)pt rounded rect differ over only \(missed) pixels of a \(Int(size.width))×\(Int(size.height)) row — if this has collapsed the two shapes are no longer distinguishable and the rest of this suite proves nothing")
    }
}
