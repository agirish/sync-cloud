import Testing
import SwiftUI
import AppKit
import Design
import FileExplorer
import Sync
import Dashboard
@testable import SyncCloud

/// **What a brand mark measures when an AppKit-backed control draws it.**
///
/// `PaneHeader`'s retired provider capsule carried the warning in prose from the day it was written
/// — "the logo stays a plain image OUTSIDE the menu label (a resizable image inside one balloons to
/// its native size)" — and prose is exactly what a later change walks past. Retiring the capsule put
/// `ProviderLogo` inside a `ProviderMenu` label and shipped a pane header with the source's mark
/// drawn across the whole pane and the nav bar pushed clean off the row.
///
/// Nothing caught it, and the reason is worth pinning as hard as the behaviour: **the brand assets
/// live in `MacApp/Assets.xcassets`, which no SPM test target can see.** From `Modules/Dashboard`'s
/// tests `NSImage(named: "googledrive")` is nil, `ProviderLogo` takes its SF-Symbol branch, and a
/// symbol is sized by font rather than by the asset — so every snapshot measured a stand-in for the
/// one thing that broke, and ten reference images were re-recorded against it.
///
/// So these live in the app target, and they measure `fittingSize` rather than pixels: the failure
/// was a *layout* failure — the label's ideal width is what shoved the row apart — so the width the
/// row would be offered is the honest measurement, and it needs no window, no display and no
/// screen-recording permission. Two earlier attempts at a guard measured neither: one asserted the
/// width inside a wrapper that pinned the width, and one compared ink against a host that clips it.
@MainActor
struct MenuLabelMarkTests {

    /// Without this the whole file is a statement about `folder.fill`. First, and loud.
    @Test func theBrandAssetsAreReachableFromThisTarget() {
        for name in ["googledrive", "icloud", "dropbox", "onedrive"] {
            #expect(NSImage(named: name) != nil,
                    "\(name) is not in this target's catalog — every measurement here would be of an SF Symbol")
        }
    }

    private static let sources = [
        CloudProvider(id: "gd", displayName: "Google Drive (EMP)", imageName: "googledrive",
                      rootPath: "/tmp/gd", openAt: "My Drive", type: .googleDrive),
        CloudProvider(id: "ic", displayName: "iCloud", imageName: "icloud",
                      rootPath: "/tmp/ic", type: .iCloud)
    ]

    /// The width SwiftUI would ask for, with **nothing constraining it**. A wrapper that pins a
    /// frame reports the frame back and measures nothing.
    private func idealWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    private func menu<L: View>(@ViewBuilder label: () -> L) -> some View {
        ProviderMenu(providers: Self.sources, currentId: "gd",
                     onSelect: { _ in }, onManage: {}, onChooseFolder: nil, label: label)
    }

    /// **The mechanism, kept alive so the fix cannot quietly stop mattering.** These assets are 512pt
    /// on the long edge; a resizable image in an AppKit-drawn label draws at exactly that, whatever
    /// frame surrounds it.
    ///
    /// Asserted as "at least ten times what it asked for" rather than against 531 precisely: the
    /// number is the artwork's, and re-exporting the artwork should not fail this test — the claim
    /// is that the frame is ignored, not that it is ignored by a particular amount.
    @Test func aResizableMarkInsideAMenuLabelIgnoresItsFrame() {
        let asked: CGFloat = 15
        let width = idealWidth(menu { ProviderLogo("googledrive", size: asked) })
        #expect(width > asked * 10,
                "a resizable mark in a menu label measured \(width) for a \(asked)pt request — if this is now small, `inAppKitLabel` is no longer buying anything and the tests below have stopped discriminating")
    }

    /// And the fix: the same mark, same size, built at a fixed intrinsic size instead.
    ///
    /// The bound is the mark plus the menu's own chrome, which is why it is not `asked` exactly.
    @Test func aPresizedMarkInsideAMenuLabelIsTheSizeItWasAsked() {
        for name in ["googledrive", "icloud", "dropbox", "onedrive"] {
            let width = idealWidth(menu { ProviderLogo(name, size: 15, inAppKitLabel: true) })
            #expect(width < 45, "\(name) measured \(width) in a menu label — it is drawing at its native size")
        }
    }

    /// **The catalog's own image is not resized.** `NSImage(named:)` hands back a shared instance;
    /// setting `size` on that one would shrink the mark everywhere else in the app — Settings, the
    /// single-source rail, the Browse sidebar.
    @Test func presizingAMarkLeavesTheCatalogsCopyAlone() throws {
        let before = try #require(NSImage(named: "googledrive")).size
        _ = idealWidth(menu { ProviderLogo("googledrive", size: 15, inAppKitLabel: true) })
        let after = try #require(NSImage(named: "googledrive")).size
        #expect(before == after, "the catalog's shared image went from \(before) to \(after)")
    }

    /// The whole point, end to end: **the header the app actually builds does not blow up.**
    ///
    /// Built through `PaneHeader` rather than `PaneBreadcrumb` directly, because `PaneBreadcrumb` is
    /// internal to `Dashboard` and — more to the point — the header is what assembles the picker
    /// from a `CloudProvider`. A test that hand-built the crumb would go green against a header that
    /// had stopped passing one.
    ///
    /// **The bound is not "fits a 250pt pane", and that is deliberate.** `fittingSize` is the
    /// *ideal* width, and a breadcrumb whose crumbs middle-truncate legitimately wants more than the
    /// pane it will compress into: this header measures 260 for a two-deep trail on a source called
    /// "Google Drive (EMP)". What the mark's regression does is not a few points over — it puts the
    /// asset's own 512 into the row, so the broken header measures north of 700. 400 separates the
    /// two with room, and **the separation is verified by mutation, not assumed**: flipping
    /// `inAppKitLabel` off in `PaneBreadcrumb.rootCrumb` fails this test at 757.
    ///
    /// Whether the bar still *fits* its pane is a different question with its own suite —
    /// `PaneBarLadderTests` bounds the drawn bar against the pane's trailing edge at every rung.
    ///
    /// **A narrow-pane version of this was written and deleted, because it passed with the bug.**
    /// It rendered the header at the split's 250pt floor and asserted that no control's focus ring
    /// ended past the content edge. With the mark drawing at 512 that assertion still held: the
    /// crumbs truncate and the row compresses, so the overflow shows up as content squeezed to
    /// nothing rather than as geometry past the edge. An ideal-width bound is what sees this, which
    /// is why it is the one kept.
    @Test func theHeaderCarryingASourcePickerDoesNotBlowUpTheRow() {
        let width = idealWidth(Self.header(relativePath: "Taxes/2026"))
        #expect(width < 400,
                "the pane header wants \(width)pt of ideal width — the source's mark is drawing at its native size")
    }

    @MainActor
    private static func header(relativePath: String, provider: CloudProvider? = sources[0]) -> some View {
        PaneHeader(
            title: "Left",
            provider: provider,
            rootPath: provider?.rootPath ?? "/tmp/none",
            relativePath: relativePath,
            canGoBack: true,
            canGoForward: false,
            onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in },
            providers: sources,
            onSelectProvider: { _ in },
            onManageProviders: {},
            onChooseFolder: nil,
            sortOption: .constant(.name),
            showHiddenFiles: .constant(false)
        )
    }
}
