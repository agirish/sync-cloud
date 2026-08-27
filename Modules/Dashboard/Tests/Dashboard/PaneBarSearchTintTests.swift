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
            isExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
            reduceMotion: false
        )
        #expect(expanded == false)
        #expect(text.isEmpty, "a query survived its field being hidden — it is now a filter with no visible carrier, and the Search rung needs a tint again")
    }

    /// The rung exists at all, and only where the host can search. Asserted in both directions
    /// because a gate answering "no" to everything is indistinguishable from one never wired: the
    /// renders below are about a control this pair proves is on the bar.
    @Test func testTheRungIsOfferedOnlyWhenTheHostCanSearch() {
        #expect(Self.header(expanded: false, query: "").availableItems.contains(.search))
        #expect(!Self.header(expanded: false, query: "", canSearch: false).availableItems.contains(.search))
    }

    /// The magnifier and the field are alternatives, never both. If the bar ever draws the
    /// magnifier *beside* an open field, "collapsed implies empty" stops covering the case where a
    /// user is typing and the glyph is also on screen.
    ///
    /// **Neither `ink > 40` nor `expanded != collapsed` was this measurement**, and the first of
    /// those mistakes has now been corrected twice on this header (see `PaneBarDeleteTests`): forty
    /// pixels of ink is met by the neighbours alone, and two renders of two different states differ
    /// in their ink totals whatever the relationship between them — that assertion held just as well
    /// for a field that joined the bar as for one that replaced it, which is the only thing this
    /// file is about.
    ///
    /// **Two readings carry it, and both are falsified by the case this file exists to catch.** A
    /// field that *joined* the bar leaves the bar's own controls on the row and adds its own, so it
    /// necessarily carries MORE than the bar alone — of both the things measured here. A field that
    /// *replaced* it carries less.
    ///
    /// The counted one is exact: each pill hosts a `_FocusRingView` (a SwiftUI `Button` with a
    /// custom style puts no `NSControl` in the tree, so the rings are the only handle on where a
    /// pill physically is), and the header's upper row goes from six of them to two when the field
    /// opens. There is no arithmetic by which a bar drawn beside the field produces fewer.
    ///
    /// Two more readings used to sit here, over the row's last 40pt, and they had to go: they
    /// located the bar as "the trailing edge", true only while a leading flexible space pinned it
    /// there. The bar packs left now and the field is capped at 460pt, so the far end of the row is
    /// empty in BOTH states — the crop had stopped telling them apart, and its own vacuity guard
    /// ("the last 40pt are not empty when collapsed") is the half that failed.
    ///
    /// The collapsed readings are the vacuity guards, deliberately loose: they say the crop and the
    /// count are looking at a bar at all, and the comparisons above them are the claim.
    @Test(.machinePinned(.pixelSampling)) func testTheFieldReplacesTheBarRatherThanJoiningIt() throws {
        let collapsed = try Self.rendered(expanded: false, query: "")
        let expanded = try Self.rendered(expanded: true, query: "invoice")

        let closedControls = Self.barRowControls(expanded: false, query: "")
        let openControls = Self.barRowControls(expanded: true, query: "invoice")
        #expect(closedControls >= 5, "the collapsed bar lays out \(closedControls) controls — this comparison would be vacuous")
        #expect(openControls < closedControls,
                "the open field's row lays out \(openControls) controls against the bar's \(closedControls) — the bar has not gone away, so the magnifier can be on screen beside a live query")

        #expect(Self.ink(collapsed) > 1000, "the collapsed bar draws almost nothing — this comparison would be vacuous")
        #expect(Self.ink(expanded) < Self.ink(collapsed),
                "the open field's row carries \(Self.ink(expanded)) px against the bar's \(Self.ink(collapsed)) — the bar is being drawn beside it")
    }

    /// How many of the bar's own controls are laid out on the header's upper row.
    static func barRowControls(expanded: Bool, query: String) -> Int {
        let defaults = ScratchDefaults("PaneBarSearchTintTests-rings")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let host = NSHostingView(rootView: AnyView(
            header(expanded: expanded, query: query)
                .defaultAppStorage(defaults)
                .frame(width: renderWidth, height: LiquidGlass.headerHeight)))
        host.frame = CGRect(x: 0, y: 0, width: renderWidth, height: LiquidGlass.headerHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var frames: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") { frames.append(v.convert(v.bounds, to: host)) }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        guard let top = frames.map(\.minY).min() else { return 0 }
        return frames.filter { abs($0.minY - top) < 2 }.count
    }

    // MARK: - Fixtures

    /// Wide enough that nothing folds into ⋯.
    private static let renderWidth: Double = 700

    private static func header(expanded: Bool, query: String, canSearch: Bool = true) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            searchText: canSearch ? .constant(query) : nil,
            searchIsExpanded: canSearch ? .constant(expanded) : nil)
    }

    private static func rendered(expanded: Bool, query: String, canSearch: Bool = true) throws -> NSBitmapImageRep {
        let defaults = ScratchDefaults("PaneBarSearchTintTests-render")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: Self.renderWidth, height: LiquidGlass.headerHeight)
        let host = NSHostingView(rootView: AnyView(
            header(expanded: expanded, query: query, canSearch: canSearch)
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

    /// Pixels that depart from the background at all, over the **bar's row** — the upper of the
    /// header's two, which is the whole of what the field takes over and hands back.
    ///
    /// By row, not by column. The crop was the trailing half, a proxy for "where the bar is" that
    /// held only while the bar was pinned to the trailing edge; it packs left now.
    private static func ink(_ rep: NSBitmapImageRep) -> Int {
        var hits = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<(rep.pixelsHigh / 2) {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if px.redComponent < 0.72 || px.greenComponent < 0.72 || px.blueComponent < 0.72 { hits += 1 }
            }
        }
        return hits
    }
}
