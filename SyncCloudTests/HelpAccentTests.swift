import AppKit
import Design
import SwiftUI
import Testing
@testable import SyncCloud

/// Help wears the hue the user picked, not the system accent, which on a Coral card would light the
/// sidebar in the Mac's blue. The hue comes from a scratch suite through `defaultAppStorage` (the
/// test host is the app, so the real preference must not be read), and pixels are read back as
/// `colorAt` returns them: Coral's deepened fill must be there under Coral and absent under Green.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct HelpAccentTests {

    private func render(hue: LiquidGlassHue, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let size = CGSize(width: 820, height: 600)
        return try renderInSRGBWindow(HelpView(available: size, openAt: "browse-workspace", onClose: {})
                                          .frame(width: size.width, height: size.height)
                                          .background(scheme == .dark ? Color.black : Color.white),
                                      size: size, scheme: scheme, hue: hue)
    }

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theOpenTopicFillsWithTheHueDeepened(scheme: ColorScheme) throws {
        let fill = LiquidGlassHue.coral.accentFillColor
        let underCoral = try pixels(near: fill, in: render(hue: .coral, scheme: scheme))
        let underGreen = try pixels(near: fill, in: render(hue: .green, scheme: scheme))
        // The open row is ~200×26pt of fill, minus its label.
        #expect(underCoral > 1_000, "Help's open topic drew \(underCoral) pixels of Coral's fill in \(scheme) with Coral picked")
        #expect(underGreen == 0, "Help's open topic drew \(underGreen) pixels of Coral's fill in \(scheme) with Green picked")
    }
}
