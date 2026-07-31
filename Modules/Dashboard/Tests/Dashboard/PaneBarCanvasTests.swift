import AppKit
import SwiftUI
import Testing
import Sync
@testable import Dashboard
import Design

/// The bar as a *canvas*: the claim that a control can sit anywhere between the provider capsule and
/// the pane's trailing edge, rather than only at the trailing edge.
///
/// These measure the laid-out result — where the controls actually end up in the window — not the
/// arrangement string that was supposed to produce it. An arrangement that parses correctly and then
/// renders right-aligned anyway is exactly the bug this feature could ship with, and only geometry
/// can see it.
@MainActor
@Suite(.serialized) struct PaneBarCanvasTests {

    private static let width: CGFloat = 560
    /// The header's own horizontal padding, so "at the trailing edge" is a number rather than a feel.
    private static let edgeInset: CGFloat = 14

    /// Every laid-out control's frame in the header's coordinates.
    ///
    /// By `_FocusRingView`, as in `PaneHeaderHeightTests`: a SwiftUI `Button` with a custom style
    /// draws into a layer and puts no `NSControl` in the AppKit tree at all, so the focus rings are
    /// the only handle on where a pill physically is.
    private static func controlFrames(_ view: some View, width: CGFloat = width) -> [CGRect] {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var frames: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") {
                frames.append(v.convert(v.bounds, to: host))
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        return frames
    }

    /// A header whose arrangement is injected, the way `DashboardSnapshotTests` injects the preview
    /// setting: `PaneHeader` reads the bar from `@AppStorage`, so without this the test would render
    /// from whatever the host machine's standard domain happens to hold.
    private static func header(_ arrangement: PaneBarArrangement,
                               iconSize: PaneBarIconSize = .regular) -> some View {
        let defaults = ScratchDefaults("PaneBarCanvasTests")
        defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(iconSize.rawValue, forKey: PaneBar.iconSizeKey)
        return PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {})
        .defaultAppStorage(defaults)
    }

    /// The bar's own controls, by row rather than by position.
    ///
    /// The header has two focusable rows — the bar, and the breadcrumb's crumbs below it — and the
    /// crumbs start at the leading padding, so any filter based on *x* silently swallows them. (It
    /// did: a first pass at these tests measured a "bar" that ran from the first crumb to the last
    /// pill and reported the trailing edge no matter what the arrangement said.) The bar is the
    /// higher row, so its rings share the smallest `minY`, and the provider capsule is an
    /// AppKit-hosted menu rather than a focus ring — it never appears here at all.
    private static func barFrames(_ arrangement: PaneBarArrangement,
                                  iconSize: PaneBarIconSize = .regular,
                                  width: CGFloat = width) -> [CGRect] {
        let frames = controlFrames(header(arrangement, iconSize: iconSize), width: width)
        guard let top = frames.map(\.minY).min() else { return [] }
        return frames.filter { abs($0.minY - top) < 2 }
    }

    // MARK: The claim

    @Test func testTheDefaultArrangementStillHugsTheTrailingEdge() {
        // At 560 this proves nothing: the default bar is nine pills wide and fills that row whatever
        // the layout does, so it "ends at the trailing edge" even with the flexible space rendering
        // as nothing at all. (Measured — a mutant that made `flexibleSpace` an `EmptyView` passed
        // this test and every snapshot.) It has to be asked in a pane roomy enough for the bar to be
        // somewhere *else*.
        let roomy: CGFloat = 800
        let frames = Self.barFrames(.default, width: roomy)
        let trailing = frames.map(\.maxX).max() ?? 0
        #expect(abs(trailing - (roomy - Self.edgeInset)) < 8,
                "the default bar should end at the pane's trailing edge, but ended at \(trailing)")
    }

    @Test func testDroppingTheFlexibleSpacePacksTheBarLeft() {
        // The mid-turn ask, as geometry. Measured in a roomy pane, where there is real slack for the
        // bar to be somewhere in: the same controls, in the same order, land ~300pt further left once
        // the flexible space is gone, and the row's whole trailing half is empty.
        let controls: [PaneBarItem] =
            [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview]
        let roomy: CGFloat = 800
        let packed = Self.barFrames(PaneBarArrangement(controls), width: roomy)
        let pinned = Self.barFrames(PaneBarArrangement([.flexibleSpace] + controls), width: roomy)

        let packedLeading = packed.map(\.minX).min() ?? 0
        let pinnedLeading = pinned.map(\.minX).min() ?? 0
        #expect(packedLeading < pinnedLeading - 200,
                "the bar barely moved: left-packed starts at \(packedLeading), pinned at \(pinnedLeading)")
        // Not "in the leading half" — a nine-pill bar is ~330pt wide and would fail that on width
        // alone. The claim is that its trailing end stops well short of the pane's edge.
        #expect((packed.map(\.maxX).max() ?? roomy) < roomy - Self.edgeInset - 200,
                "a left-packed bar still ran to the pane's trailing edge")
        #expect(abs((pinned.map(\.maxX).max() ?? 0) - (roomy - Self.edgeInset)) < 8,
                "the pinned bar should still end at the trailing edge")
    }

    @Test func testMovingTheFlexibleSpaceSplitsTheBar() {
        // Arrangement B from the mockups: navigation to hand, actions out of the way. The split is
        // visible as a gap wider than the 6pt the bar puts between neighbouring pills.
        let split = PaneBarArrangement([.viewMode, .backForward, .flexibleSpace, .scan, .sort])
        let frames = Self.barFrames(split).sorted { $0.minX < $1.minX }
        let gaps = zip(frames, frames.dropFirst()).map { $1.minX - $0.maxX }
        #expect((gaps.max() ?? 0) > 60, "no gap in the middle of the bar — the flexible space did nothing")
        #expect(frames.last.map { abs($0.maxX - (Self.width - Self.edgeInset)) < 8 } ?? false,
                "the items after the flexible space should still reach the trailing edge")
    }

    @Test func testPlacementDoesNotCostControls() {
        // Moving the bar left must not quietly drop anything: same arrangement, same control count,
        // different place.
        let arrangement: [PaneBarItem] =
            [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview]
        #expect(Self.barFrames(PaneBarArrangement(arrangement)).count
                == Self.barFrames(PaneBarArrangement([.flexibleSpace] + arrangement)).count)
    }

    // MARK: Removal and the overflow

    @Test func testARemovedControlLeavesTheBarButKeepsAnOverflowPill() {
        let full = Self.barFrames(.default).count
        let trimmed = Self.barFrames(
            PaneBarArrangement([.flexibleSpace, .viewMode, .backForward, .scan]))
        // Four controls gone (New Folder, Sort, Hidden Files, Preview), one ⋯ gained.
        #expect(trimmed.count == full - 3,
                "removing four controls and gaining ⋯ should net three fewer pills, got \(trimmed.count) vs \(full)")
    }

    // MARK: Icon size

    @Test func testChoosingSmallIconsStartsTheLadderLower() {
        // A ceiling, not a pin: at a width where Regular fits comfortably, choosing Small still gets
        // you the `.mini` pill rather than being overridden back up.
        let regular = Self.barFrames(.default, iconSize: .regular).map(\.width).max() ?? 0
        let small = Self.barFrames(.default, iconSize: .small).map(\.width).max() ?? 0
        #expect(small < regular, "Small icons rendered at \(small), Regular at \(regular)")
    }
}
