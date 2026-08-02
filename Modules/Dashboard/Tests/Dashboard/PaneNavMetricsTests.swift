import AppKit
import SwiftUI
import Testing
@testable import Dashboard
import Design

/// The pane header's nav cluster: one row of identical pills that visibly respond to the pointer.
///
/// This suite measures **painted pixels**, not frames, and that distinction is the whole point.
/// An earlier version asserted `fittingSize` and passed green while the sort menu still rendered
/// a 14pt pill inside the 20pt box it had been handed — an outer `.frame(height:)` never stretched
/// a system-drawn control, it only gave it more room to sit in. Three rounds of "fixes" shipped
/// against that false green. Everything here reads the bitmap.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneNavMetricsTests {

    private static let box = CGSize(width: 120, height: 60)

    private func bitmap<V: View>(_ view: V) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: Self.box.width, height: Self.box.height).background(Color.white)
        ))
        host.frame = CGRect(origin: .zero, size: Self.box)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Bounding box of everything the view actually paints, in points.
    private func paintedSize<V: View>(_ view: V) -> CGSize {
        guard let rep = bitmap(view) else { return .zero }
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                guard c.alphaComponent > 0.05, luminance < 0.97 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        let scale = CGFloat(rep.pixelsHigh) / Self.box.height
        return CGSize(width: (CGFloat(maxX - minX + 1) / scale).rounded(),
                      height: (CGFloat(maxY - minY + 1) / scale).rounded())
    }

    /// Mean accent-channel lift across the render — rises when the capsule takes the tint.
    private func tintStrength<V: View>(_ view: V) -> Double {
        guard let rep = bitmap(view) else { return 0 }
        var total = 0.0
        var counted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Pure-blue accent: how far blue runs ahead of the other two channels.
                total += c.blueComponent - (c.redComponent + c.greenComponent) / 2
                counted += 1
            }
        }
        return counted == 0 ? 0 : total / Double(counted)
    }

    private static let glyphs = [
        "sidebar.left", "chevron.left", "chevron.right",
        "arrow.clockwise", "arrow.up.arrow.down", "eye", "eye.slash"
    ]

    private let accent = Color(red: 0, green: 0, blue: 1)

    private func navButton(_ symbol: String, _ controlSize: ControlSize,
                           phase: HoverAffordancePhase = .rest,
                           enabled: Bool = true) -> some View {
        Image(systemName: symbol)
            .paneNavChrome(accent: accent, controlSize: controlSize)
            .environment(\.hoverAffordancePhase, phase)
            .disabled(!enabled)
    }

    private func sortMenu(_ controlSize: ControlSize,
                          phase: HoverAffordancePhase = .rest) -> some View {
        Menu {
            Button("Name") {}
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .paneNavChrome(accent: accent, controlSize: controlSize)
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .environment(\.hoverAffordancePhase, phase)
    }

    // MARK: - Size

    @Test("Every nav glyph paints the same pill")
    func glyphPillsAreIdentical() {
        for controlSize in [ControlSize.small, .mini] {
            let expected = PaneNavMetrics.pill(controlSize)
            for symbol in Self.glyphs {
                let painted = paintedSize(navButton(symbol, controlSize))
                #expect(painted == expected,
                        "\(symbol) at \(controlSize) painted \(painted), not \(expected)")
            }
        }
    }

    @Test("The sort menu paints the same pill as the buttons")
    func sortMenuMatchesItsSiblings() {
        // The one that defeated three previous attempts. `ButtonMenuStyle` pins its own height, so
        // while the menu drew its own chrome this was 14pt against the buttons' 20 — and an outer
        // frame could not budge it. It matches now only because the app draws the capsule.
        for controlSize in [ControlSize.small, .mini] {
            let button = paintedSize(navButton("chevron.left", controlSize))
            let menu = paintedSize(sortMenu(controlSize))
            #expect(menu == button,
                    "sort menu paints \(menu), buttons paint \(button) at \(controlSize)")
        }
    }

    @Test("The mini rung is genuinely smaller, so the ladder still has two steps")
    func miniIsSmallerThanSmall() {
        let small = paintedSize(navButton("chevron.left", .small))
        let mini = paintedSize(navButton("chevron.left", .mini))
        #expect(mini.width < small.width)
        #expect(mini.height < small.height)
    }

    // Two tests lived here — `clusterMatchesTheHistoricalLadder` and `clusterWidthIsHonest` — and
    // both asked about `PaneNavMetrics.clusterWidth`, a constant describing a bar of exactly six
    // controls. The bar's length is now whatever the user arranged, so that constant went, and these
    // went with it. What they were really guarding is asserted closer to the thing itself: the pill's
    // painted size directly above, and which rung a 250pt pane picks by the narrow snapshots in
    // `DashboardSnapshotTests`.

    // MARK: - Hover

    @Test("Hovering visibly tints the pill")
    func hoverIsVisible() {
        // The assertion three shipped attempts would have failed. Each depended on Liquid Glass
        // rendering something — a halo, a saturation filter, a wash behind a translucent chrome —
        // and none of them put a single accent pixel on screen.
        for controlSize in [ControlSize.small, .mini] {
            let rest = tintStrength(navButton("chevron.left", controlSize, phase: .rest))
            let hover = tintStrength(navButton("chevron.left", controlSize, phase: .hover))
            #expect(hover > rest + 0.01,
                    "no visible tint at \(controlSize): rest \(rest), hover \(hover)")
        }
    }

    @Test("Pressing reads deeper than hovering")
    func pressIsDeeperThanHover() {
        let hover = tintStrength(navButton("chevron.left", .small, phase: .hover))
        let pressed = tintStrength(navButton("chevron.left", .small, phase: .pressed))
        #expect(pressed > hover, "press \(pressed) is not deeper than hover \(hover)")
    }

    @Test("The sort menu hovers too, not just the buttons")
    func sortMenuHovers() {
        let rest = tintStrength(sortMenu(.small, phase: .rest))
        let hover = tintStrength(sortMenu(.small, phase: .hover))
        #expect(hover > rest + 0.01, "sort menu shows no tint: rest \(rest), hover \(hover)")
    }

    // MARK: - Disabled

    @Test("A disabled control stays completely inert")
    func disabledNeverLightsUp() {
        // `canGoBack` is false at the top of a tree. A Back arrow that lit up there would promise
        // a click that does nothing — worse than no hover at all.
        let rest = tintStrength(navButton("chevron.left", .small, phase: .rest, enabled: false))
        let hover = tintStrength(navButton("chevron.left", .small, phase: .hover, enabled: false))
        #expect(abs(hover - rest) < 0.001, "a disabled arrow responded to the pointer")
    }

    @Test("Disabled still reads as disabled")
    func disabledLooksDisabled() {
        // Drawing our own chrome means the greyed-out look is ours to supply too — the system
        // style is no longer doing it for us, and losing it would make an inert control look live.
        let enabled = bitmap(navButton("chevron.left", .small, enabled: true))
        let disabled = bitmap(navButton("chevron.left", .small, enabled: false))
        var differing = 0
        if let e = enabled, let d = disabled {
            for x in stride(from: 0, to: e.pixelsWide, by: 2) {
                for y in stride(from: 0, to: e.pixelsHigh, by: 2) {
                    let ec = e.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    let dc = d.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    guard let ec, let dc else { continue }
                    if abs(ec.brightnessComponent - dc.brightnessComponent) > 0.01 { differing += 1 }
                }
            }
        }
        #expect(differing > 20, "disabled renders indistinguishably from enabled")
    }
}
