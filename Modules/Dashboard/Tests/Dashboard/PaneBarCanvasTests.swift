import AppKit
import SwiftUI
import Testing
import Sync
@testable import Dashboard
import Design
import FileExplorerTestSupport

/// The bar as a canvas: a control can sit anywhere along the pane's row, from its leading inset to
/// its trailing one, not only at the trailing edge.
///
/// These measure where the controls end up in the window, not the arrangement string meant to
/// produce it: an arrangement that parses correctly and still renders right-aligned is visible
/// only in the geometry.
@MainActor
@Suite(.serialized) struct PaneBarCanvasTests {

    private static let width: CGFloat = 560
    /// The header's own horizontal padding, so "at the trailing edge" is a number rather than a feel.
    private static let edgeInset: CGFloat = 14

    /// Every laid-out control's frame in the header's coordinates, found by `_FocusRingView` as in
    /// `PaneHeaderHeightTests`: a custom-styled SwiftUI `Button` puts no `NSControl` in the AppKit
    /// tree, so the focus rings are the only handle on where a pill is.
    private static func controlFrames(_ view: some View, width: CGFloat = width) -> [CGRect] {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let frames = FocusRings.frames(in: host)
        return frames
    }

    /// A header with an injected arrangement. `PaneHeader` reads the bar from `@AppStorage`, so
    /// without this the test would render whatever the host machine's standard domain holds.
    private static func header(_ arrangement: PaneBarArrangement,
                               iconSize: PaneBarIconSize = .regular) -> some View {
        let defaults = ScratchDefaults("PaneBarCanvasTests")
        defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(iconSize.rawValue, forKey: PaneBar.iconSizeKey)
        return PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {})
        .defaultAppStorage(defaults)
    }

    /// The bar's own controls, picked by row, not position. The header has two focusable rows, the
    /// bar and the breadcrumb's crumbs below it, and the crumbs also start at the leading padding,
    /// so a filter on x would swallow them. The bar is the higher row: its rings share the smallest
    /// `minY`. The first crumb never appears here: it is the source chip, an AppKit-hosted `Menu`,
    /// and only buttons carry a focus ring.
    private static func barFrames(_ arrangement: PaneBarArrangement,
                                  iconSize: PaneBarIconSize = .regular,
                                  width: CGFloat = width) -> [CGRect] {
        let frames = controlFrames(header(arrangement, iconSize: iconSize), width: width)
        guard let top = frames.map(\.minY).min() else { return [] }
        return frames.filter { abs($0.minY - top) < 2 }
    }

    // MARK: The claim

    /// The default bar starts at the pane's leading edge. Asked in a roomy pane: at 560 the default
    /// bar fills the row whatever the layout does, so it would pass whether it packed left or
    /// right.
    @Test func testTheDefaultArrangementNowPacksAgainstTheLeadingEdge() {
        let roomy: CGFloat = 800
        let frames = Self.barFrames(.default, width: roomy)
        let leading = frames.map(\.minX).min() ?? roomy
        #expect(leading < Self.edgeInset + 24,
                "the default bar should start at the pane's leading edge, but started at \(leading)")
        // The half that catches a bar that merely grew: it stops well short of the trailing edge.
        #expect((frames.map(\.maxX).max() ?? roomy) < roomy - Self.edgeInset - 200,
                "the default bar still runs to the pane's trailing edge")
    }

    @Test func testDroppingTheFlexibleSpacePacksTheBarLeft() {
        // In a roomy pane with real slack, the same controls in the same order land far further left
        // once the leading flexible space is gone.
        let controls: [PaneBarItem] =
            [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles]
        let roomy: CGFloat = 800
        let packed = Self.barFrames(PaneBarArrangement(controls), width: roomy)
        let pinned = Self.barFrames(PaneBarArrangement([.flexibleSpace] + controls), width: roomy)

        let packedLeading = packed.map(\.minX).min() ?? 0
        let pinnedLeading = pinned.map(\.minX).min() ?? 0
        #expect(packedLeading < pinnedLeading - 200,
                "the bar barely moved: left-packed starts at \(packedLeading), pinned at \(pinnedLeading)")
        // Not "in the leading half", which a wide bar fails on width alone: its trailing end stops
        // well short of the pane's edge.
        #expect((packed.map(\.maxX).max() ?? roomy) < roomy - Self.edgeInset - 200,
                "a left-packed bar still ran to the pane's trailing edge")
        #expect(abs((pinned.map(\.maxX).max() ?? 0) - (roomy - Self.edgeInset)) < 8,
                "the pinned bar should still end at the trailing edge")
    }

    @Test func testMovingTheFlexibleSpaceSplitsTheBar() {
        // Navigation to hand, actions out of the way. The split shows as a gap far wider than the
        // 6pt between neighbouring pills.
        let split = PaneBarArrangement([.viewMode, .backForward, .flexibleSpace, .scan, .sort])
        let frames = Self.barFrames(split).sorted { $0.minX < $1.minX }
        let gaps = zip(frames, frames.dropFirst()).map { $1.minX - $0.maxX }
        #expect((gaps.max() ?? 0) > 60, "no gap in the middle of the bar — the flexible space did nothing")
        #expect(frames.last.map { abs($0.maxX - (Self.width - Self.edgeInset)) < 8 } ?? false,
                "the items after the flexible space should still reach the trailing edge")
    }

    @Test func testPlacementDoesNotCostControls() {
        // Moving the bar left must not quietly drop a control.
        let arrangement: [PaneBarItem] =
            [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles]
        #expect(Self.barFrames(PaneBarArrangement(arrangement)).count
                == Self.barFrames(PaneBarArrangement([.flexibleSpace] + arrangement)).count)
    }

    // MARK: Removal and the overflow

    /// A removed control takes its pill with it, and no ⋯ appears to hold it. Measured as pills, not
    /// in the plan, because a ⋯ is a real pill taking real width from a bar trimmed to make room.
    @Test func testARemovedControlTakesItsPillWithIt() {
        let full = Self.barFrames(.default).count
        let trimmed = Self.barFrames(
            PaneBarArrangement([.flexibleSpace, .viewMode, .backForward, .scan]))
        // Three controls gone (New Folder, Sort, Hidden Files) and nothing gained.
        #expect(trimmed.count == full - 3,
                "removing three controls should net three fewer pills, got \(trimmed.count) vs \(full) — a ⋯ came back")
    }

    // MARK: Icon size

    @Test func testChoosingSmallIconsStartsTheLadderLower() {
        // A ceiling, not a pin: where Regular fits comfortably, choosing Small still gets the
        // `.mini` pill.
        let regular = Self.barFrames(.default, iconSize: .regular).map(\.width).max() ?? 0
        let small = Self.barFrames(.default, iconSize: .small).map(\.width).max() ?? 0
        #expect(small < regular, "Small icons rendered at \(small), Regular at \(regular)")
    }
}
