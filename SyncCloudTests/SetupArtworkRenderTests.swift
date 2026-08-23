import Testing
import SwiftUI
import AppKit
@testable import SyncCloud

/// Does the tour's artwork actually paint?
///
/// The illustrations are the one part of the welcome card no assertion could previously reach:
/// they are decorative, `accessibilityHidden`, and every one of them starts at `opacity(0)` and
/// only becomes visible from an `onAppear`. A page whose art never arrives renders as a 120pt
/// blank band above the copy and nothing else changes — the card still lays out, the titles still
/// read, and the suite stays green.
///
/// **The harness validates itself against a shipped illustration first.** `ImageRenderer` is not
/// obliged to run `onAppear`, so a blank result here would be indistinguishable from art that is
/// genuinely broken — and "assert ink > 0" against a renderer that paints nothing is a test that
/// can only ever fail for the wrong reason. `testTheRendererSeesAShippedIllustration` is the
/// control: if the renderer cannot see `DuplicatesArt`, which has shipped since the tour existed, then
/// it cannot see any of them and the Browse check below is not evidence.
@Suite(.machinePinned(.pixelSampling)) struct SetupArtworkRenderTests {

    /// Renders one page's artwork at the size the card gives it, and returns the bitmap.
    ///
    /// Reduce Motion is deliberately NOT injected: `accessibilityReduceMotion` is a read-only
    /// environment key, so there is no way to ask the art views for their settled state directly.
    /// What lands in the bitmap is whatever a single render pass produces, which is precisely why
    /// the control test below exists rather than an assumption that `onAppear` ran.
    @MainActor
    static func render(_ art: SetupArt.Art) throws -> NSBitmapImageRep {
        let view = SetupIllustration(art: art, leftName: "iCloud", rightName: "Dropbox")
            .frame(width: 260, height: 120)
            .tint(.blue)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "renderer produced no image for \(art)")
        let data = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data))
    }

    /// Pixels that are not fully transparent, and how many of them carry a hue rather than grey.
    static func ink(_ bitmap: NSBitmapImageRep) -> (painted: Int, tinted: Int) {
        var painted = 0
        var tinted = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.02 else { continue }
                painted += 1
                guard let rgb = colour.usingColorSpace(.deviceRGB) else { continue }
                // Blue tint against a grey ramp: a real hue separates its channels.
                if rgb.blueComponent - rgb.redComponent > 0.15 { tinted += 1 }
            }
        }
        return (painted, tinted)
    }

    /// The control. If this fails, nothing else in this file is evidence of anything.
    @MainActor
    @Test func testTheRendererSeesAShippedIllustration() throws {
        let (painted, _) = Self.ink(try Self.render(.duplicates))
        #expect(painted > 500,
                "the renderer cannot see DuplicatesArt, which ships — every check below would be vacuous")
    }

    /// Browse's own art paints, and paints its tint.
    ///
    /// Both halves matter. A stack of column outlines with no lit row would still clear an ink
    /// count while saying nothing about drilling into a tree, which is the entire thing the
    /// illustration is for.
    @MainActor
    @Test func testTheBrowseIllustrationPaintsColumnsAndASelection() throws {
        let (painted, tinted) = Self.ink(try Self.render(.browse))
        #expect(painted > 500, "the Browse artwork rendered blank")
        #expect(tinted > 40, "the Browse artwork painted no lit row — the column trail is missing")
    }

    /// Three columns, not one blob.
    ///
    /// The columns are separated by 5pt of clear space, so a correct render leaves three runs of
    /// painted pixel-columns with gaps between them. This is what would catch the stack collapsing
    /// into a single frame — a failure an ink count cannot see, because the ink is all still there.
    @MainActor
    @Test func testTheBrowseIllustrationDrawsThreeSeparateColumns() throws {
        let bitmap = try Self.render(.browse)
        var runs = 0
        var inRun = false
        for x in 0..<bitmap.pixelsWide {
            let painted = (0..<bitmap.pixelsHigh).contains { y in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02
            }
            if painted && !inRun { runs += 1 }
            inRun = painted
        }
        #expect(runs == 3, "expected three separated columns, found \(runs) run(s) of ink")
    }

    /// Every page's art paints — by construction, not by roll-call. This suite rendered 2 of 6
    /// cases for its first weeks, so a blank illustration on four tour pages (or on whatever case
    /// is added next — `Art` is `CaseIterable` for exactly this loop) would have shipped with the
    /// suite green. The floor is far below any shipped illustration's ink but far above the noise
    /// of an art view that never ran its `onAppear` reveal or lost its body: the control test
    /// above establishes that the renderer sees a shipped illustration at all, so a blank here is
    /// the ART, not the harness.
    @MainActor
    @Test(arguments: SetupArt.Art.allCases)
    func testEveryTourPagePaintsItsIllustration(art: SetupArt.Art) throws {
        let (painted, _) = Self.ink(try Self.render(art))
        #expect(painted > 300, "\(art) renders as a blank band — its page ships with no illustration")
    }
}
