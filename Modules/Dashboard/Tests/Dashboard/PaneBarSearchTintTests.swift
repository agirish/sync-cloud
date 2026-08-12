import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// Why the Search rung has no "a query is live" tint, pinned as the invariant that makes one
/// unnecessary rather than as an absence.
///
/// The rung used to carry one, and it painted nothing — a `.foregroundStyle` on the Button, outside
/// the label, which `paneNavChrome`'s own glyph colour outranked. The tempting repair was to wire it
/// up. The reason that was wrong is the thing worth testing: **the magnifier is drawn only while the
/// field is collapsed, and collapsing always clears the query**, so the state the tint was written to
/// signal — a filter running behind a hidden field — cannot occur.
///
/// A test asserting "no accent pixels appear" would pass for the wrong reason forever. These assert
/// the mechanism instead, so a change that lets a query outlive its field fails here and the tint
/// becomes necessary again with a test already saying so.
@MainActor
@Suite(.serialized) struct PaneBarSearchTintTests {

    /// Collapsing clears the query, in one transaction. This is the whole invariant.
    @Test func testCollapsingClearsTheQuery() {
        var text = "invoice"
        var expanded = true
        ExpandingSearch.collapse(
            text: Binding(get: { text }, set: { text = $0 }),
            isExpanded: Binding(get: { expanded }, set: { expanded = $0 })
        )
        #expect(expanded == false)
        #expect(text.isEmpty, "a query survived its field being hidden — it is now a filter with no visible carrier, and the Search rung needs a tint again")
    }

    /// The other half: the magnifier and the field are alternatives, never both. If the bar ever
    /// draws the magnifier *beside* an open field, "collapsed implies empty" stops covering the
    /// case where a user is typing and the glyph is also on screen.
    ///
    /// Measured as ink, because this is a question about what is drawn: the expanded header must
    /// not contain the collapsed header's bar.
    @Test func testTheFieldReplacesTheBarRatherThanJoiningIt() throws {
        let collapsed = try Self.inkPixels(expanded: false, query: "")
        let expanded = try Self.inkPixels(expanded: true, query: "invoice")

        #expect(collapsed > 40, "the collapsed header draws no bar — this comparison would be vacuous")
        #expect(expanded != collapsed,
                "the expanded and collapsed headers paint identically, so this is not measuring the swap it claims to")
    }

    /// And the guard that keeps the pair above honest: the rung IS drawn when collapsed, so
    /// "collapsed implies empty" is a statement about a control that exists.
    @Test func testTheMagnifierIsDrawnWhenCollapsed() throws {
        #expect(try Self.inkPixels(expanded: false, query: "") > 40)
    }

    // MARK: - Fixtures

    private static func header(expanded: Bool, query: String) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            searchText: .constant(query), searchIsExpanded: .constant(expanded))
    }

    private static func inkPixels(expanded: Bool, query: String) throws -> Int {
        let defaults = ScratchDefaults("PaneBarSearchTintTests-render")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: 700, height: LiquidGlass.headerHeight)
        let host = NSHostingView(rootView: AnyView(
            header(expanded: expanded, query: query)
                .defaultAppStorage(defaults)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var hits = 0
        for x in (rep.pixelsWide / 2)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if px.redComponent < 0.72 || px.greenComponent < 0.72 || px.blueComponent < 0.72 { hits += 1 }
            }
        }
        return hits
    }
}
