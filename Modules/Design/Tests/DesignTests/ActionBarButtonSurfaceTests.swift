import AppKit
import SwiftUI
import Testing
@testable import Design

/// `actionBarButtonSurface` promises to be the SAME paint `.actionBar(_:tint:onTint:)` puts on a
/// real button, at rest. That promise is the whole reason a caller is allowed to render a picture
/// of a control instead of hand-drawing one, so it is asserted here rather than trusted.
///
/// Rendered rather than reasoned about: both paths now run through `ActionBarButtonSurface`, so a
/// property-by-property comparison would only be re-reading one struct twice. What can still drift
/// is what the two WRAPPERS add around it — `ButtonStyle.makeBody` gaining a modifier the surface
/// path never sees, or SwiftUI's `Button` contributing something of its own (its label style, its
/// own padding) that only shows up in pixels.
@MainActor
@Suite(.serialized) struct ActionBarButtonSurfaceTests {

    private static let canvas = CGSize(width: 200, height: 44)
    private static let tint = Color(red: 0, green: 0.44, blue: 0.91)

    /// Renders a view offscreen and returns its bitmap. Same never-key borderless window as
    /// `ActionBarFocusIndependenceTests` — irrelevant to the comparison (both sides get it) but it
    /// keeps the two files rendering under one set of conditions.
    private func render<V: View>(_ view: V) -> NSBitmapImageRep? {
        let subject = view
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .leading)
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Fraction of sampled pixels where the two bitmaps differ by more than a hair. A grid rather
    /// than every pixel: 8pt steps over a 200×44 canvas still cross the fill, both capsule caps,
    /// the hairline and the label, and keeps the assertion fast.
    private func fractionDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        let scale = CGFloat(lhs.pixelsWide) / Self.canvas.width
        var sampled = 0
        var differing = 0
        for y in stride(from: CGFloat(2), to: Self.canvas.height - 2, by: 2) {
            for x in stride(from: CGFloat(2), to: Self.canvas.width - 2, by: 2) {
                let px = Int(x * scale), py = Int(y * scale)
                guard let a = lhs.colorAt(x: px, y: py), let b = rhs.colorAt(x: px, y: py) else {
                    continue
                }
                sampled += 1
                // Both reps come from the same window colour space, so the components are
                // directly comparable — no re-tagging, and deliberately no conversion (see
                // `AccentPreviewTests`: `usingColorSpace` CONVERTS values rather than reading them).
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        #expect(sampled > 100, "sampled too few pixels to mean anything: \(sampled)")
        return sampled == 0 ? 1 : Double(differing) / Double(sampled)
    }

    @Test(arguments: ActionBarWeight.allCases)
    func testTheSurfaceRendersWhatTheButtonStyleRestsAt(weight: ActionBarWeight) {
        let asButton = Button(action: {}) { Label("Copy", systemImage: "arrow.right") }
            .buttonStyle(.actionBar(weight, tint: Self.tint, onTint: .white))
        let asSurface = Label("Copy", systemImage: "arrow.right")
            .actionBarButtonSurface(weight, tint: Self.tint, onTint: .white)

        guard let button = render(asButton), let surface = render(asSurface) else {
            Issue.record("no bitmap rep")
            return
        }
        // Not exact equality: text anti-aliasing is not bit-stable between two hosting views even
        // for identical glyphs. A drifted fill, a missing hairline or a shifted capsule would move
        // far more than a few percent of the sampled grid. Mutation-checked: pinning the public
        // modifier at `.hover` instead of `.rest` — the smallest wrong answer it could give — fails
        // all three weights at 18–26% of sampled pixels, two orders of magnitude past this floor.
        let differing = fractionDiffering(button, surface)
        #expect(differing < 0.02,
                "\(weight): surface and button style disagree on \(differing * 100)% of pixels")
    }

    @Test func testTheSurfaceIsTheSameSizeAsTheButton() {
        // The geometry lives in `ActionBarShape`, which both paths apply — but only a laid-out
        // measurement proves the `Button` wrapper is not adding padding of its own around it.
        let button = NSHostingView(rootView: AnyView(
            Button("Copy") {}.buttonStyle(.actionBar(.primary, tint: Self.tint, onTint: .white))))
        let surface = NSHostingView(rootView: AnyView(
            Text("Copy").actionBarButtonSurface(.primary, tint: Self.tint, onTint: .white)))
        #expect(button.fittingSize == surface.fittingSize,
                "button \(button.fittingSize) vs surface \(surface.fittingSize)")
        #expect(surface.fittingSize.height == ActionBarMetrics.height)
    }

    @Test func testIconOnlySurfaceIsCircular() {
        // Same footprint the style's `iconOnly:` produces: a square, which the capsule clip rounds.
        let surface = NSHostingView(rootView: AnyView(
            Image(systemName: "ellipsis")
                .actionBarButtonSurface(.outline, tint: Self.tint, onTint: .white, iconOnly: true)))
        #expect(surface.fittingSize.width == ActionBarMetrics.height)
        #expect(surface.fittingSize.height == ActionBarMetrics.height)
    }
}
