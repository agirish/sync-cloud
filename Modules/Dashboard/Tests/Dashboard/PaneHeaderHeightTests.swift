import AppKit
import SwiftUI
import Testing
import Sync
@testable import Dashboard
import Design

/// Measures a view the way AppKit will, in a real (never-ordered-in) window. The identical helper
/// lives in Modules/Design/Tests/DesignTests/LensHeaderCardTests.swift — SPM offers no clean way
/// to share test-support code across packages without minting a production library product.
///
/// It measures the LAID-OUT result on purpose: the card-gap regression in `4b1f611` survived 523
/// green tests because the suite asserted constants against each other while the view that was
/// meant to read them didn't.
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
/// side to the same `LiquidGlass.headerHeight`; together they are what make "both land on 83.5" a
/// checked property rather than a drawing.
@MainActor
@Suite(.serialized) struct PaneHeaderHeightTests {

    /// Every width the pane can be, including the ones that used to collapse the header. Before it
    /// was pinned this measured 80 / 80 / 68 — the narrow pane silently broke the line by 13pt,
    /// which is precisely the drift the constant exists to stop.
    @Test(arguments: [CGFloat(560), CGFloat(400), CGFloat(250)])
    func restsAtHeaderHeightAtEveryWidth(width: CGFloat) {
        #expect(laidOutHeight(Self.header(providerName: "iCloud Drive"), width: width)
                == LiquidGlass.headerHeight)
    }

    /// The long-name degradation ladder (logo drops, name truncates, nav steps to `.mini`) changes
    /// what's IN the header, never how tall it is.
    @Test func longProviderNameNarrowHoldsHeight() {
        #expect(laidOutHeight(Self.header(providerName: "Marketing Team Shared Archive Drive"),
                              width: 250) == LiquidGlass.headerHeight)
    }

    /// No provider at all — the state with the least content, and the one that measured
    /// shortest (66) before the pin.
    @Test func sparseStateHoldsHeight() {
        #expect(laidOutHeight(Self.headerNoProvider(), width: 560) == LiquidGlass.headerHeight)
    }

    /// The line itself: the pane header's bottom edge, in the pane's own coordinates, is the card
    /// inset plus the header — 83.5. `LensHeaderCard`'s visible bottom edge lands on the same
    /// number from the other side of the window.
    @Test func headerBottomEdgeLandsOn83Point5() {
        let bottomEdge = LiquidGlass.cardInset + laidOutHeight(
            Self.header(providerName: "iCloud Drive"), width: 560)
        #expect(bottomEdge == 83.5)
    }

    /// The preview toggle is an EIGHTH control in a cluster that was already at the edge of what a
    /// 250pt pane holds — the rung ladder exists because 159pt of controls sit in a 222pt box. It
    /// must therefore cost the header no height at any width: `ViewThatFits` should fold it into ⋯
    /// rather than let the row grow.
    @Test(arguments: [CGFloat(560), CGFloat(400), CGFloat(250)])
    func previewToggleCostsNoHeight(width: CGFloat) {
        #expect(laidOutHeight(Self.paneHeader(), width: width) == LiquidGlass.headerHeight)
    }

    /// And it genuinely renders: a Columns header draws one more control than the same header in Tree
    /// mode, where there is no preview for a toggle to govern.
    ///
    /// Mode is now the *whole* gate. The header used to take an `isSingleSource` and withhold the
    /// toggle from comparison panes, which is why there was a second test here asserting a comparison
    /// header drew one control fewer. That input is gone rather than merely ignored — a comparison
    /// header and the rail's are the same value now, so the property this suite could assert about
    /// them is a tautology, and the surface-independence is instead carried by the type having no
    /// surface to be told about. What a comparison pane does with the setting is asserted where it is
    /// observable: `ColumnPreviewLayoutTests.testAComparisonPaneGetsThePreviewToo`.
    @Test func aColumnsHeaderDrawsTheExtraControl() {
        let columns = Self.buttonCount(Self.paneHeader(mode: .columns), width: 560)
        let tree = Self.buttonCount(Self.paneHeader(mode: .tree), width: 560)
        #expect(columns == tree + 1)
    }

    // MARK: Fixtures

    /// Counts the header's laid-out controls — the rendered result, not the branch that was meant to
    /// produce it.
    ///
    /// By `_FocusRingView`, not by `NSControl`: a SwiftUI `Button` with a custom style draws into a
    /// layer and puts no control in the AppKit tree at all (every variant of this header reports the
    /// same three `NSControl`s — the AppKit-backed menus — whatever else is on screen). The focus
    /// rings are one per focusable control and do track, which is the same handle
    /// `FoldAllAction`'s test had to reach for.
    @MainActor
    private static func buttonCount<V: View>(_ view: V, width: CGFloat) -> Int {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var count = 0
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("_FocusRingView") { count += 1 }
            for sub in v.subviews { walk(sub) }
        }
        walk(host)
        return count
    }

    /// A pane header carrying the view-mode switch — the only kind that can offer the preview toggle.
    private static func paneHeader(mode: PaneViewMode = .columns) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(mode), onNewFolder: {})
    }

    private static func headerNoProvider() -> PaneHeader {
        PaneHeader(title: "Left", provider: nil, rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
                   canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
                   onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
                   onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false))
    }

    private static func header(providerName: String) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: providerName, imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false))
    }
}
