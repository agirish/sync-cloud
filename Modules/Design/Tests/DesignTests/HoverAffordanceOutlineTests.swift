import AppKit
import SwiftUI
import Testing
@testable import Design

/// `HoverAffordanceOutline`, rendered against the plain SwiftUI shapes it stands for, so a
/// control's ground, hit shape and hover style share one outline.
///
/// Asserted in pixels, filled and stroked: `strokeBorder` also tightens a rounded corner by half
/// the line width, which nothing documents. Dropping that tightening must fail the rounded cases.
///
/// File scope because `@Test(arguments:)` evaluates its list outside the actor, so a `static let`
/// on this `@MainActor` suite would not compile.
let outlineCases: [(name: String, shape: HoverAffordanceShape)] = [
    ("capsule", .capsule),
    ("circle", .circle),
    ("chip 6pt", .roundedRect(Radius.chip)),
    ("control 8pt", .roundedRect(Radius.control)),
    ("row 7pt", .roundedRect(7)),
]

@MainActor
@Suite(.serialized) struct HoverAffordanceOutlineTests {

    /// Renders `view` at `size` and hands back its pixels. `controlActiveState` is pinned: without
    /// it SwiftUI renders the desaturated inactive-window variant, which the user never sees.
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

    /// Pixels where the two bitmaps differ by more than a rounding wobble on any channel: the same
    /// path filled through two `Shape` types can land a hair differently in the antialiased fringe.
    func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        Pixel.differing(a, b, sRGB: true)
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

    /// A capsule wash doesn't cover a `Radius.chip` row: its 14pt radius against the row's 6pt
    /// shows a pill floating in a rounded rectangle, and only on hover. A floor, not a golden count,
    /// and the positive control for the equality tests above.
    @Test(.machinePinned(.pixelSampling)) func aCapsuleWashMissesTheCornersOfAChipRow() {
        let size = CGSize(width: 220, height: 28)
        let ground = render(HoverAffordanceShape.roundedRect(Radius.chip).outline.fill(ink), size: size)
        let capsuleWash = render(HoverAffordanceShape.capsule.outline.fill(ink), size: size)
        let missed = differingPixels(ground, capsuleWash)
        #expect(missed > 500,
                "a capsule and a \(Radius.chip)pt rounded rect differ over only \(missed) pixels of a \(Int(size.width))×\(Int(size.height)) row — if this has collapsed the two shapes are no longer distinguishable and the rest of this suite proves nothing")
    }
}
