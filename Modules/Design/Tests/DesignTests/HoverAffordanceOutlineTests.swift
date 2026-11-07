import AppKit
import SwiftUI
import Testing
@testable import Design

/// `HoverAffordanceOutline`, rendered against the plain SwiftUI shapes it stands for.
///
/// One shared value lets a call site hand its ground, its hit shape and the hover style the same
/// outline, so a control can't draw a 6pt rounded rect under a capsule wash.
///
/// The equivalence is asserted in pixels, filled and stroked, for every case the app uses:
/// `strokeBorder` insets by half the line width and also tightens a rounded corner by the same
/// amount, which nothing documents and a hand-written `inset(by:)` gets wrong. Dropping that
/// corner tightening must make the rounded-rect cases fail.
///
/// The last test measures how much of a `Radius.chip` row a capsule wash misses, so the mismatch
/// is a number, not a claim. Pinned to `.pixelSampling`: it reads pixels from a live renderer.
///
/// The cases live at file scope because `@Test(arguments:)` evaluates its list outside the actor,
/// so a `static let` on this `@MainActor` suite would not compile.
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
    /// `controlActiveState` is pinned as in `PaneTabStripRenderTests`: without it SwiftUI renders
    /// the desaturated inactive-window variant, which the user never sees. Nothing here is
    /// translucent or glass, so a flat opaque backdrop is enough and the specimens render offscreen.
    func render(_ view: some View, size: CGSize) -> NSBitmapImageRep {
        let subject = view
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
        guard let rep = offscreenBitmap(AnyView(subject), size: size, layoutPasses: 2) else {
            fatalError("no bitmap rep")
        }
        return rep
    }

    /// Pixels where the two bitmaps differ by more than a rounding wobble on any channel.
    ///
    /// A tolerance, not exact equality: the same path filled through two `Shape` types can land a
    /// hair differently in the antialiased fringe. 0.02 is far below what a real shape change makes,
    /// which the last test here measures at hundreds of pixels.
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

    /// The wash: `HoverAffordanceOutline` must fill exactly what `Capsule()`, `Circle()` and a
    /// continuous `RoundedRectangle` fill, or every hovered control in the app changes shape.
    @Test(.machinePinned(.pixelSampling), arguments: outlineCases)
    func theOutlineFillsExactlyWhatTheStyleUsedToFill(_ c: (name: String, shape: HoverAffordanceShape)) {
        let size = CGSize(width: 220, height: 28)
        let before = render(swiftUIShape(c.shape, stroked: false), size: size)
        let after = render(c.shape.outline.fill(ink), size: size)
        #expect(differingPixels(before, after) == 0,
                "\(c.name): the outline's fill is not the fill the style used to paint")
    }

    /// The ring, the harder half: `strokeBorder` pulls the shape in by half the line width and
    /// tightens a rounded corner by the same amount, which `RoundedRectangle.inset(by:)` is nowhere
    /// documented to do. This checks that `HoverAffordanceOutline.inset(by:)` reproduces it.
    @Test(.machinePinned(.pixelSampling), arguments: outlineCases)
    func theOutlineStrokesExactlyWhatTheStyleUsedToStroke(_ c: (name: String, shape: HoverAffordanceShape)) {
        let size = CGSize(width: 220, height: 28)
        let before = render(swiftUIShape(c.shape, stroked: true), size: size)
        let after = render(c.shape.outline.strokeBorder(ink, lineWidth: 0.75), size: size)
        #expect(differingPixels(before, after) == 0,
                "\(c.name): the outline's stroked border is not the ring the style used to paint")
    }

    // MARK: - The defect, in pixels

    /// A capsule wash doesn't cover a `Radius.chip` row, measured. On a 220×28 row a capsule's
    /// radius is the full 14pt half-height against the row's 6pt, so the wash pulls its ends in
    /// inside the accent fill and the row shows a pill floating in a rounded rectangle. It takes a
    /// hover to paint, so no static screenshot shows it; comparing the outlines makes it checkable.
    ///
    /// A floor, not an exact count, so it states that the shapes disagree rather than pinning a
    /// golden number; the message prints the measurement.
    @Test(.machinePinned(.pixelSampling)) func aCapsuleWashMissesTheCornersOfAChipRow() {
        let size = CGSize(width: 220, height: 28)
        let ground = render(HoverAffordanceShape.roundedRect(Radius.chip).outline.fill(ink), size: size)
        let capsuleWash = render(HoverAffordanceShape.capsule.outline.fill(ink), size: size)
        let missed = differingPixels(ground, capsuleWash)
        #expect(missed > 500,
                "a capsule and a \(Radius.chip)pt rounded rect differ over only \(missed) pixels of a \(Int(size.width))×\(Int(size.height)) row — if this has collapsed the two shapes are no longer distinguishable and the rest of this suite proves nothing")
    }
}
