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
///
/// **And against a blank one, because the renderer can fail the other way too.** Its own image is
/// a buffer it recycles, and a render with nothing to draw handed that buffer back holding an
/// earlier page's pixels — so a page with no art at all passed here, in some runs and not others.
/// `render` draws into a bitmap of its own for that reason, and
/// `testABlankPageReadsAsBlankRightAfterAPaintedOne` is the control that keeps it honest.
@Suite(.machinePinned(.pixelSampling)) struct SetupArtworkRenderTests {

    /// Renders one page's artwork at the size the card gives it, and returns the bitmap.
    ///
    /// Reduce Motion is deliberately NOT injected: `accessibilityReduceMotion` is a read-only
    /// environment key, so there is no way to ask the art views for their settled state directly.
    /// What lands in the bitmap is whatever a single render pass produces, which is precisely why
    /// the control test below exists rather than an assumption that `onAppear` ran.
    @MainActor
    static func render(_ art: SetupArt.Art) throws -> NSBitmapImageRep {
        try render(SetupIllustration(art: art, leftName: "iCloud", rightName: "Dropbox"), named: "\(art)")
    }

    /// Renders any view the way `render(_:)` renders a page: same size, same tint, same scale.
    ///
    /// **Into a bitmap this function allocates and clears — never the renderer's own image.**
    /// `ImageRenderer`'s `nsImage` and `cgImage` come back in a buffer it recycles between renders
    /// of the same pixel size, and a render with nothing visible to draw does not clear it: it
    /// returns whatever the last same-sized render painted, once that render's image has been
    /// freed. Measured 2026-09-26 with Browse's art replaced by `Color.clear`: the blank page read
    /// 18,351 painted pixels, `.duplicates`' exact count, and each of the three Browse tests passed,
    /// in one run or another, on a page that drew nothing. Art whose reveal never ran is the same
    /// case — everything at `opacity(0)` draws nothing — which is the failure this suite exists for.
    ///
    /// `render(rasterizationScale:renderer:)` is the same renderer, `onAppear` included; only the
    /// destination is ours. An unattached `NSHostingView` is no substitute: through `cacheDisplay`
    /// it drew Browse and Welcome as nothing at all, captured before their reveals showed.
    @MainActor
    static func render(_ content: some View, named name: String) throws -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let renderer = ImageRenderer(content: content.frame(width: 260, height: 120).tint(.blue))
        var image: CGImage?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            draw(context)
            image = context.makeImage()
        }
        return NSBitmapImageRep(cgImage: try #require(image, "the renderer produced no image for \(name)"))
    }

    /// Pixels that are not fully transparent, and how many of them carry a hue rather than grey.
    ///
    /// Each distinct pixel value is asked once (`PixelMemo`), the question unchanged — this used to
    /// convert every painted pixel of every page to device RGB, on the main actor.
    static func ink(_ bitmap: NSBitmapImageRep) -> (painted: Int, tinted: Int) {
        let classify = PixelMemo(bitmap) { colour -> (painted: Bool, tinted: Bool) in
            guard let colour, colour.alphaComponent > 0.02 else { return (false, false) }
            guard let rgb = colour.usingColorSpace(.deviceRGB) else { return (true, false) }
            // Blue tint against a grey ramp: a real hue separates its channels.
            return (true, rgb.blueComponent - rgb.redComponent > 0.15)
        }
        var painted = 0
        var tinted = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let pixel = classify(x, y)
                if pixel.painted { painted += 1 }
                if pixel.tinted { tinted += 1 }
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

    /// The other control: a page that paints nothing reads as nothing — straight after one that
    /// painted, at the same size.
    ///
    /// Every floor below is only evidence if a blank reads as blank, and through the renderer's own
    /// image it did not (see `render(_:named:)`). The two blanks are the two a broken page produces:
    /// a body that draws nothing, and art held at `opacity(0)` because its reveal never ran. Each
    /// follows a shipped illustration whose image is freed first, inside its own autorelease pool,
    /// because a recycled buffer is only handed out once the image holding it is gone.
    @MainActor
    @Test func testABlankPageReadsAsBlankRightAfterAPaintedOne() throws {
        let blanks: [(String, AnyView)] = [
            ("a body that draws nothing", AnyView(Color.clear)),
            ("art whose reveal never ran",
             AnyView(SetupIllustration(art: .duplicates, leftName: "iCloud", rightName: "Dropbox").opacity(0))),
        ]
        for (name, blank) in blanks {
            let before = try autoreleasepool { Self.ink(try Self.render(.duplicates)).painted }
            try #require(before > 500, "DuplicatesArt painted nothing, so nothing could go stale")
            let after = try autoreleasepool { Self.ink(try Self.render(blank, named: name)).painted }
            #expect(after == 0,
                    "\(name) read as \(after) painted pixels — the render handed back an earlier page's, so every floor here can pass on a blank page")
        }
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
        let inked = PixelMemo(bitmap) { ($0?.alphaComponent ?? 0) > 0.02 }
        var runs = 0
        var inRun = false
        for x in 0..<bitmap.pixelsWide {
            let painted = (0..<bitmap.pixelsHigh).contains { y in inked(x, y) }
            if painted && !inRun { runs += 1 }
            inRun = painted
        }
        #expect(runs == 3, "expected three separated columns, found \(runs) run(s) of ink")
    }

    /// Every page's art paints — by construction, not by roll-call. This suite rendered 2 of 6
    /// cases for its first weeks, so a blank illustration on four tour pages (or on whatever case
    /// is added next — `Art` is `CaseIterable` for exactly this loop) would have shipped with the
    /// suite green. The floor is far below any shipped illustration's ink but far above the noise
    /// of an art view that never ran its `onAppear` reveal or lost its body: the two controls
    /// above establish that the renderer sees a shipped illustration at all and that a blank reads
    /// as blank, so a blank here is the ART, not the harness — and a pass is not an earlier page.
    @MainActor
    @Test(arguments: SetupArt.Art.allCases)
    func testEveryTourPagePaintsItsIllustration(art: SetupArt.Art) throws {
        let (painted, _) = Self.ink(try Self.render(art))
        #expect(painted > 300, "\(art) renders as a blank band — its page ships with no illustration")
    }
}
