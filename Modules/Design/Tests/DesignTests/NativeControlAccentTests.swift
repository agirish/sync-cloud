import AppKit
import SwiftUI
import Testing
@testable import Design

/// **A window's native controls fill with the app's hue, and its buttons' words stay label
/// colour (DS4).**
@Suite struct NativeControlAccentTests {

    /// A named hue fills with its deepened accent — the colour its checkbox and radio marks are
    /// white on — and `.none` sets nothing, leaving the Mac's own.
    @Test func eachHueFillsWithItsDeepenedAccentAndNoneLeavesTheMacs() throws {
        func srgb(_ c: Color?) -> [CGFloat]? {
            c.flatMap { NSColor($0).usingColorSpace(.sRGB) }.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] }
        }
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = try #require(srgb(NativeControlAccent.color(for: hue)), "\(hue.displayName) has no fill")
            let expected = try #require(srgb(hue.accentFillColor))
            #expect(zip(fill, expected).allSatisfy { abs($0 - $1) < 0.002 }, "\(hue.displayName) fills with \(fill)")
        }
        // Coral is one the deepening moves, so a fill of the raw accent fails above.
        #expect(srgb(LiquidGlassHue.coral.accentFillColor) != srgb(LiquidGlassHue.coral.accentColor))
        #expect(NativeControlAccent.color(for: .none) == nil)
    }
}

