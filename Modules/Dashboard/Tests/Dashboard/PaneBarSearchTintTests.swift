import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard
import FileExplorerTestSupport

/// Why the Search rung needs no "a query is live" tint, pinned as the invariant rather than as an
/// absence. The magnifier is drawn only while the field is collapsed, and collapsing always clears
/// the query, so a filter running behind a hidden field can't occur. A change that lets a query
/// outlive its field fails here, saying the tint is needed again.
@MainActor
@Suite(.serialized) struct PaneBarSearchTintTests {

    /// Collapsing clears the query, in one transaction: the whole invariant.
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

    /// The rung is offered only where the host can search. Both directions, since a gate that always
    /// says no looks like one never wired.
    @Test func testTheRungIsOfferedOnlyWhenTheHostCanSearch() {
        #expect(Self.header(expanded: false, query: "").availableItems.contains(.search))
        #expect(!Self.header(expanded: false, query: "", canSearch: false).availableItems.contains(.search))
    }

    /// The magnifier and the field are alternatives, never both; a magnifier beside an open field
    /// would break "collapsed implies empty". A field that joined the bar would carry more controls
    /// and more ink on the row than the bar alone, and one that replaced it carries less, so both
    /// are compared. The control count is exact: each pill hosts a `_FocusRingView`, and the row
    /// loses most of them when the field opens. The collapsed readings are loose vacuity guards.
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
        let frames = FocusRings.frames(in: host)
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

    /// The same 700-point, pinned-arrangement, aqua render `PaneBarDeleteTests` measures.
    private static func rendered(expanded: Bool, query: String) throws -> NSBitmapImageRep {
        try PaneBarDeleteTests.rendered(header(expanded: expanded, query: query))
    }

    /// Pixels that depart from the background at all over the bar's row, the upper half of the
    /// header, which is what the field takes over. Cropped by row, since the bar packs left.
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
