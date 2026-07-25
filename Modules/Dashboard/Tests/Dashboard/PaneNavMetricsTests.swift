import AppKit
import SwiftUI
import Testing
@testable import Dashboard
import Design

/// Measures a control the way AppKit will. Same rig as `PaneHeaderHeightTests`, and for the same
/// reason: these are claims about the LAID-OUT result, and a suite that only compared constants
/// to each other is exactly what let this drift in the first place.
@MainActor
private func laidOutSize<V: View>(_ view: V) -> CGSize {
    let host = NSHostingView(rootView: AnyView(view))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
}

/// The pane header's nav cluster has to read as one row of identical pills.
///
/// It didn't. Liquid Glass sizes a button from its label, so the six glyphs gave six different
/// pills — `chevron.left` 29x18, `arrow.up.arrow.down` 35x19, `eye.slash` 37x20 — and the sort
/// menu came in at 35x14, visibly the runt of the row. Two rounds of fixes aimed at the chrome
/// missed it completely, because the cause was never the chrome.
@MainActor
@Suite(.serialized) struct PaneNavMetricsTests {

    /// Every glyph the cluster draws. If one is added without a frame, this catches it.
    private static let glyphs = [
        "sidebar.left", "chevron.left", "chevron.right",
        "arrow.clockwise", "arrow.up.arrow.down", "eye", "eye.slash"
    ]

    @available(macOS 26.0, *)
    private func navButton(_ symbol: String, _ controlSize: ControlSize) -> some View {
        Button {} label: {
            Image(systemName: symbol).frame(height: PaneNavMetrics.glyphHeight)
        }
        .buttonStyle(.glass)
        .controlSize(controlSize)
    }

    @Test("Every nav glyph resolves to the same pill height, at both control sizes")
    func glyphsShareOneHeight() throws {
        guard #available(macOS 26.0, *) else { return }
        for controlSize in [ControlSize.small, .mini] {
            let heights = Self.glyphs.map { laidOutSize(navButton($0, controlSize)).height }
            let first = try #require(heights.first)
            for (symbol, height) in zip(Self.glyphs, heights) {
                #expect(height == first,
                        "\(symbol) at \(controlSize) is \(height)pt, not \(first) — the frame is missing")
            }
        }
    }

    @Test("Levelling the heights costs the cluster no width")
    func widthsAreUntouched() {
        guard #available(macOS 26.0, *) else { return }
        // The whole reason this pins height and not size. An earlier version framed both axes,
        // which made every pill as wide as the widest glyph, grew the cluster from 226.5pt to
        // 252pt, and collided the controls in a 250pt pane.
        for controlSize in [ControlSize.small, .mini] {
            for symbol in Self.glyphs {
                let framed = laidOutSize(navButton(symbol, controlSize)).width
                let bare = laidOutSize(
                    Button {} label: { Image(systemName: symbol) }
                        .buttonStyle(.glass).controlSize(controlSize)
                ).width
                #expect(framed == bare,
                        "\(symbol) at \(controlSize) went from \(bare)pt to \(framed)pt wide")
            }
        }
    }

    @Test("The frame is what makes them uniform, not luck")
    func withoutTheFrameTheyDiverge() {
        guard #available(macOS 26.0, *) else { return }
        // Guards the test above from passing vacuously: if these symbols ever happened to share
        // an intrinsic size, `glyphsAreUniform` would hold with the frame removed and stop
        // protecting anything.
        let bare = Self.glyphs.map { symbol in
            laidOutSize(
                Button {} label: { Image(systemName: symbol) }
                    .buttonStyle(.glass).controlSize(.small)
            )
        }
        #expect(Set(bare.map(\.height)).count > 1,
                "the raw symbols now share a height — this suite no longer proves anything")
    }

    @Test("The sort menu matches the buttons beside it")
    func sortMenuMatchesItsSiblings() {
        guard #available(macOS 26.0, *) else { return }
        for controlSize in [ControlSize.small, .mini] {
            let button = laidOutSize(navButton("chevron.left", controlSize))
            let menu = laidOutSize(
                Menu { Button("Name") {} } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(height: PaneNavMetrics.glyphHeight)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.glass)
                .controlSize(controlSize)
                .frame(height: PaneNavMetrics.pillHeight(controlSize))
            )
            #expect(menu.height == button.height,
                    "sort menu is \(menu.height)pt against the buttons' \(button.height)pt at \(controlSize)")
        }
    }

    @Test("pillHeight tracks what a normalised button actually measures")
    func pillHeightMatchesReality() {
        guard #available(macOS 26.0, *) else { return }
        // The constant exists only to be handed to the menu, so it has to keep agreeing with the
        // buttons it is standing in for — otherwise the row silently goes ragged again.
        for controlSize in [ControlSize.small, .mini] {
            let measured = laidOutSize(navButton("chevron.left", controlSize)).height
            #expect(PaneNavMetrics.pillHeight(controlSize) == measured,
                    "pillHeight(\(controlSize)) says \(PaneNavMetrics.pillHeight(controlSize)), AppKit says \(measured)")
        }
    }

    @Test("The levelled height leaves room inside the pill for every symbol")
    func symbolsFitTheirPills() {
        guard #available(macOS 26.0, *) else { return }
        // The glyph frame is a layout height, not a clip, so a taller symbol overflows it rather
        // than being cut — but it must still fit inside the pill the frame produces, or it would
        // graze the chrome. `eye.slash` and `arrow.clockwise` are the tall ones, at 16pt.
        for controlSize in [ControlSize.small, .mini] {
            for symbol in Self.glyphs {
                let intrinsic = laidOutSize(Image(systemName: symbol)).height
                #expect(PaneNavMetrics.pillHeight(controlSize) >= intrinsic,
                        "\(symbol) is \(intrinsic)pt tall in a \(PaneNavMetrics.pillHeight(controlSize))pt pill")
            }
        }
    }
}
