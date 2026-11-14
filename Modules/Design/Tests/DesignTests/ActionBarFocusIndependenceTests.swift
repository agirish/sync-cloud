import AppKit
import SwiftUI
import Testing
@testable import Design

/// The reason `ActionBarButtonStyle` exists: its weights survive the window losing focus.
///
/// The offscreen window these tests render into is never key, as in the live app after clicking
/// away. `.borderedProminent` vs `.bordered` is exactly the difference a window's key state
/// overrides, so a hierarchy built on them shows only while the app is frontmost.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct ActionBarFocusIndependenceTests {

    private static let canvas = CGSize(width: 120, height: 40)
    /// A point inside the capsule's left cap, clear of the label glyphs. The cap's centre sits at
    /// (14, 20) with a 14pt radius, so (8, 20) is comfortably inside the fill.
    private static let sampleAt = CGPoint(x: 8, y: 20)
    private static let tint = Color(red: 0, green: 0.44, blue: 0.91)

    /// Renders a button offscreen in a never-key window and reads the colour of its fill.
    private func fillColor<V: View>(of view: V) -> NSColor {
        let subject = view
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .leading)
            .environment(\.colorScheme, .light)
        guard let rep = offscreenBitmap(AnyView(subject), size: Self.canvas) else {
            Issue.record("no bitmap rep")
            return .clear
        }
        // colorAt takes PIXELS; the backing store is 2x on a Retina machine and 1x otherwise.
        let scale = CGFloat(rep.pixelsWide) / Self.canvas.width
        let sample = rep.colorAt(x: Int(Self.sampleAt.x * scale),
                                 y: Int(Self.sampleAt.y * scale))
        return sample?.usingColorSpace(.sRGB) ?? .clear
    }

    /// How far from gray a colour is, on 0...1. The one number that separates "still the accent"
    /// from "the system desaturated it".
    private func saturation(_ color: NSColor) -> CGFloat {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        guard let high = channels.max(), let low = channels.min(), high > 0 else { return 0 }
        return (high - low) / high
    }

    @Test func testPrimaryKeepsItsAccentFillWhenTheWindowIsNotKey() {
        let sample = fillColor(of: Button("Copy") {}
            .buttonStyle(.actionBar(.primary, tint: Self.tint, onTint: .white)))
        #expect(saturation(sample) > 0.5,
                "primary desaturated in a non-key window: \(sample)")
        // And it is the tint we asked for, not some other strong colour.
        #expect(sample.blueComponent > sample.redComponent)
    }

    @Test func testQuietKeepsItsWashWhenTheWindowIsNotKey() {
        let sample = fillColor(of: Button("Copy") {}
            .buttonStyle(.actionBar(.quiet, tint: Self.tint, onTint: .white)))
        // A 14% wash over the window background: tinted, but nowhere near the primary's strength.
        #expect(saturation(sample) > 0.05, "quiet lost its wash: \(sample)")
        #expect(sample.blueComponent > sample.redComponent)
    }

    @Test func testTheStyleItReplacesDoesNotSurviveTheSameConditions() {
        // The control: never key, the system prominent capsule is near gray (saturation ~0 vs 1).
        // A failure here means AppKit's inactive treatment changed, not `ActionBarButtonStyle`.
        let ours = fillColor(of: Button("Copy") {}
            .buttonStyle(.actionBar(.primary, tint: Self.tint, onTint: .white)))
        let system = fillColor(of: Button("Copy") {}
            .buttonStyle(.borderedProminent)
            .tint(Self.tint))
        #expect(saturation(ours) > saturation(system),
                "ours \(saturation(ours)) vs system \(saturation(system))")
    }
}
