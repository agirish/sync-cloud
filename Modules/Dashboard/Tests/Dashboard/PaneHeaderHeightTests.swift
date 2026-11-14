import AppKit
import SwiftUI
import Testing
import Sync
@testable import Dashboard
import Design
import FileExplorerTestSupport

/// Measures a view the way AppKit will, in a real (never-ordered-in) window. The identical helper
/// lives in Modules/Design/Tests/DesignTests/LensHeaderCardTests.swift: SPM offers no clean way to
/// share test-support code across packages without a production library product. It measures the
/// laid-out result, because asserting constants against each other can't see a view that ignores
/// them.
@MainActor
private func laidOutHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
    host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

/// The pane side of the shared header line. `LensHeaderCardTests.restsAt81Visible` pins the other
/// side to the same `LiquidGlass.headerHeight`, so "both land on 83.5" is checked, not drawn.
@MainActor
@Suite(.serialized) struct PaneHeaderHeightTests {

    /// The header rests at `headerHeight` at every width the pane can be, narrow ones included,
    /// where an unpinned header would shrink and break the line.
    @Test(arguments: [CGFloat(560), CGFloat(400), CGFloat(250)])
    func restsAtHeaderHeightAtEveryWidth(width: CGFloat) {
        #expect(laidOutHeight(Self.header(providerName: "iCloud Drive"), width: width)
                == LiquidGlass.headerHeight)
    }

    /// A long source name in a narrow pane changes what's in the header (the name truncates, the
    /// bar steps to `.mini`), never how tall it is.
    @Test func longProviderNameNarrowHoldsHeight() {
        #expect(laidOutHeight(Self.header(providerName: "Marketing Team Shared Archive Drive"),
                              width: 250) == LiquidGlass.headerHeight)
    }

    /// No provider at all: the state with the least content, so the likeliest to shrink.
    @Test func sparseStateHoldsHeight() {
        #expect(laidOutHeight(Self.header(providerName: nil), width: 560) == LiquidGlass.headerHeight)
    }

    /// The line itself: the pane header's bottom edge, in the pane's coordinates, is the card inset
    /// plus the header, 83.5. `LensHeaderCard`'s visible bottom edge lands on the same number from
    /// the other side of the window.
    @Test func headerBottomEdgeLandsOn83Point5() {
        let bottomEdge = LiquidGlass.cardInset + laidOutHeight(
            Self.header(providerName: "iCloud Drive"), width: 560)
        #expect(bottomEdge == 83.5)
    }

    /// A full Columns bar costs the header no height at any width: where the controls don't fit,
    /// the ladder folds them into ⋯ rather than letting the row grow.
    @Test(arguments: [CGFloat(560), CGFloat(400), CGFloat(250)])
    func aFullBarCostsNoHeight(width: CGFloat) {
        #expect(laidOutHeight(Self.header(mode: .columns, newFolder: true), width: width) == LiquidGlass.headerHeight)
    }

    /// Both modes draw the same controls. The second half keeps that from being vacuous: a header
    /// with no view-mode switch draws strictly fewer, so "equal" means both drew the switch, not
    /// that both lost it.
    @Test func bothModesDrawTheSameControls() {
        let columns = Self.buttonCount(Self.header(mode: .columns, newFolder: true), width: 560)
        let tree = Self.buttonCount(Self.header(mode: .tree, newFolder: true), width: 560)
        let noSwitch = Self.buttonCount(Self.header(newFolder: true), width: 560)
        #expect(columns == tree)
        #expect(tree > noSwitch)
    }

    // MARK: Fixtures

    /// Counts the header's laid-out controls, the rendered result rather than the branch meant to
    /// produce it. By `_FocusRingView`, not `NSControl`: a custom-styled SwiftUI `Button` puts no
    /// control in the AppKit tree (only the AppKit-backed menus appear), while focus rings come one
    /// per focusable control.
    @MainActor
    private static func buttonCount<V: View>(_ view: V, width: CGFloat) -> Int {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return FocusRings.count(in: host)
    }

    /// A header identical in every argument but these: `providerName` nil drops the provider,
    /// `mode` adds the view-mode switch, `newFolder` the New Folder control.
    private static func header(providerName: String? = "iCloud Drive", mode: PaneViewMode? = nil,
                               newFolder: Bool = false) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: providerName.map {
                CloudProvider(id: "icloud", displayName: $0, imageName: "icloud-logo",
                              rootPath: "/Users/test/iCloud", type: .iCloud)
            },
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: mode.map { .constant($0) }, onNewFolder: newFolder ? {} : nil)
    }
}
