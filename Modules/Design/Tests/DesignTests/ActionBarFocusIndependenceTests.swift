import AppKit
import SwiftUI
import Testing
@testable import Design

/// The reason `ActionBarButtonStyle` exists, asserted rather than asserted-in-a-comment.
///
/// The offscreen window these tests render into is never key — the same condition as the live app
/// when you click away from it, and the reason `SNAPSHOTS.md` warns that system controls render in
/// their gray inactive style here. So this file is a ready-made rig for the exact question: does a
/// weight survive the window losing focus?
///
/// The old header carried its hierarchy in `.borderedProminent` vs `.bordered`, which is precisely
/// the difference the window's key state overrides — so the ordering it computed was visible only
/// while the app was frontmost. These tests pin that the replacement isn't.
@MainActor
@Suite(.serialized) struct ActionBarFocusIndependenceTests {

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

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap rep")
            return .clear
        }
        host.cacheDisplay(in: host.bounds, to: rep)
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
        // The control, and the whole argument in one assertion: rendered side by side under
        // identical never-key conditions, the system prominent capsule is markedly closer to gray
        // than ours. Measured, not assumed: ours samples at saturation 1.0 and the system capsule
        // at 0.0 — a flat gray — so the comparison has real room in it rather than passing by a
        // hair. A failure here means AppKit's inactive treatment changed; read it as the premise
        // moving, not as `ActionBarButtonStyle` breaking.
        let ours = fillColor(of: Button("Copy") {}
            .buttonStyle(.actionBar(.primary, tint: Self.tint, onTint: .white)))
        let system = fillColor(of: Button("Copy") {}
            .buttonStyle(.borderedProminent)
            .tint(Self.tint))
        #expect(saturation(ours) > saturation(system),
                "ours \(saturation(ours)) vs system \(saturation(system))")
    }
}
