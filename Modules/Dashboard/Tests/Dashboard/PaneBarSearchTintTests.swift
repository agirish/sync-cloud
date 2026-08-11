import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// The Search rung's "a query is live" tint, measured in paint.
///
/// The rung's own comment promises it: "Tinted whenever a query is live, so a search narrowing what
/// you are looking at can never be silently on behind a quiet glyph." Whether it arrives is not
/// something the source can be read for — `paneNavChrome` applies its own `.foregroundStyle` to the
/// glyph, and the application closest to the leaf wins — so this counts accent pixels in the two
/// states and compares them.
///
/// It did not arrive. As shipped, the tint was a `.foregroundStyle` on the BUTTON, outside the
/// label, and both states measured **0 accent pixels**: the promise in the rung's comment had been
/// false since the day it was written, three lines above the code that broke it. Through `ink:` the
/// live query measures **186**. The same mistake in the same file was caught in the Delete rung by
/// the same kind of count — which is the argument for this file existing rather than a source scan
/// asserting that some `.foregroundStyle` is present somewhere.
@MainActor
@Suite(.serialized) struct PaneBarSearchTintTests {

    /// A live query must make the magnifier wear the accent. Same fixture, same size, same
    /// appearance; the ONLY difference between the two renders is the query string.
    @Test func testALiveQueryTintsTheMagnifier() throws {
        let quiet = try Self.accentPixels(query: "")
        let live = try Self.accentPixels(query: "invoice")

        #expect(live > quiet + 20,
                "a live query paints \(live) accent px against \(quiet) with no query — the rung's tint is not reaching the glyph")
    }

    /// The guard on the comparison above: both renders must actually contain a magnifier, or
    /// "no difference" would be measuring two empty crops.
    @Test func testTheRungIsDrawnInBothStates() throws {
        for query in ["", "invoice"] {
            #expect(try Self.inkPixels(query: query) > 40,
                    "no glyph painted in the search cell for query '\(query)'")
        }
    }

    // MARK: - Fixtures

    /// Collapsed field, live query — the state the tint exists for. `searchIsExpanded` false is not
    /// a contrivance: it is precisely when the query has no other carrier on screen.
    private static func header(query: String) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            searchText: .constant(query), searchIsExpanded: .constant(false))
    }

    private static func rendered(query: String) throws -> NSBitmapImageRep {
        let defaults = ScratchDefaults("PaneBarSearchTintTests-render")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: 700, height: LiquidGlass.headerHeight)
        let host = NSHostingView(rootView: AnyView(
            header(query: query)
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
        return rep
    }

    /// Blue-leaning pixels in the bar's half of the header. The trailing half only: the provider
    /// capsule carries iCloud's own blue, and a crop spanning it would drown the signal.
    private static func accentPixels(query: String) throws -> Int {
        try count(query: query) { px in
            px.blueComponent - px.redComponent > 0.15 && px.blueComponent - px.greenComponent > 0.05
        }
    }

    private static func inkPixels(query: String) throws -> Int {
        try count(query: query) { px in
            px.redComponent < 0.72 || px.greenComponent < 0.72 || px.blueComponent < 0.72
        }
    }

    private static func count(query: String, where matches: (NSColor) -> Bool) throws -> Int {
        let rep = try rendered(query: query)
        var hits = 0
        for x in (rep.pixelsWide / 2)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if matches(px) { hits += 1 }
            }
        }
        return hits
    }
}
