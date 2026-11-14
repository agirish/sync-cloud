import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard
@testable import FileExplorer
import FileExplorerTestSupport

/// An Organize lens's header card against the pane's toolbar card, both real, side by side: the
/// lens half of what ``EditHeaderMatchesPaneHeaderTests`` does for Edit's document column.
///
/// The lens header card is pinned to the toolbar card's height. The pane's tab strip pushes the
/// toolbar card down by ``PaneTabStripLadder/slotHeight(_:)``, so the lens must be told about it or
/// its header sits one slot high. The pane half is ``EditHeaderMatchesPaneHeaderTests/pane(_:tabStrip:)``.
@MainActor
@Suite(.serialized) struct LensHeaderMatchesPaneHeaderTests {

    private static let paneWidth: CGFloat = 320
    private static let lensWidth: CGFloat = 560
    private static let height: CGFloat = 520

    /// Both halves in one window, the way `singleSourceLayout`'s expanded arm puts them.
    static func mount(style: SurfaceStyle, scale: CGFloat, tabStrip: Bool,
                      lensIsTold: Bool? = nil) -> NSHostingView<AnyView> {
        let defaults = ScratchDefaults("LensHeaderMatchesPaneHeaderTests")
        defaults.set(style.rawValue, forKey: LiquidGlass.surfaceStyleKey)
        defaults.set(GlassLevel.solid.rawValue, forKey: LiquidGlass.levelKey)
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: paneWidth + lensWidth, height: height)
        let host = NSHostingView(rootView: AnyView(
            HStack(spacing: 0) {
                EditHeaderMatchesPaneHeaderTests.pane(style, tabStrip: tabStrip)
                    .frame(width: paneWidth)
                LensWorkspaceView(syncManager: FileSyncManager(), lens: .duplicates,
                                  providerName: "Projects", scanTargetFolder: "/root/Documents",
                                  onFindDuplicates: {},
                                  paneShowsTabStrip: lensIsTold ?? tabStrip)
                    .frame(width: lensWidth)
            }
            .frame(width: size.width, height: size.height)
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, scale)
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The two header edges, in the window's (flipped) coordinates, by one rule for both columns.
    /// Each column's content is its tallest scroll view (the lens header's rail is a one-row one).
    /// In `.cards` the edge is the bottom of the layer-backed card just above the content; in
    /// `.unified` the content sits flush under the header, so the edge is where it starts.
    static func edges(in host: NSView, style: SurfaceStyle) -> (pane: CGFloat?, lens: CGFloat?) {
        let cards = host.subviews.map { $0.convert($0.bounds, to: host) }
        var scrolls: [CGRect] = []
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView { scrolls.append(scroll.convert(scroll.bounds, to: host)) }
            v.subviews.forEach(walk)
        }
        walk(host)
        func edge(_ inColumn: (CGRect) -> Bool) -> CGFloat? {
            guard let content = scrolls.filter(inColumn).max(by: { $0.height < $1.height })?.minY
            else { return nil }
            switch style {
            case .cards:
                return cards.filter { inColumn($0) && $0.maxY <= content + 0.5 }.map(\.maxY).max()
            case .unified:
                return content
            }
        }
        return (edge { $0.midX < paneWidth }, edge { $0.midX > paneWidth })
    }

    /// The lens header ends where the pane's toolbar card does, with one tab and with two, in both
    /// surface styles at every text size.
    /// Mutation that must fail this: dropping the slot, or leaving the gutter out in `.cards`.
    @Test func theLensHeaderEndsWhereThePanesToolbarCardDoes() throws {
        for style in [SurfaceStyle.cards, .unified] {
            for tabStrip in [false, true] {
                for size in FontSize.allCases {
                    let host = Self.mount(style: style, scale: size.scale, tabStrip: tabStrip)
                    let (pane, lens) = Self.edges(in: host, style: style)
                    let paneEdge = try #require(pane, "no pane header edge found (\(style)) — vacuous")
                    let lensEdge = try #require(lens, "no lens header card found (\(style)) — vacuous")
                    #expect(abs(paneEdge - lensEdge) < 0.51,
                            "\(style), \(tabStrip ? "two tabs" : "one tab"), \(size.percent)%: pane header ends at \(paneEdge), lens header at \(lensEdge)")
                }
            }
        }
    }

    /// The measurement can fail: a lens not told about the strip sits exactly one slot above the
    /// pane. Otherwise a measure that found the same view on both sides would pass the test above.
    @Test func aLensNotToldAboutTheStripSitsOneSlotHigh() throws {
        for style in [SurfaceStyle.cards, .unified] {
            let host = Self.mount(style: style, scale: 1, tabStrip: true, lensIsTold: false)
            let (pane, lens) = Self.edges(in: host, style: style)
            let paneEdge = try #require(pane, "no pane header edge found (\(style)) — vacuous")
            let lensEdge = try #require(lens, "no lens header card found (\(style)) — vacuous")
            #expect(abs(paneEdge - lensEdge - PaneTabStripLadder.slotHeight(style)) < 0.51,
                    "\(style): pane header ends at \(paneEdge), untold lens header at \(lensEdge)")
        }
    }
}
