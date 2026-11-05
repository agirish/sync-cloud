import Testing
import SwiftUI
import AppKit
@testable import SyncCloud

/// Does the tour's artwork actually paint?
///
/// The illustrations are decorative and `accessibilityHidden`, and most reveal some or all of their
/// drawing from an `onAppear`; Welcome and Browse draw nothing until it runs. A page whose art never
/// arrives is a blank 120pt band while the card still lays out and every other test stays green. A
/// page whose reveal never runs stays in its first frame, so every page is compared with that frame.
///
/// Two controls keep the harness honest. `testTheRendererSeesAShippedIllustration` checks the
/// renderer sees `DuplicatesArt`, revealed, since `ImageRenderer` isn't obliged to run `onAppear`.
/// `testABlankPageReadsAsBlankRightAfterAPaintedOne` checks a blank reads as blank, since the
/// renderer's own image is a recycled buffer that can hand back an earlier page's pixels; `render`
/// draws into a bitmap of its own for that reason.
@Suite(.machinePinned(.pixelSampling)) struct SetupArtworkRenderTests {

    /// Renders one page's artwork at the size the card gives it, and returns the bitmap.
    ///
    /// Reduce Motion isn't injected, so each page takes the machine's branch;
    /// `testEveryTourPageRevealsWhenItAppears` pins both through the writable
    /// `_accessibilityReduceMotion`. The bitmap is one render pass, so the control test checks that
    /// `onAppear` ran rather than assuming it.
    @MainActor
    static func render(_ art: SetupArt.Art) throws -> NSBitmapImageRep {
        try render(SetupIllustration(art: art, leftName: "iCloud", rightName: "Dropbox", accent: Self.accent), named: "\(art)")
    }

    /// The accent every page is handed: blue, which `ink` tells from the grey ramp.
    static let accent = Color.blue

    /// Renders any view the way `render(_:)` renders a page: same size, same scale.
    ///
    /// Draws into a bitmap this function allocates and clears, never the renderer's own image.
    /// `ImageRenderer`'s `nsImage` and `cgImage` reuse a buffer between same-sized renders, and a
    /// render with nothing visible doesn't clear it, so a blank page (or art held at `opacity(0)`)
    /// would read as the last page's pixels once that image is freed.
    ///
    /// `render(rasterizationScale:renderer:)` is the same renderer, `onAppear` included; only the
    /// destination is ours. An unattached `NSHostingView` is no substitute: its `cacheDisplay`
    /// captures Browse and Welcome before their reveals show.
    @MainActor
    static func render(_ content: some View, named name: String) throws -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let renderer = ImageRenderer(content: content.frame(width: 260, height: 120))
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
    /// Each distinct pixel value is classified once (`PixelMemo`), to keep the main actor free.
    static func ink(_ bitmap: NSBitmapImageRep) -> (painted: Int, tinted: Int) {
        let classify = PixelMemo(bitmap) { colour -> (painted: Bool, tinted: Bool) in
            guard let colour, colour.alphaComponent > 0.02 else { return (false, false) }
            guard let rgb = colour.usingColorSpace(.deviceRGB) else { return (true, false) }
            // Blue accent against a grey ramp: a real hue separates its channels.
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

    /// Pixels whose green stands clear of both other channels — on `DuplicatesArt`, its check mark
    /// and nothing else. Asked once per distinct pixel value, like `ink`.
    static func greenInk(_ bitmap: NSBitmapImageRep) -> Int {
        let isGreen = PixelMemo(bitmap) { colour -> Bool in
            guard let colour, colour.alphaComponent > 0.02,
                  let rgb = colour.usingColorSpace(.deviceRGB) else { return false }
            return rgb.greenComponent - rgb.redComponent > 0.15 && rgb.greenComponent - rgb.blueComponent > 0.15
        }
        var green = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where isGreen(x, y) { green += 1 }
        }
        return green
    }

    /// The control. If this fails, nothing else in this file is evidence of anything.
    ///
    /// It counts the reveal, not just the drawing: `DuplicatesArt` paints its documents before
    /// `onAppear` runs, so the ink floor holds either way. Its green check mark is the one part only
    /// the reveal draws. It heads no panel, so nothing edits it for a page's sake, which lets it
    /// stand as the reference.
    @MainActor
    @Test func testTheRendererSeesAShippedIllustration() throws {
        let bitmap = try Self.render(.duplicates)
        let (painted, _) = Self.ink(bitmap)
        #expect(painted > 500,
                "the renderer cannot see DuplicatesArt, which ships — every check below would be vacuous")
        let checkMark = Self.greenInk(bitmap)
        #expect(checkMark > 200,
                "DuplicatesArt rendered without its check mark, which only its onAppear reveal draws — the renderer is reading pages before their reveal, so a blank page below would be the harness, not the art")
    }

    /// The other control: a page that paints nothing reads as nothing, straight after one that
    /// painted at the same size (see `render(_:named:)`).
    ///
    /// The two blanks are the ones a broken page produces: a body that draws nothing, and art held
    /// at `opacity(0)` by a reveal that never ran. Each follows a shipped illustration freed in its
    /// own autorelease pool, because a recycled buffer is only handed out once its image is gone.
    @MainActor
    @Test func testABlankPageReadsAsBlankRightAfterAPaintedOne() throws {
        let blanks: [(String, AnyView)] = [
            ("a body that draws nothing", AnyView(Color.clear)),
            ("art whose reveal never ran",
             AnyView(SetupIllustration(art: .duplicates, leftName: "iCloud", rightName: "Dropbox",
                                     accent: Self.accent).opacity(0))),
        ]
        for (name, blank) in blanks {
            let before = try autoreleasepool { Self.ink(try Self.render(.duplicates)).painted }
            try #require(before > 500, "DuplicatesArt painted nothing, so nothing could go stale")
            let after = try autoreleasepool { Self.ink(try Self.render(blank, named: name)).painted }
            #expect(after == 0,
                    "\(name) read as \(after) painted pixels — the render handed back an earlier page's, so every floor here can pass on a blank page")
        }
    }

    /// Browse's own art paints, and paints its tint: column outlines with no lit row would clear an
    /// ink count while showing nothing about drilling into a tree, which is the illustration's point.
    @MainActor
    @Test func testTheBrowseIllustrationPaintsColumnsAndASelection() throws {
        let (painted, tinted) = Self.ink(try Self.render(.browse))
        #expect(painted > 500, "the Browse artwork rendered blank")
        #expect(tinted > 40, "the Browse artwork painted no lit row — the column trail is missing")
    }

    /// Three columns, not one blob. They are 5pt apart, so a correct render leaves three runs of
    /// painted pixel-columns. Catches the stack collapsing into one frame, which an ink count can't.
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

    /// Every page's art paints, over `Art.allCases` so a new case is covered too. The floor is far
    /// below any shipped illustration's ink and far above a page that lost its body. It catches a
    /// dead reveal only on Welcome and Browse, which draw nothing before it; the rest are
    /// `testEveryTourPageRevealsWhenItAppears`'s. With the two controls green, a blank here is the
    /// art, not the harness.
    @MainActor
    @Test(arguments: SetupArt.Art.allCases)
    func testEveryTourPagePaintsItsIllustration(art: SetupArt.Art) throws {
        let (painted, _) = Self.ink(try Self.render(art))
        #expect(painted > 300, "\(art) renders as a blank band — its page ships with no illustration")
    }

    /// Pages whose `onAppear` adds nothing but motion, so there is no reveal to hold them to.
    ///
    /// Transfer only starts a drift, which Reduce Motion skips, and the renderer draws it unmoved in
    /// a process's first Transfer render and drifted after, so a before-and-after would depend on
    /// test order. Held to having no reveal instead: gain one, and the check below says so.
    static let pagesWithoutAReveal: Set<SetupArt.Art> = [.transfer]

    /// Every page changes when it appears, so a dead reveal is caught on every page.
    ///
    /// Each page is drawn before `onAppear` (`setupArtReveals` off, the frame a dead reveal leaves)
    /// and revealed. Both renders are exact, so a dead reveal leaves them identical. Run with Reduce
    /// Motion off and on, since each takes its own branch and either can break alone. The floor is
    /// far below the smallest reveal (Compare's, about 2,900 pixels) and far above zero.
    @MainActor
    @Test(arguments: SetupArt.Art.allCases)
    func testEveryTourPageRevealsWhenItAppears(art: SetupArt.Art) throws {
        for reduceMotion in [false, true] {
            let page = SetupIllustration(art: art, leftName: "iCloud", rightName: "Dropbox", accent: Self.accent)
                .environment(\._accessibilityReduceMotion, reduceMotion)
            let before = try Self.render(page.environment(\.setupArtReveals, false), named: "\(art) before its reveal")
            let revealed = try Self.render(page, named: "\(art)")
            let changed = try Self.changedPixels(revealed, before)
            let setting = reduceMotion ? "with Reduce Motion" : "without Reduce Motion"
            if !Self.pagesWithoutAReveal.contains(art) {
                #expect(changed > 1_000,
                        "\(art) draws the same before and after it appears \(setting) (\(changed) pixels changed) — its reveal no longer runs")
            } else if reduceMotion {
                #expect(changed == 0,
                        "\(art) now changes when it appears \(setting) (\(changed) pixels) — it has a reveal; take it out of pagesWithoutAReveal so the reveal is held to it")
            }
        }
    }

    /// Pixels whose bytes differ between two renders — exact, which is meaningful because both
    /// came through `render(_:named:)` into one context format.
    static func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> Int {
        try #require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh
                     && a.bytesPerRow == b.bytesPerRow && a.bitsPerPixel == 32 && b.bitsPerPixel == 32,
                     "the two renders do not share a format, so their bytes cannot be compared")
        let first = UnsafeRawPointer(try #require(a.bitmapData))
        let second = UnsafeRawPointer(try #require(b.bitmapData))
        var changed = 0
        for y in 0..<a.pixelsHigh {
            let row = y * a.bytesPerRow
            for x in 0..<a.pixelsWide {
                let offset = row + x * 4
                if first.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    != second.loadUnaligned(fromByteOffset: offset, as: UInt32.self) { changed += 1 }
            }
        }
        return changed
    }
}
