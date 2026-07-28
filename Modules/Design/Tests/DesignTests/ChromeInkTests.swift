import AppKit
import SwiftUI
import Testing
@testable import Design

/// `ChromeInk` brightens chrome labels on a dark appearance only. Two things have to be true and
/// neither is readable from the rule alone: the ink has to reach the rendered control, and the
/// states that are supposed to stay quiet — disabled above all — have to stay quiet.
@MainActor
@Suite(.serialized) struct ChromeInkTests {

    // MARK: The rule

    @Test func darkTakesPrimaryAndLightIsUntouched() {
        #expect(ChromeInk.label(.dark, light: .red) == .primary)
        #expect(ChromeInk.label(.light, light: .red) == .red)
        #expect(ChromeInk.label(.light, light: .secondary) == .secondary)
    }

    /// The optional form hands dark back to the label hierarchy rather than to a flat colour, and
    /// leaves light alone — including the no-provider case, where there was no tint to begin with.
    @Test func tintDropsOnDarkAndSurvivesOnLight() {
        #expect(ChromeInk.tint(.dark, light: .red) == nil)
        #expect(ChromeInk.tint(.light, light: .red) == .red)
        #expect(ChromeInk.tint(.light, light: nil) == nil)
        #expect(ChromeInk.tint(.dark, light: nil) == nil)
    }

    // MARK: What actually paints

    /// The two weights that changed, measured through the real button style. A filled-square glyph
    /// stands in for the label so the sample lands on ink rather than on antialiased text.
    @Test func darkLabelsPaintBrighterThanLightOnes() {
        for weight in [ActionBarWeight.quiet, .outline] {
            let dark = inkLuminance(weight, appearance: .darkAqua, enabled: true)
            let light = inkLuminance(weight, appearance: .aqua, enabled: true)
            #expect(dark > 0.85, "\(weight.rawValue) dark ink should be near-white, got \(dark)")
            #expect(dark > light, "\(weight.rawValue): dark \(dark) should out-read light \(light)")
        }
    }

    /// `.primary` weight is deliberately NOT routed through `ChromeInk` — it already carries
    /// `onTint` on a deepened fill. Pinned so a later tidy-up doesn't fold it in and quietly change
    /// the one weight whose contrast is already guaranteed by `AccentFill`.
    @Test func primaryWeightIsUnchangedByAppearance() {
        let dark = inkLuminance(.primary, appearance: .darkAqua, enabled: true)
        let light = inkLuminance(.primary, appearance: .aqua, enabled: true)
        #expect(abs(dark - light) < 0.02, "primary should not shift with appearance")
    }

    /// The guard rail. A disabled control keeps `ActionBarMetrics.disabledOpacity` over the whole
    /// capsule, so brightening the ink must not make it read as live.
    @Test func disabledStaysQuietterThanEnabledInDark() {
        for weight in [ActionBarWeight.quiet, .outline] {
            let on = inkLuminance(weight, appearance: .darkAqua, enabled: true)
            let off = inkLuminance(weight, appearance: .darkAqua, enabled: false)
            #expect(off < on, "\(weight.rawValue): disabled \(off) must stay under enabled \(on)")
        }
    }

    // MARK: Rig

    /// Renders one action-bar button over a mid-tone backdrop and returns the luminance of the
    /// brightest pixel in its middle — the glyph's ink.
    private func inkLuminance(_ weight: ActionBarWeight,
                              appearance: NSAppearance.Name,
                              enabled: Bool) -> Double {
        let size = CGSize(width: 80, height: 44)
        let button = Button { } label: { Image(systemName: "square.fill") }
            .buttonStyle(.actionBar(weight, tint: Color(red: 0.2, green: 0.7, blue: 0.5),
                                    onTint: .white, iconOnly: true))
            .disabled(!enabled)
        let scene = ZStack { Color(white: 0.30); button }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

        let host = NSHostingView(rootView: AnyView(scene))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return .nan }
        host.cacheDisplay(in: host.bounds, to: rep)

        let scale = Double(rep.pixelsWide) / Double(size.width)
        var best = 0.0
        for y in stride(from: 16.0, through: 28.0, by: 1.0) {
            for x in stride(from: 32.0, through: 48.0, by: 1.0) {
                guard let px = rep.colorAt(x: Int(x * scale), y: Int(y * scale)) else { continue }
                let l = 0.2126 * Double(px.redComponent) + 0.7152 * Double(px.greenComponent)
                      + 0.0722 * Double(px.blueComponent)
                best = max(best, l)
            }
        }
        return best
    }
}