/// Rendered and read back: under Coral a slider's track and a checkbox's box are the deepened coral
/// — and a bordered button's label has none of it, which is what `.tint` would have done to it.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct NativeControlAccentRenderTests {

    static let size = CGSize(width: 240, height: 34)

    static func render(_ control: some View, hue: LiquidGlassHue?, dark: Bool = false) throws -> NSBitmapImageRep {
        let base = control
            .padding(6)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(dark ? Color(white: 0.13) : Color(white: 0.96))
        let root: AnyView = hue.map { AnyView(base.nativeControlAccent($0)) } ?? AnyView(base)
        let host = NSHostingView(rootView: root
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        return rep
    }

    /// Pixels within 12/255 of `color` on every channel, read as raw bytes.
    static func count(_ rep: NSBitmapImageRep, near color: Color) -> Int {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let want = [Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255))]
        var n = 0
        var p = [Int](repeating: 0, count: 4)
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            rep.getPixel(&p, atX: x, y: y)
            if (0..<3).allSatisfy({ abs(p[$0] - want[$0]) <= 12 }) { n += 1 }
        } }
        return n
    }

    static let coral = LiquidGlassHue.coral.accentFillColor
    static let systemAccent = Color(nsColor: .controlAccentColor)

    /// The known swatch reads back exactly, or no count below means anything.
    @Test func theProbeReadsAKnownSwatch() throws {
        let rep = try Self.render(Rectangle().fill(Self.coral).frame(width: 40, height: 20), hue: nil)
        #expect(Self.count(rep, near: Self.coral) > 400, "a coral swatch does not read back as coral")
    }

    @Test(arguments: [false, true]) func theSliderAndCheckboxFillWithTheHue(dark: Bool) throws {
        let slider = Slider(value: .constant(0.6)).frame(width: 200)
        let checkbox = Toggle("Checkbox", isOn: .constant(true)).toggleStyle(.checkbox)
        for (name, view) in [("slider", AnyView(slider)), ("checkbox", AnyView(checkbox))] {
            let coral = try Self.render(view, hue: .coral, dark: dark)
            let bare = try Self.render(view, hue: nil, dark: dark)
            #expect(Self.count(coral, near: Self.coral) > 60, "the \(name) is not filled with Coral")
            #expect(Self.count(bare, near: Self.coral) == 0, "the \(name) is Coral with no accent set — the probe proves nothing")
            #expect(Self.count(coral, near: Self.systemAccent) < 5, "the \(name) still shows the Mac's accent under Coral")
        }
    }

    /// **The reason this is the accent colour and not `.tint`**: a bordered button's words keep
    /// their label colour. `.tint` turned them the hue — measured, about 950 hued pixels on this
    /// button.
    @Test func aBorderedButtonsWordsStayLabelColour() throws {
        let button = Button("Bordered button") {}.buttonStyle(.bordered)
        let rep = try Self.render(button, hue: .coral)
        #expect(Self.count(rep, near: Self.coral) < 5, "the bordered button's words took the hue")
        // ...and the same button under `.tint` does take it, so the probe can see it.
        let tinted = try Self.render(button.tint(Self.coral), hue: nil)
        #expect(Self.count(tinted, near: Self.coral) > 60, "a tinted button shows no coral — the probe proves nothing")
    }

    /// **The None swatch stays the Mac's accent inside a Coral window.** `LiquidGlassHue.none` was
    /// `Color.accentColor`, which resolves to the accent the ENVIRONMENT carries — so under a root
    /// that sets Coral, Setup's None swatch filled with Coral.
    @Test func theNoneHueIsTheMacsAccentUnderAnotherHuesRoot() throws {
        let swatch = Circle().fill(LiquidGlassHue.none.accentColor).frame(width: 24, height: 24)
        let rep = try Self.render(swatch, hue: .coral)
        #expect(Self.count(rep, near: Self.systemAccent) > 200, "the None swatch is not the Mac's accent")
        #expect(Self.count(rep, near: Self.coral) == 0, "the None swatch took the window's Coral")
    }

    /// Presents `content` as a sheet from a window whose root sets `hue`, and renders the SHEET's
    /// window. The parent is ordered in — a sheet presents only from a visible window — and buried
    /// under everything, so it never stands over the owner's screen.
    static func renderSheet(_ content: some View, root hue: LiquidGlassHue) throws -> NSBitmapImageRep {
        let presenter = Color.clear
            .frame(width: 320, height: 160)
            .sheet(isPresented: .constant(true)) {
                // The sheet is its own window, with its own active state: an inactive one draws
                // its controls grey whatever the accent.
                content.padding(16).frame(width: size.width, height: 60, alignment: .leading)
                    .environment(\.controlActiveState, .key)
            }
            .nativeControlAccent(hue)
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: presenter)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.contentView = host
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }
        #expect(window.level.rawValue == Int(CGWindowLevelForKey(.minimumWindow)), "the presenter is not buried")
        let deadline = Date().addingTimeInterval(10)
        while window.attachedSheet == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let sheet = try #require(window.attachedSheet, "the sheet never presented")
        let view = try #require(sheet.contentView)
        #expect(sheet.level.rawValue <= window.level.rawValue, "the sheet is not buried with its parent: level \(sheet.level.rawValue)")
        sheet.colorSpace = .sRGB
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// **A control in a sheet takes the presenting window's hue** (RC1). The accent colour a root
    /// sets stops at a presentation, so a sheet's slider drew the Mac's accent on a Coral window;
    /// `presentedNativeControlAccent` carries the root's hue across. The hue is the presenter's,
    /// not the stored one — Settings and Setup set their own — so the test picks one that is not
    /// stored.
    @Test func aControlInASheetTakesThePresentersHue() throws {
        let hue: LiquidGlassHue = LiquidGlassHue.stored() == .coral ? .green : .coral
        let fill = hue.accentFillColor
        let slider = Slider(value: .constant(0.6)).frame(width: 200)
        let carried = try Self.renderSheet(slider.presentedNativeControlAccent(), root: hue)
        #expect(Self.count(carried, near: fill) > 60, "the sheet's slider is not \(hue.displayName)")
        #expect(Self.count(carried, near: Self.systemAccent) < 5, "the sheet's slider still shows the Mac's accent")
        // ...and without it the sheet's slider is the Mac's, so the probe sees the bug it guards.
        let bare = try Self.renderSheet(slider, root: hue)
        #expect(Self.count(bare, near: fill) == 0, "a bare sheet's slider took the hue — the probe proves nothing")
        #expect(Self.count(bare, near: Self.systemAccent) > 60, "a bare sheet's slider is not the Mac's accent")
    }

    /// At None a sheet keeps the Mac's accent too — the carried hue sets nothing.
    @Test func aSheetUnderNoneKeepsTheMacsAccent() throws {
        let slider = Slider(value: .constant(0.6)).frame(width: 200)
        let rep = try Self.renderSheet(slider.presentedNativeControlAccent(), root: LiquidGlassHue.none)
        #expect(Self.count(rep, near: Self.systemAccent) > 60, "the sheet's slider at None is not the Mac's accent")
    }

    /// `.none` sets nothing: the slider is the Mac's accent, exactly as with no root at all.
    @Test func noneLeavesTheMacsAccent() throws {
        let slider = Slider(value: .constant(0.6)).frame(width: 200)
        let none = try Self.render(slider, hue: LiquidGlassHue.none)
        #expect(Self.count(none, near: Self.systemAccent) > 60, "the slider at None is not the Mac's accent")
    }
}
