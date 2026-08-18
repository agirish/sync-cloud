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
    /// those mistakes has now been corrected twice on this header (see `PaneBarDeleteTests`): the
    /// crop is the trailing HALF of a 700pt bar holding six rungs, so forty pixels of ink is met by
    /// the neighbours alone, and two renders of two different states differ in their ink totals
    /// whatever the relationship between them — that assertion held just as well for a field that
    /// joined the bar as for one that replaced it, which is the only thing this file is about.
    ///
    /// Two directional readings carry it instead. The open field takes the bar's whole track, so its
    /// trailing half is a stretch of empty box and must hold *substantially less* ink than the bar it
    /// replaced; and the last 40pt — where the trailing-pinned bar ends, and where Search sits as the
    /// last item — must hold **nothing at all**, because what is there while the field is open is the
    /// `Color.clear` dismissal area. A bar drawn alongside the field fails both.
    ///
    /// The collapsed readings are the vacuity guards, deliberately loose: they say the crops are
    /// where the bar is, and the zero above them is the claim.
    @Test func testTheFieldReplacesTheBarRatherThanJoiningIt() throws {
        let collapsed = try Self.rendered(expanded: false, query: "")
        let expanded = try Self.rendered(expanded: true, query: "invoice")

        #expect(Self.ink(collapsed) > 1000, "the collapsed bar draws almost nothing — this comparison would be vacuous")
        #expect(Self.ink(expanded) * 2 < Self.ink(collapsed),
                "the open field's half of the header carries \(Self.ink(expanded)) px against the bar's \(Self.ink(collapsed)) — the bar has not gone away, so the magnifier can be on screen beside a live query")

        #expect(Self.ink(collapsed, trailing: 40) > 100, "the bar's last 40pt are empty even collapsed — this crop is not where Search sits")
        #expect(Self.ink(expanded, trailing: 40) == 0,
                "\(Self.ink(expanded, trailing: 40)) px are painted where the bar's trailing rung sits while the field is open — the bar is being drawn beside it")
    }

    // MARK: - Fixtures

    private static func header(expanded: Bool, query: String, canSearch: Bool = true) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
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
        let size = CGSize(width: 700, height: LiquidGlass.headerHeight)
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

    /// Pixels that depart from the background at all, over the bar's half of the header — or, given
    /// `trailing:`, over that many points at its trailing edge.
    private static func ink(_ rep: NSBitmapImageRep, trailing points: Double? = nil) -> Int {
        let from = points.map { rep.pixelsWide - Int($0 * Double(rep.pixelsWide) / 700.0) }
            ?? rep.pixelsWide / 2
        var hits = 0
        for x in from..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if px.redComponent < 0.72 || px.greenComponent < 0.72 || px.blueComponent < 0.72 { hits += 1 }
            }
        }
        return hits
    }
}
