import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard
@testable import FileExplorer
import FileExplorerTestSupport

/// **An Organize lens's header card against the pane's toolbar card, both real, side by side** —
/// the lens half of what ``EditHeaderMatchesPaneHeaderTests`` does for Edit's document column.
///
/// The lens's header card is pinned to the pane's toolbar card's height so that the two share a
/// bottom edge, the pane's header↔list line. The pane's tab strip (two tabs, or View ▸ Tab Bar)
/// pushes its toolbar card down by ``PaneTabStripLadder/slotHeight(_:)``; until the lens was told
/// about it, its header stayed at the top of the column, one strip slot above the pane's — in
/// both surface styles.
///
/// The pane half is ``EditHeaderMatchesPaneHeaderTests/pane(_:tabStrip:)`` — `PaneHeader` over a
/// `List`, carded as `ContentView.paneColumn` cards them.
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

    /// The two header edges, in the window's (flipped) coordinates — one rule for both columns.
    ///
    /// Each column's content is a scroll view, the tallest in its column (the lens header's rail
    /// is a scroll view too, one row high). **In `.cards`** each section is a card, and each card
    /// is a layer-backed view of its own directly under the host, so the header's edge is the
    /// bottom of the card directly above the content's. **In `.unified`** a column is one region
    /// with its content flush under the header — the rule `columnRegionFrame` and
    /// `panesRegionFrame` both draw — so the header's edge is where the content starts.
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

    /// **The lens header ends where the pane's toolbar card does, with one tab and with two** — both
    /// surface styles, every text size. One tab draws no strip; two do, and push the pane's header
    /// down by the strip's slot. Mutation: dropping the slot fails every strip case by 34pt in
    /// `.unified` and 39pt in `.cards`; leaving the gutter out of it fails `.cards` alone.
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

    /// **The measurement can fail.** A lens not told about the strip sits one slot above the pane —
    /// the defect this suite was written for — so the edges must disagree by exactly that slot.
    /// Without this, a measure that found the same view on both sides would pass the test above.
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
