import AppKit
import Design
import SwiftUI
import Testing
@testable import SyncCloud

/// **The guided setup's words and glyphs wear the hue the user picked.**
///
/// They drew in `.foregroundStyle(.tint)`, and nothing above the sheet set a tint — so each was the
/// SYSTEM accent: on a Coral sheet the welcome card's numbers, the Why panels' examples, the ticked
/// chips and the tour's lit marks stayed the Mac's blue, even on the Appearance screen while the hue
/// changed around them. Each now names the hue's raw accent. The pixels are read back as `colorAt`
/// returns them from an sRGB window: Coral's accent must be there with Coral picked and absent with
/// Green, so a reading cannot pass by Coral being hard-wired. Nothing here sets a `.tint`, so a site
/// that went back to one draws the system's again and fails. The hue is also stored in a scratch
/// suite, because the test host IS the app and must not read his real preference.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct SetupAccentTests {

    /// `view` drawn at `scale` times its size — so a caption's stems hold whole pixels of their
    /// colour — in an sRGB window of `scheme`, with `hue` stored.
    private func render(_ view: some View, size: CGSize, scale: CGFloat, hue: LiquidGlassHue,
                        scheme: ColorScheme) throws -> NSBitmapImageRep {
        let store = TestDefaults()
        store.defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: scaled.width, height: scaled.height, alignment: .topLeading)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            .environment(\.setupArtReveals, false)
            .defaultAppStorage(store.defaults)))
        host.frame = CGRect(origin: .zero, size: scaled)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels within 0.02 of Coral's raw accent on every channel, read from `colorAt` as-is.
    private func coralPixels(in rep: NSBitmapImageRep) throws -> Int {
        let target = try #require(NSColor(LiquidGlassHue.coral.accentColor).usingColorSpace(.sRGB))
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - target.redComponent), abs(c.greenComponent - target.greenComponent),
                       abs(c.blueComponent - target.blueComponent)) < 0.02 { n += 1 }
            }
        }
        return n
    }

    /// Coral's pixels in `make(hue)` drawn with `hue` picked, under Coral and under Green.
    private func readings(_ make: (LiquidGlassHue) -> some View, size: CGSize, scale: CGFloat,
                          scheme: ColorScheme) throws -> (coral: Int, green: Int) {
        (try coralPixels(in: render(make(.coral), size: size, scale: scale, hue: .coral, scheme: scheme)),
         try coralPixels(in: render(make(.green), size: size, scale: scale, hue: .green, scheme: scheme)))
    }

    private func expectWearsTheHue(_ make: (LiquidGlassHue) -> some View, size: CGSize, scale: CGFloat = 2,
                                   atLeast minimum: Int, _ what: String) throws {
        for scheme in [ColorScheme.light, .dark] {
            let (coral, green) = try readings(make, size: size, scale: scale, scheme: scheme)
            #expect(coral >= minimum, "\(what) drew \(coral) Coral pixels in \(scheme) with Coral picked — not the app's hue")
            #expect(green == 0, "\(what) drew \(green) Coral pixels in \(scheme) with Green picked — the hue is not read")
        }
    }

    @Test func theWhyPanelsExamplesWearTheHue() throws {
        let size = CGSize(width: 240, height: 260)
        try expectWearsTheHue({ YouWhy(hue: $0, firstName: "Abhishek") }, size: size, atLeast: 200,
                              "You's Why panel, the name in the example")
        try expectWearsTheHue({ CountriesWhy(hue: $0, folderName: "Documents") }, size: size, atLeast: 200,
                              "Countries' Why panel, \"US · IN\"")
        try expectWearsTheHue({ LearnWhy(hue: $0, folderName: "Documents") }, size: size, atLeast: 200,
                              "Learn's Why panel, the filed examples")
    }

    @Test func aTickedChipAndAnAddChipWearTheHue() throws {
        let size = CGSize(width: 160, height: 30)
        try expectWearsTheHue({ SetupChip(mark: .tick(true), title: "Abhishek", isFilled: true,
                                          accent: $0.accentColor) },
                              size: size, scale: 4, atLeast: 1_000, "a ticked chip's tick")
        try expectWearsTheHue({ SetupChip(mark: .add, title: "Priya", accent: $0.accentColor) },
                              size: size, scale: 4, atLeast: 10, "an add chip's +")
    }

    /// The numbers down the welcome card, told from its tour art by drawing it again without the rows.
    @Test func theWelcomeCardsNumbersWearTheHue() throws {
        let size = CGSize(width: 560, height: 520)
        for scheme in [ColorScheme.light, .dark] {
            let rows = try readings({ WelcomeScreen(paneNames: ("iCloud", "Dropbox"), hue: $0) },
                                    size: size, scale: 1, scheme: scheme)
            let bare = try readings({ WelcomeScreen(paneNames: ("iCloud", "Dropbox"), hue: $0, rows: []) },
                                    size: size, scale: 1, scheme: scheme)
            #expect(rows.coral - bare.coral >= 100,
                    "the welcome card's numbers drew \(rows.coral - bare.coral) Coral pixels in \(scheme) with Coral picked")
            #expect(rows.green == 0, "the welcome card drew \(rows.green) Coral pixels in \(scheme) with Green picked")
        }
    }

    /// Each tour page that lights something lights it in the hue — revealed, through the tour's own
    /// renderer, since most pages draw their lit marks only once the reveal runs.
    @Test(arguments: [SetupArt.Art.browse, .transfer, .duplicates, .filing, .edit])
    func aTourPageLightsInTheHue(art: SetupArt.Art) throws {
        for scheme in [ColorScheme.light, .dark] {
            func page(_ hue: LiquidGlassHue) throws -> Int {
                let store = TestDefaults()
                store.defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)
                let view = SetupIllustration(art: art, leftName: "iCloud", rightName: "Dropbox",
                                             accent: hue.accentColor)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme)
                    .defaultAppStorage(store.defaults)
                return try coralPixels(in: SetupArtworkRenderTests.render(view, named: "\(art)"))
            }
            let coral = try page(.coral)
            let green = try page(.green)
            #expect(coral >= 200, "the \(art) tour page drew \(coral) Coral pixels in \(scheme) with Coral picked")
            #expect(green == 0, "the \(art) tour page drew \(green) Coral pixels in \(scheme) with Green picked")
        }
    }
}
